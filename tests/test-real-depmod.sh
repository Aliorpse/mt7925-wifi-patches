#!/usr/bin/env bash

set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: real depmod evidence requires Linux.\n'
    exit 0
fi

for command in cc depmod flock modinfo; do
    command -v "$command" >/dev/null || {
        printf 'SKIP: real depmod evidence requires %s.\n' "$command"
        exit 0
    }
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/module-overlay.sh"
TEST_DIR=$(mktemp -d)
FAKE_ROOT="$TEST_DIR/root"
MODULES_ROOT="$FAKE_ROOT/lib/modules"
ETC_ROOT="$FAKE_ROOT/etc"
PROC_MODULES="$FAKE_ROOT/proc/modules"
FAKE_BIN="$TEST_DIR/bin"
KVER='1.0.0-depmod-test'
REAL_DEPMOD=$(command -v depmod)
REAL_MODINFO=$(command -v modinfo)
FILES=(mt76.ko mt76-connac-lib.ko mt792x-lib.ko mt7925-common.ko mt7925e.ko)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$FAKE_BIN" "$ETC_ROOT" "${PROC_MODULES%/*}"
: > "$PROC_MODULES"

cat > "$TEST_DIR/module.c" <<'EOF'
const char vermagic[] __attribute__((section(".modinfo"), used)) =
    "vermagic=1.0.0-depmod-test";
const char license[] __attribute__((section(".modinfo"), used)) =
    "license=GPL";
EOF
cc -c "$TEST_DIR/module.c" -o "$TEST_DIR/module.ko"

stock_base="$MODULES_ROOT/$KVER/kernel/drivers/net/wireless/mediatek/mt76"
mkdir -p "$stock_base/mt7925"
for index in "${!FILES[@]}"; do
    case ${FILES[$index]} in
        mt7925-common.ko|mt7925e.ko)
            destination="$stock_base/mt7925/${FILES[$index]}"
            ;;
        *)
            destination="$stock_base/${FILES[$index]}"
            ;;
    esac
    cp "$TEST_DIR/module.ko" "$destination"
done
: > "$MODULES_ROOT/$KVER/modules.order"
: > "$MODULES_ROOT/$KVER/modules.builtin"
: > "$MODULES_ROOT/$KVER/modules.builtin.modinfo"

make_stage() {
    local stage=$1

    mkdir -p "$stage"
    for file in "${FILES[@]}"; do
        cp "$TEST_DIR/module.ko" "$stage/$file"
    done
    printf 'kernel=%s\nsource_sha=0123456789abcdef0123456789abcdef01234567\ncompiler=cc depmod fixture\npatches=none\n' \
        "$KVER" > "$stage/.build-info"
}

cat > "$FAKE_BIN/depmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_DEPMOD" -b "$FAKE_ROOT" "$@"
if grep -Fq '.mt7925-wifi-patches' \
    "$FAKE_ROOT/lib/modules/$FAKE_KVER/modules.dep"; then
    printf 'depmod scanned transaction backup modules\n' >&2
    exit 80
fi
EOF

cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$REAL_MODINFO" -b "$FAKE_ROOT" "$@"
EOF

cat > "$FAKE_BIN/modprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == -r && $# -eq 2 ]]; then
    temporary="$FAKE_PROC_MODULES.tmp"
    : > "$temporary"
    while IFS= read -r line; do
        [[ ${line%% *} == "$2" ]] || printf '%s\n' "$line" >> "$temporary"
    done < "$FAKE_PROC_MODULES"
    mv "$temporary" "$FAKE_PROC_MODULES"
    exit 0
fi
[[ $# -eq 1 && $1 == mt7925e ]] || exit 2
cat > "$FAKE_PROC_MODULES" <<'LOADED'
mt76 1 0 - Live 0x0
mt76_connac_lib 1 1 mt76, Live 0x0
mt792x_lib 1 1 mt76_connac_lib, Live 0x0
mt7925_common 1 1 mt792x_lib, Live 0x0
mt7925e 1 1 mt7925_common, Live 0x0
LOADED
EOF
chmod +x "$FAKE_BIN"/*

run_helper() {
    PATH="$FAKE_BIN:$PATH" \
    REAL_DEPMOD="$REAL_DEPMOD" \
    REAL_MODINFO="$REAL_MODINFO" \
    FAKE_ROOT="$FAKE_ROOT" \
    FAKE_KVER="$KVER" \
    FAKE_PROC_MODULES="$PROC_MODULES" \
    MT7925_MODULES_ROOT="$MODULES_ROOT" \
    MT7925_ETC_ROOT="$ETC_ROOT" \
    MT7925_PROC_MODULES="$PROC_MODULES" \
    MT7925_MODPROBE="$FAKE_BIN/modprobe" \
    MT7925_DEPMOD="$FAKE_BIN/depmod" \
    MT7925_MODINFO="$FAKE_BIN/modinfo" \
        "$HELPER" "$@"
}

stage_one="$TEST_DIR/stage-one"
stage_two="$TEST_DIR/stage-two"
make_stage "$stage_one"
make_stage "$stage_two"

run_helper install "$stage_one" "$KVER" 0 0
run_helper install "$stage_two" "$KVER" 0 0

active="$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches"
transaction="$MODULES_ROOT/.mt7925-wifi-patches/$KVER"
mkdir -p "$transaction/previous"
cp "$active"/*.ko "$transaction/previous/"
PATH="$FAKE_BIN:$PATH" REAL_DEPMOD="$REAL_DEPMOD" FAKE_ROOT="$FAKE_ROOT" \
    FAKE_KVER="$KVER" "$FAKE_BIN/depmod" -a "$KVER"
resolved=$(PATH="$FAKE_BIN:$PATH" REAL_MODINFO="$REAL_MODINFO" FAKE_ROOT="$FAKE_ROOT" \
    "$FAKE_BIN/modinfo" -k "$KVER" -n mt7925e)
[[ $resolved == "$active/mt7925e.ko" ]] || fail "active overlay did not win resolution: $resolved"

run_helper revert "$KVER"
stock="$stock_base/mt7925/mt7925e.ko"
resolved=$(PATH="$FAKE_BIN:$PATH" REAL_MODINFO="$REAL_MODINFO" FAKE_ROOT="$FAKE_ROOT" \
    "$FAKE_BIN/modinfo" -k "$KVER" -n mt7925e)
[[ $resolved == "$stock" ]] || fail "stock module did not resolve after revert: $resolved"
grep -Fq '.mt7925-wifi-patches' "$MODULES_ROOT/$KVER/modules.dep" &&
    fail 'transaction modules remained in depmod indexes after revert'

printf 'Real depmod ignores external transaction backups and restores stock resolution.\n'
