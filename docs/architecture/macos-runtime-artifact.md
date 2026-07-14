---
title: macOS runtime artifact
description: Provenance, validation, staging, and activation contract for the remote-built macOS CodexSwitch runtime set.
toc:
  - macOS Runtime Artifact
  - Purpose
  - Build Gate
  - Trust Bootstrap
  - Manifest
  - Staging
  - Activation
  - Failure Contract
cross_dependencies:
  - ../../crates/codexswitch-cli/src/codex_update/macos_activation.rs
  - ../../crates/codexswitch-cli/src/codex_update/preparation.rs
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../scripts/install-macos-cli-artifact.sh
  - ../../.github/workflows/build-fork.yml
  - macos-cli-launcher.md
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# macOS Runtime Artifact

## Purpose

A complete macOS hot-swap runtime has three coupled executables: `codex`,
`codex-code-mode-host`, and `codexswitch-cli`. They are built from one exact
CodexSwitch commit on native Apple Silicon, transferred as one artifact, staged
as one immutable generation, and activated by one journaled transaction. Mixing
one new executable with an older member is prohibited.

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
upstream workspace but are not listed by the patched member crates. Immediately
after patching, the workflow refreshes `codex-rs/Cargo.lock` with offline Cargo
metadata resolution. That lockfile change is part of the hashed source patch;
the release build still uses `--locked`, and post-build provenance revalidates
the same complete patch hash.

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
exposes this artifact format and guarded activation command. It copies the
three executables and the original `manifest.json` into one new attempt-ID
generation. Existing signatures and manifest-approved bytes are preserved;
the control plane never builds, downloads, or re-signs on the Mac. An existing
same-version generation is reused only when a full revalidation proves the
exact manifest and all three executable identities. Reuse refreshes the
observed installed route before a journal records its rollback baseline.

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

The running CLI process is not signalled or replaced in memory. After successful
activation, one explicit exit and resume starts the new executable set.

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
