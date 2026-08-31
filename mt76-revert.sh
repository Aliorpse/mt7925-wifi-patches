#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_ROOT=${MT7925_MODULES_ROOT:-/lib/modules}
ETC_ROOT=${MT7925_ETC_ROOT:-/etc}
confirmed=0

usage() {
    printf 'usage: %s [--yes]\n' "${0##*/}" >&2
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes) confirmed=1 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

KVER=$(uname -r)

if ((confirmed == 0)); then
    printf 'This will remove:\n'
    printf '  Overlay: %s\n' "$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches"
    printf '  ASPM setting: %s\n' "$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    printf '  Power-save setting: %s\n' "$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    printf 'Continue? [y/N] '
    if ! IFS= read -r reply || [[ $reply != [Yy] && $reply != [Yy][Ee][Ss] ]]; then
        printf 'Aborted.\n'
        exit 0
    fi
fi

sudo "$SCRIPT_DIR/scripts/module-overlay.sh" revert "$KVER"
