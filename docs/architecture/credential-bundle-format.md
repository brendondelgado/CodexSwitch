---
title: Credential bundle format
description: Versioned encryption and import contract for token-bearing Mac-to-VPS account bundles.
toc:
  - Credential Bundle Format
  - Threat Model
  - Version 2 Envelope
  - Authenticated Payload Consistency
  - Key Derivation
  - Import Rules
  - Compatibility
  - Remote Mutation Transport
  - Durable Credential Sync Operations
  - Reconciliation and Retry
  - Polling Distinction
cross_dependencies:
  - ../../Sources/CodexSwitch/Models/LinuxDevboxBundle.swift
  - ../../Sources/CodexSwitch/Services/LinuxDevboxExportService.swift
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../crates/codexswitch-cli/src/import.rs
  - ../linux-cli-only.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# Credential Bundle Format

## Threat Model

A `.csbundle` contains complete account credentials and may be copied through a
temporary transport directory. Encryption must remain resistant to offline
guessing if an archive is captured. File permissions and a short expiry reduce
exposure but do not replace a password-hardening KDF.

The unencrypted envelope must not reveal account emails, active account
identity, host name, token hashes, or quota state. Those fields belong only in
the authenticated ciphertext.

## Version 2 Envelope

Version 2 is a bounded JSON object with only cryptographic routing fields:

- `format`: `codexswitch-linux-devbox-bundle`
- `schemaVersion`: `2`
- `kdf`: `pbkdf2-hmac-sha256-v2`
- `iterations`: `600000`
- `cipher`: `aes-256-gcm`
- `salt`: 32 random bytes, base64 encoded
- `nonce`: 12 random bytes, base64 encoded
- `ciphertext`: encrypted payload plus the 16-byte GCM tag, base64 encoded

The encrypted payload contains metadata and accounts together. Decoders impose
explicit limits before base64 allocation or JSON decoding, reject unknown or
duplicate fields, and require exact salt, nonce, tag, and derived-key lengths.

## Authenticated Payload Consistency

Authenticated metadata is a redundant integrity description, not a hint. A
version 2 decoder accepts a payload only when all of these values exactly match
the authenticated account array before any account-selection policy runs:

- `accountCount` equals the array length.
- `emails` equals the account emails in payload order.
- The non-empty payload contains exactly one active account.
- `activeAccountId` equals that active account's provider `accountId`.
- `activeEmail` equals that active account's `email`.

Exporters derive all five fields from the final ordered account array. Importers
must reject a mismatch instead of repairing metadata, selecting a replacement
active account, or committing any account-store or auth-file mutation.
After validation, import preserves that authenticated active identity exactly.
Plan preference and quota policy do not run between bundle validation and
persistence.

## Key Derivation

Version 2 derives a 32-byte AES key with PBKDF2-HMAC-SHA256 and 600,000
iterations. The iteration count is encoded for future migration but imports
accept only a bounded approved range. Export uses the canonical current value.

This follows the current OWASP PBKDF2-HMAC-SHA256 work-factor recommendation
and NIST SP 800-132's requirement for a random salt and deliberately expensive
password-based derivation:

- https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- https://csrc.nist.gov/pubs/sp/800/132/final

Automatic Mac-to-VPS sync continues to use a cryptographically random
passphrase. Manual export requires a non-empty confirmation and applies the
same KDF; no fast-path derivation exists.

## Import Rules

Import reads regular files only, without following symlinks. It bounds total
bytes, parses the envelope, derives the key, authenticates and decrypts, then
parses the inner payload. No metadata is trusted before GCM authentication.

Only a validated version 2 `.csbundle` may enter `import` or `update-bundle`.
Format detection, version probing, decryption, and compatibility inspection are
non-mutating phases. The mutating handoff occurs only after the version 2
envelope, authenticated payload, metadata consistency, expiry, and account
invariants all pass.

The passphrase file is a regular current-user file with mode `0600`, bounded
length, and no symlink traversal. Import clears passphrase bytes where the
platform API permits and never logs credentials, salts, ciphertext, or derived
keys. Interactive passphrase entry disables terminal echo before reading and
restores the original terminal attributes on success, error, and unwind.

## Compatibility

New exports are version 2 only. Legacy encrypted version 1 `.csbundle`, `.age`,
and `.tar` inputs may be identified or compatibility-inspected without changing
state, but they can never reach the account-store/auth mutation path used by
`import` or `update-bundle`. Operators must create a fresh version 2 export.
Legacy inspection is isolated and bounded; an unknown version, extension, or
algorithm fails closed.

## Remote Mutation Transport

Mac-initiated VPS credential sync stages each transfer in a new remote directory
with mode `0700`; bundle and passphrase files remain mode `0600`. The remote
command installs `EXIT`, `HUP`, `INT`, and `TERM` cleanup traps before invoking
`update-bundle`. Cleanup removes the whole private staging directory and must
preserve the command's original exit status. Automatic sync never bypasses the
authenticated bundle expiry. If cleanup fails, the remote command emits a
dedicated cleanup-failure marker and cannot report success; CodexSwitch records
a durable unresolved hold instead of silently leaving credential files behind.

Read-only SSH probes may try another transport candidate. A mutating remote
command uses fresh high-entropy start and completion markers and may try another
candidate only when the local process runner proves that SSH itself never
launched. A start marker without the matching completion marker is
outcome-unknown. Error text, exit status `255`, missing markers, timeouts, and
connection loss never authorize a mutation replay. The same rule applies to
account swaps, credential updates, and `poll`, because polling persists
refreshed account state.

An outcome-unknown credential update or unresolved cleanup creates a durable
automatic-sync hold. Later account events must not submit the mutation again
under a new operation identifier. An operator must reconcile the remote account
store and staging directory before clearing that hold. Deterministic remote
rejection is reported but is not automatically replayed.

## Durable Credential Sync Operations

Before the Mac creates a remote staging directory, it must durably commit one
token-free operation record under `~/.codexswitch`. The record contains only an
operation identifier, a target-host fingerprint, the local credential-state
fingerprint, expected non-secret account-identity and complete credential-set
fingerprints, the expected active provider account identifier and token-hash
prefix, the pre-mutation remote evidence, the derived staging paths, timestamps,
phase, and a human-readable reason. Raw tokens, bundle bytes, passphrases,
emails, and private keys are forbidden from the journal.

The operation identifier owns both local and remote staging paths. A crash,
forced exit, or relaunch with a `pending` record is therefore outcome-unknown;
the next process must not mint a new identifier or submit the bundle again.
Every deterministic terminal path resolves the same record:

- successful import clears it after verified local cleanup;
- proven local process-launch failure clears it before scheduling a bounded
  retry;
- deterministic remote rejection clears it after verified cleanup;
- timeout, signal exit after import starts, missing completion evidence, or
  cleanup failure retains it with a specific token-free unresolved reason.

Local staging is created as a new `0700` directory. Bundle and passphrase files
are opened as new regular files with mode `0600`; permissions are restrictive
from creation rather than repaired after writing. Local cleanup must verify the
path is absent. A failed removal or failed absence check is observable and keeps
the operation held.

## Reconciliation and Retry

A held operation has one clear path: read-only reconciliation of that same
operation. Reconciliation first proves that its remote staging path is absent,
then reads remote auth diagnostics and token-free account evidence. The evidence
includes a one-way fingerprint over every account's provider identifier, full
token tuple, and active flag; raw credentials never leave the VPS. It may
classify the operation as committed only when that complete credential-set
fingerprint, the active provider identifier, active token-hash prefix,
auth/store agreement, and account-identity fingerprint all match the journal.
It may classify the operation as safe to retry only when the stage is absent and
all remote evidence exactly matches the recorded pre-mutation baseline. Missing,
malformed, changing, conflicting, or unreachable evidence keeps the hold.

Clearing is compare-and-delete against the journaled operation identifier. A
stale callback or operator action cannot clear a newer operation. The stored
reason is published in the VPS status and swap log while reconciliation remains
unresolved; there is no blind `clear` switch.

If the recorded remote stage still exists, CodexSwitch leaves it untouched. An
operator must first prove that no live import owns that exact operation path and
remove only that recorded path. The next periodic reconciliation then performs
the same absence and state checks; it does not accept an operator assertion in
place of evidence.

Only a proven pre-execution local launch failure is retryable. It is scheduled
through one bounded delayed retry, not left in an inert in-memory queue. All
other failures require a new account event or successful reconciliation.

## Polling Distinction

`poll` persists quota and refreshed account state, so one invocation still uses
the mutating SSH marker policy and never tries another transport after an
unknown start. It does not transfer a credential bundle, create secret staging,
or change the selected account, so it does not share the credential-operation
journal. An unknown poll is surfaced as outcome-unknown and may be attempted
again only by a later independently scheduled refresh; it is never replayed
inside the failed call. A timeout, missing completion marker, or signal exit
after the poll starts is unknown. A completed nonzero exit is also unknown at
the Mac transport layer because the caller has no independent commit evidence;
the next scheduled read refresh reconciles the persisted state.
