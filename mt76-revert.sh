#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if ((confirmed == 0)); then
    printf 'Remove the current kernel mt7925 overlay and project-owned settings? [y/N] '
    if ! IFS= read -r reply || [[ $reply != [Yy] && $reply != [Yy][Ee][Ss] ]]; then
        printf 'Aborted.\n'
        exit 0
    fi
fi

sudo "$SCRIPT_DIR/scripts/module-overlay.sh" revert "$(uname -r)"
