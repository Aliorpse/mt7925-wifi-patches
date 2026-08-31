#!/usr/bin/env bash

set -u

PROJECT='mt7925-wifi-patches'
MODULES_ROOT=${MT7925_MODULES_ROOT:-/lib/modules}
ETC_ROOT=${MT7925_ETC_ROOT:-/etc}
PROC_MODULES=${MT7925_PROC_MODULES:-/proc/modules}
SYS_CLASS_NET=${MT7925_SYS_CLASS_NET:-/sys/class/net}
ASPM_PARAMETER=${MT7925_ASPM_PARAMETER:-/sys/module/mt7925e/parameters/disable_aspm}
UNAME=${MT7925_UNAME:-uname}
MODINFO=${MT7925_MODINFO:-modinfo}
IW=${MT7925_IW:-iw}
NOTIFY_SEND=${MT7925_NOTIFY_SEND:-notify-send}

if [[ $# -gt 1 || ($# -eq 1 && $1 != --text) ]]; then
    printf 'usage: %s [--text]\n' "${0##*/}" >&2
    exit 2
fi
text_mode=0
[[ $# -eq 0 ]] || text_mode=1

if ! KVER=$("$UNAME" -r 2>/dev/null) || [[ -z $KVER ]]; then
    printf '%s: could not determine the running kernel\n' "${0##*/}" >&2
    exit 1
fi

OVERLAY="$MODULES_ROOT/$KVER/updates/$PROJECT"
KERNEL_ROOT="$MODULES_ROOT/$KVER/kernel"
BUILD_INFO="$OVERLAY/.build-info"
ASPM_CONFIG="$ETC_ROOT/modprobe.d/99-$PROJECT.conf"
POWER_DISPATCHER="$ETC_ROOT/NetworkManager/dispatcher.d/99-$PROJECT"

module_path=''
state=unknown
metadata_kernel=''
source_sha=''
compiler=''
patches=''

if module_path=$("$MODINFO" -n mt7925e 2>/dev/null) && [[ -n $module_path ]]; then
    case $module_path in
        "$OVERLAY"/*)
            if [[ ! -r $BUILD_INFO ]]; then
                state=missing
            else
                kernel_seen=0
                source_seen=0
                compiler_seen=0
                patches_seen=0
                duplicate=0
                invalid=0
                line_count=0
                while IFS= read -r line; do
                    ((line_count += 1))
                    case $line in
                        kernel=*)
                            ((kernel_seen)) && duplicate=1
                            metadata_kernel=${line#kernel=}
                            kernel_seen=1
                            ;;
                        source_sha=*)
                            ((source_seen)) && duplicate=1
                            source_sha=${line#source_sha=}
                            source_seen=1
                            ;;
                        compiler=*)
                            ((compiler_seen)) && duplicate=1
                            compiler=${line#compiler=}
                            compiler_seen=1
                            ;;
                        patches=*)
                            ((patches_seen)) && duplicate=1
                            patches=${line#patches=}
                            patches_seen=1
                            ;;
                        *) invalid=1 ;;
                    esac
                done < "$BUILD_INFO"

                if ((invalid || line_count != 4 || duplicate || !kernel_seen || !source_seen || !compiler_seen || !patches_seen)) ||
                    [[ -z $metadata_kernel || -z $source_sha || -z $compiler || -z $patches ]]; then
                    state=missing
                elif [[ $metadata_kernel != "$KVER" || ! $source_sha =~ ^[0-9a-f]{40}$ ]]; then
                    state=stale
                else
                    state=unloaded
                    if [[ -r $PROC_MODULES ]]; then
                        while read -r name rest; do
                            if [[ $name == mt7925e ]]; then
                                state=loaded
                                break
                            fi
                        done < "$PROC_MODULES"
                    fi
                fi
            fi
            ;;
        "$KERNEL_ROOT"/*) state=stock ;;
        *) state=external ;;
    esac
fi

urgency=critical
exit_status=1
case $state in
    loaded)
        TITLE='MT7925 WiFi: Custom driver loaded'
        BODY="Driver: Custom (loaded)
Kernel: $KVER
Source: $source_sha
Compiler: $compiler
Patches: $patches"
        urgency=normal
        exit_status=0
        ;;
    unloaded)
        TITLE='MT7925 WiFi: Custom driver not loaded'
        BODY="Driver: Custom (installed, not loaded)
Kernel: $KVER
Source: $source_sha
Compiler: $compiler
Patches: $patches
Run: ./mt76-rebuild.sh"
        ;;
    stale)
        TITLE='MT7925 WiFi: Stale custom metadata'
        BODY="Driver: Custom (stale metadata)
Running kernel: $KVER
Metadata kernel: $metadata_kernel
Source: $source_sha
Run: ./mt76-rebuild.sh"
        ;;
    missing)
        TITLE='MT7925 WiFi: Custom metadata missing'
        BODY="Driver: Custom (metadata missing or incomplete)
Kernel: $KVER
Metadata: $BUILD_INFO
Run: ./mt76-rebuild.sh"
        ;;
    stock)
        TITLE='MT7925 WiFi: Stock driver'
        BODY="Driver: Stock (custom not installed)
Kernel: $KVER
Resolved module: $module_path
Run: ./mt76-rebuild.sh"
        ;;
    external)
        TITLE='MT7925 WiFi: Unknown external driver'
        BODY="Driver: Unknown external
Kernel: $KVER
Resolved module: $module_path
Action: inspect or remove this external module before rebuilding"
        ;;
    *)
        TITLE='MT7925 WiFi: Driver state unknown'
        BODY="Driver: Unknown (mt7925e did not resolve)
Kernel: $KVER"
        ;;
esac

has_project_header() {
    local file=$1

    [[ -f $file && ! -L $file ]] || return 1
    grep -Fqx '# Generated by mt7925-wifi-patches' "$file" 2>/dev/null
}

exact_aspm_setting() {
    [[ -f $ASPM_CONFIG && ! -L $ASPM_CONFIG ]] || return 1
    cmp -s "$ASPM_CONFIG" <(
        printf '%s\n' \
            '# Generated by mt7925-wifi-patches' \
            'options mt7925e disable_aspm=1'
    )
}

exact_power_dispatcher() {
    [[ -f $POWER_DISPATCHER && ! -L $POWER_DISPATCHER ]] || return 1
    cmp -s "$POWER_DISPATCHER" <(cat <<'EOF'
#!/usr/bin/env bash
# Generated by mt7925-wifi-patches

set -euo pipefail

IFACE=${1-}
ACTION=${2-}
[[ $ACTION == up ]] || exit 0
[[ $IFACE =~ ^[A-Za-z0-9_.:-]+$ && $IFACE != none ]] || exit 0
[[ -n ${CONNECTION_UUID-} && ${DEVICE_IFACE-} == "$IFACE" ]] || exit 0
module_path=$(readlink -f -- "/sys/class/net/$IFACE/device/driver/module" 2>/dev/null) || exit 0
[[ ${module_path##*/} == mt7925e ]] || exit 0
exec iw dev "$IFACE" set power_save off
EOF
    )
}

aspm_setting='not selected'
if exact_aspm_setting; then
    aspm_setting=selected
elif has_project_header "$ASPM_CONFIG"; then
    aspm_setting='modified/unknown'
fi

if [[ -f $ASPM_PARAMETER && -r $ASPM_PARAMETER ]] &&
   IFS= read -r aspm_live < "$ASPM_PARAMETER"; then
    case $aspm_live in
        1|Y|y) ASPM_STATUS="ASPM: Disabled (live; project setting $aspm_setting)" ;;
        0|N|n) ASPM_STATUS="ASPM: Enabled (live; project setting $aspm_setting)" ;;
        *) ASPM_STATUS="ASPM: Unknown (unrecognized live value; project setting $aspm_setting)" ;;
    esac
else
    ASPM_STATUS="ASPM: Unknown (live parameter unavailable; project setting $aspm_setting)"
fi

power_setting='not selected'
if exact_power_dispatcher; then
    power_setting=selected
elif has_project_header "$POWER_DISPATCHER"; then
    power_setting='modified/unknown'
fi

PS_STATUS="Power Save: Unknown (no mt7925e interface; project setting $power_setting)"
iw_output=''
if iw_output=$("$IW" dev 2>/dev/null); then
    while read -r kind iface rest; do
        [[ $kind == Interface && -n ${iface-} ]] || continue
        module_link=$(readlink -f -- "$SYS_CLASS_NET/$iface/device/driver/module" 2>/dev/null) || continue
        [[ ${module_link##*/} == mt7925e ]] || continue

        power_state=''
        if power_output=$("$IW" dev "$iface" get power_save 2>/dev/null); then
            while read -r first second value rest; do
                if [[ $first == Power && $second == save: ]]; then
                    power_state=$value
                    break
                fi
            done <<< "$power_output"
        fi
        case $power_state in
            off) PS_STATUS="Power Save ($iface): Off (project setting $power_setting)" ;;
            on) PS_STATUS="Power Save ($iface): On (project setting $power_setting)" ;;
            *) PS_STATUS="Power Save ($iface): Unknown (project setting $power_setting)" ;;
        esac
        break
    done <<< "$iw_output"
fi

BODY+=$'\n'"$ASPM_STATUS"$'\n'"$PS_STATUS"

print_text() {
    printf '%s\n%s\n' "$TITLE" "$BODY"
}

if ((text_mode)); then
    print_text
elif command -v "$NOTIFY_SEND" >/dev/null 2>&1; then
    "$NOTIFY_SEND" -u "$urgency" -t 10000 "$TITLE" "$BODY" || print_text
else
    print_text
fi

exit "$exit_status"
