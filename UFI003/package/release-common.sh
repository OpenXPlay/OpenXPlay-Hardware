#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Sourced by the release workflow and its offline tests. No device commands run here.

ufi003_release_fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# Sets RELEASE_VERSION (display), DEBVERSION (payload/filename) and PRERELEASE.
ufi003_release_version() {
    PRERELEASE=false
    case "$1" in
        workflow_dispatch)
            case "$3" in ''|*[!0-9a-f]*) ufi003_release_fail 'Invalid commit SHA' ;; esac
            printf '%s\n' "$3" | grep -Eq '^[0-9a-f]{40}$' ||
                ufi003_release_fail 'Expected a full commit SHA for a manual build'
            DEBVERSION=0.0.0~dev.$(printf '%.7s' "$3")
            RELEASE_VERSION=$DEBVERSION
            ;;
        push)
            case "$2" in
                refs/tags/ufi003-device-v*) RELEASE_VERSION=${2#refs/tags/ufi003-device-v} ;;
                *) ufi003_release_fail "Not a UFI003 device tag: $2" ;;
            esac
            # SemVer core and prerelease identifiers; build metadata is not a release tag.
            case "$RELEASE_VERSION" in
                ''|*[!0-9A-Za-z.-]*) ufi003_release_fail "Invalid UFI003 device version: $RELEASE_VERSION" ;;
            esac
            ufi003_number='(0|[1-9][0-9]*)'
            ufi003_identifier="($ufi003_number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
            printf '%s\n' "$RELEASE_VERSION" | LC_ALL=C grep -Eq \
                "^$ufi003_number\\.$ufi003_number\\.$ufi003_number(-$ufi003_identifier(\\.$ufi003_identifier)*)?$" ||
                ufi003_release_fail "Invalid UFI003 device version: $RELEASE_VERSION"
            case "$RELEASE_VERSION" in *-*) PRERELEASE=true ;; esac
            DEBVERSION=$(printf '%s' "$RELEASE_VERSION" | sed 's/-/~/')
            ;;
        *) ufi003_release_fail "Unsupported release event: $1" ;;
    esac
}

ufi003_release_curl() {
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 20 --max-time 180 "$@"
}

# Fetch only binaries. build-bundle.sh records the corresponding sources in SOURCES.txt.
ufi003_fetch_debs() (
    set -eu
    pins=$1
    debs=$2
    mkdir -p "$debs"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    while read -r pkg version digest extra; do
        case "$pkg" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] && printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' ||
            ufi003_release_fail "Invalid debs.txt row: $pkg"
        printf '%s\n' "$version" | grep -Eq '^[0-9][0-9A-Za-z.+:~_-]*$' ||
            ufi003_release_fail "Invalid pinned version: $pkg $version"
        # Binary names do not necessarily name their source package/pool directory.
        case "$pkg" in
            libasound2|libasound2-data) source=alsa-lib ;;
            libelf1|libdw1) source=elfutils ;;
            libnl-3-200|libnl-genl-3-200) source=libnl3 ;;
            iw|bluez) source=$pkg ;;
            *) ufi003_release_fail "Add a source-package mapping for $pkg" ;;
        esac
        case "$source" in
            lib*) prefix=$(printf '%.4s' "$source") ;;
            *) prefix=$(printf '%.1s' "$source") ;;
        esac
        arch=arm64
        [ "$pkg" != libasound2-data ] || arch=all
        filename=${pkg}_${version}_${arch}.deb
        part=$debs/$filename.part
        pool=main/$prefix/$source/$filename
        fetched=false
        # Search pools, not suites: bluez +deb11u1 may be a security or updates upload.
        for archive in https://archive.debian.org/debian/pool \
                       https://archive.debian.org/debian-security/pool/updates; do
            if ufi003_release_curl --output "$part" "$archive/$pool"; then
                fetched=true
                break
            fi
        done
        if [ "$fetched" = false ]; then
            encoded_version=$(jq -nr --arg version "$version" '$version | @uri')
            ufi003_release_curl --output "$work/binaries.json" \
                "https://snapshot.debian.org/mr/binary/$pkg/$encoded_version/binfiles" ||
                ufi003_release_fail "Cannot locate $filename on snapshot.debian.org"
            hash=$(jq -er --arg arch "$arch" '
                [.result[] | select(.architecture == $arch) | .hash] | unique |
                if length == 1 then .[0] else error("Expected one binary for architecture") end
                ' "$work/binaries.json") || ufi003_release_fail "Ambiguous snapshot binary: $filename"
            printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{40}$' ||
                ufi003_release_fail "Invalid snapshot file hash: $filename"
            ufi003_release_curl --output "$part" "https://snapshot.debian.org/file/$hash" ||
                ufi003_release_fail "Cannot download $filename from snapshot.debian.org"
        fi
        # Never fall back after a digest mismatch, even if the HTTP request succeeded.
        printf '%s  %s\n' "$digest" "$part" | sha256sum -c - ||
            ufi003_release_fail "SHA-256 mismatch: $filename"
        mv "$part" "$debs/$filename"
    done < "$pins"
)

# Checks a copy in a disposable directory; never extracts beside the release files.
ufi003_check_bundle() (
    set -eu
    version=$1
    name=openxplay-ufi003-device-$version
    bundle=$2/$name.tar.gz
    [ -f "$bundle" ] || ufi003_release_fail "Missing expected bundle: $bundle"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    tar -tzf "$bundle" > "$work/entries" || ufi003_release_fail 'Cannot list bundle'
    [ "$(cut -d / -f 1 "$work/entries" | LC_ALL=C sort -u)" = "$name" ] ||
        ufi003_release_fail 'Bundle must unpack to one expected top directory'
    if grep -Eq '(^|/)\.\.?(/|$)' "$work/entries"; then
        ufi003_release_fail 'Bundle has a non-canonical archive path'
    fi
    if grep -Eq '(^|/)(offline-mfi[^/]*|tls\.password|[^/]*\.(pk8|p7b|p12|pfx))(/|$)' "$work/entries"; then
        ufi003_release_fail 'Bundle contains a forbidden identity path'
    fi
    mkdir "$work/unpacked"
    tar -xzf "$bundle" -C "$work/unpacked" || ufi003_release_fail 'Cannot unpack bundle'
    root=$work/unpacked/$name
    [ -d "$root" ] || ufi003_release_fail 'Bundle top entry is not a directory'
    jq -e -s --arg version "$version" '
        length == 1 and (.[0] |
            .schema == "org.openxplay.flash-stage/1" and
            .stage == "device" and .device == "ufi003" and .version == $version)
        ' "$root/manifest.json" >/dev/null || ufi003_release_fail 'Invalid bundle manifest or version'
    (cd "$root" && sha256sum -c SHA256SUMS) || ufi003_release_fail 'Bundle SHA256SUMS check failed'
    printf 'PASS %s\n' "$name.tar.gz"
)
