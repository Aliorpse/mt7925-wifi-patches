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

source_dir="$TEST_DIR/wireless-next"
git init --quiet "$source_dir"
git -C "$source_dir" fetch --depth=1 \
    "$WIRELESS_NEXT_REPO" "$WIRELESS_NEXT_REF"
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
WIRELESS_NEXT_SHA=$(git -C "$source_dir" rev-parse HEAD)
printf 'wireless-next %s resolves to %s.\n' \
    "$WIRELESS_NEXT_REF" "$WIRELESS_NEXT_SHA"

if [[ $KERNEL_REF == current-native ]]; then
    kdir=$source_dir
else
    kdir="$TEST_DIR/linux"
    git clone --depth=1 --branch "$KERNEL_REF" \
        https://github.com/torvalds/linux.git "$kdir"
fi
make "${KBUILD_TOOL_ARGS[@]}" -C "$kdir" defconfig
make "${KBUILD_TOOL_ARGS[@]}" -C "$kdir" -j"$(nproc)" modules_prepare

if grep -q 'ieee80211_txq_aql_pending' \
    "$kdir/include/net/mac80211.h"; then
    printf '0x00000000\tieee80211_txq_aql_pending\tmac80211\tEXPORT_SYMBOL_GPL\t\n' \
        > "$kdir/Module.symvers"
fi

printf 'Compatibility patches:\n'
"$ROOT_DIR/scripts/compat.sh" apply \
    "$source_dir" "$kdir"

mt76_dir="$source_dir/drivers/net/wireless/mediatek/mt76"
printf '%s\n' \
    'API compile check: KBUILD_MODPOST_WARN=1 because modules_prepare has no complete Module.symvers.'
make "${KBUILD_TOOL_ARGS[@]}" -C "$kdir" M="$mt76_dir" \
    CONFIG_MT76_CORE=m \
    CONFIG_MT76_USB=n \
    CONFIG_MT76_SDIO=n \
    CONFIG_MT76x02_LIB=n \
    CONFIG_MT76x02_USB=n \
    CONFIG_MT76_CONNAC_LIB=m \
    CONFIG_MT792x_LIB=m \
    CONFIG_MT792x_USB=n \
    CONFIG_MT76_NPU= \
    CONFIG_MT76x0_COMMON=n \
    CONFIG_MT76x2_COMMON=n \
    CONFIG_MT7603E=n \
    CONFIG_MT7615_COMMON=n \
    CONFIG_MT7915E=n \
    CONFIG_MT7921_COMMON=n \
    CONFIG_MT7996E=n \
    CONFIG_MT7925_COMMON=m \
    CONFIG_MT7925E=m \
    CONFIG_MT7925U=n \
    KBUILD_MODPOST_WARN=1 \
    modules -j"$(nproc)"

expected_modules=(
    "$mt76_dir/mt76-connac-lib.ko"
    "$mt76_dir/mt76.ko"
    "$mt76_dir/mt7925/mt7925-common.ko"
    "$mt76_dir/mt7925/mt7925e.ko"
    "$mt76_dir/mt792x-lib.ko"
)
modules=()
while IFS= read -r module; do
    modules+=("$module")
done < <(find "$mt76_dir" -type f -name '*.ko' -print | LC_ALL=C sort)
[[ ${#modules[@]} -eq 5 ]] || {
    printf 'Expected exactly five module outputs, found %s.\n' "${#modules[@]}" >&2
    exit 1
}
for index in "${!expected_modules[@]}"; do
    [[ ${modules[$index]} == "${expected_modules[$index]}" ]] || {
        printf 'Unexpected module output: %s\n' "${modules[$index]}" >&2
        exit 1
    }
done

echo "wireless-next $WIRELESS_NEXT_SHA mt76 modules build against $KERNEL_REF headers."
