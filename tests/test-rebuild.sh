#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBUILD="$ROOT_DIR/mt76-rebuild.sh"
TEST_DIR="$(mktemp -d)"
REAL_GIT="$(command -v git)"
REMOTE="$TEST_DIR/wireless-next.git"
REMOTE_WORK="$TEST_DIR/remote-work"
FAKE_BIN="$TEST_DIR/fake-bin"
KDIR="$TEST_DIR/kernel-build"
SIG_ENFORCE="$TEST_DIR/sig-enforce"
LOCKDOWN="$TEST_DIR/lockdown"
KVER='7.2.0-test'
SOURCE_SHA=''
RUN_ROOT=''
INSTALL_HELPER=''
INSTALL_LOG=''
INSTALL_COUNT=''
STAGE_SNAPSHOT=''
MAKE_LOG=''
OUTPUT=''
FAIL_STAGE=''
FAKE_ROOT=0
FAKE_PATCHES=$'action-frame\naql\n'
FLOCK_DIR=''
INSTALL_READY=''
INSTALL_RELEASE=''

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file=$1 expected=$2

    grep -Fq -- "$expected" "$file" ||
        fail "$file does not contain $(printf '%q' "$expected")"
}

clear_install() {
    rm -f "$INSTALL_LOG" "$INSTALL_COUNT"
    rm -rf "$STAGE_SNAPSHOT"
}

assert_no_install() {
    [[ ! -e $INSTALL_COUNT ]] ||
        fail "install helper ran during ${FAIL_STAGE:-failed preflight}"
}

make_remote() {
    "$REAL_GIT" init --quiet --bare "$REMOTE"
    "$REAL_GIT" init --quiet "$REMOTE_WORK"
    "$REAL_GIT" -C "$REMOTE_WORK" checkout --quiet -b main
    mkdir -p \
        "$REMOTE_WORK/drivers/net/wireless/mediatek/mt76/mt7925"
    printf 'obj-y += mt7925/\n' \
        > "$REMOTE_WORK/drivers/net/wireless/mediatek/mt76/Makefile"
    printf 'obj-m += mt7925e.o\n' \
        > "$REMOTE_WORK/drivers/net/wireless/mediatek/mt76/mt7925/Makefile"
    "$REAL_GIT" -C "$REMOTE_WORK" add .
    "$REAL_GIT" -C "$REMOTE_WORK" \
        -c user.name='Rebuild Test' \
        -c user.email='rebuild-test@example.invalid' \
        commit --quiet -m fixture
    "$REAL_GIT" -C "$REMOTE_WORK" remote add origin "$REMOTE"
    "$REAL_GIT" -C "$REMOTE_WORK" push --quiet -u origin main
    "$REAL_GIT" --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
    SOURCE_SHA=$("$REAL_GIT" -C "$REMOTE_WORK" rev-parse HEAD)
}

make_fake_commands() {
    mkdir -p "$FAKE_BIN" "$KDIR"

    cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
if [[ $FAIL_STAGE == fetch && " $* " == *' fetch '* ]]; then
    printf 'fake fetch failure\n' >&2
    exit 70
fi
exec "$REAL_GIT" "$@"
EOF

    cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -u ]] || exit 2
if [[ $FAKE_ROOT == 1 ]]; then
    printf '0\n'
else
    printf '1000\n'
fi
EOF

    cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -r ]] || exit 2
printf '%s\n' "$FAKE_KVER"
EOF

    cat > "$FAKE_BIN/nproc" <<'EOF'
#!/usr/bin/env bash
printf '2\n'
EOF

    cat > "$FAKE_BIN/clang" <<'EOF'
#!/usr/bin/env bash
printf 'clang version rebuild-test\n'
EOF

    cat > "$FAKE_BIN/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s ' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"

mt76_dir=''
for arg in "$@"; do
    case $arg in
        M=*) mt76_dir=${arg#M=} ;;
    esac
done
[[ -n $mt76_dir ]] || exit 2

case " $* " in
    *' clean '*)
        rm -f \
            "$mt76_dir/mt76.ko" \
            "$mt76_dir/mt76-connac-lib.ko" \
            "$mt76_dir/mt792x-lib.ko" \
            "$mt76_dir/mt7925/mt7925-common.ko" \
            "$mt76_dir/mt7925/mt7925e.ko"
        ;;
    *' modules '*)
        if [[ $FAIL_STAGE == build ]]; then
            printf 'fake build failure\n' >&2
            exit 71
        fi
        mkdir -p "$mt76_dir/mt7925"
        printf 'module\n' > "$mt76_dir/mt76.ko"
        printf 'module\n' > "$mt76_dir/mt76-connac-lib.ko"
        printf 'module\n' > "$mt76_dir/mt792x-lib.ko"
        printf 'module\n' > "$mt76_dir/mt7925/mt7925-common.ko"
        if [[ $FAIL_STAGE != expected-file ]]; then
            printf 'module\n' > "$mt76_dir/mt7925/mt7925e.ko"
        fi
        ;;
esac
EOF

    cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
module=${!#}
if [[ $FAIL_STAGE == module-format && ${module##*/} == mt76.ko ]]; then
    printf 'ASCII text\n'
else
    printf 'ELF 64-bit LSB relocatable\n'
fi
EOF

    cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -F && $# -eq 3 ]] || exit 2
case $2 in
    vermagic)
        if [[ $FAIL_STAGE == vermagic && ${3##*/} == mt76.ko ]]; then
            printf 'wrong-kernel SMP\n'
        elif [[ $FAIL_STAGE == vermagic-prefix && ${3##*/} == mt76.ko ]]; then
            printf '%s0 SMP\n' "$FAKE_KVER"
        else
            printf '%s SMP preempt mod_unload\n' "$FAKE_KVER"
        fi
        ;;
    signer)
        [[ $FAIL_STAGE == signature ]] || printf 'Rebuild Test Signer\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF

    cat > "$FAKE_BIN/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && $1 == -n && $2 =~ ^[0-9]+$ ]] || exit 2
[[ -n ${FAKE_FLOCK_DIR-} ]] || exit 0
mkdir "$FAKE_FLOCK_DIR" 2>/dev/null
EOF

    cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1##*/} == mt76-rebuild.sh ]]; then
    printf 'whole-script sudo is forbidden\n' >&2
    exit 72
fi
exec "$@"
EOF

    chmod +x "$FAKE_BIN"/*
}

make_run_root() {
    local name=$1

    RUN_ROOT="$TEST_DIR/$name"
    INSTALL_HELPER="$RUN_ROOT/install-helper"
    INSTALL_LOG="$RUN_ROOT/install.log"
    INSTALL_COUNT="$RUN_ROOT/install.count"
    STAGE_SNAPSHOT="$RUN_ROOT/stage"
    MAKE_LOG="$RUN_ROOT/make.log"
    OUTPUT="$RUN_ROOT/output"
    mkdir -p "$RUN_ROOT/scripts"
    cp "$REBUILD" "$RUN_ROOT/mt76-rebuild.sh"

    cat > "$RUN_ROOT/scripts/compat.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == apply && $# -eq 3 ]] || exit 2
if [[ $FAIL_STAGE == patch ]]; then
    printf 'fake patch failure\n' >&2
    exit 73
fi
printf '%s' "$FAKE_PATCHES"
EOF

    cat > "$INSTALL_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f $FAKE_INSTALL_COUNT ]] || read -r count < "$FAKE_INSTALL_COUNT"
printf '%s\n' "$((count + 1))" > "$FAKE_INSTALL_COUNT"
printf '%s\n' "$@" > "$FAKE_INSTALL_LOG"
rm -rf "$FAKE_STAGE_SNAPSHOT"
cp -R "$2" "$FAKE_STAGE_SNAPSHOT"
if [[ -n ${FAKE_INSTALL_READY-} && $count -eq 0 ]]; then
    : > "$FAKE_INSTALL_READY"
    while [[ ! -e ${FAKE_INSTALL_RELEASE-} ]]; do
        sleep 0.01
    done
fi
EOF

    chmod +x \
        "$RUN_ROOT/mt76-rebuild.sh" \
        "$RUN_ROOT/scripts/compat.sh" \
        "$INSTALL_HELPER"
}

run_rebuild() {
    PATH="$FAKE_BIN:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FAKE_GIT_LOG="$RUN_ROOT/git.log" \
    FAKE_KVER="$KVER" \
    FAKE_ROOT="$FAKE_ROOT" \
    FAKE_MAKE_LOG="$MAKE_LOG" \
    FAKE_INSTALL_LOG="$INSTALL_LOG" \
    FAKE_INSTALL_COUNT="$INSTALL_COUNT" \
    FAKE_STAGE_SNAPSHOT="$STAGE_SNAPSHOT" \
    FAKE_FLOCK_DIR="$FLOCK_DIR" \
    FAKE_INSTALL_READY="$INSTALL_READY" \
    FAKE_INSTALL_RELEASE="$INSTALL_RELEASE" \
    FAIL_STAGE="$FAIL_STAGE" \
    FAKE_PATCHES="$FAKE_PATCHES" \
    MT7925_WIRELESS_NEXT_REPO="$REMOTE" \
    MT7925_KDIR="$KDIR" \
    MT7925_SIG_ENFORCE_FILE="$SIG_ENFORCE" \
    MT7925_LOCKDOWN_FILE="$LOCKDOWN" \
    MT7925_INSTALL_HELPER="$INSTALL_HELPER" \
    LLVM=1 CC=clang \
        "$RUN_ROOT/mt76-rebuild.sh" "$@" > "$OUTPUT" 2>&1
}

assert_install_args() {
    local expected_aspm=$1 expected_power_save=$2 line
    local -a args=()

    [[ $(<"$INSTALL_COUNT") == 1 ]] || fail 'expected one install-helper invocation'
    while IFS= read -r line; do
        args+=("$line")
    done < "$INSTALL_LOG"
    [[ ${#args[@]} -eq 5 ]] || fail "expected 5 helper arguments, got ${#args[@]}"
    [[ ${args[0]} == install ]] || fail 'helper command is not install'
    [[ ${args[2]} == "$KVER" ]] || fail 'helper kernel argument is wrong'
    [[ ${args[3]} == "$expected_aspm" ]] || fail 'helper ASPM argument is wrong'
    [[ ${args[4]} == "$expected_power_save" ]] || fail 'helper power-save argument is wrong'
}

assert_stage() {
    local expected_metadata=$1 actual_files actual_metadata
    local expected_files=$'./.build-info\n./mt76-connac-lib.ko\n./mt76.ko\n./mt7925-common.ko\n./mt7925e.ko\n./mt792x-lib.ko'

    actual_files=$(cd "$STAGE_SNAPSHOT" && find . -type f -print | LC_ALL=C sort)
    [[ $actual_files == "$expected_files" ]] ||
        fail "unexpected staged files: $(printf '%q' "$actual_files")"
    actual_metadata=$(<"$STAGE_SNAPSHOT/.build-info")
    [[ $actual_metadata == "$expected_metadata" ]] ||
        fail "unexpected build metadata: $(printf '%q' "$actual_metadata")"
}

assert_make_variables() {
    local line calls=0

    while IFS= read -r line; do
        ((calls += 1))
        line=" $line "
        [[ $line == *' LLVM=1 '* ]] || fail "make call $calls omitted LLVM=1"
        [[ $line == *' CC=clang '* ]] || fail "make call $calls omitted CC=clang"
    done < "$MAKE_LOG"
    [[ $calls -gt 0 ]] || fail 'make was not invoked'
}

assert_pcie_only_build() {
    local line expected arg modules_calls=0
    local -a enabled=(
        CONFIG_MT76_CORE=m
        CONFIG_MT76_CONNAC_LIB=m
        CONFIG_MT792x_LIB=m
        CONFIG_MT7925_COMMON=m
        CONFIG_MT7925E=m
    )
    local -a disabled=(
        CONFIG_MT76_USB=n
        CONFIG_MT76_SDIO=n
        CONFIG_MT76x02_LIB=n
        CONFIG_MT76x02_USB=n
        CONFIG_MT792x_USB=n
        CONFIG_MT76_NPU=
        CONFIG_MT76x0_COMMON=n
        CONFIG_MT76x2_COMMON=n
        CONFIG_MT7603E=n
        CONFIG_MT7615_COMMON=n
        CONFIG_MT7915E=n
        CONFIG_MT7921_COMMON=n
        CONFIG_MT7996E=n
        CONFIG_MT7925U=n
    )

    while IFS= read -r line; do
        line=" $line "
        [[ $line == *' modules '* ]] || continue
        ((modules_calls += 1))
        for expected in "${enabled[@]}" "${disabled[@]}"; do
            [[ $line == *" $expected "* ]] ||
                fail "PCIe-only build omitted $expected"
        done
        for arg in $line; do
            case $arg in
                CONFIG_MT*=m)
                    case " ${enabled[*]} " in
                        *" $arg "*) ;;
                        *) fail "PCIe-only build enabled unrelated $arg" ;;
                    esac
                    ;;
            esac
        done
    done < "$MAKE_LOG"
    [[ $modules_calls -eq 1 ]] || fail "expected one modules build, got $modules_calls"
}

assert_shallow_clone() {
    local actual expected

    expected="clone --depth=1 --branch main --no-checkout $REMOTE $RUN_ROOT/wireless-next"
    IFS= read -r actual < "$RUN_ROOT/git.log"
    [[ $actual == "$expected" ]] ||
        fail "expected shallow main clone, got $(printf '%q' "$actual")"
}

assert_detached_source() {
    [[ $("$REAL_GIT" -C "$RUN_ROOT/wireless-next" rev-parse HEAD) == "$SOURCE_SHA" ]] ||
        fail 'source checkout is not at the fetched SHA'
    if "$REAL_GIT" -C "$RUN_ROOT/wireless-next" symbolic-ref -q HEAD >/dev/null; then
        fail 'source checkout remained attached to a branch'
    fi
}

test_concurrent_rebuild_lock() {
    local first_output="$RUN_ROOT/first-rebuild.output"
    local second_output="$RUN_ROOT/second-rebuild.output"
    local first_pid first_status second_status git_before git_after

    clear_install
    FAIL_STAGE=''
    FLOCK_DIR="$RUN_ROOT/build-lock-held"
    INSTALL_READY="$RUN_ROOT/first-install.ready"
    INSTALL_RELEASE="$RUN_ROOT/first-install.release"
    rm -rf "$FLOCK_DIR"
    rm -f "$INSTALL_READY" "$INSTALL_RELEASE"

    OUTPUT=$first_output
    run_rebuild &
    first_pid=$!
    for _ in {1..1000}; do
        [[ -e $INSTALL_READY ]] && break
        sleep 0.01
    done
    [[ -e $INSTALL_READY ]] || {
        touch "$INSTALL_RELEASE"
        wait "$first_pid" || true
        fail 'first rebuild did not reach the installer handoff'
    }

    git_before=$(wc -l < "$RUN_ROOT/git.log")
    OUTPUT=$second_output
    if run_rebuild; then
        second_status=0
    else
        second_status=$?
    fi
    git_after=$(wc -l < "$RUN_ROOT/git.log")

    touch "$INSTALL_RELEASE"
    if wait "$first_pid"; then
        first_status=0
    else
        first_status=$?
    fi

    [[ $first_status -eq 0 ]] || fail "first concurrent rebuild failed with $first_status"
    [[ $second_status -ne 0 ]] || fail 'concurrent rebuild loser was accepted'
    assert_contains "$second_output" 'another rebuild is already running'
    [[ $git_after -eq $git_before ]] || fail 'concurrent rebuild loser wrote the shared source tree'
    [[ $(<"$INSTALL_COUNT") == 1 ]] || fail 'concurrent rebuild loser reached the installer'

    rm -rf "$FLOCK_DIR"
    FLOCK_DIR=''
    INSTALL_READY=''
    INSTALL_RELEASE=''
    OUTPUT="$RUN_ROOT/output"
}

assert_failure_before_install() {
    FAIL_STAGE=$1
    printf 'N\n' > "$SIG_ENFORCE"
    printf '[none] integrity confidentiality\n' > "$LOCKDOWN"
    [[ $FAIL_STAGE != signature ]] || printf 'Y\n' > "$SIG_ENFORCE"
    clear_install
    if run_rebuild; then
        fail "$FAIL_STAGE failure was accepted"
    fi
    assert_no_install
}

make_remote
make_fake_commands

make_run_root root-run
FAKE_ROOT=1
clear_install
if run_rebuild; then
    fail 'direct root execution was accepted'
fi
assert_contains "$OUTPUT" 'normal user'
[[ ! -e $RUN_ROOT/wireless-next ]] || fail 'root execution cloned source'
assert_no_install

make_run_root normal-run
FAKE_ROOT=0
FAIL_STAGE=''
printf 'N\n' > "$SIG_ENFORCE"
printf '[none] integrity confidentiality\n' > "$LOCKDOWN"

if ! run_rebuild --help; then
    fail '--help failed'
fi
assert_contains "$OUTPUT" 'usage:'
[[ ! -e $RUN_ROOT/wireless-next ]] || fail '--help cloned source'

if run_rebuild --unknown; then
    fail 'unknown option was accepted'
fi
assert_contains "$OUTPUT" 'usage:'
[[ ! -e $RUN_ROOT/wireless-next ]] || fail 'unknown option cloned source'

clear_install
if ! run_rebuild; then
    fail "success flow failed: $(<"$OUTPUT")"
fi
assert_contains "$OUTPUT" "$SOURCE_SHA"
assert_install_args 0 0
assert_shallow_clone
assert_detached_source
assert_make_variables
assert_pcie_only_build
assert_stage $'kernel=7.2.0-test\nsource_sha='"$SOURCE_SHA"$'\ncompiler=clang version rebuild-test\npatches=action-frame,aql'

clear_install
run_rebuild --disable-aspm || fail '--disable-aspm flow failed'
assert_install_args 1 0

clear_install
run_rebuild --disable-power-save || fail '--disable-power-save flow failed'
assert_install_args 0 1

test_concurrent_rebuild_lock

assert_failure_before_install fetch
assert_failure_before_install patch
assert_failure_before_install build
assert_failure_before_install expected-file
assert_failure_before_install module-format
assert_failure_before_install vermagic
assert_failure_before_install vermagic-prefix
assert_failure_before_install signature

FAIL_STAGE=signature
printf 'N\n' > "$SIG_ENFORCE"
rm -f "$LOCKDOWN"
clear_install
if ! run_rebuild; then
    fail 'absent lockdown interface blocked normal flow'
fi
assert_install_args 0 0

printf '[none] integrity confidentiality\n' > "$LOCKDOWN"
clear_install
if ! run_rebuild; then
    fail 'inactive lockdown rejected unsigned modules'
fi
assert_install_args 0 0

FAIL_STAGE=''
printf 'N\n' > "$SIG_ENFORCE"
chmod 000 "$LOCKDOWN"
clear_install
if run_rebuild; then
    chmod 600 "$LOCKDOWN"
    fail 'existing unreadable lockdown interface was accepted'
fi
chmod 600 "$LOCKDOWN"
assert_contains "$OUTPUT" 'cannot determine kernel lockdown state'
assert_no_install

for lockdown_state in 'none [integrity] confidentiality' 'none integrity [confidentiality]'; do
    FAIL_STAGE=signature
    printf 'N\n' > "$SIG_ENFORCE"
    printf '%s\n' "$lockdown_state" > "$LOCKDOWN"
    clear_install
    if run_rebuild; then
        fail "unsigned modules were accepted under lockdown: $lockdown_state"
    fi
    assert_no_install
done

for lockdown_state in 'none [integrity] confidentiality' 'none integrity [confidentiality]'; do
    FAIL_STAGE=''
    printf 'N\n' > "$SIG_ENFORCE"
    printf '%s\n' "$lockdown_state" > "$LOCKDOWN"
    clear_install
    if ! run_rebuild; then
        fail "signed modules were rejected under lockdown: $lockdown_state"
    fi
    assert_install_args 0 0
done

FAIL_STAGE=signature
printf 'Y\n' > "$SIG_ENFORCE"
rm -f "$LOCKDOWN"
clear_install
if run_rebuild; then
    fail 'sig_enforce accepted unsigned modules without lockdown interface'
fi
assert_contains "$OUTPUT" 'unsigned'
assert_no_install

FAIL_STAGE=''
printf 'N\n' > "$SIG_ENFORCE"
printf 'unknown\n' > "$LOCKDOWN"
clear_install
if run_rebuild; then
    fail 'unknown lockdown state was accepted'
fi
assert_no_install

FAIL_STAGE=''
printf 'unknown\n' > "$SIG_ENFORCE"
printf '[none] integrity confidentiality\n' > "$LOCKDOWN"
clear_install
if run_rebuild; then
    fail 'unknown signature-enforcement state was accepted'
fi
assert_no_install

FAKE_PATCHES=''
printf 'Y\n' > "$SIG_ENFORCE"
rm -f "$LOCKDOWN"
clear_install
if ! run_rebuild --disable-aspm --disable-power-save; then
    fail "signed optional-settings flow failed: $(<"$OUTPUT")"
fi
assert_install_args 1 1
assert_stage $'kernel=7.2.0-test\nsource_sha='"$SOURCE_SHA"$'\ncompiler=clang version rebuild-test\npatches=none'

printf 'Rebuild source, build, staging, and preflight tests passed at %s.\n' "$SOURCE_SHA"
