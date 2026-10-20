#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-16
# Best-effort maintenance never waits for synchronization; cap local commands at 2 s.
(
    systemctl enable systemd-timesyncd.service || :
    systemctl --no-block start systemd-timesyncd.service || :
    synced=$(timedatectl show -p NTPSynchronized --value) || exit 0
    [ "$synced" = yes ] || exit 0
    now=$(date +%s) || exit 0
    case "$now" in ''|*[!0-9]*) exit 0 ;; esac
    state=${DESTDIR:-}/var/lib/openxplay
    future() {
        [ -f "$1" ] || return 1
        mtime=$(stat -c %Y "$1") || return 1
        case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
        [ "$mtime" -gt "$now" ]
    }
    if future "$state/admin-tls.json"; then
        rm -f "$state/admin-tls.json"
    fi
    if future "$state/receiver-tls/cert.pem" || future "$state/receiver-tls/key.pem"; then
        rm -f "$state/receiver-tls/cert.pem" "$state/receiver-tls/key.pem"
    fi
) </dev/null >/dev/null 2>&1 &
worker=$!
# Keep maintenance inside ExecStartPre: systemd kills leftover pre-start children.
(sleep 2; kill "$worker" 2>/dev/null || :) </dev/null >/dev/null 2>&1 &
deadline=$!
wait "$worker" || :
kill "$deadline" 2>/dev/null || :
wait "$deadline" 2>/dev/null || :
exit 0
