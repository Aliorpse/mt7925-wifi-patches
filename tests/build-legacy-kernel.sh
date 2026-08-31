#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_REF="${KERNEL_REF:-v7.0}"
WIRELESS_NEXT_REF="${WIRELESS_NEXT_REF:-main}"
WIRELESS_NEXT_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/wireless/wireless-next.git"
TEST_DIR="$(mktemp -d)"
KBUILD_TOOL_ARGS=()

for tool in LLVM LLVM_IAS CC LD AR NM STRIP OBJCOPY OBJDUMP READELF HOSTCC HOSTCXX; do
    if declare -p "$tool" >/dev/null 2>&1; then
        KBUILD_TOOL_ARGS+=("$tool=${!tool-}")
    fi
done

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

git clone --depth=1 --branch "$KERNEL_REF" \
    https://github.com/torvalds/linux.git "$TEST_DIR/linux"
make "${KBUILD_TOOL_ARGS[@]}" -C "$TEST_DIR/linux" defconfig
make "${KBUILD_TOOL_ARGS[@]}" -C "$TEST_DIR/linux" -j"$(nproc)" modules_prepare

git init --quiet "$TEST_DIR/wireless-next"
git -C "$TEST_DIR/wireless-next" fetch --depth=1 \
    "$WIRELESS_NEXT_REPO" "$WIRELESS_NEXT_REF"
git -C "$TEST_DIR/wireless-next" checkout --quiet --detach FETCH_HEAD
WIRELESS_NEXT_SHA=$(git -C "$TEST_DIR/wireless-next" rev-parse HEAD)
printf 'wireless-next %s resolves to %s.\n' \
    "$WIRELESS_NEXT_REF" "$WIRELESS_NEXT_SHA"

if grep -q 'ieee80211_txq_aql_pending' \
    "$TEST_DIR/linux/include/net/mac80211.h"; then
    printf '0x0\tieee80211_txq_aql_pending\tmac80211\tEXPORT_SYMBOL_GPL\n' \
        > "$TEST_DIR/linux/Module.symvers"
fi

printf 'Compatibility patches:\n'
"$ROOT_DIR/scripts/compat.sh" apply \
    "$TEST_DIR/wireless-next" "$TEST_DIR/linux"

mt76_dir="$TEST_DIR/wireless-next/drivers/net/wireless/mediatek/mt76"
printf '%s\n' \
    'API compile check: KBUILD_MODPOST_WARN=1 because modules_prepare has no complete Module.symvers.'
make "${KBUILD_TOOL_ARGS[@]}" -C "$TEST_DIR/linux" M="$mt76_dir" \
    CONFIG_MT76_CORE=m \
    CONFIG_MT76_CONNAC_LIB=m \
    CONFIG_MT792x_LIB=m \
    CONFIG_MT7925_COMMON=m \
    CONFIG_MT7925E=m \
    KBUILD_MODPOST_WARN=1 \
    modules -j"$(nproc)"

echo "wireless-next $WIRELESS_NEXT_SHA mt76 modules build against $KERNEL_REF headers."
