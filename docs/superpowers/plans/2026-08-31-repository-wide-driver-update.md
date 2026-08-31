# Repository-Wide MT7925 Driver Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make current `wireless-next/main` build safely for MT7925 PCIe across Linux 6.18 through current APIs, install through a transactional external-module overlay, and close all open repository issues with verified evidence.

**Architecture:** Resolve one wireless-next HEAD SHA per run, detect target-kernel API features, and apply four independent fail-closed patches. Build unprivileged, stage and validate five modules, then use one privileged overlay helper for atomic install/revert; status, CI, desktop integration, and docs consume the same paths and metadata.

**Tech Stack:** Bash, git, Linux Kbuild, modprobe/depmod/modinfo, GitHub Actions, shell-based tests with fake commands and temporary roots.

**Spec:** `docs/superpowers/specs/2026-08-31-repository-wide-driver-update-design.md`

## Global Constraints

- Production source is latest `wireless-next/main`; resolve and print one exact SHA per run.
- Feature probes, not kernel version comparisons, select compatibility patches.
- Unknown patch/source shapes fail before `/lib/modules` or `/etc` changes.
- Build only MT7925 PCIe modules: `mt76`, `mt76-connac-lib`, `mt792x-lib`, `mt7925-common`, `mt7925e`.
- Do not backport the complete NAN host stack; disable MT7925 NAN as a unit when the host contract is incomplete.
- Do not overwrite package-owned modules; use `/lib/modules/$KVER/updates/mt7925-wifi-patches/`.
- Clone, patch, and compile as a normal user; use sudo only for install/revert and selected settings.
- ASPM and power-save changes are opt-in and may touch only project-owned files and an MT7925 interface.
- Detect signature enforcement and reject unsigned modules before system changes; do not add MOK management.
- Do not add DKMS, USB support, vendored firmware, a framework, or new runtime dependencies.
- CI/harness evidence must not be described as real-hardware stability evidence.

---

## File Map

- `scripts/compat.sh`: target-header feature detection and fail-closed patch application; shared by production and CI.
- `scripts/module-overlay.sh`: privileged install/revert transaction and project-owned optional settings.
- `patches/legacy-action-frame-api.patch`: old action-frame struct/macro adaptation for MT7925 build files only.
- `patches/legacy-eml-api.patch`: old EMLSR delay-mask names.
- `patches/legacy-nan-api.patch`: remove current MT7925 NAN consumer from hosts without the complete NAN contract.
- `patches/legacy-aql-api.patch`: restore the MT7925-safe pre-AQL sleeping-station branch.
- `mt76-rebuild.sh`: normal-user orchestration, source resolution, build, validation, and privileged helper invocation.
- `mt76-revert.sh`: confirmation and privileged helper invocation for the running kernel.
- `mt76-check.sh`: status derived from module resolution, metadata, load state, and MT7925-only settings.
- `tests/test-compat.sh`: feature-generation and patch apply/repeat/failure tests.
- `tests/test-module-overlay.sh`: temporary-root transaction, rollback, settings, and revert tests.
- `tests/build-legacy-kernel.sh`: one API-generation build using the production compatibility script.
- `.github/workflows/compat-patch.yml`: static checks, API matrix, Clang path, strict packaged-header build.
- `README.md`, `CLAUDE.md`, `mt76-check.desktop`, `mt76-status.desktop`, `.gitignore`: synchronized user/maintainer behavior and removed backup assumptions.

---

### Task 1: Independent Compatibility Detection and Existing Patch Split

**Files:**
- Create: `scripts/compat.sh`
- Create: `tests/test-compat.sh`
- Modify: `patches/legacy-action-frame-api.patch`
- Create: `patches/legacy-eml-api.patch`
- Delete after replacement: `tests/test-compat-patch.sh`

**Interfaces:**
- Produces: `scripts/compat.sh detect KDIR` prints required patch IDs, one per line.
- Produces: `scripts/compat.sh apply SOURCE_DIR KDIR` applies required patches and prints applied IDs, one per line.
- Patch IDs are exactly `action-frame`, `eml`, `nan`, and `aql`.
- `KDIR/Module.symvers` is required when the AQL declaration exists; missing symbol export selects `aql`.

- [ ] **Step 1: Write detection tests for all API generations**

Create `tests/test-compat.sh` with a temporary header-tree builder. The assertions must cover:

```bash
assert_patches v6.18 $'action-frame\neml\nnan\naql'
assert_patches v7.0  $'action-frame\neml\nnan\naql'
assert_patches v7.1  $'eml\naql'
assert_patches v7.2  $'aql'
assert_patches current ''
```

Each fixture writes only the signatures the detector consumes:

```bash
mkdir -p "$kdir/include/linux" "$kdir/include/net" "$kdir/include/uapi/linux"
printf '%s\n' "$action_macro" > "$kdir/include/linux/ieee80211.h"
printf '%s\n' "$eml_symbols" > "$kdir/include/linux/ieee80211-eht.h"
printf '%s\n' "$nan_uapi" > "$kdir/include/uapi/linux/nl80211.h"
printf '%s\n' "$cfg_nan" > "$kdir/include/net/cfg80211.h"
printf '%s\n' "$mac_nan" "$aql_decl" > "$kdir/include/net/mac80211.h"
printf '%s\n' "$aql_export" > "$kdir/Module.symvers"
```

Also assert that an unrecognized action macro or EML generation exits nonzero and names the unsupported header.

- [ ] **Step 2: Run the new test and confirm the missing-script failure**

Run: `./tests/test-compat.sh`

Expected: FAIL because `scripts/compat.sh` does not exist.

- [ ] **Step 3: Implement the detector CLI**

Create `scripts/compat.sh` using `set -euo pipefail`. The core selection must be equivalent to:

```bash
detect_patches() {
    local kdir=$1
    local action="$kdir/include/linux/ieee80211.h"
    local eml="$kdir/include/linux/ieee80211-eht.h"
    local nl80211="$kdir/include/uapi/linux/nl80211.h"
    local cfg80211="$kdir/include/net/cfg80211.h"
    local mac80211="$kdir/include/net/mac80211.h"

    grep -Eq '^[[:space:]]*#define[[:space:]]+IEEE80211_MIN_ACTION_SIZE\(' "$action" || printf '%s\n' action-frame
    grep -q 'IEEE80211_EML_CAP_EML_PADDING_DELAY' "$eml" || printf '%s\n' eml

    if ! grep -q 'NL80211_IFTYPE_NAN_DATA' "$nl80211" ||
       ! grep -q 'CFG80211_NAN_SCHED_NUM_TIME_SLOTS' "$cfg80211" ||
       ! grep -q 'CFG80211_NAN_MAX_PEER_MAPS' "$cfg80211" ||
       ! grep -q 'BSS_CHANGED_NAN_LOCAL_SCHED' "$mac80211" ||
       ! grep -q 'nan_peer_sched_changed' "$mac80211" ||
       ! grep -q 'ieee80211_nan_sched_update_done' "$mac80211"; then
        printf '%s\n' nan
    fi

    if ! grep -q 'ieee80211_txq_aql_pending' "$mac80211" ||
       ! grep -q '[[:space:]]ieee80211_txq_aql_pending[[:space:]]' "$kdir/Module.symvers"; then
        printf '%s\n' aql
    fi
}
```

Before this selection, validate that all consumed headers and `Module.symvers` exist and that action/EML headers contain one recognized generation. `apply` maps each ID to `patches/legacy-$id-api.patch`, runs `git -C "$source" apply --check`, then applies it. Diagnostics go to stderr; stdout remains the stable patch-ID stream.

- [ ] **Step 4: Split action and EML patches**

Keep only `mt76_connac_mac.c` and `mt7925/mac.c` action-frame hunks in `legacy-action-frame-api.patch`; remove the mt7996 and MT7925 EML hunks. Move the two `mt7925/mcu.c` EML name changes into `legacy-eml-api.patch`.

Add test setup that clones or copies one resolved wireless-next tree, runs `git reset --hard` before each combination, applies the selected patches, confirms the expected legacy expressions, reruns from clean source, and verifies `git apply --reverse --check` for each patch.

- [ ] **Step 5: Run compatibility detection and patch tests**

Run: `./tests/test-compat.sh`

Expected: PASS with all five API generations and both split patches verified.

- [ ] **Step 6: Commit the compatibility foundation**

```bash
git add scripts/compat.sh tests/test-compat.sh patches/legacy-action-frame-api.patch patches/legacy-eml-api.patch tests/test-compat-patch.sh
git commit -m "Split kernel compatibility detection"
```

---

### Task 2: NAN and AQL Compatibility Against Current wireless-next

**Files:**
- Create: `patches/legacy-nan-api.patch`
- Create: `patches/legacy-aql-api.patch`
- Modify: `tests/test-compat.sh`
- Modify: `tests/build-legacy-kernel.sh`

**Interfaces:**
- Consumes: `scripts/compat.sh apply SOURCE_DIR KDIR` from Task 1.
- Produces: a patched MT7925-only source tree with no unsupported NAN host references and no AQL helper reference on legacy targets.
- `tests/build-legacy-kernel.sh` accepts `KERNEL_REF`, `WIRELESS_NEXT_REF`, and normal Kbuild variables including `LLVM=1`.

- [ ] **Step 1: Extend tests to require NAN/AQL patch behavior**

After applying the v7.0 selection to a clean current wireless-next tree, assert:

```bash
! grep -Rqs 'NL80211_IFTYPE_NAN_DATA' "$mt76_dir/mt7925" "$mt76_dir/mt792x.h" "$mt76_dir/mt792x_core.c" "$mt76_dir/mt76_connac_mcu.c"
! grep -q 'nan.o' "$mt76_dir/mt7925/Makefile"
! grep -q 'ieee80211_txq_aql_pending' "$mt76_dir/tx.c"
grep -q 'if (test_bit(MT_WCID_FLAG_PS, &wcid->flags))' "$mt76_dir/tx.c"
```

For a current fixture, assert no patch changes the source. Add a mutation test that changes one NAN patch context line and confirms `compat.sh apply` exits nonzero before any later patch is applied.

- [ ] **Step 2: Run the test and confirm missing-patch failures**

Run: `./tests/test-compat.sh`

Expected: FAIL because `legacy-nan-api.patch` and `legacy-aql-api.patch` do not exist.

- [ ] **Step 3: Generate and curate the NAN compatibility patch**

Use current wireless-next `ca800a9302764c445de0da0e84d2252400a770ee` as the initial patch baseline. Reverse the NAN consumer commits in newest-to-oldest order:

```bash
git revert --no-commit \
  420e0bbd52ab6fa05ebfdb4dbe5442d47e4bfdf9 \
  9bb39d09ab0f0f0e2f341d727e65fa1712c3bffa \
  0f3605e4f8de07c1c12271b7f602754e494fec5c \
  4ee3d2a5f2cd5b6d0ba0d997913c1b763ef4d5c5 \
  9824fb4edbf39468f9fa2f1f8c146aca74529c80 \
  a5487a6824068cba6fab02f3e5186940a59275ed \
  b7ab9f780dc8f6cc9ce30333e9f131ed3419c6b3
```

Resolve later-source conflicts by removing only NAN additions. Preserve `a7c71a346591` multicast registration, `9080164f3b6d` BSS capability guards, and all later TLV, PCIe deadlock, delayed-work, WCID, regulatory, WoW, and EHT fixes. Export the resulting source diff as `patches/legacy-nan-api.patch`, reset the generated tree, and prove the patch reapplies cleanly.

- [ ] **Step 4: Add the minimal AQL rollback patch**

In current `mt76/tx.c`, replace:

```c
if (test_bit(MT_WCID_FLAG_PS, &wcid->flags)) {
	if (!(dev->drv->drv_flags & MT_DRV_HW_PS_BUFFERING))
		return 0;
	if (ieee80211_txq_aql_pending(phy->hw, txq))
		return 0;
}
```

with the pre-AQL MT7925 behavior:

```c
if (test_bit(MT_WCID_FLAG_PS, &wcid->flags))
	return 0;
```

Store only that hunk in `patches/legacy-aql-api.patch`; do not reverse unrelated power-save buffering code used by other drivers.

- [ ] **Step 5: Make the build test use production patch selection**

Update `tests/build-legacy-kernel.sh` to resolve/print `WIRELESS_NEXT_REF`, call `scripts/compat.sh apply`, preserve `LLVM`, `CC`, and other Kbuild variables, and label `KBUILD_MODPOST_WARN=1` as an API compile check because `modules_prepare` has no real `Module.symvers`.

For source-tag API tests, create a temporary `Module.symvers` containing the AQL export only when the target header declares it; production rebuilds must still require the real target file.

- [ ] **Step 6: Run red-to-green API builds**

Run sequentially:

```bash
KERNEL_REF=v7.0 ./tests/build-legacy-kernel.sh
KERNEL_REF=v7.1 ./tests/build-legacy-kernel.sh
KERNEL_REF=v7.2 ./tests/build-legacy-kernel.sh
KERNEL_REF=v7.1 LLVM=1 ./tests/build-legacy-kernel.sh
```

Expected: all configured objects compile; v7.0 reports all four patches, v7.1 reports EML+AQL, v7.2 reports AQL, and Clang preserves `LLVM=1`.

- [ ] **Step 7: Commit current-source compatibility**

```bash
git add patches/legacy-nan-api.patch patches/legacy-aql-api.patch tests/test-compat.sh tests/build-legacy-kernel.sh
git commit -m "Support current mt7925 on stable kernel APIs"
```

---

### Task 3: Normal-User Source, Build, and Preflight Flow

**Files:**
- Modify: `mt76-rebuild.sh`
- Create: `tests/test-rebuild.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `scripts/compat.sh apply SOURCE_DIR KDIR`.
- Produces: a validated staging directory passed as the first argument to `sudo scripts/module-overlay.sh install`.
- Installed metadata fields are exactly `kernel=`, `source_sha=`, `compiler=`, and `patches=`.
- Tests set `MT7925_INSTALL_HELPER` to a fake executable; production defaults to `scripts/module-overlay.sh`, which Task 4 implements before any real install verification.

- [ ] **Step 1: Write orchestration failure tests with fake commands**

Create a fake PATH and repository remote under a temporary directory. Assert that rebuild:

- Rejects direct root execution before cloning.
- Fails on fetch error rather than using stale source.
- Prints and records the resolved SHA.
- Preserves `LLVM=1 CC=clang` in the fake make invocation.
- Does not invoke the install helper when a patch, build, expected-file, module-format, vermagic, or signature check fails.
- Passes both optional-setting flags only when requested.

The success test must create exactly the five expected staged module paths and assert one install-helper invocation.

- [ ] **Step 2: Run the orchestration test and confirm current behavior fails**

Run: `./tests/test-rebuild.sh`

Expected: FAIL because rebuild escalates the entire script and has no staging/preflight contract.

- [ ] **Step 3: Rewrite source and build orchestration minimally**

Use `set -euo pipefail`; parse only `--disable-aspm`, `--disable-power-save`, and `--help`. Require a normal user. Fetch/reset the ignored generated `wireless-next` tree to the resolved origin/main SHA, print it, apply compatibility, and run Kbuild without swallowing errors.

Build to a temporary staging root. Validate each expected module with `test -s`, `file`, and `modinfo -F vermagic <path>`; require vermagic to begin with `$KVER`. Check module signature enforcement before unloading anything. Construct `.build-info` with:

```text
kernel=<uname -r>
source_sha=<40-character SHA>
compiler=<make/compiler identity>
patches=<comma-separated IDs or none>
```

Select `install_helper=${MT7925_INSTALL_HELPER:-$SCRIPT_DIR/scripts/module-overlay.sh}` and invoke only:

```bash
sudo "$install_helper" install \
    "$stage_dir" "$KVER" "$disable_aspm" "$disable_power_save"
```

- [ ] **Step 4: Run rebuild tests and shell syntax**

```bash
./tests/test-rebuild.sh
bash -n mt76-rebuild.sh scripts/compat.sh tests/test-rebuild.sh
```

Expected: PASS.

- [ ] **Step 5: Remove obsolete backup ignores and commit**

Remove `backup-modules/` from `.gitignore`; retain generated source/build ignores.

```bash
git add mt76-rebuild.sh tests/test-rebuild.sh .gitignore
git commit -m "Build mt7925 modules before privilege escalation"
```

---

### Task 4: Transactional Overlay Install, Revert, and Optional Settings

**Files:**
- Create: `scripts/module-overlay.sh`
- Create: `tests/test-module-overlay.sh`
- Modify: `mt76-revert.sh`

**Interfaces:**
- `scripts/module-overlay.sh install STAGE_DIR KVER DISABLE_ASPM DISABLE_POWER_SAVE`
- `scripts/module-overlay.sh revert KVER`
- Test-only overrides: `MT7925_MODULES_ROOT`, `MT7925_ETC_ROOT`, `MT7925_PROC_MODULES`, and command-path variables for `modprobe`, `depmod`, `modinfo`, and `iw`; defaults remain real Linux paths/commands.
- Overlay metadata: `$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches/.build-info`.

- [ ] **Step 1: Write transaction and rollback tests first**

Cover first install, replacement install, another kernel path, unload failure, copy failure, depmod failure, wrong modinfo resolution, load failure, rollback to previous overlay, rollback to stock, revert, repeated revert, existing user config, both optional settings, and MT7925-only dispatcher filtering.

Each failure assertion checks that package-owned files under `$MODULES_ROOT/$KVER/kernel/` are byte-identical and that the fake modinfo resolves either the previous overlay or stock after rollback.

- [ ] **Step 2: Run the overlay test and confirm missing-helper failure**

Run: `./tests/test-module-overlay.sh`

Expected: FAIL because `scripts/module-overlay.sh` does not exist.

- [ ] **Step 3: Implement one privileged helper with strict path validation**

Require root in production and reject KVER values other than `[A-Za-z0-9._+-]+`. Require the stage to contain only the five expected modules plus `.build-info`. Use sibling directories:

```text
updates/.mt7925-wifi-patches.new
updates/.mt7925-wifi-patches.previous
updates/mt7925-wifi-patches
```

Copy to `.new`, unload loaded modules in dependency order without `|| true`, rename current to `.previous`, activate `.new`, run depmod, assert all five `modinfo -n` paths are under the active overlay, load `mt7925e`, and verify `/proc/modules`. Remove `.previous` only after success.

Install a trap after activation that unloads partial custom modules, restores `.previous` or removes the new overlay, reruns depmod, and loads the prior/stock `mt7925e` before returning the original failure.

- [ ] **Step 4: Implement project-owned optional settings**

Use exact project paths:

```text
/etc/modprobe.d/99-mt7925-wifi-patches.conf
/etc/NetworkManager/dispatcher.d/99-mt7925-wifi-patches
```

Both files begin `# Generated by mt7925-wifi-patches`. Refuse to replace a file without that header. The dispatcher exits unless `$ACTION == up`, the interface is managed, and `/sys/class/net/$IFACE/device/driver/module` resolves to `mt7925e`; then it runs `iw dev "$IFACE" set power_save off`.

Stage optional files and activate them only after module load succeeds. Include previous project-owned settings in rollback.

- [ ] **Step 5: Rewrite revert as a thin confirmed wrapper**

`mt76-revert.sh` parses `--yes`, prompts otherwise, and runs:

```bash
sudo "$SCRIPT_DIR/scripts/module-overlay.sh" revert "$(uname -r)"
```

The helper unloads, removes only the current kernel overlay and matching generated settings, runs depmod, verifies stock resolution, loads stock `mt7925e`, and reports success only after verification.

- [ ] **Step 6: Run transaction tests and syntax**

```bash
./tests/test-module-overlay.sh
bash -n scripts/module-overlay.sh mt76-revert.sh tests/test-module-overlay.sh
```

Expected: PASS for every success, failure, rollback, and idempotent path.

- [ ] **Step 7: Commit safe installation**

```bash
git add scripts/module-overlay.sh tests/test-module-overlay.sh mt76-revert.sh
git commit -m "Install mt7925 through a transactional module overlay"
```

---

### Task 5: Truthful Status and Desktop Integration

**Files:**
- Create: `tests/test-status.sh`
- Modify: `mt76-check.sh`
- Modify: `mt76-check.desktop`
- Modify: `mt76-status.desktop`

**Interfaces:**
- Consumes overlay path and `.build-info` from Task 4.
- `mt76-check.sh --text` prints status without requiring `notify-send`; default mode sends the same message as a desktop notification.

- [ ] **Step 1: Write status-state tests**

Using fake `uname`, `modinfo`, `/proc/modules`, sysfs, and `iw`, assert distinct messages and exit states for stock, custom loaded, custom installed but unloaded, stale metadata/kernel, missing metadata, optional ASPM, and MT7925 interface power-save state. A marker file alone must still report stock/not installed.

- [ ] **Step 2: Run and confirm marker-based implementation fails**

Run: `./tests/test-status.sh`

Expected: FAIL because current status trusts `.custom-mt76` and selects the first Wi-Fi interface.

- [ ] **Step 3: Implement status from live evidence**

Resolve `modinfo -n mt7925e`, require the current-kernel overlay prefix, parse `.build-info`, and check `mt7925e` in `/proc/modules`. Inspect optional settings only at project-owned paths. Discover a Wi-Fi interface by matching its sysfs driver module to `mt7925e`; never report another adapter's power-save state.

Add `--text` for deterministic tests and terminal troubleshooting. If `notify-send` is unavailable in default mode, print the text instead of failing silently.

- [ ] **Step 4: Fix desktop command resolution**

Set both desktop entries to:

```ini
Exec=mt76-check.sh
```

README will install the executable to `~/.local/bin`, which desktop launchers resolve through PATH. Keep existing names/categories/autostart properties.

- [ ] **Step 5: Run status and desktop checks**

```bash
./tests/test-status.sh
bash -n mt76-check.sh tests/test-status.sh
desktop-file-validate mt76-check.desktop mt76-status.desktop
```

Expected: PASS; if `desktop-file-validate` is unavailable on Darwin, record that and run it in CI.

- [ ] **Step 6: Commit status fixes**

```bash
git add tests/test-status.sh mt76-check.sh mt76-check.desktop mt76-status.desktop
git commit -m "Report the active mt7925 driver state"
```

---

### Task 6: CI Matrix and Documentation Synchronization

**Files:**
- Modify: `.github/workflows/compat-patch.yml`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- CI source job outputs `wireless_sha` used by every API build job.
- Every build log prints kernel ref, compiler, source SHA, detected features, and patch IDs.

- [ ] **Step 1: Expand CI with one resolved source revision**

Add jobs for:

```yaml
strategy:
  fail-fast: false
  matrix:
    kernel: [v6.18, v7.0, v7.1, v7.2]
    toolchain: [gcc]
include:
  - kernel: v7.1
    toolchain: llvm
```

Resolve wireless-next HEAD once in a small job and pass the SHA to matrix jobs. Add static shell tests, all local test scripts, desktop validation, and a strict packaged-runner-header build with real `Module.symvers`. Keep the weekly schedule as the moving-HEAD canary and raise build timeouts to realistic matrix limits.

- [ ] **Step 2: Rewrite README around verified behavior**

Document:

- Run `./mt76-rebuild.sh`, not whole-script sudo.
- MT7925 PCIe-only scope and exact five modules.
- Tested API matrix rather than blanket 6.x/all-distro claims.
- Matching distro headers, Arch flavor headers, and Clang `LLVM=1`.
- Latest-HEAD risk and printed SHA.
- External `updates/` install path and automatic rollback.
- Secure Boot refusal/manual signing reference.
- Opt-in `--disable-aspm` and `--disable-power-save` trade-offs.
- Distro-managed linux-firmware update/check commands.
- `./mt76-check.sh --text`, real modinfo verification, and portable revert.
- Correct desktop install commands using `install -Dm755` before copying entries.

Remove package overwrite, backup marker, auto-disable, Fedora-only restore, USB implication, and unsupported hardware claims.

- [ ] **Step 3: Synchronize maintainer guidance**

Update `CLAUDE.md` to match the same source, patch, build, overlay, status, test, and revert contracts. Remove direct `cp` into package paths, mutable manual edits, shared backups, marker checks, and automatic settings claims.

- [ ] **Step 4: Run complete local static/flow suite**

```bash
bash -n mt76-rebuild.sh mt76-revert.sh mt76-check.sh scripts/*.sh tests/*.sh
./tests/test-compat.sh
./tests/test-rebuild.sh
./tests/test-module-overlay.sh
./tests/test-status.sh
desktop-file-validate mt76-check.desktop mt76-status.desktop
git diff --check
```

Expected: all available checks pass; desktop validation may be CI-only on Darwin.

- [ ] **Step 5: Commit CI and documentation**

```bash
git add .github/workflows/compat-patch.yml README.md CLAUDE.md
git commit -m "Document and test the supported mt7925 workflow"
```

---

### Task 7: Independent Review, Remote Verification, and Issue Resolution

**Files:**
- Review: all changed tracked files
- Update only if review/verification finds a defect

**Interfaces:**
- Consumes all previous task deliverables.
- Produces pushed `main`, green Actions evidence, and issue replies/closure.

- [ ] **Step 1: Run focused and repository-wide code review**

Review for compatibility safety, privilege boundaries, path traversal, rollback completeness, user-file ownership, shell quoting, hidden ignored failures, source-SHA consistency, and claims unsupported by tests. Fix findings in the owning task's files and rerun its focused test.

- [ ] **Step 2: Run fresh final verification**

```bash
bash -n mt76-rebuild.sh mt76-revert.sh mt76-check.sh scripts/*.sh tests/*.sh
./tests/test-compat.sh
./tests/test-rebuild.sh
./tests/test-module-overlay.sh
./tests/test-status.sh
desktop-file-validate mt76-check.desktop mt76-status.desktop
git diff --check
git status --short
```

Also run the v7.0/v7.1/v7.2 and Clang API builds that are feasible locally; record any Linux-only checks delegated to Actions.

- [ ] **Step 3: Inspect commit set and push the approved branch**

Inspect `git status`, full diff from `origin/main`, and `git log --oneline origin/main..HEAD`. Ensure `.serena`, `wireless-next`, build outputs, and secrets are not tracked. Push the reviewed commits to `main` as approved by the user.

- [ ] **Step 4: Wait for GitHub Actions and inspect every job**

Use `gh run list` to identify the pushed workflow, `gh run watch <id> --exit-status`, and `gh run view <id> --log-failed` for any failure. Fix root causes, rerun local focused verification, commit, and push until the required workflow is green.

- [ ] **Step 5: Reply to and close issues #1, #4, #5, and #6**

Each reply includes the fix commit, successful run URL, tested kernel/compiler row, resolved wireless-next SHA, reproduction command, and the limit that CI does not prove radio stability. Close all four after the main workflow is green; invite reopening if the exact environment still fails.

Reply to closed #2 with the NAN/AQL regression resolution and evidence link.

- [ ] **Step 6: Record final state**

Report changed behavior, verification commands/results, pushed commit(s), Actions URL, and issue URLs. File a MemPalace diary entry with the final source policy, compatibility matrix, branch/commits, and any hardware-only residual risk.
