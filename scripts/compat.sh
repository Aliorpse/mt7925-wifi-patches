#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
    printf 'compat.sh: %s\n' "$*" >&2
    exit 1
}

detect_patches() {
    local kdir=$1
    local action="$kdir/include/linux/ieee80211.h"
    local eml="$kdir/include/linux/ieee80211-eht.h"
    local nl80211="$kdir/include/uapi/linux/nl80211.h"
    local cfg80211="$kdir/include/net/cfg80211.h"
    local mac80211="$kdir/include/net/mac80211.h"
    local symvers="$kdir/Module.symvers"
    local file current_action=0 legacy_action=0 current_eml=0 legacy_eml=0

    for file in "$action" "$eml" "$nl80211" "$cfg80211" "$mac80211"; do
        [[ -f $file ]] || die "required file not found: $file"
    done

    grep -Eq '^[[:space:]]*#define[[:space:]]+IEEE80211_MIN_ACTION_SIZE\(' "$action" && current_action=1
    grep -Eq '^[[:space:]]*#define[[:space:]]+IEEE80211_MIN_ACTION_SIZE[[:space:]]+' "$action" && legacy_action=1
    [[ $((current_action + legacy_action)) -eq 1 ]] || die "unsupported action API in $action"

    if grep -q 'IEEE80211_EML_CAP_EML_PADDING_DELAY' "$eml" &&
       grep -q 'IEEE80211_EML_CAP_EML_TRANSITION_DELAY' "$eml"; then
        current_eml=1
    fi
    if grep -q 'IEEE80211_EML_CAP_EMLSR_PADDING_DELAY' "$eml" &&
       grep -q 'IEEE80211_EML_CAP_EMLSR_TRANSITION_DELAY' "$eml"; then
        legacy_eml=1
    fi
    [[ $((current_eml + legacy_eml)) -eq 1 ]] || die "unsupported EML API in $eml"

    ((current_action)) || printf '%s\n' action-frame
    ((current_eml)) || printf '%s\n' eml

    if ! grep -q 'NL80211_IFTYPE_NAN_DATA' "$nl80211" ||
       ! grep -q 'CFG80211_NAN_SCHED_NUM_TIME_SLOTS' "$cfg80211" ||
       ! grep -q 'CFG80211_NAN_MAX_PEER_MAPS' "$cfg80211" ||
       ! grep -q 'BSS_CHANGED_NAN_LOCAL_SCHED' "$mac80211" ||
       ! grep -q 'nan_peer_sched_changed' "$mac80211" ||
       ! grep -q 'ieee80211_nan_sched_update_done' "$mac80211" ||
       ! grep -q 'ieee80211_nan_cluster_joined' "$mac80211"; then
        printf '%s\n' nan
    fi

    if ! grep -q 'ieee80211_txq_aql_pending' "$mac80211"; then
        printf '%s\n' aql
    elif [[ ! -f $symvers ]]; then
        die "required file not found: $symvers"
    elif ! grep -q '[[:space:]]ieee80211_txq_aql_pending[[:space:]]' "$symvers"; then
        printf '%s\n' aql
    fi
}

apply_patches() {
    local source=$1
    local kdir=$2
    local detected patch_id patch
    local -a patch_ids=() patch_files=()

    git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "source is not a git worktree: $source"
    detected=$(detect_patches "$kdir")
    [[ -n $detected ]] || return 0

    while IFS= read -r patch_id; do
        patch="$ROOT_DIR/patches/legacy-$patch_id-api.patch"
        [[ -f $patch ]] || die "required patch not found: $patch"
        patch_ids+=("$patch_id")
        patch_files+=("$patch")
    done <<< "$detected"

    git -C "$source" apply --check "${patch_files[@]}"
    git -C "$source" apply "${patch_files[@]}"
    printf '%s\n' "${patch_ids[@]}"
}

usage() {
    printf 'usage: %s detect KDIR | apply SOURCE_DIR KDIR\n' "${0##*/}" >&2
    exit 2
}

case ${1-} in
    detect)
        [[ $# -eq 2 ]] || usage
        detect_patches "$2"
        ;;
    apply)
        [[ $# -eq 3 ]] || usage
        apply_patches "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
