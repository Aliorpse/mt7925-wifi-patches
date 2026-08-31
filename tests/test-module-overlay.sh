#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/module-overlay.sh"
REVERT="$ROOT_DIR/mt76-revert.sh"
TEST_DIR="$(mktemp -d)"
FAKE_ROOT="$TEST_DIR/root"
MODULES_ROOT="$FAKE_ROOT/lib/modules"
ETC_ROOT="$FAKE_ROOT/etc"
PROC_MODULES="$FAKE_ROOT/proc/modules"
FAKE_BIN="$TEST_DIR/fake-bin"
STAGES="$TEST_DIR/stages"
OUTPUT="$TEST_DIR/output"
COMMAND_LOG="$TEST_DIR/commands.log"
IW_LOG="$TEST_DIR/iw.log"
FAIL_MARKER="$TEST_DIR/fail-once"
PACKAGE_SNAPSHOT="$TEST_DIR/package-snapshot"
KVER='7.2.0-overlay-test'
OTHER_KVER='7.1.0-other-test'
FAIL_STAGE=''
RUN_STATUS=0
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ ! -f $OUTPUT ]] || printf '%s\n' '--- helper output ---' "$(<"$OUTPUT")" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

assert_file_equals() {
    local file=$1 expected=$2 actual

    [[ -f $file ]] || fail "missing file: $file"
    actual=$(<"$file")
    [[ $actual == "$expected" ]] ||
        fail "$file contained $(printf '%q' "$actual"), expected $(printf '%q' "$expected")"
}

module_file() {
    case $1 in
        mt76) printf 'mt76.ko\n' ;;
        mt76_connac_lib) printf 'mt76-connac-lib.ko\n' ;;
        mt792x_lib) printf 'mt792x-lib.ko\n' ;;
        mt7925_common) printf 'mt7925-common.ko\n' ;;
        mt7925e) printf 'mt7925e.ko\n' ;;
        *) return 1 ;;
    esac
}

stock_path() {
    local kver=$1 module=$2 base

    base="$MODULES_ROOT/$kver/kernel/drivers/net/wireless/mediatek/mt76"
    case $module in
        mt76) printf '%s/mt76.ko\n' "$base" ;;
        mt76_connac_lib) printf '%s/mt76-connac-lib.ko\n' "$base" ;;
        mt792x_lib) printf '%s/mt792x-lib.ko\n' "$base" ;;
        mt7925_common) printf '%s/mt7925/mt7925-common.ko\n' "$base" ;;
        mt7925e) printf '%s/mt7925/mt7925e.ko\n' "$base" ;;
        *) return 1 ;;
    esac
}

make_stock_kernel() {
    local kver=$1 module path

    for module in mt76 mt76_connac_lib mt792x_lib mt7925_common mt7925e; do
        path=$(stock_path "$kver" "$module")
        mkdir -p "${path%/*}"
        printf 'package-owned %s %s\n' "$kver" "$module" > "$path"
    done
}

write_loaded_stack() {
    mkdir -p "${PROC_MODULES%/*}"
    cat > "$PROC_MODULES" <<'EOF'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
mt7925_common 1 1 mt792x_lib, Live 0x0
mt7925e 1 1 mt7925_common, Live 0x0
EOF
}

make_stage() {
    local name=$1 tag=$2 kver=${3:-$KVER} file stage

    stage="$STAGES/$name"
    mkdir -p "$stage"
    for file in mt76.ko mt76-connac-lib.ko mt792x-lib.ko mt7925-common.ko mt7925e.ko; do
        printf '%s %s\n' "$tag" "$file" > "$stage/$file"
    done
    printf 'kernel=%s\nsource_sha=0123456789abcdef\ncompiler=test compiler\npatches=none\nbuild=%s\n' \
        "$kver" "$tag" > "$stage/.build-info"
    printf '%s\n' "$stage"
}

reset_fixture() {
    rm -rf "$FAKE_ROOT" "$STAGES" "$PACKAGE_SNAPSHOT"
    rm -f "$OUTPUT" "$COMMAND_LOG" "$IW_LOG" "$FAIL_MARKER" "$TEST_DIR/sudo.log"
    mkdir -p "$STAGES" "$ETC_ROOT/modprobe.d" "$ETC_ROOT/NetworkManager/dispatcher.d"
    make_stock_kernel "$KVER"
    write_loaded_stack
    "$REAL_CP" -R "$MODULES_ROOT/$KVER/kernel" "$PACKAGE_SNAPSHOT"
    FAIL_STAGE=''
}

make_fake_commands() {
    mkdir -p "$FAKE_BIN"

    cat > "$FAKE_BIN/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_FAIL_STAGE-} == copy ]]; then
    for arg in "$@"; do
        if [[ $arg == *'/.mt7925-wifi-patches.new'* ]]; then
            printf 'fake copy failure\n' >&2
            exit 70
        fi
    done
fi
exec "$FAKE_REAL_CP" "$@"
EOF

    cat > "$FAKE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=${!#}
if [[ ${FAKE_FAIL_STAGE-} == settings && $destination == "$FAKE_DISPATCHER_TARGET" && ! -e $FAKE_FAIL_MARKER ]]; then
    : > "$FAKE_FAIL_MARKER"
    printf 'fake settings activation failure\n' >&2
    exit 71
fi
exec "$FAKE_REAL_MV" "$@"
EOF

    cat > "$FAKE_BIN/depmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'depmod %s\n' "$*" >> "$FAKE_COMMAND_LOG"
[[ $# -eq 2 && $1 == -a && $2 == "$FAKE_KVER" ]] || exit 2
active="$FAKE_MODULES_ROOT/$FAKE_KVER/updates/mt7925-wifi-patches/.build-info"
if [[ ${FAKE_FAIL_STAGE-} == depmod && -f $active && ! -e $FAKE_FAIL_MARKER ]]; then
    while IFS= read -r line; do
        if [[ $line == 'build=new' ]]; then
            : > "$FAKE_FAIL_MARKER"
            printf 'fake depmod failure\n' >&2
            exit 72
        fi
    done < "$active"
fi
EOF

    cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 4 && $1 == -k && $2 == "$FAKE_KVER" && $3 == -n ]] || exit 2
module=$4
case $module in
    mt76) file=mt76.ko; stock=mt76.ko ;;
    mt76_connac_lib) file=mt76-connac-lib.ko; stock=mt76-connac-lib.ko ;;
    mt792x_lib) file=mt792x-lib.ko; stock=mt792x-lib.ko ;;
    mt7925_common) file=mt7925-common.ko; stock=mt7925/mt7925-common.ko ;;
    mt7925e) file=mt7925e.ko; stock=mt7925/mt7925e.ko ;;
    *) exit 1 ;;
esac
active="$FAKE_MODULES_ROOT/$FAKE_KVER/updates/mt7925-wifi-patches"
if [[ -f $active/$file ]]; then
    if [[ ${FAKE_FAIL_STAGE-} == modinfo && $module == mt7925e ]]; then
        while IFS= read -r line; do
            [[ $line != 'build=new' ]] || {
                printf '%s/%s\n' "$FAKE_MODULES_ROOT/$FAKE_KVER/kernel/drivers/net/wireless/mediatek/mt76" "$stock"
                exit 0
            }
        done < "$active/.build-info"
    fi
    printf '%s/%s\n' "$active" "$file"
else
    printf '%s/%s\n' "$FAKE_MODULES_ROOT/$FAKE_KVER/kernel/drivers/net/wireless/mediatek/mt76" "$stock"
fi
EOF

    cat > "$FAKE_BIN/modprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'modprobe %s\n' "$*" >> "$FAKE_COMMAND_LOG"
if [[ ${1-} == -r && $# -eq 2 ]]; then
    module=$2
    if [[ ${FAKE_FAIL_STAGE-} == unload && $module == mt792x_lib ]]; then
        printf 'fake unload failure\n' >&2
        exit 73
    fi
    temporary="$FAKE_PROC_MODULES.tmp"
    : > "$temporary"
    while IFS= read -r line; do
        [[ ${line%% *} == "$module" ]] || printf '%s\n' "$line" >> "$temporary"
    done < "$FAKE_PROC_MODULES"
    "$FAKE_REAL_MV" "$temporary" "$FAKE_PROC_MODULES"
    exit 0
fi
[[ $# -eq 1 && $1 == mt7925e ]] || exit 2
active="$FAKE_MODULES_ROOT/$FAKE_KVER/updates/mt7925-wifi-patches/.build-info"
if [[ ${FAKE_FAIL_STAGE-} == load && -f $active && ! -e $FAKE_FAIL_MARKER ]]; then
    cat > "$FAKE_PROC_MODULES" <<'PARTIAL'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
PARTIAL
    : > "$FAKE_FAIL_MARKER"
    printf 'fake load failure\n' >&2
    exit 74
fi
cat > "$FAKE_PROC_MODULES" <<'LOADED'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
mt7925_common 1 1 mt792x_lib, Live 0x0
mt7925e 1 1 mt7925_common, Live 0x0
LOADED
EOF

    cat > "$FAKE_BIN/iw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_IW_LOG"
EOF

    cat > "$FAKE_BIN/readlink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -f && ${2-} == -- && $# -eq 3 ]] || exit 2
printf '/sys/module/%s\n' "${FAKE_DRIVER_MODULE:-mt7925e}"
EOF

    cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_SUDO_LOG"
EOF

    cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && $1 == -r ]] || exit 2
printf '%s\n' "$FAKE_KVER"
EOF

    chmod +x "$FAKE_BIN"/*
}

run_overlay() {
    local dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"

    rm -f "$OUTPUT"
    if PATH="$FAKE_BIN:$PATH" \
        MT7925_MODULES_ROOT="$MODULES_ROOT" \
        MT7925_ETC_ROOT="$ETC_ROOT" \
        MT7925_PROC_MODULES="$PROC_MODULES" \
        MT7925_MODPROBE="$FAKE_BIN/modprobe" \
        MT7925_DEPMOD="$FAKE_BIN/depmod" \
        MT7925_MODINFO="$FAKE_BIN/modinfo" \
        MT7925_IW="$FAKE_BIN/iw" \
        FAKE_MODULES_ROOT="$MODULES_ROOT" \
        FAKE_PROC_MODULES="$PROC_MODULES" \
        FAKE_COMMAND_LOG="$COMMAND_LOG" \
        FAKE_IW_LOG="$IW_LOG" \
        FAKE_FAIL_STAGE="$FAIL_STAGE" \
        FAKE_FAIL_MARKER="$FAIL_MARKER" \
        FAKE_DISPATCHER_TARGET="$dispatcher" \
        FAKE_REAL_CP="$REAL_CP" \
        FAKE_REAL_MV="$REAL_MV" \
        FAKE_KVER="$KVER" \
        "$HELPER" "$@" > "$OUTPUT" 2>&1; then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

assert_success() {
    [[ $RUN_STATUS -eq 0 ]] || fail "command failed with status $RUN_STATUS"
}

assert_failure() {
    [[ $RUN_STATUS -ne 0 ]] || fail 'command unexpectedly succeeded'
}

assert_package_unchanged() {
    diff -r "$PACKAGE_SNAPSHOT" "$MODULES_ROOT/$KVER/kernel" >/dev/null ||
        fail 'package-owned kernel modules changed'
}

assert_no_transaction_siblings() {
    local updates="$MODULES_ROOT/$KVER/updates"

    [[ ! -e $updates/.mt7925-wifi-patches.new ]] || fail 'new transaction directory remained'
    [[ ! -e $updates/.mt7925-wifi-patches.previous ]] || fail 'previous transaction directory remained'
}

assert_resolves_stock() {
    local module expected actual

    for module in mt76 mt76_connac_lib mt792x_lib mt7925_common mt7925e; do
        expected=$(stock_path "$KVER" "$module")
        actual=$(FAKE_MODULES_ROOT="$MODULES_ROOT" FAKE_KVER="$KVER" FAKE_FAIL_STAGE='' \
            "$FAKE_BIN/modinfo" -k "$KVER" -n "$module")
        [[ $actual == "$expected" ]] || fail "$module did not resolve to stock: $actual"
    done
}

assert_resolves_overlay() {
    local module file expected actual

    for module in mt76 mt76_connac_lib mt792x_lib mt7925_common mt7925e; do
        file=$(module_file "$module")
        expected="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches/$file"
        actual=$(FAKE_MODULES_ROOT="$MODULES_ROOT" FAKE_KVER="$KVER" FAKE_FAIL_STAGE='' \
            "$FAKE_BIN/modinfo" -k "$KVER" -n "$module")
        [[ $actual == "$expected" ]] || fail "$module did not resolve to overlay: $actual"
    done
}

assert_overlay_tag() {
    local expected=$1 line found=0
    local info="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches/.build-info"

    [[ -f $info ]] || fail 'active overlay metadata is missing'
    while IFS= read -r line; do
        [[ $line != "build=$expected" ]] || found=1
    done < "$info"
    [[ $found -eq 1 ]] || fail "active overlay is not build $expected"
}

assert_loaded_stack() {
    local actual='' name rest
    local expected=$'mt76\nmt76_connac_lib\nmt792x_lib\nmt7925_common\nmt7925e'

    while read -r name rest; do
        actual+="${actual:+$'\n'}$name"
    done < "$PROC_MODULES"
    [[ $actual == "$expected" ]] || fail "unexpected loaded stack: $(printf '%q' "$actual")"
}

assert_failed_install_is_stock() {
    local active="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches"

    assert_failure
    [[ ! -e $active ]] || fail 'failed first install left an active overlay'
    assert_no_transaction_siblings
    assert_package_unchanged
    assert_resolves_stock
}

test_strict_validation() {
    local stage traversal_stage tree_snapshot="$TEST_DIR/validation-tree"

    reset_fixture
    "$REAL_CP" -R "$MODULES_ROOT/$KVER" "$tree_snapshot"
    stage=$(make_stage validation validation)
    run_overlay install "$stage" '../bad-kernel' 0 0
    assert_failed_install_is_stock
    diff -r "$tree_snapshot" "$MODULES_ROOT/$KVER" >/dev/null || fail 'invalid KVER changed the module tree'

    mkdir -p "$MODULES_ROOT/../kernel"
    traversal_stage=$(make_stage traversal traversal '..')
    run_overlay install "$traversal_stage" '..' 0 0
    assert_failure
    [[ ! -e $MODULES_ROOT/../updates ]] || fail 'dot-dot KVER escaped the module root'
    assert_package_unchanged

    printf 'unexpected\n' > "$stage/extra.ko"
    run_overlay install "$stage" "$KVER" 0 0
    assert_failed_install_is_stock
    diff -r "$tree_snapshot" "$MODULES_ROOT/$KVER" >/dev/null || fail 'invalid stage changed the module tree'

    rm -f "$stage/extra.ko"
    printf 'kernel=wrong-kernel\n' > "$stage/.build-info"
    run_overlay install "$stage" "$KVER" 0 0
    assert_failed_install_is_stock
    diff -r "$tree_snapshot" "$MODULES_ROOT/$KVER" >/dev/null || fail 'mismatched metadata changed the module tree'
    pass 'strict KVER and exact stage validation'
}

test_first_and_replacement_install() {
    local first second expected_log

    reset_fixture
    first=$(make_stage first first)
    run_overlay install "$first" "$KVER" 0 0
    assert_success
    assert_overlay_tag first
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_package_unchanged
    expected_log=$'modprobe -r mt7925e\nmodprobe -r mt7925_common\nmodprobe -r mt792x_lib\nmodprobe -r mt76_connac_lib\nmodprobe -r mt76\ndepmod -a 7.2.0-overlay-test\nmodprobe mt7925e'
    assert_file_equals "$COMMAND_LOG" "$expected_log"

    : > "$COMMAND_LOG"
    second=$(make_stage second second)
    run_overlay install "$second" "$KVER" 0 0
    assert_success
    assert_overlay_tag second
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_package_unchanged
    pass 'first and replacement overlay installs'
}

test_other_kernel_untouched() {
    local stage before after

    reset_fixture
    make_stock_kernel "$OTHER_KVER"
    mkdir -p "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches"
    printf 'other kernel overlay\n' > "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko"
    before=$(cksum "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko")
    stage=$(make_stage scoped scoped)
    run_overlay install "$stage" "$KVER" 0 0
    assert_success
    after=$(cksum "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko")
    [[ $after == "$before" ]] || fail 'another kernel overlay changed'
    pass 'current-kernel scoping leaves another kernel path untouched'
}

test_pre_activation_failures() {
    local stage failure

    for failure in unload copy; do
        reset_fixture
        stage=$(make_stage "$failure" new)
        FAIL_STAGE=$failure
        run_overlay install "$stage" "$KVER" 0 0
        assert_failed_install_is_stock
        [[ $failure != unload ]] || assert_loaded_stack
    done
    pass 'partial unload and copy failures restore stock without package changes'
}

test_stock_rollbacks() {
    local stage failure

    for failure in depmod modinfo load; do
        reset_fixture
        stage=$(make_stage "$failure" new)
        FAIL_STAGE=$failure
        run_overlay install "$stage" "$KVER" 0 0
        assert_failed_install_is_stock
        assert_loaded_stack
    done
    pass 'depmod, resolution, and load failures roll back to stock'
}

test_previous_overlay_and_settings_rollback() {
    local old_stage new_stage config dispatcher old_config old_dispatcher

    reset_fixture
    old_stage=$(make_stage old old)
    run_overlay install "$old_stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    printf '# previous local line\n' >> "$config"
    printf '# previous local line\n' >> "$dispatcher"
    old_config=$(<"$config")
    old_dispatcher=$(<"$dispatcher")

    new_stage=$(make_stage rollback new)
    FAIL_STAGE=settings
    run_overlay install "$new_stage" "$KVER" 1 1
    assert_failure
    assert_overlay_tag old
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_file_equals "$config" "$old_config"
    assert_file_equals "$dispatcher" "$old_dispatcher"
    assert_package_unchanged
    pass 'post-load settings failure restores previous overlay and settings'
}

test_user_owned_settings() {
    local stage config dispatcher config_before dispatcher_before

    reset_fixture
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    printf '# user-owned config\noptions mt7925e disable_aspm=0\n' > "$config"
    printf '#!/bin/sh\n# user-owned dispatcher\n' > "$dispatcher"
    config_before=$(<"$config")
    dispatcher_before=$(<"$dispatcher")
    stage=$(make_stage user-settings new)
    run_overlay install "$stage" "$KVER" 1 1
    assert_failed_install_is_stock
    assert_file_equals "$config" "$config_before"
    assert_file_equals "$dispatcher" "$dispatcher_before"

    FAIL_STAGE=''
    run_overlay revert "$KVER"
    assert_success
    assert_file_equals "$config" "$config_before"
    assert_file_equals "$dispatcher" "$dispatcher_before"
    assert_package_unchanged
    pass 'user-owned settings are neither overwritten nor deleted'
}

test_optional_settings_and_dispatcher_filter() {
    local stage config dispatcher first second

    reset_fixture
    stage=$(make_stage settings settings)
    run_overlay install "$stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    assert_file_equals "$config" $'# Generated by mt7925-wifi-patches\noptions mt7925e disable_aspm=1'
    [[ -x $dispatcher ]] || fail 'dispatcher is not executable'
    {
        IFS= read -r first
        IFS= read -r second
    } < "$dispatcher"
    [[ $first == '#!/usr/bin/env bash' && $second == '# Generated by mt7925-wifi-patches' ]] ||
        fail 'dispatcher lacks its shebang and ownership header'

    : > "$IW_LOG"
    PATH="$FAKE_BIN:$PATH" FAKE_IW_LOG="$IW_LOG" FAKE_DRIVER_MODULE=mt7925e \
        CONNECTION_UUID=managed-connection DEVICE_IFACE=wlan0 "$dispatcher" wlan0 up
    assert_file_equals "$IW_LOG" 'dev wlan0 set power_save off'

    : > "$IW_LOG"
    PATH="$FAKE_BIN:$PATH" FAKE_IW_LOG="$IW_LOG" FAKE_DRIVER_MODULE=mt7925e \
        CONNECTION_UUID=managed-connection DEVICE_IFACE=wlan0 "$dispatcher" wlan0 down
    [[ ! -s $IW_LOG ]] || fail 'dispatcher changed power save for a non-up action'

    PATH="$FAKE_BIN:$PATH" FAKE_IW_LOG="$IW_LOG" FAKE_DRIVER_MODULE=mt7925e \
        DEVICE_IFACE=wlan0 "$dispatcher" wlan0 up
    [[ ! -s $IW_LOG ]] || fail 'dispatcher targeted an unmanaged interface'

    PATH="$FAKE_BIN:$PATH" FAKE_IW_LOG="$IW_LOG" FAKE_DRIVER_MODULE=other_driver \
        CONNECTION_UUID=managed-connection DEVICE_IFACE=wlan0 "$dispatcher" wlan0 up
    [[ ! -s $IW_LOG ]] || fail 'dispatcher targeted a non-mt7925e interface'

    PATH="$FAKE_BIN:$PATH" FAKE_IW_LOG="$IW_LOG" FAKE_DRIVER_MODULE=mt7925e \
        CONNECTION_UUID=managed-connection DEVICE_IFACE=wlan1 "$dispatcher" wlan0 up
    [[ ! -s $IW_LOG ]] || fail 'dispatcher targeted a different managed interface'
    pass 'both optional settings and MT7925-only managed dispatcher filtering'
}

test_revert_and_repeated_revert() {
    local stage config dispatcher

    reset_fixture
    stage=$(make_stage revert revert)
    run_overlay install "$stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"

    FAIL_STAGE=unload
    run_overlay revert "$KVER"
    assert_failure
    assert_overlay_tag revert
    assert_resolves_overlay
    assert_loaded_stack
    [[ -e $config && -e $dispatcher ]] || fail 'failed revert removed generated settings'
    assert_package_unchanged

    FAIL_STAGE=''
    run_overlay revert "$KVER"
    assert_success
    [[ ! -e $MODULES_ROOT/$KVER/updates/mt7925-wifi-patches ]] || fail 'revert left overlay active'
    [[ ! -e $config && ! -e $dispatcher ]] || fail 'revert left generated settings'
    assert_no_transaction_siblings
    assert_resolves_stock
    assert_loaded_stack
    assert_package_unchanged

    rm -rf "$ETC_ROOT"
    run_overlay revert "$KVER"
    assert_success
    [[ ! -e $ETC_ROOT ]] || fail 'repeated revert created an empty settings tree'
    assert_resolves_stock
    assert_loaded_stack
    assert_package_unchanged
    pass 'failed, successful, and repeated revert preserve a verified module state'
}

test_thin_revert_wrapper() {
    local -a args=()
    local line sudo_log="$TEST_DIR/sudo.log"

    rm -f "$sudo_log"
    PATH="$FAKE_BIN:$PATH" FAKE_SUDO_LOG="$sudo_log" FAKE_KVER="$KVER" "$REVERT" --yes > "$OUTPUT" 2>&1 ||
        fail '--yes revert wrapper failed'
    while IFS= read -r line; do args+=("$line"); done < "$sudo_log"
    [[ ${#args[@]} -eq 3 ]] || fail "wrapper passed ${#args[@]} sudo arguments"
    [[ ${args[0]} == "$ROOT_DIR/scripts/module-overlay.sh" ]] || fail 'wrapper called the wrong helper'
    [[ ${args[1]} == revert && ${args[2]} == "$KVER" ]] || fail 'wrapper passed wrong helper arguments'

    rm -f "$sudo_log"
    printf 'n\n' | PATH="$FAKE_BIN:$PATH" FAKE_SUDO_LOG="$sudo_log" FAKE_KVER="$KVER" \
        "$REVERT" > "$OUTPUT" 2>&1 || fail 'declined revert returned failure'
    [[ ! -e $sudo_log ]] || fail 'declined revert invoked sudo'

    if PATH="$FAKE_BIN:$PATH" FAKE_SUDO_LOG="$sudo_log" FAKE_KVER="$KVER" \
        "$REVERT" --unknown > "$OUTPUT" 2>&1; then
        fail 'revert wrapper accepted an unknown option'
    fi
    [[ ! -e $sudo_log ]] || fail 'invalid revert invoked sudo'
    pass 'thin revert wrapper confirmation and --yes behavior'
}

make_fake_commands
[[ -x $HELPER ]] || fail "missing helper: $HELPER"

test_strict_validation
test_first_and_replacement_install
test_other_kernel_untouched
test_pre_activation_failures
test_stock_rollbacks
test_previous_overlay_and_settings_rollback
test_user_owned_settings
test_optional_settings_and_dispatcher_filter
test_revert_and_repeated_revert
test_thin_revert_wrapper

printf 'Transactional module overlay tests passed.\n'
