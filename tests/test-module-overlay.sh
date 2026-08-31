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
MODINFO_LOG="$TEST_DIR/modinfo.log"
DEPMOD_STATE="$TEST_DIR/depmod.state"
IW_LOG="$TEST_DIR/iw.log"
WRITE_LOG="$TEST_DIR/writes.log"
FAIL_MARKER="$TEST_DIR/fail-once"
PACKAGE_SNAPSHOT="$TEST_DIR/package-snapshot"
KVER='7.2.0-overlay-test'
OTHER_KVER='7.1.0-other-test'
FAIL_STAGE=''
RUN_STATUS=0
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"
REAL_RM="$(command -v rm)"
REAL_MKDIR="$(command -v mkdir)"
IW_COMMAND=''
NETWORK_MANAGER_COMMAND=''
FLOCK_DIR=''
HOLD_READY=''
HOLD_RELEASE=''
ALLOW_PRESERVED_SETTINGS=0

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

assert_contains() {
    local file=$1 expected=$2

    grep -Fq -- "$expected" "$file" ||
        fail "$file does not contain $(printf '%q' "$expected")"
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
    printf 'kernel=%s\nsource_sha=0123456789abcdef0123456789abcdef01234567\ncompiler=test compiler\npatches=none\n' \
        "$kver" > "$stage/.build-info"
    printf '%s\n' "$stage"
}

reset_fixture() {
    rm -rf "$FAKE_ROOT" "$STAGES" "$PACKAGE_SNAPSHOT"
    rm -f "$OUTPUT" "$COMMAND_LOG" "$MODINFO_LOG" "$IW_LOG" "$WRITE_LOG" "$FAIL_MARKER" "$TEST_DIR/sudo.log"
    mkdir -p "$STAGES" "$ETC_ROOT/modprobe.d" "$ETC_ROOT/NetworkManager/dispatcher.d"
    make_stock_kernel "$KVER"
    write_loaded_stack
    : > "$MODINFO_LOG"
    printf 'stock\n' > "$DEPMOD_STATE"
    "$REAL_CP" -R "$MODULES_ROOT/$KVER/kernel" "$PACKAGE_SNAPSHOT"
    FAIL_STAGE=''
    IW_COMMAND="$FAKE_BIN/iw"
    NETWORK_MANAGER_COMMAND="$FAKE_BIN/NetworkManager"
    FLOCK_DIR=''
    HOLD_READY=''
    HOLD_RELEASE=''
    ALLOW_PRESERVED_SETTINGS=0
}

make_fake_commands() {
    mkdir -p "$FAKE_BIN"

    cat > "$FAKE_BIN/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    case $arg in
        "$FAKE_MODULES_ROOT"/*|"$FAKE_ETC_ROOT"/*)
            printf 'mkdir %s\n' "$*" >> "$FAKE_WRITE_LOG"
            break
            ;;
    esac
done
exec "$FAKE_REAL_MKDIR" "$@"
EOF

    cat > "$FAKE_BIN/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=${!#}
if [[ ${FAKE_FAIL_STAGE-} == copy ]]; then
    if [[ $destination == */.mt7925-wifi-patches/*/new/* ]]; then
        printf 'fake copy failure\n' >&2
        exit 70
    fi
fi
"$FAKE_REAL_CP" "$@"
if [[ ${FAKE_FAIL_STAGE-} == metadata-copy && $destination == */new/.build-info ]]; then
    printf 'unexpected=root-copy-corruption\n' >> "$destination"
fi
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
if [[ ${FAKE_FAIL_STAGE-} == settings-restore ]]; then
    source=$1
    if [[ $source == */dispatcher.new && $destination == "$FAKE_DISPATCHER_TARGET" ]]; then
        printf 'fake settings activation failure\n' >&2
        exit 71
    fi
    if [[ $source == */aspm.previous ]]; then
        printf 'fake settings restore failure\n' >&2
        exit 75
    fi
fi
exec "$FAKE_REAL_MV" "$@"
EOF

    cat > "$FAKE_BIN/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=${!#}
if [[ ${FAKE_FAIL_STAGE-} =~ ^cleanup-(install|revert)$ && $target == */.mt7925-wifi-patches/*/previous && -d $target && ! -e $FAKE_FAIL_MARKER ]]; then
    "$FAKE_REAL_RM" -f "$target/mt76.ko"
    : > "$FAKE_FAIL_MARKER"
    printf 'fake partial previous-overlay cleanup failure\n' >&2
    exit 77
fi
exec "$FAKE_REAL_RM" "$@"
EOF

    cat > "$FAKE_BIN/depmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'depmod %s\n' "$*" >> "$FAKE_COMMAND_LOG"
[[ $# -eq 2 && $1 == -a && $2 == "$FAKE_KVER" ]] || exit 2
if [[ -n ${FAKE_HOLD_READY-} && ! -e $FAKE_HOLD_READY ]]; then
    : > "$FAKE_HOLD_READY"
    while [[ ! -e ${FAKE_HOLD_RELEASE-} ]]; do
        sleep 0.01
    done
fi
for forbidden in \
    "$FAKE_MODULES_ROOT/$FAKE_KVER/updates/.mt7925-wifi-patches.new" \
    "$FAKE_MODULES_ROOT/$FAKE_KVER/updates/.mt7925-wifi-patches.previous"; do
    [[ ! -e $forbidden ]] || {
        printf 'depmod-visible transaction directory: %s\n' "$forbidden" >&2
        exit 78
    }
done
active="$FAKE_MODULES_ROOT/$FAKE_KVER/updates/mt7925-wifi-patches/.build-info"
resolution=stock
if [[ -f $active ]]; then
    read -r build _ < "${active%/.build-info}/mt7925e.ko"
    [[ -n $build ]] || exit 2
    resolution="overlay:$build"
fi
if [[ ${FAKE_FAIL_STAGE-} =~ ^(depmod|rollback-resolution|rollback-stack)$ && -f $active && ! -e $FAKE_FAIL_MARKER ]]; then
    if [[ $build == new ]]; then
        printf 'stale\n' > "$FAKE_DEPMOD_STATE"
        : > "$FAKE_FAIL_MARKER"
        printf 'fake depmod failure\n' >&2
        exit 72
    fi
fi
if [[ ${FAKE_FAIL_STAGE-} == rollback-resolution && -e $FAKE_FAIL_MARKER ]]; then
    printf 'stale\n' > "$FAKE_DEPMOD_STATE"
else
    printf '%s\n' "$resolution" > "$FAKE_DEPMOD_STATE"
fi
EOF

    cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 4 && $1 == -k && $2 == "$FAKE_KVER" && $3 == -n ]] || exit 2
module=$4
printf '%s\n' "$module" >> "$FAKE_MODINFO_LOG"
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
    read -r build _ < "$active/mt7925e.ko"
    if [[ $(<"$FAKE_DEPMOD_STATE") != "overlay:$build" ]]; then
        printf '%s/stale/%s\n' "$FAKE_MODULES_ROOT/$FAKE_KVER" "$file"
        exit 0
    fi
    if [[ ${FAKE_FAIL_STAGE-} == modinfo && $module == mt7925e ]]; then
        if [[ $build == new ]]; then
            printf '%s/%s\n' "$FAKE_MODULES_ROOT/$FAKE_KVER/kernel/drivers/net/wireless/mediatek/mt76" "$stock"
            exit 0
        fi
    fi
    printf '%s/%s\n' "$active" "$file"
else
    if [[ $(<"$FAKE_DEPMOD_STATE") != stock ]]; then
        printf '%s/stale/%s\n' "$FAKE_MODULES_ROOT/$FAKE_KVER" "$file"
        exit 0
    fi
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
if [[ ${FAKE_FAIL_STAGE-} == settings-live-modified && -f $active && ! -e $FAKE_FAIL_MARKER ]]; then
    printf '# transaction-time local modification\n' >> "$FAKE_ASPM_TARGET"
    : > "$FAKE_FAIL_MARKER"
    printf 'fake module-load failure after live settings modification\n' >&2
    exit 76
fi
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
if [[ ${FAKE_FAIL_STAGE-} == rollback-stack && -e $FAKE_FAIL_MARKER ]]; then
    cat > "$FAKE_PROC_MODULES" <<'PARTIAL'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
mt7925e 1 1 mt7925_common, Live 0x0
PARTIAL
    exit 0
fi
if [[ ${FAKE_FAIL_STAGE-} != settings-restore ]]; then
    if [[ ${FAKE_EXPECT_ASPM-0} == 1 ]]; then
        [[ -f $FAKE_ASPM_TARGET ]] || {
            printf 'ASPM setting was not active before module load\n' >&2
            exit 79
        }
    elif [[ ${FAKE_ALLOW_PRESERVED_SETTINGS-0} == 0 ]]; then
        [[ ! -e $FAKE_ASPM_TARGET ]] || {
            printf 'ASPM setting was not removed before module load\n' >&2
            exit 79
        }
    fi
    if [[ ${FAKE_EXPECT_DISPATCHER-0} == 1 ]]; then
        [[ -f $FAKE_DISPATCHER_TARGET ]] || {
            printf 'dispatcher was not active before module load\n' >&2
            exit 79
        }
    elif [[ ${FAKE_ALLOW_PRESERVED_SETTINGS-0} == 0 ]]; then
        [[ ! -e $FAKE_DISPATCHER_TARGET ]] || {
            printf 'dispatcher was not removed before module load\n' >&2
            exit 79
        }
    fi
fi
cat > "$FAKE_PROC_MODULES" <<'LOADED'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
mt7925_common 1 1 mt792x_lib, Live 0x0
mt7925e 1 1 mt7925_common, Live 0x0
LOADED
EOF

    cat > "$FAKE_BIN/NetworkManager" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

    cat > "$FAKE_BIN/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && $1 == -n && $2 =~ ^[0-9]+$ ]] || exit 2
[[ -n ${FAKE_FLOCK_DIR-} ]] || exit 0
mkdir "$FAKE_FLOCK_DIR" 2>/dev/null
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
    local expect_aspm=0 expect_dispatcher=0 run_output=${RUN_OUTPUT:-$OUTPUT}

    if [[ ${1-} == install ]]; then
        expect_aspm=${4-0}
        expect_dispatcher=${5-0}
    fi

    rm -f "$run_output"
    if PATH="$FAKE_BIN:$PATH" \
        MT7925_MODULES_ROOT="$MODULES_ROOT" \
        MT7925_ETC_ROOT="$ETC_ROOT" \
        MT7925_PROC_MODULES="$PROC_MODULES" \
        MT7925_MODPROBE="$FAKE_BIN/modprobe" \
        MT7925_DEPMOD="$FAKE_BIN/depmod" \
        MT7925_MODINFO="$FAKE_BIN/modinfo" \
        MT7925_IW="$IW_COMMAND" \
        MT7925_NETWORK_MANAGER="$NETWORK_MANAGER_COMMAND" \
        MT7925_FLOCK="$FAKE_BIN/flock" \
        FAKE_MODULES_ROOT="$MODULES_ROOT" \
        FAKE_PROC_MODULES="$PROC_MODULES" \
        FAKE_COMMAND_LOG="$COMMAND_LOG" \
        FAKE_WRITE_LOG="$WRITE_LOG" \
        FAKE_MODINFO_LOG="$MODINFO_LOG" \
        FAKE_DEPMOD_STATE="$DEPMOD_STATE" \
        FAKE_IW_LOG="$IW_LOG" \
        FAKE_FAIL_STAGE="$FAIL_STAGE" \
        FAKE_FAIL_MARKER="$FAIL_MARKER" \
        FAKE_FLOCK_DIR="$FLOCK_DIR" \
        FAKE_HOLD_READY="$HOLD_READY" \
        FAKE_HOLD_RELEASE="$HOLD_RELEASE" \
        FAKE_EXPECT_ASPM="$expect_aspm" \
        FAKE_EXPECT_DISPATCHER="$expect_dispatcher" \
        FAKE_ALLOW_PRESERVED_SETTINGS="$ALLOW_PRESERVED_SETTINGS" \
        FAKE_ASPM_TARGET="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf" \
        FAKE_DISPATCHER_TARGET="$dispatcher" \
        FAKE_ETC_ROOT="$ETC_ROOT" \
        FAKE_REAL_CP="$REAL_CP" \
        FAKE_REAL_MV="$REAL_MV" \
        FAKE_REAL_RM="$REAL_RM" \
        FAKE_REAL_MKDIR="$REAL_MKDIR" \
        FAKE_KVER="$KVER" \
        "$HELPER" "$@" > "$run_output" 2>&1; then
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
    local transaction="$MODULES_ROOT/.mt7925-wifi-patches/$KVER"

    [[ ! -e $updates/.mt7925-wifi-patches.new ]] || fail 'new transaction directory remained'
    [[ ! -e $updates/.mt7925-wifi-patches.previous ]] || fail 'previous transaction directory remained'
    [[ ! -e $transaction/new ]] || fail 'new external transaction directory remained'
    [[ ! -e $transaction/previous ]] || fail 'previous external transaction directory remained'
}

assert_resolves_stock() {
    local module expected actual

    for module in mt76 mt76_connac_lib mt792x_lib mt7925_common mt7925e; do
        expected=$(stock_path "$KVER" "$module")
        actual=$(FAKE_MODULES_ROOT="$MODULES_ROOT" FAKE_KVER="$KVER" FAKE_FAIL_STAGE='' \
            FAKE_MODINFO_LOG=/dev/null FAKE_DEPMOD_STATE="$DEPMOD_STATE" \
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
            FAKE_MODINFO_LOG=/dev/null FAKE_DEPMOD_STATE="$DEPMOD_STATE" \
            "$FAKE_BIN/modinfo" -k "$KVER" -n "$module")
        [[ $actual == "$expected" ]] || fail "$module did not resolve to overlay: $actual"
    done
}

assert_modinfo_calls() {
    local expected_count=$1 count=0 module
    local -a expected_modules=(mt76 mt76_connac_lib mt792x_lib mt7925_common mt7925e)

    while IFS= read -r module; do
        [[ $module == "${expected_modules[$((count % 5))]}" ]] ||
            fail "unexpected modinfo call $((count + 1)): $module"
        ((count += 1))
    done < "$MODINFO_LOG"
    [[ $count -eq $expected_count ]] || fail "expected $expected_count modinfo calls, got $count"
}

assert_overlay_tag() {
    local expected=$1 actual
    local module="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches/mt7925e.ko"

    [[ -f $module ]] || fail 'active overlay module is missing'
    read -r actual _ < "$module"
    [[ $actual == "$expected" ]] || fail "active overlay is not build $expected"
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

test_exact_metadata_validation() {
    local stage case_name

    for case_name in extra duplicate short-sha empty-compiler copied-corruption; do
        reset_fixture
        stage=$(make_stage "metadata-$case_name" metadata)
        case $case_name in
            extra)
                printf 'unexpected=value\n' >> "$stage/.build-info"
                ;;
            duplicate)
                printf 'patches=nan\n' >> "$stage/.build-info"
                ;;
            short-sha)
                printf 'kernel=%s\nsource_sha=0123456789abcdef\ncompiler=test compiler\npatches=none\n' \
                    "$KVER" > "$stage/.build-info"
                ;;
            empty-compiler)
                printf 'kernel=%s\nsource_sha=0123456789abcdef0123456789abcdef01234567\ncompiler=\npatches=none\n' \
                    "$KVER" > "$stage/.build-info"
                ;;
            copied-corruption)
                FAIL_STAGE=metadata-copy
                ;;
        esac
        run_overlay install "$stage" "$KVER" 0 0
        assert_failed_install_is_stock
        assert_no_transaction_siblings
        assert_package_unchanged
    done
    pass 'stage and root-owned metadata require the exact four-field producer contract'
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
    local stage before after transaction_before transaction_after

    reset_fixture
    make_stock_kernel "$OTHER_KVER"
    mkdir -p "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches"
    printf 'other kernel overlay\n' > "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko"
    mkdir -p "$MODULES_ROOT/.mt7925-wifi-patches/$OTHER_KVER/previous"
    printf 'other transaction\n' > "$MODULES_ROOT/.mt7925-wifi-patches/$OTHER_KVER/previous/mt7925e.ko"
    before=$(cksum "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko")
    transaction_before=$(cksum "$MODULES_ROOT/.mt7925-wifi-patches/$OTHER_KVER/previous/mt7925e.ko")
    stage=$(make_stage scoped scoped)
    run_overlay install "$stage" "$KVER" 0 0
    assert_success
    after=$(cksum "$MODULES_ROOT/$OTHER_KVER/updates/mt7925-wifi-patches/mt7925e.ko")
    transaction_after=$(cksum "$MODULES_ROOT/.mt7925-wifi-patches/$OTHER_KVER/previous/mt7925e.ko")
    [[ $after == "$before" ]] || fail 'another kernel overlay changed'
    [[ $transaction_after == "$transaction_before" ]] || fail 'another kernel transaction state changed'
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

test_power_save_dependency_preflight() {
    local stage missing

    for missing in iw NetworkManager; do
        reset_fixture
        stage=$(make_stage "missing-$missing" dependencies)
        if [[ $missing == iw ]]; then
            IW_COMMAND="$FAKE_BIN/missing-iw"
        else
            NETWORK_MANAGER_COMMAND="$FAKE_BIN/missing-NetworkManager"
        fi
        run_overlay install "$stage" "$KVER" 0 1
        assert_failed_install_is_stock
        assert_contains "$OUTPUT" "required command not found"
        [[ ! -s $WRITE_LOG ]] || fail "missing $missing dependency allowed a shared write"
        [[ ! -s $COMMAND_LOG ]] || fail "missing $missing dependency reached module operations"
        assert_no_transaction_siblings
        assert_package_unchanged
    done
    pass 'power-save dependency failures stop before transaction writes'
}

test_stock_rollbacks() {
    local stage failure expected_calls

    for failure in depmod modinfo load; do
        reset_fixture
        stage=$(make_stage "$failure" new)
        FAIL_STAGE=$failure
        run_overlay install "$stage" "$KVER" 0 0
        if [[ $failure == depmod ]]; then
            expected_calls=5
        else
            expected_calls=10
        fi
        assert_modinfo_calls "$expected_calls"
        assert_failed_install_is_stock
        assert_loaded_stack
    done
    pass 'depmod, resolution, and load failures roll back to stock'
}

test_rollback_verification_warnings() {
    local stage failure

    for failure in rollback-resolution rollback-stack; do
        reset_fixture
        stage=$(make_stage "$failure" new)
        FAIL_STAGE=$failure
        run_overlay install "$stage" "$KVER" 0 0
        assert_failure
        [[ $RUN_STATUS -eq 72 ]] || fail "rollback replaced original status 72 with $RUN_STATUS"
        assert_modinfo_calls 5
        if [[ $failure == rollback-resolution ]]; then
            assert_contains "$OUTPUT" 'rollback module resolution verification failed'
            assert_file_equals "$DEPMOD_STATE" 'stale'
        else
            assert_contains "$OUTPUT" 'rollback loaded module verification failed'
            assert_file_equals "$DEPMOD_STATE" 'stock'
        fi
        [[ ! -e $MODULES_ROOT/$KVER/updates/mt7925-wifi-patches ]] ||
            fail "$failure left a failed overlay active"
        assert_no_transaction_siblings
        assert_package_unchanged
    done
    pass 'rollback warns when restored resolution or loaded dependencies fail verification'
}

test_previous_overlay_and_settings_rollback() {
    local old_stage new_stage config dispatcher old_config old_dispatcher

    reset_fixture
    old_stage=$(make_stage old old)
    run_overlay install "$old_stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    old_config=$(<"$config")
    old_dispatcher=$(<"$dispatcher")

    : > "$MODINFO_LOG"
    new_stage=$(make_stage rollback new)
    FAIL_STAGE=settings
    run_overlay install "$new_stage" "$KVER" 1 1
    assert_modinfo_calls 10
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

test_failed_settings_restore_preserves_backup() {
    local old_stage new_stage config dispatcher old_config old_dispatcher backup
    local -a preserved=()

    reset_fixture
    old_stage=$(make_stage preserve-old old)
    run_overlay install "$old_stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    old_config=$(<"$config")
    old_dispatcher=$(<"$dispatcher")

    new_stage=$(make_stage preserve-new new)
    FAIL_STAGE=settings-restore
    run_overlay install "$new_stage" "$KVER" 1 1
    assert_failure
    [[ $RUN_STATUS -eq 71 ]] || fail "rollback replaced original status 71 with $RUN_STATUS"
    assert_contains "$OUTPUT" 'backup preserved at '
    assert_contains "$OUTPUT" 'restore it manually'

    shopt -s nullglob
    preserved=("$ETC_ROOT"/.mt7925-wifi-patches.*)
    shopt -u nullglob
    [[ ${#preserved[@]} -eq 1 ]] || fail "expected one preserved settings directory, got ${#preserved[@]}"
    backup="${preserved[0]}/aspm.previous"
    assert_file_equals "$backup" "$old_config"
    assert_file_equals "$dispatcher" "$old_dispatcher"
    assert_overlay_tag old
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_package_unchanged
    pass 'failed settings restore preserves byte-identical backup with recovery instructions'
}

test_modified_live_setting_and_previous_backup_survive_rollback() {
    local old_stage new_stage config dispatcher old_config old_dispatcher live_config backup
    local -a preserved=()

    reset_fixture
    old_stage=$(make_stage live-preserve-old old)
    run_overlay install "$old_stage" "$KVER" 1 1
    assert_success
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    old_config=$(<"$config")
    old_dispatcher=$(<"$dispatcher")
    live_config="$old_config"$'\n# transaction-time local modification'

    new_stage=$(make_stage live-preserve-new new)
    FAIL_STAGE=settings-live-modified
    run_overlay install "$new_stage" "$KVER" 1 1
    assert_failure
    [[ $RUN_STATUS -eq 76 ]] || fail "rollback replaced original status 76 with $RUN_STATUS"
    assert_file_equals "$config" "$live_config"

    shopt -s nullglob
    preserved=("$ETC_ROOT"/.mt7925-wifi-patches.*)
    shopt -u nullglob
    [[ ${#preserved[@]} -eq 1 ]] || fail "expected one preserved settings directory, got ${#preserved[@]}"
    backup="${preserved[0]}/aspm.previous"
    assert_file_equals "$backup" "$old_config"
    assert_file_equals "$dispatcher" "$old_dispatcher"
    assert_contains "$OUTPUT" "live setting preserved at $config"
    assert_contains "$OUTPUT" "previous backup preserved at $backup"
    assert_contains "$OUTPUT" 'compare with: diff -u --'
    assert_overlay_tag old
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_package_unchanged
    pass 'rollback preserves modified live setting and previous backup with recovery instructions'
}

test_cleanup_failures_preserve_committed_state() {
    local old_stage new_stage transaction

    reset_fixture
    old_stage=$(make_stage cleanup-install-old old)
    run_overlay install "$old_stage" "$KVER" 0 0
    assert_success

    new_stage=$(make_stage cleanup-install-new new)
    FAIL_STAGE=cleanup-install
    run_overlay install "$new_stage" "$KVER" 0 0
    assert_success
    assert_contains "$OUTPUT" 'cleanup warning'
    assert_overlay_tag new
    assert_resolves_overlay
    assert_loaded_stack
    transaction="$MODULES_ROOT/.mt7925-wifi-patches/$KVER"
    [[ -d $transaction/previous ]] || fail 'partial previous backup was not preserved after install cleanup failure'
    [[ ! -e $transaction/new ]] || fail 'new transaction directory remained after install cleanup failure'
    assert_package_unchanged

    reset_fixture
    old_stage=$(make_stage cleanup-revert-old old)
    run_overlay install "$old_stage" "$KVER" 0 0
    assert_success
    FAIL_STAGE=cleanup-revert
    run_overlay revert "$KVER"
    assert_success
    assert_contains "$OUTPUT" 'cleanup warning'
    [[ ! -e $MODULES_ROOT/$KVER/updates/mt7925-wifi-patches ]] ||
        fail 'revert cleanup failure restored the removed overlay'
    [[ -d $MODULES_ROOT/.mt7925-wifi-patches/$KVER/previous ]] ||
        fail 'partial previous backup was not preserved after revert cleanup failure'
    assert_resolves_stock
    assert_loaded_stack
    assert_package_unchanged
    pass 'install and revert cleanup failures preserve the committed verified state'
}

test_concurrent_transaction_lock() {
    local first_stage second_stage first_output="$TEST_DIR/first-transaction.output"
    local second_output="$TEST_DIR/second-transaction.output" first_pid second_status

    reset_fixture
    first_stage=$(make_stage concurrent-first first)
    second_stage=$(make_stage concurrent-second second)
    FLOCK_DIR="$TEST_DIR/transaction-lock-held"
    HOLD_READY="$TEST_DIR/first-depmod.ready"
    HOLD_RELEASE="$TEST_DIR/first-depmod.release"
    rm -rf "$FLOCK_DIR"
    rm -f "$HOLD_READY" "$HOLD_RELEASE"

    RUN_OUTPUT=$first_output run_overlay install "$first_stage" "$KVER" 0 0 &
    first_pid=$!
    for _ in {1..1000}; do
        [[ -e $HOLD_READY ]] && break
        sleep 0.01
    done
    [[ -e $HOLD_READY ]] || {
        touch "$HOLD_RELEASE"
        wait "$first_pid" || true
        fail 'first transaction did not reach depmod'
    }
    assert_overlay_tag first

    RUN_OUTPUT=$second_output run_overlay install "$second_stage" "$KVER" 0 0
    second_status=$RUN_STATUS
    assert_overlay_tag first

    touch "$HOLD_RELEASE"
    wait "$first_pid" || fail 'first locked transaction failed'
    [[ $second_status -ne 0 ]] || fail 'concurrent privileged transaction loser was accepted'
    assert_contains "$second_output" 'another module transaction is already running'
    assert_overlay_tag first
    assert_resolves_overlay
    assert_loaded_stack
    assert_no_transaction_siblings
    assert_package_unchanged

    rm -rf "$FLOCK_DIR"
    FLOCK_DIR=''
    HOLD_READY=''
    HOLD_RELEASE=''
    pass 'global transaction lock rejects a concurrent writer before shared changes'
}

test_exact_generated_settings_replace_and_revert() {
    local old_stage new_stage config dispatcher

    reset_fixture
    config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
    old_stage=$(make_stage exact-old old)
    run_overlay install "$old_stage" "$KVER" 1 1
    assert_success

    new_stage=$(make_stage exact-new new)
    run_overlay install "$new_stage" "$KVER" 1 1
    assert_success
    assert_overlay_tag new
    assert_file_equals "$config" $'# Generated by mt7925-wifi-patches\noptions mt7925e disable_aspm=1'
    [[ -x $dispatcher ]] || fail 'exact generated dispatcher was not replaced'

    run_overlay revert "$KVER"
    assert_success
    [[ ! -e $config && ! -e $dispatcher ]] || fail 'revert left exact generated settings'
    assert_resolves_stock
    assert_loaded_stack
    assert_package_unchanged
    pass 'exact generated settings are replaceable and removable'
}

test_modified_generated_settings_are_user_owned() {
    local modified old_stage new_stage config dispatcher modified_file other_file
    local modified_before other_before

    for modified in aspm dispatcher; do
        reset_fixture
        config="$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
        dispatcher="$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"
        old_stage=$(make_stage "modified-$modified-old" old)
        run_overlay install "$old_stage" "$KVER" 1 1
        assert_success

        if [[ $modified == aspm ]]; then
            modified_file=$config
            other_file=$dispatcher
        else
            modified_file=$dispatcher
            other_file=$config
        fi
        printf '# local modification\n' >> "$modified_file"
        modified_before=$(<"$modified_file")
        other_before=$(<"$other_file")

        new_stage=$(make_stage "modified-$modified-new" new)
        run_overlay install "$new_stage" "$KVER" 1 1
        assert_failure
        assert_overlay_tag old
        assert_file_equals "$modified_file" "$modified_before"
        assert_file_equals "$other_file" "$other_before"
        assert_no_transaction_siblings
        assert_package_unchanged

        ALLOW_PRESERVED_SETTINGS=1
        run_overlay revert "$KVER"
        assert_success
        assert_file_equals "$modified_file" "$modified_before"
        [[ ! -e $other_file ]] || fail "revert preserved exact generated $other_file"
        assert_resolves_stock
        assert_loaded_stack
        assert_package_unchanged
    done
    pass 'locally modified marked settings are refused and preserved as user-owned'
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
    ALLOW_PRESERVED_SETTINGS=1
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
    ALLOW_PRESERVED_SETTINGS=1
    run_overlay revert "$KVER"
    assert_failure
    assert_overlay_tag revert
    assert_resolves_overlay
    assert_loaded_stack
    [[ -e $config && -e $dispatcher ]] || fail 'failed revert removed generated settings'
    assert_package_unchanged

    FAIL_STAGE=''
    ALLOW_PRESERVED_SETTINGS=0
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
        MT7925_MODULES_ROOT="$MODULES_ROOT" MT7925_ETC_ROOT="$ETC_ROOT" \
        "$REVERT" > "$OUTPUT" 2>&1 || fail 'declined revert returned failure'
    [[ ! -e $sudo_log ]] || fail 'declined revert invoked sudo'
    assert_contains "$OUTPUT" "$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches"
    assert_contains "$OUTPUT" "$ETC_ROOT/modprobe.d/99-mt7925-wifi-patches.conf"
    assert_contains "$OUTPUT" "$ETC_ROOT/NetworkManager/dispatcher.d/99-mt7925-wifi-patches"

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
test_exact_metadata_validation
test_first_and_replacement_install
test_other_kernel_untouched
test_pre_activation_failures
test_power_save_dependency_preflight
test_stock_rollbacks
test_rollback_verification_warnings
test_previous_overlay_and_settings_rollback
test_failed_settings_restore_preserves_backup
test_modified_live_setting_and_previous_backup_survive_rollback
test_cleanup_failures_preserve_committed_state
test_concurrent_transaction_lock
test_exact_generated_settings_replace_and_revert
test_modified_generated_settings_are_user_owned
test_user_owned_settings
test_optional_settings_and_dispatcher_filter
test_revert_and_repeated_revert
test_thin_revert_wrapper

printf 'Transactional module overlay tests passed.\n'
