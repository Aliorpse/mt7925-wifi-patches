# Repository-Wide MT7925 Driver Update Design

Date: 2026-08-31

## Goal

Keep installing the current `wireless-next/main` MT7925 PCIe driver while
making builds against older distribution kernels predictable, preventing
partial system modifications, and resolving GitHub issues #1, #4, #5, and #6.

The update also incorporates current upstream MT7925 fixes by continuing to
build from `wireless-next/main`, makes installation and rollback safe across
kernel updates, and aligns CI, status reporting, desktop integration, README,
and maintainer documentation with actual behavior.

## User Decisions

- Production builds continue to follow the latest `wireless-next/main`, not a
  pinned release SHA.
- Compatibility is selected through target-header feature probes, with one
  independent patch per incompatible API generation.
- Unknown upstream changes fail closed before system modules are modified.
- The project remains MT7925 PCIe (`mt7925e`) only.
- Package-owned kernel modules are preserved; custom modules use the native
  external-module `updates/` path.
- ASPM and Wi-Fi power-save workarounds become explicit options rather than
  default system changes.
- Secure Boot enforcement is detected and reported, but MOK enrollment and key
  management are not implemented.
- After local and GitHub Actions verification, changes are committed and pushed
  to `main`; all affected issues receive evidence-based replies and are closed
  with explicit verification limits.

## Non-Goals

- Backporting the complete cfg80211/mac80211 NAN Data Path stack to old kernels.
- Supporting MT7925 USB (`mt7925u`) or unrelated mt76 chip families.
- Converting the project to DKMS in this update.
- Vendoring or silently replacing linux-firmware binary blobs.
- Managing Secure Boot keys or claiming hardware stability from compile-only CI.
- Carrying OpenWrt-only patches unless they are independently reviewed and are
  absent from current `wireless-next`.

## Current Problems

### Moving source versus stable headers

`mt76-rebuild.sh` and the scheduled CI job combine the latest
`wireless-next/main` source with older kernel headers. The existing patch only
handles the action-frame API and EML constant rename, and incorrectly treats
those independent changes as one feature generation.

Current upstream additionally requires:

- Full NAN schedule and NAN Data Interface APIs not present in Linux 6.18 or
  7.0.
- `ieee80211_txq_aql_pending()` and its exported mac80211 symbol, introduced
  after Linux 7.2.

Defining the missing NAN constants locally is unsafe because the enum,
cfg80211/mac80211 lifecycle, station state, callbacks, and exported behavior
must agree across the whole host wireless stack. Declaring the AQL function
alone is also unsafe because old mac80211 modules do not export it.

### Unsafe installation state

The current rebuild runs the clone and build as root, ignores source update and
module unload failures, overwrites package-owned modules, shares one backup
across kernels, writes the success marker before module loading, and cannot
reliably roll back partial installation. Revert can restore modules from the
wrong kernel and can leave custom uncompressed modules beside stock compressed
modules.

### Status and documentation drift

The marker file does not prove that the current kernel resolves or loads the
custom module. Stability settings can affect unrelated Wi-Fi interfaces and
revert can delete user-owned files. Desktop entries use an unexpanded `~` path,
and the README does not install the checker executable there. Documentation
overstates distro, kernel, and hardware support.

## Source Resolution

Each build will resolve `wireless-next/main` once and use that exact commit for
the complete run:

1. Fetch `main` from the canonical wireless-next repository.
2. Resolve and print the full source SHA.
3. Reset the generated source tree to a clean detached state at that SHA.
4. Detect target-kernel API features.
5. Apply only the required compatibility patches.
6. Record the source SHA and applied patch IDs in installed build metadata.

An offline or failed fetch is an error. The script must not silently report an
old checkout as current. Re-running always starts from a clean resolved source,
so patch state files inside `.git` are unnecessary.

An exclusive repository-local build lock covers source reset, patching, build,
staging, and installer handoff. A concurrent rebuild exits before changing the
shared source tree, preventing mixed-SHA module sets.

Following HEAD means future upstream API changes can still require maintenance.
The contract is therefore: known API generations are adapted; unknown source or
patch shapes stop before installation and print the source SHA, kernel release,
compiler, and failed stage for an actionable issue report.

## Compatibility Architecture

A single reusable compatibility script will be called by production builds and
tests. It will inspect the target kernel headers and `Module.symvers`, then apply
four independent patches with `git apply --check` before changing the source.
Every patch application is fail-closed and recorded.

### Action-frame API

Probe `include/linux/ieee80211.h` for the function-like versus object-like
`IEEE80211_MIN_ACTION_SIZE` macro.

On legacy headers, adapt current mt76 source to the old action-frame layout.
Keep only hunks needed by the configured MT7925 build; remove the unrelated
mt7996 hunk.

### EML constant names

Probe `include/linux/ieee80211-eht.h` when present, otherwise the legacy
combined `include/linux/ieee80211.h`, for generic `IEEE80211_EML_CAP_EML_*`
versus legacy `IEEE80211_EML_CAP_EMLSR_*` delay masks.

On legacy headers, rewrite only the two MT7925 delay-mask references. This must
run even when the action-frame API is already modern, which is the Linux 7.1
combination reported in issue #4.

### NAN schedule and NDI support

Probe the complete host contract, not one constant. Required evidence includes
the NAN_DATA interface type, local/peer schedule constants and structures,
mac80211 NAN schedule state/callbacks, station NAN state, and cluster-join API.

When that contract is incomplete, disable the new MT7925 NAN consumer as one
unit:

- Do not build the new MT7925 NAN object.
- Do not advertise NAN_DATA or register NAN schedule callbacks.
- Remove or guard MT7925 NAN-only state, MCU paths, firmware events, and helper
  calls that require the missing host contract.
- Preserve unrelated MT7925 fixes that happened to land in the same upstream
  period.

NAN support remains available unchanged on kernels that provide the complete
contract. The compatibility path intentionally omits NAN Data Path on older
kernels rather than inventing an incompatible UAPI.

### AQL helper and export

Probe both the mac80211 header declaration and the target kernel's
`Module.symvers` export for `ieee80211_txq_aql_pending`.

If either is absent, restore the previous generic mt76 sleeping-station branch
instead of calling the helper. This is safe for this project's MT7925-only
configuration because MT7925 does not enable the new hardware-managed power-save
buffering flag. The patch must be revisited before supporting mt7915 or mt7996.

### Flexible-array allocator API

Probe `include/linux/slab.h` for `kzalloc_flex()`. When absent, replace the
current mt76 receive-aggregation allocation with the equivalent overflow-safe
legacy form `kzalloc(struct_size(tid, reorder_buf, size), GFP_KERNEL)`.

### Expected API matrix

| Target headers | Compatibility selected |
| --- | --- |
| Linux 6.18 | Action + EML + NAN disabled + AQL rollback + alloc-flex rollback |
| Linux 7.0 | Action + EML + NAN disabled + AQL rollback |
| Linux 7.1 | EML + NAN disabled + AQL rollback |
| Linux 7.2 | AQL rollback |
| Current native API | No patch expected |

Feature probes, not release numbers, are authoritative because distributions
can backport individual APIs.

## Upstream Driver and Firmware Policy

Following `wireless-next/main` includes current MT7925 fixes without carrying
duplicate downstream patches, including firmware TLV loop validation, PCIe
reset/unregister deadlock fixes, delayed-work cancellation, stale WCID lifetime
fixes, regulatory handling, TX-power message length, WoW firmware layout, and
Wi-Fi 7 capability corrections.

The script will print the exact upstream SHA so users and issue reports identify
the driver that was installed.

Firmware remains owned by the distribution's `linux-firmware` package. The
README will show how to inspect installed MT7925 firmware and recommend updating
the distro package. It will not claim a stability effect for the August 2026
binary refresh because upstream provides no behavioral changelog.

## Build Flow

The top-level rebuild is run as the invoking user, without `sudo`:

1. Check tools, matching current-kernel build headers, writable build workspace,
   compiler selection, and Secure Boot/module-signature enforcement.
2. Resolve a clean wireless-next HEAD SHA.
3. Probe target features and apply compatibility patches.
4. Build the five PCIe modules with the target kernel's toolchain. Preserve
   caller compiler variables such as `LLVM=1` and `CC=clang`.
5. Stage exactly these outputs before privilege escalation:
   `mt76.ko`, `mt76-connac-lib.ko`, `mt792x-lib.ko`,
   `mt7925-common.ko`, and `mt7925e.ko`.
6. Validate that all five files exist, are non-empty, identify as kernel
   modules, and have a first vermagic token exactly equal to the running kernel.
7. Invoke `sudo` only for the installation transaction and explicitly selected
   stability settings.

If the script itself is launched as root, it will stop with instructions to run
it as a normal user. This prevents generated source and build files from becoming
root-owned and keeps mutable upstream build logic outside the privileged phase.

When signature enforcement is active and the staged modules are unsigned, the
script exits before unloading or writing modules and links to documented manual
signing guidance.

## Installation Transaction

Custom files will live under:

`/lib/modules/$KVER/updates/mt7925-wifi-patches/`

Transaction state stays outside the kernel version tree so `depmod` cannot scan
staged or previous modules. On the same filesystem it lives under:

`/lib/modules/.mt7925-wifi-patches/$KVER/{new,previous}`

Package-owned files under `kernel/drivers/...` are never overwritten. The
external `updates/` location gives the custom modules normal depmod precedence
and makes portable rollback a removal operation rather than a package restore.

Privileged installation performs these stages:

1. Acquire one privileged global transaction lock shared by install and revert.
2. Copy staged files and build metadata into the external transaction `new`
   directory.
3. Require current mt76/MT7925 modules to unload successfully when loaded. An
   in-use module aborts installation before activating new files.
4. Rename any existing project overlay to the external transaction `previous`
   directory.
5. Rename `new` into place, run `depmod -a $KVER`, and verify `modinfo -n`
   resolves all five module names to the project overlay.
6. Activate transactionally staged optional settings before module load so
   modprobe reads the requested ASPM option and the dispatcher can observe the
   interface-up event.
7. Load `mt7925e` and verify the expected module stack is loaded.
8. Mark the verified state committed, then remove `previous` as best-effort
   cleanup. Cleanup failure warns and preserves the active verified state; it
   never triggers rollback to a partially deleted backup.

On any failure after activation, rollback unloads any partial custom stack,
restores the previous project overlay or removes the new overlay when none
existed, reruns depmod, reloads the prior/stock module, and returns nonzero with
the failing stage. Success metadata is written only as part of the activated
overlay and is trusted only together with live `modinfo` and load checks.

## Revert Flow

Revert is scoped to the running kernel:

1. Show the exact project overlay and project-owned optional settings to remove.
2. Obtain confirmation unless a documented noninteractive flag is supplied.
3. Require the active MT7925 stack to unload when loaded.
4. Remove only `/lib/modules/$KVER/updates/mt7925-wifi-patches/` and any stale
   external transaction state for that kernel.
5. Remove optional config files only when their generated ownership header and
   expected content match.
6. Run depmod and verify `modinfo -n mt7925e` no longer resolves inside the
   project overlay.
7. Load the stock module and verify it is loaded.

No cross-kernel backup and no distro package-manager fallback are needed. A
failure never prints a successful revert message.

## Optional Stability Settings

`mt76-rebuild.sh` accepts explicit options:

- `--disable-aspm` creates a project-named modprobe configuration containing
  `options mt7925e disable_aspm=1`.
- `--disable-power-save` creates a project-owned NetworkManager dispatcher.

The dispatcher changes power-save state only when the interface is managed and
its sysfs driver resolves to `mt7925e`. A missing NetworkManager or `iw` command
causes that requested option to fail before installation rather than creating a
nonfunctional file.

Both files include a generated ownership header. Existing files not owned by
this project are never overwritten or removed. Revert removes only matching
project-owned files. Requested settings are staged before privilege escalation
and installed atomically after module activation; a settings failure restores
the prior project-owned files and rolls back the driver transaction.

## Status and Desktop Integration

`mt76-check.sh` derives driver status from all of the following:

- `modinfo -n mt7925e` resolves inside the current kernel's project overlay.
- Overlay metadata matches the running kernel and contains a wireless-next SHA.
- `mt7925e` is currently loaded.
- Optional ASPM configuration is present only when selected.
- Power-save state is read only from an interface bound to `mt7925e`.

A path under the package-owned `$KVER/kernel/` tree is stock. Any other external
module path that is not this project's exact overlay is reported as an unknown
external driver, never as stock.

The checker reports installed-but-not-loaded, stale-kernel, missing metadata,
and stock-driver states separately. It no longer treats a marker as proof and
does not label enabled ASPM/power-save as an error when those options were not
requested.

Desktop entries use `Exec=mt76-check.sh`, relying on the executable installed in
`~/.local/bin`. README installation commands install the checker before copying
the desktop entries. Both files are validated with `desktop-file-validate`.

## Test Design

### Compatibility tests

The production compatibility script is tested directly against one resolved
wireless-next SHA. Tests cover each independent feature combination, patch
apply/reverse checks, repeat runs from a clean source, and fail-closed behavior
when an expected source hunk changes.

### Kernel API build matrix

GitHub Actions resolves wireless-next HEAD once, exposes the SHA as a job output,
and gives every matrix job that same source revision.

The compile matrix covers:

- Linux 6.18, 7.0, 7.1, and 7.2 API generations with GCC.
- One old-kernel Clang/`LLVM=1` build for issue #5.
- Current native kernel APIs, where no compatibility patch is expected.

Every API row asserts exactly the five expected module outputs. The native row
must report no compatibility patch.

Vanilla source-tag jobs are explicitly named API compile checks. Where only
`modules_prepare` is available, unresolved base-kernel symbols are not presented
as loadability evidence. A separate job using packaged runner headers and their
real `Module.symvers` performs strict modpost, dependency, and vermagic checks
without converting unresolved symbols to warnings.

Every job prints the target kernel, compiler, wireless-next SHA, detected
features, and applied patch IDs.

### Install/revert flow test

A small shell test uses a temporary module root and fake privileged commands to
exercise:

- First install and repeated install.
- A different running-kernel path.
- Missing build output and vermagic mismatch.
- Source fetch, patch, build, unload, copy, depmod, load, and verification
  failures.
- Rollback to a previous overlay and rollback to stock.
- Revert and idempotent revert.
- Existing user-owned config files.
- Optional settings and MT7925-only interface filtering.

### Static checks

- `bash -n` for every shell script.
- `git diff --check`.
- `desktop-file-validate` for both desktop entries.
- The compatibility, build-matrix, and install/revert tests above.

## Documentation Update

`README.md` and `CLAUDE.md` will be rewritten to match the same behavior:

- Run rebuild without whole-script sudo.
- State MT7925 PCIe-only scope.
- Explain latest-HEAD source policy and print/diagnostic SHA.
- Publish tested API generations instead of claiming all Linux 6.x kernels and
  all distributions.
- Document matching distro headers and Arch kernel flavors.
- Document Clang/`LLVM=1`, Secure Boot detection, external-module path, status
  checks, and transaction rollback.
- Make ASPM and power-save opt-in and explain their trade-offs.
- Recommend distro-managed linux-firmware updates.
- Install the desktop checker and entries consistently.
- Remove package-module overwrite, shared backup, marker, and Fedora-only revert
  instructions.

## Issue Resolution

After the implementation and all available verification pass:

| Issue | Resolution evidence |
| --- | --- |
| #1 | Status is based on current-kernel module resolution, metadata, and load state; install metadata is created only after successful activation. Ubuntu flow and failure paths are covered without relying on a marker. |
| #4 | Linux 7.1 receives EML compatibility independently from the already-modern action API and disables NAN because the tag lacks the required mac80211 cluster-join helper; Linux 6.18 is covered by the complete legacy combination. |
| #5 | Missing AQL declaration/export selects the safe rollback, and a Clang/`LLVM=1` old-kernel job passes while preserving compiler variables. |
| #6 | The same AQL compatibility path passes the Linux 7.1/GCC job and produces all five expected modules. |
| Closed #2 | A follow-up explains that NAN and AQL regressions added after its original action-frame fix are now covered. |

Replies include the fix commit, relevant successful Actions jobs, tested kernel
and compiler scope, exact upstream SHA, and an explicit statement that CI proves
compile/install-flow behavior rather than real-hardware radio stability.

Issues #1, #4, #5, and #6 are closed only after the pushed `main` workflow is
green. If a reporter's exact environment cannot be reproduced, the closing
reply states that validation gap, distinguishes compile/install-flow evidence
from hardware evidence, and invites reopening if the reported symptom remains.

## Repository Delivery

Implementation stays focused on the existing shell project. It adds only the
shared compatibility logic, independent patches, and one install/revert test
needed to avoid production/test drift. It does not introduce a framework,
package, daemon, or speculative device support.

Before pushing:

1. Review status, diff, and recent commits; stage only intended repository
   files, excluding local `.serena` state and generated source/build trees.
2. Run all local checks available on the development host.
3. Commit with a concise repository-style message and push to `main` as approved.
4. Wait for and inspect the complete GitHub Actions result.
5. Reply to and close issues according to the evidence rules above.

## Success Criteria

- Current wireless-next HEAD builds through the selected compatibility paths for
  Linux 6.18, 7.0, 7.1, and 7.2 API generations, plus a native current API job.
- GCC and the issue #5 Clang path pass and produce the five MT7925 PCIe modules.
- No unknown patch/source mismatch can reach the installation stage.
- Package-owned modules remain unchanged during install and revert tests.
- Failed activation restores the prior project overlay or stock resolution.
- Revert is kernel-scoped, portable, and verified.
- Status never reports patched solely because a marker exists.
- Optional settings affect only project-owned files and the MT7925 interface.
- README, CLAUDE.md, desktop entries, scripts, tests, and CI agree.
- Pushed `main` Actions are green before evidence-based issue closure.
