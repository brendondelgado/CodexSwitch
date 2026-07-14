---
title: Remote macOS runtime build
description: Operator procedure for producing provenance-locked CodexSwitch macOS arm64 runtime and app artifacts with GitHub Actions.
toc:
  - Remote macOS Runtime Build
  - Purpose
  - Safety Boundary
  - Runner And Build Contract
  - Resolve Provenance
  - Dispatch
  - Verify The Run
  - Download And Inspect
  - App-Only Artifact
  - Dispatch The App Build
  - Verify The App Build
  - Download And Install The App
  - Failure Handling
cross_dependencies:
  - ../../.github/workflows/build-fork.yml
  - ../../.github/workflows/build-macos-app.yml
  - ../../Tests/Fixtures/BuildFork/patch_codex_source.rs
  - ../../scripts/build-app.sh
  - ../../scripts/install-macos-app-artifact.sh
  - ../../scripts/test_macos_app_artifact.py
  - ../architecture/macos-runtime-artifact.md
  - ../architecture/macos-cli-launcher.md
  - ../architecture/runtime-and-host-ownership.md
version_control:
  branch: main
  status: operational
  last_updated: 2026-07-14
---

# Remote macOS Runtime Build

## Purpose

Use the manual `Build macOS Runtime Artifact` GitHub Actions workflow to build
the complete Apple Silicon runtime away from a space-constrained Mac. One run
produces the coupled `codex`, `codex-code-mode-host`, and `codexswitch-cli`
executables described by the
[macOS runtime artifact contract](../architecture/macos-runtime-artifact.md).

The workflow builds `codexswitch-cli` from the exact CodexSwitch commit selected
by the dispatch event. A workflow-only patch driver then applies that commit's
existing v3 source transformations to the exact upstream `rust-v<version>` tag
before Cargo builds the Codex runtime pair.

## Safety Boundary

The workflow:

- runs only through `workflow_dispatch`;
- has read-only repository contents access plus narrowly scoped OIDC and
  attestation-write permissions, and requires no repository secrets;
- does not push, tag, publish a release, deploy, stage, install, signal, or
  activate any runtime;
- runs the complete Swift app test suite before any runtime compilation and
  removes its temporary build directory immediately afterward;
- uses one Cargo build job at a time and disables release LTO;
- validates the three executable modes before uploading only those files and
  `manifest.json`;
- publishes GitHub build-provenance attestations for all four exact artifact
  members before upload;
- retains the uploaded artifact for seven days.

Downloading an artifact is not approval to activate it. Review the manifest,
attestations, and run evidence first. The canonical installer performs one
explicit, lease-held staging and activation transaction governed by the
architecture contract.

## Runner And Build Contract

The workflow uses the fixed GitHub-hosted label `macos-15`. GitHub's current
[hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
lists `macos-15` as a standard M1 `arm64` macOS runner. The job also requires
`uname -m` to equal `arm64` before it checks out or builds source, so a future
label drift fails closed.

Both Cargo workspaces run with:

```text
CARGO_BUILD_JOBS=1
CARGO_PROFILE_RELEASE_LTO=false
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
CARGO_INCREMENTAL=0
```

The Codex runtime build names both packages in one Cargo invocation:
`codex-cli` and `codex-code-mode-host`. The ephemeral checkout and build targets
are not uploaded.

GitHub Actions may retain the Cargo registry, git database, and target
directories in a repository-scoped cache keyed by the target architecture,
exact upstream commit, and CodexSwitch commit. A new CodexSwitch commit restores
the newest cache for the same upstream commit, then Cargo revalidates every
object against the current source and flags. Cache restore and save failures are
non-fatal because provenance never depends on the cache. The cache remains on
GitHub infrastructure; no build target is downloaded to or retained on the Mac.
The artifact still comes only from the clean `--locked` build and passes the
same source-diff, binary, manifest, and attestation gates.

If the v3 patch adds a direct dependency to an upstream member crate, the patch
driver updates that member's `Cargo.lock` entry in canonical sorted order before
the workflow calculates the source-patch digest. The driver also reconciles
source-local `0.0.0` lockfile placeholders with the release version declared in
the root `[workspace.package]` table. It does not rewrite sourced packages or
non-placeholder local versions. The runtime compile remains `--locked`; a
lockfile that would change during compilation is a release failure.

## Resolve Provenance

The workflow requires three inputs:

| Input | Contract |
| --- | --- |
| `codexswitch_git_sha` | Full 40-character lowercase commit selected by the dispatch ref. It must equal the event's immutable `github.sha`. |
| `upstream_codex_version` | Stable three-component version such as `0.144.4`; it selects `refs/tags/rust-v0.144.4`. |
| `upstream_codex_git_sha` | Full 40-character lowercase commit behind that upstream tag. The checked-out `HEAD` must match it. |

Resolve the values without modifying the worktree:

```bash
DISPATCH_REF=main
CODEXSWITCH_SHA="$(git rev-parse "${DISPATCH_REF}^{commit}")"
UPSTREAM_CODEX_VERSION=0.144.4
UPSTREAM_TAG="rust-v${UPSTREAM_CODEX_VERSION}"
UPSTREAM_CODEX_SHA="$({
  git ls-remote --tags https://github.com/openai/codex.git \
    "refs/tags/${UPSTREAM_TAG}" "refs/tags/${UPSTREAM_TAG}^{}"
} | awk '
  $2 ~ /\^\{\}$/ { peeled = $1 }
  $2 !~ /\^\{\}$/ { direct = $1 }
  END { print (peeled != "" ? peeled : direct) }
')"
test "${#CODEXSWITCH_SHA}" -eq 40
test "${#UPSTREAM_CODEX_SHA}" -eq 40
```

The workflow file must exist at `DISPATCH_REF`. Uncommitted local changes are
never part of a remote artifact; commit the intended source first and dispatch
the ref whose resolved commit is `CODEXSWITCH_SHA`.

## Dispatch

Dispatch only after reviewing all three provenance values:

```bash
gh workflow run build-fork.yml \
  --ref "$DISPATCH_REF" \
  -f codexswitch_git_sha="$CODEXSWITCH_SHA" \
  -f upstream_codex_version="$UPSTREAM_CODEX_VERSION" \
  -f upstream_codex_git_sha="$UPSTREAM_CODEX_SHA"
```

Do not use a branch name whose tip no longer matches `CODEXSWITCH_SHA`. The
workflow rejects that mismatch before compilation.

## Verify The Run

The run must prove all of the following before upload:

1. The event SHA, checked-out CodexSwitch `HEAD`, and requested CodexSwitch SHA
   are identical.
2. The Swift app and complete Swift test suite pass on the native macOS runner.
3. The upstream tag, requested upstream SHA, and checked-out upstream `HEAD`
   are identical and the remote is `https://github.com/openai/codex.git`.
4. The patch driver was compiled from the dispatched tree and the patched diff
   has a reported SHA-256.
5. After both Cargo builds finish, the CodexSwitch checkout is still clean at
   the dispatched commit and the upstream full `HEAD` delta, including index
   and working-tree changes, still has exactly the pre-build SHA-256 with no
   untracked files.
6. All three output files are nonempty, executable, regular files and thin
   `arm64` Mach-O executables.
7. `codex --version` reports the requested upstream version.
8. `codex` contains the full convergence-v3, rotation-handoff-v1, external
   app-server v3, local CLI v3, and `/goal` capability markers.
9. The complete `codexswitch-cli --version` output embeds the full dispatched
   commit
   and build epoch, matches `codexSwitchBuildVersion`, and its help exposes both
   `activate-macos-runtime-artifact` and `install-prepared-codex` without
   invoking either command. Its hidden, read-only `macos-runtime-contract`
   command must also return the exact artifact format, activation-journal
   format, target, architecture, and command list as JSON. Do not substitute a
   `strings` scan for this executable contract report; release optimization may
   encode compared literals without preserving them as contiguous strings.
10. `manifest.json` matches `codexswitch-macos-runtime-artifact-v1`, including
   the exact upstream commit, source-patch SHA-256, file names, byte lengths,
   and file SHA-256 values.
11. GitHub build-provenance attestations bind all four members to this workflow,
   source commit, main-branch ref, and GitHub-hosted runner.

The final job summary records the dispatch ref, both source SHAs, the upstream
tag and version, the patch SHA-256, build epoch, runner architecture, and
artifact name.

## Download And Inspect

Locate the completed manual run and download its named artifact:

```bash
gh run list --workflow build-fork.yml --event workflow_dispatch
gh run view <run-id>
gh run download <run-id> --name <artifact-name> --dir <empty-directory>
```

The download directory must contain exactly:

```text
codex
codex-code-mode-host
codexswitch-cli
manifest.json
```

GitHub's official
[`upload-artifact` permission contract](https://github.com/actions/upload-artifact#permission-loss)
normalizes files in a downloaded multi-file artifact to mode `0644`. A tar
wrapper would preserve mode but violate this artifact's required four-file
shape. Restore only the three executable bits after download:

```bash
DOWNLOAD_DIR=/absolute/path/to/download-directory
chmod 0755 \
  "$DOWNLOAD_DIR/codex" \
  "$DOWNLOAD_DIR/codex-code-mode-host" \
  "$DOWNLOAD_DIR/codexswitch-cli"
```

`chmod` does not change the file bytes or manifest hashes. Perform it before
passing the directory to the canonical installer; do not add a sidecar or
archive to the directory. The installer repeats this mode normalization after
attestation verification, so the explicit `chmod` is optional.

Activate only from a clean local checkout of the manifest's exact main commit:

```bash
scripts/install-macos-cli-artifact.sh "$DOWNLOAD_DIR"
```

The script copies the four downloaded files through no-follow descriptors into
a private snapshot, independently verifies each snapshot member with
`gh attestation verify`, validates and freezes that snapshot without executing
the mutable download paths, then invokes exactly one
`activate-macos-runtime-artifact` transaction from the same snapshot.

Do not merge binaries from different runs. Do not add notes, archives, checksum
sidecars, or logs to this directory. The manifest is the only metadata member
allowed by the canonical format.

## App-Only Artifact

Use the separate `Build macOS App Artifact` workflow when the menu-bar app must
be updated without rebuilding or mixing it into the three-executable runtime
set. The app workflow accepts only one input: the full CodexSwitch commit SHA
selected by the dispatch ref. It requires `refs/heads/main`, a clean exact
checkout, and a native arm64 `macos-15` runner.

The workflow first runs the complete Swift suite with `--jobs 1 --no-parallel`
in a private temporary directory. It then calls `scripts/build-app.sh` without
`--install` using these deterministic values:

```text
CODEXSWITCH_BUILD_CONFIGURATION=release
CODEXSWITCH_SWIFTPM_JOBS=1
CODEXSWITCH_SOURCE_REVISION=<full dispatched commit>
CODEXSWITCH_BUILD_NUMBER=<commit epoch>
CODEXSWITCH_VERSION=1.0.0
CODEXSWITCH_CODESIGN_IDENTITY=-
```

The resulting app is validated before packaging and after a fresh ZIP
round-trip. `ditto` packages the bundle without resource forks, extended
attributes, quarantine, or ACL metadata. The workflow uploads exactly
`CodexSwitch.app.zip` and `manifest.json` as a dedicated artifact; it attests
both members first and never uploads `.build`, `build`, test output, or runtime
executables.

## Dispatch The App Build

Resolve and review the exact clean main commit:

```bash
DISPATCH_REF=main
CODEXSWITCH_SHA="$(git rev-parse "${DISPATCH_REF}^{commit}")"
test "${#CODEXSWITCH_SHA}" -eq 40
test -z "$(git status --porcelain --untracked-files=normal)"
```

Dispatch the app-only workflow at that same ref:

```bash
gh workflow run build-macos-app.yml \
  --ref "$DISPATCH_REF" \
  -f codexswitch_git_sha="$CODEXSWITCH_SHA"
```

Moving branch tips do not silently change the selected source: the job requires
the dispatch SHA, checked-out `HEAD`, and requested SHA to be identical before
tests or compilation.

## Verify The App Build

The completed run must prove:

1. The dispatch ref is `refs/heads/main`, and checkout SHA equals the requested
   full SHA with no tracked or untracked changes.
2. The runner is native arm64 and the serialized Swift suite passed before the
   release app build began.
3. `CFBundleSourceRevision` is the full SHA, `CFBundleVersion` is the commit
   epoch, `CFBundleShortVersionString` is `1.0.0`, and the bundle identifier and
   executable are canonical.
4. The executable is a nonempty thin arm64 Mach-O within its size bound.
5. Strict deep code-signature verification succeeds and reports an ad-hoc
   signature.
6. Bundled `patch-asar.py` exactly matches the dispatched source, and its hash
   and the executable hash match the manifest.
7. The executable contains none of `LINUX_DEVBOX_ACTIVE_PUSH`,
   `pendingLinuxDevboxActive`, or `pushLinuxDevboxActiveAccount`.
8. ZIP preflight accepts only bounded, relative, non-link entries under
   `CodexSwitch.app`, and all bundle checks pass after extraction into a fresh
   directory.
9. The source checkout is clean at the exact SHA after build output has been
   removed.
10. Pinned official actions attest both exact members before the separate
    artifact is uploaded.

## Download And Install The App

Locate and download the app-only artifact into an empty directory:

```bash
gh run list --workflow build-macos-app.yml --event workflow_dispatch
gh run view <run-id>
gh run download <run-id> --name <artifact-name> --dir <empty-directory>
```

The download directory must contain exactly:

```text
CodexSwitch.app.zip
manifest.json
```

From a clean local `main` checkout at the manifest's exact commit, run:

```bash
scripts/install-macos-app-artifact.sh <empty-directory>
```

The installer snapshots and attests both members, validates the strict manifest
and archive bounds, safely extracts the ZIP, and repeats the complete bundle
contract before it creates an `/Applications` staging directory or asks the
running app to quit. It never recompiles or re-signs the bundle. Replacement is
transactional: validation or launch failure restores and relaunches the prior
app, while a preactivation failure leaves the installed app unchanged.

## Failure Handling

A provenance mismatch, changed upstream patch anchor, Cargo failure, missing
marker, architecture mismatch, malformed manifest, or unexpected directory
member fails the run before upload. Fix the source or select the correct refs,
then start a new manual run. Do not weaken a validator to salvage an old build.

A successful remote build is still only a transfer artifact. This runbook does
not authorize activation by itself. The workflow never executes
`activate-macos-runtime-artifact` or `install-prepared-codex`; it uses only
their `--help` paths to prove that the control plane exposes guarded activation
and recovery commands.

For the app-only path, a plist mismatch, non-arm64 executable, invalid
signature, patcher drift, removed-code marker, unsafe ZIP entry, manifest
mismatch, source-tree drift, or attestation failure likewise stops before
upload or activation. Do not re-sign, edit, or repack a failed download. Build
a new artifact from the corrected exact commit. If post-swap app validation or
launch fails, retain the installer error and any reported recovery path; do not
delete a preserved rollback directory by hand.
