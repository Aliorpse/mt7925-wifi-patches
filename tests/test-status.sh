#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/mt76-check.sh"
TEST_DIR="$(mktemp -d)"
FAKE_ROOT="$TEST_DIR/root"
MODULES_ROOT="$FAKE_ROOT/lib/modules"
ETC_ROOT="$FAKE_ROOT/etc"
PROC_MODULES="$FAKE_ROOT/proc/modules"
SYS_CLASS_NET="$FAKE_ROOT/sys/class/net"
FAKE_BIN="$TEST_DIR/bin"
OUTPUT="$TEST_DIR/output"
MODINFO_PATH="$TEST_DIR/modinfo-path"
IW_DEV="$TEST_DIR/iw-dev"
POWER_SAVE_DIR="$TEST_DIR/power-save"
NOTIFY_LOG="$TEST_DIR/notify.log"
KVER='7.2.0-status-test'
SHA='0123456789abcdef0123456789abcdef01234567'
OVERLAY="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches"
STOCK_MODULE="$MODULES_ROOT/$KVER/kernel/drivers/net/wireless/mediatek/mt76/mt7925/mt7925e.ko"
NOTIFY_COMMAND="$FAKE_BIN/notify-send"
RUN_STATUS=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ ! -f $OUTPUT ]] || printf '%s\n' '--- checker output ---' "$(<"$OUTPUT")" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

assert_status() {
    [[ $RUN_STATUS -eq $1 ]] || fail "expected status $1, got $RUN_STATUS"
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain $(printf '%q' "$2")"
}

assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        fail "$1 unexpectedly contains $(printf '%q' "$2")"
    fi
}

assert_rebuild_action() {
    local line actions=0

    while IFS= read -r line; do
        case $line in
            Run:*)
                ((actions += 1))
                [[ $line == 'Run: ./mt76-rebuild.sh' ]] ||
                    fail "$OUTPUT contains the wrong remediation line: $line"
                ;;
        esac
    done < "$OUTPUT"
    [[ $actions -eq 1 ]] || fail "$OUTPUT contains $actions remediation lines, expected 1"
    assert_not_contains "$OUTPUT" 'sudo ./mt76-rebuild.sh'
}

assert_file_equals() {
    local actual

    [[ -f $1 ]] || fail "missing file: $1"
    actual=$(<"$1")
    [[ $actual == "$2" ]] ||
        fail "$1 contained $(printf '%q' "$actual"), expected $(printf '%q' "$2")"
}

make_fake_commands() {
    mkdir -p "$FAKE_BIN"

    cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && $1 == -r ]] || exit 2
printf '%s\n' "$FAKE_KVER"
EOF

    cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && $1 == -n && $2 == mt7925e ]] || exit 2
[[ -s $FAKE_MODINFO_PATH ]] || exit 1
printf '%s\n' "$(<"$FAKE_MODINFO_PATH")"
EOF

    cat > "$FAKE_BIN/iw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 1 && $1 == dev ]]; then
    cat "$FAKE_IW_DEV"
elif [[ $# -eq 4 && $1 == dev && $3 == get && $4 == power_save ]]; then
    [[ -f $FAKE_POWER_SAVE_DIR/$2 ]] || exit 1
    printf 'Power save: %s\n' "$(<"$FAKE_POWER_SAVE_DIR/$2")"
else
    exit 2
fi
EOF

    cat > "$FAKE_BIN/notify-send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 6 && $1 == -u && $3 == -t ]] || exit 2
printf '%s\n%s\n' "$5" "$6" > "$FAKE_NOTIFY_LOG"
EOF

    chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/modinfo" "$FAKE_BIN/iw" "$FAKE_BIN/notify-send"
}

reset_fixture() {
    rm -rf "$FAKE_ROOT" "$POWER_SAVE_DIR"
    rm -f "$OUTPUT" "$NOTIFY_LOG"
    mkdir -p "${STOCK_MODULE%/*}" "${PROC_MODULES%/*}" "$ETC_ROOT" "$SYS_CLASS_NET" "$POWER_SAVE_DIR"
    printf 'stock module\n' > "$STOCK_MODULE"
    printf '%s\n' "$STOCK_MODULE" > "$MODINFO_PATH"
    : > "$PROC_MODULES"
    : > "$IW_DEV"
    NOTIFY_COMMAND="$FAKE_BIN/notify-send"
}

write_metadata() {
    local kernel=${1:-$KVER} source_sha=${2:-$SHA}

    mkdir -p "$OVERLAY"
    printf 'kernel=%s\nsource_sha=%s\ncompiler=gcc test compiler\npatches=none\n' \
        "$kernel" "$source_sha" > "$OVERLAY/.build-info"
}

install_custom() {
    write_metadata "${1:-$KVER}" "${2:-$SHA}"
    printf 'custom module\n' > "$OVERLAY/mt7925e.ko"
    printf '%s\n' "$OVERLAY/mt7925e.ko" > "$MODINFO_PATH"
}

load_custom() {
    printf 'mt7925e 1 0 - Live 0x0\n' > "$PROC_MODULES"
}

add_interface() {
    local iface=$1 module=$2 power_save=$3
    local module_dir="$FAKE_ROOT/sys/module/$module"
    local driver_dir="$SYS_CLASS_NET/$iface/device/driver"

    mkdir -p "$module_dir" "$driver_dir"
    ln -s "$module_dir" "$driver_dir/module"
    printf 'phy#0\n\tInterface %s\n' "$iface" >> "$IW_DEV"
    printf '%s\n' "$power_save" > "$POWER_SAVE_DIR/$iface"
}

run_check() {
    rm -f "$OUTPUT"
    if PATH="$FAKE_BIN:$PATH" \
        FAKE_KVER="$KVER" \
        FAKE_MODINFO_PATH="$MODINFO_PATH" \
        FAKE_IW_DEV="$IW_DEV" \
        FAKE_POWER_SAVE_DIR="$POWER_SAVE_DIR" \
        FAKE_NOTIFY_LOG="$NOTIFY_LOG" \
        MT7925_UNAME="$FAKE_BIN/uname" \
        MT7925_MODINFO="$FAKE_BIN/modinfo" \
        MT7925_IW="$FAKE_BIN/iw" \
        MT7925_NOTIFY_SEND="$NOTIFY_COMMAND" \
        MT7925_MODULES_ROOT="$MODULES_ROOT" \
        MT7925_ETC_ROOT="$ETC_ROOT" \
        MT7925_PROC_MODULES="$PROC_MODULES" \
        MT7925_SYS_CLASS_NET="$SYS_CLASS_NET" \
        "$CHECK" "$@" > "$OUTPUT" 2>&1; then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

test_stock_resolution_ignores_markers_and_similar_prefixes() {
    local marker similar

    reset_fixture
    marker="$MODULES_ROOT/$KVER/kernel/drivers/net/wireless/mediatek/mt76/.custom-mt76"
    mkdir -p "${marker%/*}"
    : > "$marker"
    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'MT7925 WiFi: Stock driver'
    assert_contains "$OUTPUT" 'Driver: Stock (custom not installed)'
    assert_rebuild_action

    similar="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches-old"
    mkdir -p "$similar"
    printf 'not the project overlay\n' > "$similar/mt7925e.ko"
    printf '%s\n' "$similar/mt7925e.ko" > "$MODINFO_PATH"
    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'Driver: Stock (custom not installed)'
    assert_rebuild_action
    pass 'stock resolution ignores markers and non-overlay path prefixes'
}

test_loaded_custom_reports_metadata_and_mt7925_interface() {
    local intermediate_module

    reset_fixture
    install_custom
    load_custom
    mkdir -p "$ETC_ROOT/modprobe.d"
    printf 'options mt7925e disable_aspm=1\n' > "$ETC_ROOT/modprobe.d/mt7925.conf"
    add_interface other0 ath11k off
    add_interface wlan0 mt7925e on
    intermediate_module="$FAKE_ROOT/sys/mt7925e-module-link"
    ln -s "$FAKE_ROOT/sys/module/mt7925e" "$intermediate_module"
    rm "$SYS_CLASS_NET/wlan0/device/driver/module"
    ln -s "$intermediate_module" "$SYS_CLASS_NET/wlan0/device/driver/module"

    run_check --text
    assert_status 0
    assert_contains "$OUTPUT" 'MT7925 WiFi: Custom driver loaded'
    assert_contains "$OUTPUT" 'Driver: Custom (loaded)'
    assert_contains "$OUTPUT" "Source: $SHA"
    assert_contains "$OUTPUT" 'Compiler: gcc test compiler'
    assert_contains "$OUTPUT" 'Patches: none'
    assert_contains "$OUTPUT" 'ASPM: Default (not requested)'
    assert_contains "$OUTPUT" 'Power Save (wlan0): On (default)'
    assert_not_contains "$OUTPUT" 'Power Save (other0)'
    pass 'loaded custom status reports metadata and only the bound MT7925 interface'
}

test_installed_custom_reports_unloaded() {
    reset_fixture
    install_custom

    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'MT7925 WiFi: Custom driver not loaded'
    assert_contains "$OUTPUT" 'Driver: Custom (installed, not loaded)'
    assert_rebuild_action
    pass 'valid custom overlay is distinct when mt7925e is unloaded'
}

test_stale_kernel_and_source_metadata() {
    reset_fixture
    install_custom '7.1.0-old-kernel'
    load_custom

    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'MT7925 WiFi: Stale custom metadata'
    assert_contains "$OUTPUT" 'Driver: Custom (stale metadata)'
    assert_contains "$OUTPUT" 'Metadata kernel: 7.1.0-old-kernel'
    assert_rebuild_action

    write_metadata "$KVER" not-a-wireless-next-sha
    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'Driver: Custom (stale metadata)'
    assert_contains "$OUTPUT" 'Source: not-a-wireless-next-sha'
    assert_rebuild_action
    pass 'kernel mismatch and invalid wireless-next SHA report stale metadata'
}

test_missing_and_incomplete_metadata() {
    reset_fixture
    mkdir -p "$OVERLAY"
    printf 'custom module\n' > "$OVERLAY/mt7925e.ko"
    printf '%s\n' "$OVERLAY/mt7925e.ko" > "$MODINFO_PATH"

    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'MT7925 WiFi: Custom metadata missing'
    assert_contains "$OUTPUT" 'Driver: Custom (metadata missing or incomplete)'
    assert_rebuild_action

    printf 'kernel=%s\nsource_sha=%s\n' "$KVER" "$SHA" > "$OVERLAY/.build-info"
    run_check --text
    assert_status 1
    assert_contains "$OUTPUT" 'Driver: Custom (metadata missing or incomplete)'
    assert_rebuild_action
    pass 'resolved overlay requires complete build metadata'
}

test_source_never_recommends_root_rebuild() {
    if grep -Fq -- 'sudo ./mt76-rebuild.sh' "$CHECK"; then
        fail 'checker source still recommends running the normal-user rebuild script with sudo'
    fi
    pass 'checker source never recommends a root rebuild invocation'
}

test_optional_settings_report_live_state_without_targeting_other_adapters() {
    reset_fixture
    install_custom
    load_custom
    mkdir -p "$ETC_ROOT/modprobe.d" "$ETC_ROOT/NetworkManager/dispatcher.d"
    printf '# Generated by mt7925-wifi-patches\noptions mt7925e disable_aspm=1\n' \
        > "$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    printf '# Generated by mt7925-wifi-patches\n' \
        > "$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    add_interface other0 ath11k off
    add_interface wlan0 mt7925e on

    run_check --text
    assert_status 0
    assert_contains "$OUTPUT" 'ASPM: Disabled (requested)'
    assert_contains "$OUTPUT" 'Power Save (wlan0): On (requested off)'
    assert_not_contains "$OUTPUT" 'Power Save (other0)'

    printf 'off\n' > "$POWER_SAVE_DIR/wlan0"
    run_check --text
    assert_status 0
    assert_contains "$OUTPUT" 'Power Save (wlan0): Off'
    pass 'optional settings use project paths and live MT7925 power-save state'
}

test_text_notification_and_missing_notifier_fallback_match() {
    local expected

    reset_fixture
    install_custom
    load_custom
    run_check --text
    assert_status 0
    expected=$(<"$OUTPUT")

    run_check
    assert_status 0
    [[ ! -s $OUTPUT ]] || fail 'successful notification also printed text'
    assert_file_equals "$NOTIFY_LOG" "$expected"

    NOTIFY_COMMAND="$FAKE_BIN/missing-notify-send"
    run_check
    assert_status 0
    assert_file_equals "$OUTPUT" "$expected"
    pass '--text, desktop notification, and notifier fallback use identical text'
}

make_fake_commands
test_stock_resolution_ignores_markers_and_similar_prefixes
test_loaded_custom_reports_metadata_and_mt7925_interface
test_installed_custom_reports_unloaded
test_stale_kernel_and_source_metadata
test_missing_and_incomplete_metadata
test_source_never_recommends_root_rebuild
test_optional_settings_report_live_state_without_targeting_other_adapters
test_text_notification_and_missing_notifier_fallback_match
printf 'Status and desktop-notification tests passed.\n'
