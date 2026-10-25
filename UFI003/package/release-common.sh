#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Sourced by the release workflow and its offline tests. No device commands run here.

ufi003_release_fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# Sets RELEASE_VERSION (display), DEBVERSION (payload/filename) and PRERELEASE.
device_release_version() {
    device=$1
    shift
    case "$device" in ufi003|phicomm-n1) ;; *) ufi003_release_fail "Unsupported device: $device" ;; esac
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
                refs/tags/"$device"-device-v*) RELEASE_VERSION=${2#refs/tags/"$device"-device-v} ;;
                *) ufi003_release_fail "Not a $device device tag: $2" ;;
            esac
            # SemVer core and prerelease identifiers; build metadata is not a release tag.
            case "$RELEASE_VERSION" in
                ''|*[!0-9A-Za-z.-]*) ufi003_release_fail "Invalid $device device version: $RELEASE_VERSION" ;;
            esac
            ufi003_number='(0|[1-9][0-9]*)'
            ufi003_identifier="($ufi003_number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
            printf '%s\n' "$RELEASE_VERSION" | LC_ALL=C grep -Eq \
                "^$ufi003_number\\.$ufi003_number\\.$ufi003_number(-$ufi003_identifier(\\.$ufi003_identifier)*)?$" ||
                ufi003_release_fail "Invalid $device device version: $RELEASE_VERSION"
            case "$RELEASE_VERSION" in *-*) PRERELEASE=true ;; esac
            DEBVERSION=$(printf '%s' "$RELEASE_VERSION" | sed 's/-/~/')
            ;;
        *) ufi003_release_fail "Unsupported release event: $1" ;;
    esac
}

ufi003_release_version() { device_release_version ufi003 "$@"; }

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
device_check_bundle() (
    set -eu
    device=$1
    shift
    case "$device" in ufi003|phicomm-n1) ;; *) ufi003_release_fail "Unsupported device: $device" ;; esac
    version=$1
    name=openxplay-$device-device-$version
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
    jq -e -s --arg version "$version" --arg device "$device" '
        length == 1 and (.[0] |
            .schema == "org.openxplay.flash-stage/1" and
            .stage == "device" and .device == $device and .version == $version and
            (.packages | type == "array" and length > 0) and
            all(.packages[];
                (.name | type == "string" and test("^[a-z0-9][a-z0-9+.-]+$")) and
                (.version | type == "string" and test("^[0-9][0-9A-Za-z.+:~_-]*$")) and
                (.file | type == "string" and test("^debs/[a-z0-9][A-Za-z0-9.+:~_-]*\\.deb$")) and
                (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
            (.packages | length == (map(.name) | unique | length)) and
            (.packages | length == (map(.file) | unique | length)) and
            any(.packages[]; .name == ("openxplay-" + $device) and .version == $version) and
            (if $device == "phicomm-n1" then
                .transport == "ssh" and .requires.debianVersion == "13" and
                .requires.deviceTreeModel == "Phicomm N1" and .requires.dpkgArchitecture == "arm64" and
                (.requires | has("kernelRelease") | not)
             else true end))
        ' "$root/manifest.json" >/dev/null || ufi003_release_fail 'Invalid bundle manifest or version'
    (cd "$root" && sha256sum -c SHA256SUMS) || ufi003_release_fail 'Bundle SHA256SUMS check failed'
    jq -r '.packages[] | [.name, .version, .file, .sha256] | @tsv' "$root/manifest.json" > "$work/packages"
    tab=$(printf '\t')
    while IFS="$tab" read -r pkg ver file digest; do
        deb=$root/$file
        [ -f "$deb" ] && [ ! -L "$deb" ] || ufi003_release_fail "Missing manifest package: $file"
        [ "$(sha256sum "$deb" | cut -d' ' -f1)" = "$digest" ] ||
            ufi003_release_fail "Manifest package SHA-256 mismatch: $file"
        [ "$(dpkg-deb -f "$deb" Package)" = "$pkg" ] && [ "$(dpkg-deb -f "$deb" Version)" = "$ver" ] ||
            ufi003_release_fail "Manifest does not match Debian control metadata: $file"
        case "$(dpkg-deb -f "$deb" Architecture)" in
            arm64|all) ;;
            *) ufi003_release_fail "Unsupported manifest package architecture: $file" ;;
        esac
    done < "$work/packages"
    [ "$(find "$root/debs" -type f -name '*.deb' | wc -l)" -eq "$(wc -l < "$work/packages")" ] ||
        ufi003_release_fail 'Bundle contains an unlisted Debian package'
    printf 'PASS %s\n' "$name.tar.gz"
)

ufi003_check_bundle() { device_check_bundle ufi003 "$@"; }

# The N1 list is measured on the box and can contain any Debian binary package, arm64 or all.
# Snapshot supplies the source-independent binary lookup; trust only the committed SHA-256 and
# verified control fields. No package-name-to-source or architecture table is needed.
phicomm_n1_fetch_debs() (
    set -eu
    pins=$1
    debs=$2
    mkdir -p "$debs"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    seen=' '
    while read -r pkg version digest extra || [ -n "$pkg" ]; do
        case "$pkg" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] && printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]+$' &&
            printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' ||
            ufi003_release_fail "Invalid debs.txt row: $pkg"
        printf '%s\n' "$version" | grep -Eq '^[0-9][0-9A-Za-z.+:~-]*$' ||
            ufi003_release_fail "Invalid pinned version: $pkg $version"
        case "$seen" in *" $pkg "*) ufi003_release_fail "Duplicate pinned package: $pkg" ;; esac
        seen="$seen$pkg "
        encoded_version=$(jq -nr --arg version "$version" '$version | @uri')
        ufi003_release_curl --output "$work/binaries.json" \
            "https://snapshot.debian.org/mr/binary/$pkg/$encoded_version/binfiles" ||
            ufi003_release_fail "Cannot locate $pkg $version on snapshot.debian.org"
        hash=$(jq -er '
            [.result[] | select(.architecture == "arm64" or .architecture == "all") | .hash] | unique |
            if length == 1 then .[0] else error("Expected one arm64/all binary") end
            ' "$work/binaries.json") || ufi003_release_fail "Ambiguous snapshot binary: $pkg $version"
        printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{40}$' || ufi003_release_fail "Invalid snapshot file hash: $pkg"
        part=$work/package.deb
        ufi003_release_curl --output "$part" "https://snapshot.debian.org/file/$hash" ||
            ufi003_release_fail "Cannot download $pkg $version"
        printf '%s  %s\n' "$digest" "$part" | sha256sum -c - || ufi003_release_fail "SHA-256 mismatch: $pkg"
        arch=$(dpkg-deb -f "$part" Architecture)
        case "$arch" in arm64|all) ;; *) ufi003_release_fail "Unsupported architecture: $pkg $arch" ;; esac
        [ "$(dpkg-deb -f "$part" Package)" = "$pkg" ] && [ "$(dpkg-deb -f "$part" Version)" = "$version" ] ||
            ufi003_release_fail "Control metadata does not match pin: $pkg $version"
        mv -f "$part" "$debs/${pkg}_${version#*:}_${arch}.deb"
    done < "$pins"
)

# Keep the firmware and its redistribution licence pinned to unmodified linux-firmware files.
phicomm_n1_fetch_firmware() (
    set -eu
    pins=$1
    firmware=$2
    mkdir -p "$firmware"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    seen=' '
    while read -r commit path digest extra || [ -n "$commit" ]; do
        case "$commit" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] && printf '%s\n' "$commit" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$' &&
            printf '%s\n' "$path" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' &&
            printf '%s\n' "$digest" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' ||
            ufi003_release_fail "Invalid firmware.txt row: $commit"
        case "/$path/" in *..*|*/./*) ufi003_release_fail "Invalid firmware path: $path" ;; esac
        base=${path##*/}
        case "$seen" in *" $base "*) ufi003_release_fail "Duplicate firmware basename: $base" ;; esac
        seen="$seen$base "
        part=$work/firmware
        ufi003_release_curl --output "$part" \
            "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/$path?id=$commit" ||
            ufi003_release_fail "Cannot download firmware: $path"
        printf '%s  %s\n' "$digest" "$part" | sha256sum -c - ||
            ufi003_release_fail "SHA-256 mismatch: $path"
        mv -f "$part" "$firmware/$base"
    done < "$pins"
)
