# Final Review Fix Report

Date: 2026-08-31

Worktree: `/Users/burakgon/Developer/mt7925-wifi-patches/.worktrees/implementation`

Branch: `opencode/mt7925-implementation`

Starting HEAD: `48c4a02 Correct final transaction requirements`

Implementation commit: `74c8700 Harden mt7925 transaction and verification`

Report commit: the commit containing this document.

## Status

All 1 Critical, 7 Important, and 5 Minor findings in
`final-fix-brief.md` are fixed. No finding was omitted or marked blocked.

No command used host `sudo`, changed host modules, or wrote below the host
`/lib/modules` or `/etc`. Privileged-flow evidence used temporary roots and
disposable Linux containers.

## Finding Mapping

### 1. Depmod-visible transaction directories

- Production: `scripts/module-overlay.sh` now keeps `new` and `previous` at
  `$MODULES_ROOT/.mt7925-wifi-patches/$KVER/`. Only the active overlay is under
  `$MODULES_ROOT/$KVER/updates/mt7925-wifi-patches/`.
- Rollback, revert, stale-state cleanup, and finish cleanup use the external
  paths. Renames remain beneath `$MODULES_ROOT`, preserving the normal
  same-filesystem atomic-rename assumption.
- Regression: `tests/test-module-overlay.sh` rejects any transaction sibling
  below the version tree and verifies per-kernel external state.
- Real evidence: `tests/test-real-depmod.sh` runs real `depmod` and `modinfo`
  over compiled ELF module fixtures. Replacement installation leaves the
  previous copy present during depmod, proves it is absent from `modules.dep`,
  then proves stock `mt7925e` resolution after revert.

### 2. Complete rebuild and privileged transaction serialization

- Production: `mt76-rebuild.sh` holds a nonblocking repository-local `flock`
  from before source mutation through the installer handoff.
- Production: `scripts/module-overlay.sh` holds one nonblocking global lock at
  `$MODULES_ROOT/.mt7925-wifi-patches.lock` for install and revert.
- Regressions: `test_concurrent_rebuild_lock` and
  `test_concurrent_transaction_lock` hold the winning process at a controlled
  boundary, start a real concurrent loser, and prove the loser exits before
  source, installer, or active-overlay writes.

### 3. Commit before best-effort previous-backup cleanup

- Production: install and revert set `committed=1` immediately after module and
  setting verification, before `cleanup_previous`.
- Production: failed cleanup emits `cleanup warning`, returns success, and does
  not enter rollback even after a simulated partial deletion.
- Regressions: `test_cleanup_failures_preserve_committed_state` covers both
  install and revert and verifies active/stock resolution plus the loaded stack.

### 4. Setting activation order and live ASPM status

- Production: exact settings are activated or removed after module resolution
  and before `modprobe mt7925e` for install and revert.
- Regression: the fake modprobe refuses module load unless the requested exact
  setting state is already visible.
- Production: `mt76-check.sh` reads
  `/sys/module/mt7925e/parameters/disable_aspm` when present. Missing or
  unrecognized live state reports unknown instead of inferring from config.
- Regression: status tests cover live enabled/disabled state and the absent
  parameter.

### 5. Exact first-token vermagic equality

- Production: rebuild and strict CI parse the first vermagic token and compare
  it exactly to the target kernel release.
- Regression: `vermagic-prefix` rejects `$KVER` followed by an extra `0`.
- Strict container evidence checked the first token of all five modules against
  `7.3.0-0.rc0.260819gbd5f485f3f02.5.fc46.aarch64`.

### 6. Package-tree-only stock classification

- Production: only paths under `$MODULES_ROOT/$KVER/kernel/` are stock.
  Non-project paths elsewhere are `Unknown external` with an inspection/removal
  action, never a rebuild-only stock action.
- Regression: status covers DKMS, another `updates/` owner, a similar project
  prefix, and a path outside the module tree.

### 7. Current-native API row and exact five-output assertions

- Production: CI includes `current-native` with GCC and expected patch IDs
  `none`.
- Production: `tests/build-legacy-kernel.sh` uses one wireless-next checkout as
  both source and headers for that row.
- Production: every API row now rejects any output set other than the exact five
  MT7925 PCIe modules. The strict row retains the same exact-output check.
- Regression: the fake build proves source/header identity, no native patch IDs,
  a valid five-field synthetic `Module.symvers`, and rejection of a sixth `.ko`.
- Real native evidence built exactly five modules from
  `ca800a9302764c445de0da0e84d2252400a770ee` with no compatibility patches.
- Evidence labels remain `API-only` for source-tag/current-native rows and
  `strict modpost` only for the packaged-header row.

### 8. Power-save dependency preflight

- Production: requested power-save disable resolves both `iw` and
  `NetworkManager` before settings or module transaction writes.
- Regression: missing-iw and missing-NetworkManager cases verify an empty shared
  write log, no module operations, stock resolution, and unchanged packages.

### 9. Exact metadata producer contract and copied-file revalidation

- Production: metadata must contain exactly four nonduplicate fields and no
  extras: matching `kernel`, 40-character lowercase `source_sha`, nonempty
  `compiler`, and nonempty `patches`.
- Production: validation runs on the user stage and again on the privileged copy
  in transaction `new`.
- Regressions: extra, duplicate, short SHA, empty compiler, and corruption during
  privileged copy all fail before activation. Fixtures now use the exact
  producer contract.

### 10. Forced detached source checkout

- Production: rebuild uses `git checkout --detach --force "$source_sha"` and
  then cleans the source.
- Regression: the fetched SHA must equal `HEAD`, and `git symbolic-ref -q HEAD`
  must fail.

### 11. Effective static `git diff --check` gate

- Production: static Actions computes Git's empty tree and runs
  `git diff --check "$empty_tree" HEAD`, checking the complete tracked tree.
- Self-review rejected plain `git diff --check` because a clean checkout would
  make that command a no-op.
- Regression: `tests/test-workflow.sh` requires the effective full-tree command.

### 12. Exact revert confirmation disclosure

- Production: interactive revert prints the current-kernel overlay, ASPM path,
  and NetworkManager dispatcher path before prompting.
- Regression: the declined-confirmation path verifies all three exact paths and
  proves sudo is not invoked.

### 13. Byte-identical status ownership

- Production: status compares ASPM and dispatcher files byte-for-byte with the
  installer canonical content.
- Production: a marked but modified file reports `modified/unknown`, not
  `selected`.
- Regression: both canonical files report selected; appended local changes to
  both report modified/unknown while live ASPM and power-save state remain
  independently observable.

## RED Evidence

The focused regressions were added before their production fixes. Representative
pre-fix failures were:

- Detached checkout, `./tests/test-rebuild.sh`:
  `FAIL: source checkout remained attached to a branch`.
- Metadata contract, `./tests/test-module-overlay.sh`:
  `FAIL: command unexpectedly succeeded` after extra metadata was accepted.
- External status, `./tests/test-status.sh`: a DKMS path printed
  `MT7925 WiFi: Stock driver`.
- Native row, `./tests/test-compat.sh`: failure reported that current-native did
  not use one wireless-next source/header generation.
- Static gate, `./tests/test-workflow.sh`:
  `FAIL: static GitHub Actions gates omit git diff --check`.
- Real depmod, disposable Debian `./tests/test-real-depmod.sh`:
  `depmod scanned transaction backup modules`.

The native build also exposed an independent fixture defect before GREEN:
current modpost rejected a four-field synthetic symbol dump with
`ERROR: modpost: parse error in symbol dump file`. The synthetic
`Module.symvers` now includes the required explicit fifth namespace field, and
the focused fake build verifies that exact format.

## GREEN Evidence

### Local host

Fresh commands:

```text
bash -n mt76-rebuild.sh mt76-revert.sh mt76-check.sh scripts/*.sh tests/*.sh
./tests/test-compat.sh
./tests/test-rebuild.sh
./tests/test-module-overlay.sh
./tests/test-status.sh
./tests/test-workflow.sh
./tests/test-real-depmod.sh
git diff --check
```

Results: syntax PASS; compatibility PASS; rebuild PASS; 19 overlay cases PASS;
9 status cases PASS; workflow contract PASS; diff check PASS. Real depmod
correctly prints `SKIP` on Darwin and was run for real in Linux below.

### Disposable Ubuntu static/flow gate

The full suite ran as a non-root container user with the worktree Git metadata
mounted at its real absolute path:

```text
bash -n ...
test-compat PASS
test-rebuild PASS
test-module-overlay PASS (19 cases)
test-real-depmod PASS
test-status PASS (9 cases)
test-workflow PASS
desktop-file-validate PASS
git diff --check PASS
```

`desktop-file-validate` emitted only the pre-existing non-failing hint that
`System;Settings;Network;` contains multiple main categories.

### Static analyzers

```text
actionlint 1.7.12: 0 parse errors, 0 errors
yamllint: PASS with repository-appropriate document-start, line-length, and
  GitHub `on` truthiness rules disabled
shellcheck 0.11.0: PASS; SC2016 excluded for intentional literal dispatcher
  script generation
markdownlint-cli2 0.23.2: README.md and CLAUDE.md, 0 issues
```

### Real depmod

Disposable Debian/Ubuntu Linux runs used real `depmod`, `modinfo`, compiled ELF
fixtures, fake roots, and fake module loading only:

```text
Installed mt7925 module overlay for 1.0.0-depmod-test.
Installed mt7925 module overlay for 1.0.0-depmod-test.
Reverted to stock mt7925 modules for 1.0.0-depmod-test.
Real depmod ignores external transaction backups and restores stock resolution.
```

### Current-native API build

Disposable Ubuntu 24.04, GCC, arm64 container:

```text
wireless-next main resolves to ca800a9302764c445de0da0e84d2252400a770ee.
Compatibility patches:
Patch IDs: none
Result: exactly five modules built against current-native headers
```

Exactly five outputs were asserted. As an API-only build, unresolved
base-kernel symbols were warnings, not loadability evidence.

### Strict packaged-header build

Disposable Fedora Rawhide, package-owned headers and real `Module.symvers`:

```text
Kernel ref: packaged 7.3.0-0.rc0.260819gbd5f485f3f02.5.fc46.aarch64
Source SHA: ca800a9302764c445de0da0e84d2252400a770ee
Patch IDs: aql
Build mode: strict modpost; unresolved symbols are errors.
```

Strict modpost passed. Exactly five outputs were asserted, and every first
vermagic token exactly equaled the packaged kernel release. The container noted
a non-failing Rawhide compiler minor-version difference and skipped optional BTF
generation because no `vmlinux` was installed.

## Changed Files

- `.github/workflows/compat-patch.yml`
- `.gitignore`
- `CLAUDE.md`
- `README.md`
- `mt76-check.sh`
- `mt76-rebuild.sh`
- `mt76-revert.sh`
- `scripts/module-overlay.sh`
- `tests/build-legacy-kernel.sh`
- `tests/test-compat.sh`
- `tests/test-module-overlay.sh`
- `tests/test-real-depmod.sh`
- `tests/test-rebuild.sh`
- `tests/test-status.sh`
- `tests/test-workflow.sh`
- `.superpowers/sdd/2026-08-31-repository-wide-driver-update/final-fix-report.md`

## Self-Review

- Reviewed the full `48c4a02..74c8700` implementation diff for privilege
  boundaries, path traversal, symlinks, lock lifetime, rollback state, cleanup
  commit boundaries, user-file ownership, metadata strictness, shell quoting,
  source SHA consistency, exact module outputs, and evidence labels.
- Confirmed no production host paths are used by tests and no real module load,
  unload, or sudo operation ran on the host.
- Confirmed locks remain held through rollback/cleanup because their file
  descriptors live in the invoking shell until process exit.
- Confirmed cleanup failure cannot trigger rollback after `committed=1`, while
  all failures before verification still restore previous or stock resolution.
- Confirmed optional settings are visible to modprobe/dispatcher before module
  load and are restored on pre-commit failure.
- Confirmed only intended files are committed; generated source, build outputs,
  local Serena state, and secrets are absent.
- Self-review found and fixed the clean-checkout no-op whitespace gate and the
  current-modpost five-field synthetic `Module.symvers` requirement.
- No unresolved Critical, Important, or Minor finding remains.

## Residual Concerns

- CI/API builds do not prove radio stability, suspend behavior, Secure Boot key
  acceptance, or real-hardware loadability.
- Production still intentionally follows moving `wireless-next/main`; future
  source/API drift can fail closed and require patch refresh.
- Atomic rename assumes the normal layout where `$MODULES_ROOT` and its kernel
  version directories share a filesystem, as approved in the ruling.
- The real depmod test proves kmod indexing and resolution with synthetic ELF
  modules; module loading remains faked to avoid host kernel changes.
