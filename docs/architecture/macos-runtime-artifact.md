---
title: macOS runtime artifact
description: Provenance, validation, staging, and activation contracts for remote-built CodexSwitch macOS runtime and app artifacts.
toc:
  - macOS Runtime Artifact
  - Purpose
  - App Artifact Boundary
  - Build Gate
  - Trust Bootstrap
  - Manifest
  - App Manifest
  - Staging
  - Activation
  - App Installation
  - Failure Contract
cross_dependencies:
  - ../../crates/codexswitch-cli/src/codex_update/macos_activation.rs
  - ../../crates/codexswitch-cli/src/codex_update/preparation.rs
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../scripts/build-app.sh
  - ../../scripts/install-macos-cli-artifact.sh
  - ../../scripts/install-macos-app-artifact.sh
  - ../../scripts/test_macos_app_artifact.py
  - ../../.github/workflows/build-fork.yml
  - ../../.github/workflows/build-macos-app.yml
  - macos-cli-launcher.md
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-14
---

# macOS Runtime Artifact

## Purpose

A complete macOS hot-swap runtime has three coupled executables: `codex`,
`codex-code-mode-host`, and `codexswitch-cli`. They are built from one exact
CodexSwitch commit on native Apple Silicon, transferred as one artifact, staged
as one immutable generation, and activated by one journaled transaction. Mixing
one new executable with an older member is prohibited.

## App Artifact Boundary

The menu-bar application is a separate sidecar artifact. It is never placed in
the runtime artifact directory and does not change the runtime artifact's exact
four-member contract. The app-only artifact directory contains exactly two
regular, non-symlink files: `CodexSwitch.app.zip` and `manifest.json`.

The dedicated manual workflow builds from one exact clean commit on
`refs/heads/main` using a native `macos-15` arm64 runner. It runs the complete
Swift test suite serially, then invokes the existing `scripts/build-app.sh`
without installation using release configuration, one SwiftPM job, the full
commit as `CODEXSWITCH_SOURCE_REVISION`, the commit epoch as
`CODEXSWITCH_BUILD_NUMBER`, version `1.0.0`, and explicit ad-hoc signing. The
workflow never compiles the Rust runtime, installs the app, modifies a release,
or mutates a host outside its ephemeral runner.

Both uploaded members receive GitHub build-provenance attestations before the
artifact is uploaded. Ad-hoc code signing proves bundle integrity after
extraction; GitHub attestation and the exact clean source checkout establish
publisher and source identity. The app ZIP must remain independent from the
coupled CLI runtime artifact so either can be reviewed and activated without
silently authorizing the other.

## Build Gate

The native artifact workflow must compile and run the complete Swift app test
suite before building any release executable. Compilation uses one job, and
test execution is explicitly non-parallel because the suite exercises shared
process state, subprocess admission, signal delivery, and updater leases.
Swift Testing executes tests concurrently by default; limiting SwiftPM build
jobs alone does not serialize those tests.

The workflow provides the test process with a private temporary directory under
the GitHub runner's canonical workspace temp root. Security tests must not be
made dependent on the runner's `/var` compatibility symlink, and concurrent
workflow runs must not share test paths. The workflow exports that directory as
`CODEXSWITCH_TEST_TMPDIR`; fixtures that exercise retained paths, no-follow
access, ownership, or permissions use this explicit root instead of Foundation's
platform temp-directory APIs. The temporary directory and `.build` output are
removed whether the gate succeeds or fails.

The source patch may add direct dependencies that already exist in the
upstream workspace but are not listed by the patched member crates. The patch
driver updates those member entries in `codex-rs/Cargo.lock` deterministically
and in canonical sorted order. Release tags may also carry `0.0.0` placeholders
for source-local workspace packages after the root workspace version has been
set to the release version. Before adding dependencies, the driver replaces
only those source-local placeholder versions with the root
`[workspace.package]` version; registry and git packages, and local packages
that already have a non-placeholder version, are unchanged. These lockfile
changes are part of the hashed source patch. The release build still uses
`--locked`, and post-build provenance revalidates the same complete patch hash.
Injected-method idempotence markers must identify the target implementation,
not only a method name that can legitimately appear on multiple auth types.

## Trust Bootstrap

The downloaded `codexswitch-cli` is untrusted until the repository installer
has independently verified GitHub build-provenance attestations for all four
artifact members. Each attestation must name the public
`brendondelgado/CodexSwitch` repository, the canonical
`.github/workflows/build-fork.yml` workflow, `refs/heads/main`, the exact clean
CodexSwitch commit recorded by the manifest, and a GitHub-hosted runner. The
local repository must be a clean checkout of that same commit.

Before verification, the installer copies all four downloaded members through
no-follow file descriptors into a private, newly created snapshot directory.
It verifies attestations, schema, byte lengths, SHA-256 values, thin arm64
Mach-O identities, and existing signatures against that frozen snapshot, then
executes and activates only those same snapshot paths. It rechecks the complete
snapshot immediately before execution and proves the installed control plane
and retained manifest identity afterward. The mutable download directory is
never executed. Generic code-signature integrity or a self-reported `--version`
is never a trust anchor.

After provenance verification, the installer executes the snapshot's hidden,
read-only `macos-runtime-contract` command and requires an exact JSON report for
the artifact format, activation-journal format, target, architecture, and
guarded activation commands. Release optimization may encode string comparisons
without retaining their source literals as contiguous binary strings, so
`strings` output is not a valid control-plane contract check. The executable
report is used by both CI and the installer; its bytes are already bound by the
manifest and GitHub attestation before the installer runs it.

## Manifest

The artifact directory contains exactly the three regular executable files and
`manifest.json`. The manifest format is
`codexswitch-macos-runtime-artifact-v1` and records:

```json
{
  "format": "codexswitch-macos-runtime-artifact-v1",
  "codexSwitchGitSha": "40 lowercase hexadecimal characters",
  "codexSwitchBuildVersion": "embedded control-plane build version",
  "upstreamCodexVersion": "0.144.4",
  "upstreamCodexGitSha": "40 lowercase hexadecimal characters",
  "sourcePatchSha256": "64 lowercase hexadecimal characters",
  "targetTriple": "aarch64-apple-darwin",
  "architecture": "arm64",
  "buildEpoch": 1783915200,
  "files": [
    {"name": "codex", "bytes": 1, "sha256": "64 lowercase hexadecimal characters"},
    {"name": "codex-code-mode-host", "bytes": 1, "sha256": "64 lowercase hexadecimal characters"},
    {"name": "codexswitch-cli", "bytes": 1, "sha256": "64 lowercase hexadecimal characters"}
  ]
}
```

File names are exact and unique. Unknown files, links, special files, zero-byte
members, malformed versions, unknown targets, and hash or length mismatches are
rejected before updater state changes.

## App Manifest

The app artifact manifest format is `codexswitch-macos-app-artifact-v1`:

```json
{
  "format": "codexswitch-macos-app-artifact-v1",
  "codexSwitchGitSha": "40 lowercase hexadecimal characters",
  "appVersion": "1.0.0",
  "buildEpoch": 1783915200,
  "bundleIdentifier": "com.codexswitch",
  "bundleName": "CodexSwitch.app",
  "architecture": "arm64",
  "signing": "adhoc",
  "archive": {
    "name": "CodexSwitch.app.zip",
    "bytes": 1,
    "sha256": "64 lowercase hexadecimal characters"
  },
  "bundleFiles": [
    {
      "path": "Contents/MacOS/CodexSwitch",
      "bytes": 1,
      "sha256": "64 lowercase hexadecimal characters"
    },
    {
      "path": "Contents/Resources/patch-asar.py",
      "bytes": 1,
      "sha256": "64 lowercase hexadecimal characters"
    }
  ]
}
```

The manifest is at most 64 KiB and the ZIP is at most 512 MiB. The executable
is at most 256 MiB, the bundled patcher is at most 4 MiB, and archive inspection
allows at most 4,096 entries and 1 GiB of total uncompressed data. Paths must be
relative descendants of the single `CodexSwitch.app` root. Encrypted entries,
links, special files, duplicate paths, traversal components, and unexpected
top-level members are rejected before extraction. Hashes and lengths for the
archive, executable, and patcher must all match the manifest.

Before packaging and again after a fresh extraction, the workflow verifies the
exact plist source revision, build epoch, app version, bundle identifier, and
executable name; a thin arm64 Mach-O executable; a strict deep ad-hoc code
signature; byte equality between the bundled and source `patch-asar.py`; and
absence of the removed VPS active-push markers.

## Staging

`codexswitch-cli activate-macos-runtime-artifact --directory <path>` is the
canonical operator command. It acquires one updater lease before validation and
keeps that lease through staging, activation, readback, state commit, and
recovery. Lock contention, a fresh incompatible updater operation, or a stale
unreconciled transaction is an error; none can be reported as successful
activation.

The staging phase validates the source directory without following links,
verifies all hashes and Mach-O arm64 identities, checks the full runtime v3
marker contract, verifies the helper, and proves that the control-plane binary
reports this artifact format and both guarded activation commands. It copies
the three executables and the original `manifest.json` into one new attempt-ID
generation. Existing signatures and manifest-approved bytes are preserved; the
control plane never builds, downloads, or re-signs on the Mac. An existing
same-version generation is reused only when a full revalidation proves the exact
manifest and all three executable identities. Reuse refreshes the observed
installed route before a journal records its rollback baseline.

`stage-macos-runtime-artifact` remains a diagnostic operator command, but it
fails closed on contention and does not authorize a later unrelated artifact.
`install-prepared-codex` must revalidate the retained manifest sidecar and all
members, so a separately invoked install remains bound to the originally
staged artifact.

Automatic metadata checks cannot invoke artifact staging.

## Activation

Activation requires the retained manifest and all three prepared executables.
The journal binds their identities and complete manifest provenance. It
publishes the managed runtime launcher first, then the control-plane CLI, then
the user and Homebrew bridges. Every publication prefix is executable: a clean
first install cannot expose a bridge before its target exists, and an update's
existing bridges can immediately use the newly published managed route.

A successful readback reparses the retained manifest, proves every published
identity and complete immutable generation, and only then commits updater
state. The committed state records `installedArtifactManifestSha256`; prepared
artifact identity is cleared independently so an installed report cannot
confuse completed provenance with pending work. `manifest.json` is frozen
read-only with its generation; executable members are frozen read/execute-only.
Later metadata and status observations preserve that committed identity when
the installed version is unchanged. A changed installed-version observation or
reconciliation of a source-built prepared runtime clears it, so neither routine
polling nor stale provenance can rewrite the truth.
The repository installer preserves its original `PATH` through final route
validation; in zsh, the special `path` array must never be reused as a scalar
loop variable before the launcher smoke test.

The running CLI process is not signalled or replaced in memory. After successful
activation, one explicit exit and resume starts the new executable set.

## App Installation

`scripts/install-macos-app-artifact.sh <directory>` is the only app-sidecar
activation path. It requires a clean local `main` checkout at the manifest's
exact commit. Before interacting with the installed app, it copies both
downloaded members through no-follow file descriptors into a private snapshot,
checks the exact member set and bounds, validates the strict manifest and all
hashes, and verifies both GitHub attestations against
`brendondelgado/CodexSwitch`, the pinned app workflow, `refs/heads/main`, the
exact source digest, and a GitHub-hosted runner.

The installer then inspects the ZIP for unsafe entries, extracts it into a new
private directory, and repeats every workflow bundle validation against the
clean source checkout. It does not compile, download, patch, or re-sign. Any
failure through this point leaves `/Applications/CodexSwitch.app` and its
running process untouched.

Activation copies the already validated bundle into a same-filesystem staging
directory under `/Applications`, validates that copy, asks the old app to quit,
and refuses replacement while its executable remains live. An existing app is
replaced with `renameatx_np(..., RENAME_SWAP)` so the previous bundle remains
the rollback object. A first installation uses one same-filesystem rename.
Installed validation or relaunch failure restores the previous bundle, or
removes the failed first installation, before returning an error. A rollback
failure preserves the recovery directory and reports its exact path.

## Failure Contract

Every destination has a synchronized same-directory backup before the first
rename. Before state commit, recovery restores the exact old files or exact
absence. After state commit, recovery verifies and finishes the new set. An
`installing` state or live install transaction without its matching journal is
an unresolved durable failure; a new transaction must never adopt the visible
route as a guessed rollback baseline. An unexpected file identity, missing
committed generation, corrupt journal, or incomplete rollback likewise fails
closed. Rollback also restores the updater's previous installed-version
observation so state cannot describe the rejected route. Deterministic tests
cover clean first-install absence at every publication prefix and both sides of
the state-commit boundary.
