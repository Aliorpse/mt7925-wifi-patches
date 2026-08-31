#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIRELESS_NEXT_REPO="${MT7925_WIRELESS_NEXT_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/wireless/wireless-next.git}"
KVER="$(uname -r)"
KDIR="${MT7925_KDIR:-/lib/modules/$KVER/build}"
SOURCE_ROOT="$SCRIPT_DIR/wireless-next"
MT76_DIR="$SOURCE_ROOT/drivers/net/wireless/mediatek/mt76"
SIG_ENFORCE_FILE="${MT7925_SIG_ENFORCE_FILE:-/sys/module/module/parameters/sig_enforce}"
disable_aspm=0
disable_power_save=0
signature_enforced=0
stage_dir=''
KBUILD_TOOL_ARGS=()

usage() {
    printf 'usage: %s [--disable-aspm] [--disable-power-save] [--help]\n' "${0##*/}"
}

die() {
    printf 'mt76-rebuild.sh: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --disable-aspm)
            disable_aspm=1
            ;;
        --disable-power-save)
            disable_power_save=1
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

user_id=$(id -u)
[[ $user_id =~ ^[0-9]+$ ]] || die "could not determine the current user"
[[ $user_id -ne 0 ]] || die "run this script as a normal user, without sudo"
[[ -d $KDIR ]] || die "kernel build directory not found: $KDIR"
[[ -r $SIG_ENFORCE_FILE ]] ||
    die "cannot determine module signature enforcement from $SIG_ENFORCE_FILE"

signature_state=$(<"$SIG_ENFORCE_FILE")
case $signature_state in
    1|Y|y) signature_enforced=1 ;;
    0|N|n) ;;
    *) die "unknown module signature enforcement state: $signature_state" ;;
esac

for tool in LLVM LLVM_IAS CC LD AR NM STRIP OBJCOPY OBJDUMP READELF HOSTCC HOSTCXX; do
    if declare -p "$tool" >/dev/null 2>&1; then
        KBUILD_TOOL_ARGS+=("$tool=${!tool-}")
    fi
done

if [[ -n ${CC-} ]]; then
    compiler_command=$CC
elif [[ -n ${LLVM-} ]]; then
    compiler_command=clang
else
    compiler_command=gcc
fi
compiler_identity=$("$compiler_command" --version)
compiler_identity=${compiler_identity%%$'\n'*}
[[ -n $compiler_identity ]] || die "could not identify compiler: $compiler_command"

printf 'MT7925 WiFi Driver Rebuild\n'
printf '==========================\n'
printf 'Kernel: %s\n' "$KVER"
printf 'Compiler: %s\n' "$compiler_identity"

if [[ ! -d $SOURCE_ROOT/.git ]]; then
    [[ ! -e $SOURCE_ROOT ]] || die "source path is not a git repository: $SOURCE_ROOT"
    git clone --no-checkout "$WIRELESS_NEXT_REPO" "$SOURCE_ROOT"
fi

git -C "$SOURCE_ROOT" remote set-url origin "$WIRELESS_NEXT_REPO"
git -C "$SOURCE_ROOT" fetch --depth=1 origin main
source_sha=$(git -C "$SOURCE_ROOT" rev-parse FETCH_HEAD)
[[ $source_sha =~ ^[0-9a-f]{40}$ ]] || die "invalid wireless-next SHA: $source_sha"
printf 'wireless-next main resolves to %s.\n' "$source_sha"
git -C "$SOURCE_ROOT" reset --hard "$source_sha"
git -C "$SOURCE_ROOT" clean -fdx

patch_output=$("$SCRIPT_DIR/scripts/compat.sh" apply "$SOURCE_ROOT" "$KDIR")
if [[ -n $patch_output ]]; then
    patches=${patch_output//$'\n'/,}
else
    patches=none
fi
printf 'Compatibility patches: %s\n' "$patches"

make "${KBUILD_TOOL_ARGS[@]}" -C "$KDIR" M="$MT76_DIR" clean
make "${KBUILD_TOOL_ARGS[@]}" -C "$KDIR" M="$MT76_DIR" \
    CONFIG_MT76_CORE=m \
    CONFIG_MT76_CONNAC_LIB=m \
    CONFIG_MT792x_LIB=m \
    CONFIG_MT7925_COMMON=m \
    CONFIG_MT7925E=m \
    modules -j"$(nproc)"

stage_dir=$(mktemp -d)
cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

source_modules=(
    mt76.ko
    mt76-connac-lib.ko
    mt792x-lib.ko
    mt7925/mt7925-common.ko
    mt7925/mt7925e.ko
)
staged_modules=(
    mt76.ko
    mt76-connac-lib.ko
    mt792x-lib.ko
    mt7925-common.ko
    mt7925e.ko
)

for index in "${!source_modules[@]}"; do
    source_module="$MT76_DIR/${source_modules[$index]}"
    staged_module="$stage_dir/${staged_modules[$index]}"
    cp "$source_module" "$staged_module"
    [[ -s $staged_module ]] || die "built module is empty: $source_module"

    module_format=$(file -b "$staged_module")
    [[ $module_format == *ELF*relocatable* ]] ||
        die "built file is not an ELF relocatable module: $staged_module"

    vermagic=$(modinfo -F vermagic "$staged_module")
    [[ $vermagic == "$KVER"* ]] ||
        die "module vermagic does not match $KVER: $staged_module"

    if [[ $signature_enforced -eq 1 ]]; then
        if ! signer=$(modinfo -F signer "$staged_module"); then
            die "could not inspect module signature: $staged_module"
        fi
        [[ -n $signer ]] ||
            die "module signatures are enforced but $staged_module is unsigned; sign the modules before installing"
    fi
done

printf 'kernel=%s\nsource_sha=%s\ncompiler=%s\npatches=%s\n' \
    "$KVER" "$source_sha" "$compiler_identity" "$patches" \
    > "$stage_dir/.build-info"

install_helper=${MT7925_INSTALL_HELPER:-$SCRIPT_DIR/scripts/module-overlay.sh}
sudo "$install_helper" install \
    "$stage_dir" "$KVER" "$disable_aspm" "$disable_power_save"

printf 'Custom mt76 modules installed for kernel %s.\n' "$KVER"
