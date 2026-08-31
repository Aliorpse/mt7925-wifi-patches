#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/compat-patch.yml"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

grep -Fq 'empty_tree=$(git hash-object -t tree /dev/null)' "$WORKFLOW" ||
    fail 'static GitHub Actions gate does not cover the complete tracked tree'
grep -Fq 'git diff --check "$empty_tree" HEAD' "$WORKFLOW" ||
    fail 'static GitHub Actions gates omit an effective git diff --check'

native_row=$(awk '
    /- kernel: current-native/ { capture = 1 }
    capture { print }
    capture && /patches:/ { exit }
' "$WORKFLOW")
[[ $native_row == *'toolchain: gcc'* && $native_row == *'patches: none'* ]] ||
    fail 'API matrix omits the no-patch current-native row'
[[ $(grep -Fc -- '- kernel: current-native' "$WORKFLOW") -eq 1 ]] ||
    fail 'current-native API row must appear exactly once'

printf 'Workflow static gate and current-native matrix contract passed.\n'
