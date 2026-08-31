#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPAT="$ROOT_DIR/scripts/compat.sh"
ACTION_PATCH="$ROOT_DIR/patches/legacy-action-frame-api.patch"
EML_PATCH="$ROOT_DIR/patches/legacy-eml-api.patch"
WIRELESS_NEXT_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/wireless/wireless-next.git"
WIRELESS_NEXT_PLAIN="https://git.kernel.org/pub/scm/linux/kernel/git/wireless/wireless-next.git/plain"
TEST_DIR="$(mktemp -d)"
SOURCE_DIR="$TEST_DIR/wireless-next"
WIRELESS_NEXT_SHA=''

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

make_fixture() {
    local generation=$1
    local kdir="$TEST_DIR/$generation"
    local action_macro eml_symbols nan_uapi cfg_nan mac_nan aql_decl aql_export

    nan_uapi=''
    cfg_nan=''
    mac_nan=''
    aql_decl=''
    aql_export=''

    case "$generation" in
        v6.18|v7.0)
            action_macro='#define IEEE80211_MIN_ACTION_SIZE 24'
            eml_symbols=$'#define IEEE80211_EML_CAP_EMLSR_PADDING_DELAY 0\n#define IEEE80211_EML_CAP_EMLSR_TRANSITION_DELAY 0'
            ;;
        v7.1)
            action_macro='#define IEEE80211_MIN_ACTION_SIZE(member) 24'
            eml_symbols=$'#define IEEE80211_EML_CAP_EMLSR_PADDING_DELAY 0\n#define IEEE80211_EML_CAP_EMLSR_TRANSITION_DELAY 0'
            nan_uapi='NL80211_IFTYPE_NAN_DATA'
            cfg_nan=$'CFG80211_NAN_SCHED_NUM_TIME_SLOTS\nCFG80211_NAN_MAX_PEER_MAPS'
            mac_nan=$'BSS_CHANGED_NAN_LOCAL_SCHED\nnan_peer_sched_changed\nieee80211_nan_sched_update_done'
            ;;
        v7.2)
            action_macro='#define IEEE80211_MIN_ACTION_SIZE(member) 24'
            eml_symbols=$'#define IEEE80211_EML_CAP_EML_PADDING_DELAY 0\n#define IEEE80211_EML_CAP_EML_TRANSITION_DELAY 0'
            nan_uapi='NL80211_IFTYPE_NAN_DATA'
            cfg_nan=$'CFG80211_NAN_SCHED_NUM_TIME_SLOTS\nCFG80211_NAN_MAX_PEER_MAPS'
            mac_nan=$'BSS_CHANGED_NAN_LOCAL_SCHED\nnan_peer_sched_changed\nieee80211_nan_sched_update_done'
            aql_decl='void ieee80211_txq_aql_pending(void);'
            ;;
        current)
            action_macro='#define IEEE80211_MIN_ACTION_SIZE(member) 24'
            eml_symbols=$'#define IEEE80211_EML_CAP_EML_PADDING_DELAY 0\n#define IEEE80211_EML_CAP_EML_TRANSITION_DELAY 0'
            nan_uapi='NL80211_IFTYPE_NAN_DATA'
            cfg_nan=$'CFG80211_NAN_SCHED_NUM_TIME_SLOTS\nCFG80211_NAN_MAX_PEER_MAPS'
            mac_nan=$'BSS_CHANGED_NAN_LOCAL_SCHED\nnan_peer_sched_changed\nieee80211_nan_sched_update_done'
            aql_decl='void ieee80211_txq_aql_pending(void);'
            aql_export='0x0 ieee80211_txq_aql_pending mac80211 EXPORT_SYMBOL_GPL'
            ;;
        *)
            fail "unknown fixture generation: $generation"
            ;;
    esac

    rm -rf "$kdir"
    mkdir -p "$kdir/include/linux" "$kdir/include/net" "$kdir/include/uapi/linux"
    printf '%s\n' "$action_macro" > "$kdir/include/linux/ieee80211.h"
    printf '%s\n' "$eml_symbols" > "$kdir/include/linux/ieee80211-eht.h"
    printf '%s\n' "$nan_uapi" > "$kdir/include/uapi/linux/nl80211.h"
    printf '%s\n' "$cfg_nan" > "$kdir/include/net/cfg80211.h"
    printf '%s\n' "$mac_nan" "$aql_decl" > "$kdir/include/net/mac80211.h"
    printf '%s\n' "$aql_export" > "$kdir/Module.symvers"
    printf '%s\n' "$kdir"
}

assert_patches() {
    local generation=$1
    local expected=$2
    local kdir actual

    kdir=$(make_fixture "$generation")
    actual=$("$COMPAT" detect "$kdir")
    [[ $actual == "$expected" ]] ||
        fail "$generation: expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
}

assert_aql_without_symvers() {
    local kdir actual
    local stderr="$TEST_DIR/no-aql-symvers.stderr"

    kdir=$(make_fixture v7.1)
    printf '%s\n' \
        '#define IEEE80211_EML_CAP_EML_PADDING_DELAY 0' \
        '#define IEEE80211_EML_CAP_EML_TRANSITION_DELAY 0' > "$kdir/include/linux/ieee80211-eht.h"
    rm "$kdir/Module.symvers"

    if ! actual=$("$COMPAT" detect "$kdir" 2> "$stderr"); then
        fail 'detection failed without an AQL declaration'
    fi
    [[ ! -s $stderr ]] || fail 'detection read missing Module.symvers without an AQL declaration'
    [[ $actual == aql ]] || fail "missing AQL declaration: expected aql, got $(printf '%q' "$actual")"
}

assert_unsupported() {
    local header=$1
    local content=$2
    local kdir output

    kdir=$(make_fixture current)
    printf '%s\n' "$content" > "$kdir/$header"
    if output=$("$COMPAT" detect "$kdir" 2>&1); then
        fail "$header: unsupported generation was accepted"
    fi
    [[ $output == *"$header"* ]] || fail "$header: diagnostic did not name unsupported header"
}

copy_wireless_next_tree() {
    local remote_head source_file
    local -a source_files=(
        drivers/net/wireless/mediatek/mt76/mt76_connac_mac.c
        drivers/net/wireless/mediatek/mt76/mt7925/mac.c
        drivers/net/wireless/mediatek/mt76/mt7925/mcu.c
        drivers/net/wireless/mediatek/mt76/mt7996/mac.c
    )

    remote_head=$(git ls-remote "$WIRELESS_NEXT_REPO" refs/heads/main)
    read -r WIRELESS_NEXT_SHA _ <<< "$remote_head"
    [[ $WIRELESS_NEXT_SHA =~ ^[0-9a-f]{40}$ ]] || fail 'could not resolve wireless-next/main'

    git init --quiet "$SOURCE_DIR"
    for source_file in "${source_files[@]}"; do
        mkdir -p "$SOURCE_DIR/$(dirname "$source_file")"
        curl --fail --location --silent --show-error \
            "$WIRELESS_NEXT_PLAIN/$source_file?id=$WIRELESS_NEXT_SHA" \
            --output "$SOURCE_DIR/$source_file"
    done
    git -C "$SOURCE_DIR" add .
    git -C "$SOURCE_DIR" \
        -c user.name='Compatibility Test' \
        -c user.email='compat-test@example.invalid' \
        commit --quiet -m "Record wireless-next $WIRELESS_NEXT_SHA"
}

reset_source() {
    git -C "$SOURCE_DIR" reset --hard --quiet HEAD
    git -C "$SOURCE_DIR" clean -fdq
}

assert_action_patch_scope() {
    reset_source
    git -C "$SOURCE_DIR" apply --check "$ACTION_PATCH"
    git -C "$SOURCE_DIR" apply "$ACTION_PATCH"

    grep -Fq 'IEEE80211_MIN_ACTION_SIZE + 1 + 1 + 2' \
        "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt76_connac_mac.c" ||
        fail 'action patch did not adapt mt76_connac_mac.c'
    grep -Fq 'mgmt->u.action.u.addba_req.action_code' \
        "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mac.c" ||
        fail 'action patch did not adapt mt7925/mac.c'
    grep -Fq 'IEEE80211_EML_CAP_EML_PADDING_DELAY' \
        "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mcu.c" ||
        fail 'action patch changed the EML API'
    grep -Fq 'IEEE80211_MIN_ACTION_SIZE(action_code)' \
        "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7996/mac.c" ||
        fail 'action patch changed mt7996'
    git -C "$SOURCE_DIR" apply --reverse --check "$ACTION_PATCH"
}

make_apply_fixture() {
    local action_generation=$1
    local eml_generation=$2
    local kdir

    kdir=$(make_fixture current)
    if [[ $action_generation == legacy ]]; then
        printf '%s\n' '#define IEEE80211_MIN_ACTION_SIZE 24' > "$kdir/include/linux/ieee80211.h"
    fi
    if [[ $eml_generation == legacy ]]; then
        printf '%s\n' \
            '#define IEEE80211_EML_CAP_EMLSR_PADDING_DELAY 0' \
            '#define IEEE80211_EML_CAP_EMLSR_TRANSITION_DELAY 0' > "$kdir/include/linux/ieee80211-eht.h"
    fi
    printf '%s\n' "$kdir"
}

assert_applied_patches() {
    local action_generation=$1
    local eml_generation=$2
    local expected=$3
    local kdir actual

    reset_source
    kdir=$(make_apply_fixture "$action_generation" "$eml_generation")
    actual=$("$COMPAT" apply "$SOURCE_DIR" "$kdir")
    [[ $actual == "$expected" ]] ||
        fail "$action_generation/$eml_generation: expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"

    if [[ $action_generation == legacy ]]; then
        grep -Fq 'IEEE80211_MIN_ACTION_SIZE + 1 + 1 + 2' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt76_connac_mac.c" ||
            fail 'selected action patch did not adapt mt76_connac_mac.c'
        grep -Fq 'mgmt->u.action.u.addba_req.action_code' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mac.c" ||
            fail 'selected action patch did not adapt mt7925/mac.c'
        git -C "$SOURCE_DIR" apply --reverse --check "$ACTION_PATCH"
    else
        grep -Fq 'IEEE80211_MIN_ACTION_SIZE(addba_req.capab)' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt76_connac_mac.c" ||
            fail 'unselected action patch changed mt76_connac_mac.c'
        grep -Fq 'IEEE80211_MIN_ACTION_SIZE(action_code)' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mac.c" ||
            fail 'unselected action patch changed mt7925/mac.c'
    fi

    if [[ $eml_generation == legacy ]]; then
        grep -Fq 'IEEE80211_EML_CAP_EMLSR_PADDING_DELAY' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mcu.c" ||
            fail 'selected EML patch did not adapt the padding-delay name'
        grep -Fq 'IEEE80211_EML_CAP_EMLSR_TRANSITION_DELAY' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mcu.c" ||
            fail 'selected EML patch did not adapt the transition-delay name'
        git -C "$SOURCE_DIR" apply --reverse --check "$EML_PATCH"
    else
        grep -Fq 'IEEE80211_EML_CAP_EML_PADDING_DELAY' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mcu.c" ||
            fail 'unselected EML patch changed the padding-delay name'
        grep -Fq 'IEEE80211_EML_CAP_EML_TRANSITION_DELAY' \
            "$SOURCE_DIR/drivers/net/wireless/mediatek/mt76/mt7925/mcu.c" ||
            fail 'unselected EML patch changed the transition-delay name'
    fi
}

assert_patches v6.18 $'action-frame\neml\nnan\naql'
assert_patches v7.0 $'action-frame\neml\nnan\naql'
assert_patches v7.1 $'eml\naql'
assert_patches v7.2 $'aql'
assert_patches current ''
assert_aql_without_symvers

assert_unsupported include/linux/ieee80211.h '#define IEEE80211_MIN_ACTION_LENGTH 24'
assert_unsupported include/linux/ieee80211-eht.h '#define IEEE80211_EML_CAP_UNKNOWN 0'

copy_wireless_next_tree
assert_action_patch_scope
assert_applied_patches legacy legacy $'action-frame\neml'
assert_applied_patches legacy current 'action-frame'
assert_applied_patches current legacy 'eml'
assert_applied_patches current current ''

printf 'Compatibility detection and split patch tests passed at %s.\n' "$WIRELESS_NEXT_SHA"
