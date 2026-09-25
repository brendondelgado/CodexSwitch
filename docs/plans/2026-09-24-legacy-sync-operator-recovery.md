---
title: Legacy credential sync operator recovery
description: Real cross-host guarded supersession without importing credentials or claiming historical completion.
toc:
  - Contract
  - Operator Workflow
  - Guard Protocol
  - Failure And Verification
cross_dependencies:
  - 2026-09-24-credential-import-receipts.md
  - ../../scripts/recover-legacy-credential-sync.py
  - ../../scripts/test_recover_legacy_credential_sync.py
version_control:
  branch: codex/vps-reliability-20260924
  status: independent-review-passed-not-live-applied
  last_updated: 2026-09-24
---

# Contract

Retire only an explicitly reviewed unresolved, receipt-less Mac journal. Preserve
its exact original bytes in one fixed adjacent private backup slot. Return
`supersededUnknownOutcome`, never imported, completed, converged or ready. No
provider requests, credential writes, runtime activation, signals, service changes,
cache changes, or remote artifact creation. Existing locks are never created,
deleted, chmodded, or replaced. This tool works with the existing 7f60 data/lock
contracts and does not need the new receipt command.

Local quiescence is enforced by holding the existing `codexswitch-app.lock`
exclusively, plus the exact journal lock, and rejecting local importer/staging
processes. Main must stop the CodexSwitch primary using its reviewed maintenance
procedure before invocation; the tool never stops it. Acquiring the singleton
lock also prevents a replacement app from starting its services during recovery.

# Operator Workflow

Main owns live execution. Run fixtures first with
`python3 -B scripts/test_recover_legacy_credential_sync.py`.

On the Mac, use `python3 -B scripts/recover-legacy-credential-sync.py review`
with `--host`, `--user`, `--port`, `--ssh-key`, `--remote-home`, and
`--remote-release` set to the reviewed current endpoint and immutable release
directory. Endpoint fields must hash to the old journal's target fingerprint.
The REQUIRED `--expected-cli-sha256` must come from main's fresh full attested
build, not an expired staged artifact or a digest copied from an unreviewed VPS.
The remote helper hashes the actual immutable CLI on each observation.
The default local home/journal are the current user's home and
`.codexswitch/linux-devbox-credential-sync.json`; `--local-home` is available
for an explicitly reviewed alternate home, not a way to bypass live ownership.

Review prints only the operation UUID, exact journal SHA-256, target fingerprint,
generation hashes, authority epoch and a confirmation string. It holds real
guards but does not back up or retire the journal. Pass that exact confirmation
to `apply --confirm supersede-unknown:<uuid>:<sha256>` with the same endpoint
arguments. Apply obtains all guards afresh and refuses changed journal bytes.
Use no credentials in command-line arguments. SSH requires an existing trusted
host key and noninteractive public-key authentication; never disable host checks.

Example shape, with reviewed values supplied by main (do not run placeholders):

```sh
python3 -B /private/tmp/codexswitch-vps-reliability-20260924/scripts/recover-legacy-credential-sync.py review \
  --host "$REVIEWED_HOST" --user signul --port 22 \
  --ssh-key "$REVIEWED_SSH_KEY_PATH" --remote-home /home/signul \
  --remote-release "$FRESH_ATTESTED_RELEASE_DIRECTORY" \
  --expected-cli-sha256 "$FRESH_ATTESTED_CLI_SHA256"

python3 -B /private/tmp/codexswitch-vps-reliability-20260924/scripts/recover-legacy-credential-sync.py apply \
  --host "$REVIEWED_HOST" --user signul --port 22 \
  --ssh-key "$REVIEWED_SSH_KEY_PATH" --remote-home /home/signul \
  --remote-release "$FRESH_ATTESTED_RELEASE_DIRECTORY" \
  --expected-cli-sha256 "$FRESH_ATTESTED_CLI_SHA256" \
  --confirm "$EXACT_REVIEW_CONFIRMATION"
```

Use the literal host/user/port/key configuration that created the journal, not a
different SSH alias, because the endpoint fingerprint intentionally binds them.
The singleton lock path is exactly `~/.codexswitch/codexswitch-app.lock`, as in
`Sources/CodexSwitch/Services/SingleInstanceLock.swift`. The journal lock is
`~/.codexswitch/linux-devbox-credential-sync.json.lock`. Both must already exist;
the tool acquires them without writing PID or lock contents.

On success, main can independently clear obsolete non-authoritative UI caches
and resume ordinary authority reconciliation. This tool does not do that. A
fresh import on an older release stays upgrade-deferred; retiring the old hold
does not authorize an unsafe import or bypass authority selection.

# Guard Protocol

The identical helper source is sent in memory over authenticated SSH to Python;
no remote script, receipt or credential artifact is written. One SSH process
holds shared `runtime-start-install.lock`, exclusive existing
`accounts.runtime-activation.lock`, `accounts.provider-io.lock`, the authority
lock and account-store lock. All acquisition is nonblocking. No CLI calls occur
under store locks. Expected immutable release and lock inode/owner/path are
rechecked on every challenge. Remote `/proc` inspection rejects old importers
and operation staging shells, including the decryption-before-lease window.

Mac process inspection requests `comm` and `args` separately as final columns
with `ps -ww`. Actual Mac PID 60733 demonstrated that `comm` before `args` was
truncated to `/Applications/Co`; final-column comm showed the full CodexSwitch
executable. Paths with spaces remain one parsed value after UID and PID.

Executable-link inspection is supplementary: regular-file metadata never
identified an importer by itself. EACCES/EPERM on `/proc/PID/exe` is acceptable
only with complete bounded NUL-terminated argv, nonempty argv[0], stable
PID/start ticks and real/effective/saved/filesystem UIDs, unchanged argv across
the observation, and no importer or operation-stage arguments. Both executable
observations must agree, whether readable metadata or permission denial.
For a denied executable, argv[0] must explain the stable kernel comm through
its executable basename (including the kernel's 15-byte truncation) or a
`comm: ...` process title. Empty, mismatched or control-character launch forms
refuse. Missing, oversized, nonterminated or changing argv and unexpected
executable errors refuse. No systemd, PAM, SSH or PID exception is needed.

This is an absence contract for accidentally lingering cooperating importers,
not a malicious same-UID boundary. Such a writer can already bypass advisory
locks, rewrite process titles or write credential files directly. The scanner
does not authenticate code or prove that arbitrary interpreters cannot perform
future imports. Safety also requires every existing continuous guard lock,
both operation stages absent, fresh generation evidence and the final recheck;
a scanner-only pass is not authorization to recover. The role-specific
systemd/PAM proofs are removed rather than retained as unused complexity.
Remote stage absence is checked again after the final process scan, before
returning each observation.

Fresh secure reads bind stable authority epoch/request/target, complete active
store/auth token equality, SHA-256 file generations, and a confirmed current
activation record. Secret bytes stay only in remote memory. Two challenge-bound
observations must match, bracket durable local backup, and prove both stages
absent. Store/authority locks prevent cooperative concurrent writes; generation
rechecks reject uncoordinated changes. Local journal identity/generation are
compared again immediately before retirement under the continuously held lock.

The helper has a bounded lifetime and a post-observation hold grace on EOF or
transport loss; no successful one-shot flock probe is accepted. The local side
checks its SSH child is still live immediately before unlink. There is no atomic
distributed filesystem transaction: an external SIGKILL, host crash or hostile
same-UID writer in the final check/unlink interval cannot be eliminated by SSH.
No inference about remote historical success is made, and the private backup
remains the recovery source even if local directory fsync fails after unlink.

# Failure And Verification

Every refusal before unlink preserves the original journal. A fixed different
backup is a capacity conflict, not permission to overwrite it. A matching backup
from an interrupted attempt can be reused only after exact verification. Missing
locks, symlinks, unsafe modes, process ambiguity, contention, stale/changed
evidence, malformed records, mismatched target/release, or guard loss fail closed.
Errors are fixed messages: never print parser contents, process argv, remote
stderr, tokens, account emails, raw account stores or auth records.
After deployment, any durable receipt for this operation, any pending durable
import intent, or malformed receipt ledger also refuses legacy supersession.
Known receipt history must use receipt reconciliation, not this legacy path.

Deterministic tests use private temporary directories, fake process inventories,
socket transport with a separate helper process, and real flock contention.
All 39 fixtures passed after the supplementary-executable revision, including
denied-exe unrelated processes, importers, unreadable/truncated/oversized/changed
argv, PID reuse, UID changes, executable-access transitions, unexpected errors,
unexplained launch forms and remote stage reappearance after the final scan.
Existing coverage includes store/auth mismatch,
pending activation, stale evidence, attestation mismatch, unknown journal fields,
same-bytes inode replacement, generation drift, stage and backup symlinks,
missing locks, contention, importer/PID-reuse inspection, replayed challenges,
transport EOF grace, lost guard, and backup write failure. No credential values
were emitted; byte equality fixtures assert remote data is unchanged.

Read-only bounded inventory at 2026-09-24 17:26:24-25 UTC found the same 11
permission-denied executable links in two complete same-UID snapshots. All
process UIDs were 1001; process and parent identities remained stable. Only
`/proc/PID/exe` stat/readlink returned EACCES; argv, status and cgroups were
readable. No full arguments, prompts or credentials were emitted.

| PID | Parent PID/UID | Kernel comm | argv[0] only | Raw/nonempty argc | Cgroup category |
| --- | --- | --- | --- | --- | --- |
| 1180 | 1/0 | systemd | /usr/lib/systemd/systemd | 2/2 | user-manager init.scope |
| 1224 | 1180/1001 | (sd-pam) | (sd-pam) | 1/1 | user-manager init.scope |
| 1807194 | 1180/1001 | gpg-agent | /usr/bin/gpg-agent | 2/2 | systemd user service |
| 1956374 | 1956193/0 | sshd | sshd: signul@notty | 3/1 | login session.scope |
| 1956397 | 1956374/1001 | sftp-server | /usr/lib/openssh/sftp-server | 1/1 | login session.scope |
| 2252367 | 2252227/0 | sshd | sshd: signul@notty | 3/1 | login session.scope |
| 2447964 | 2447804/0 | sshd | sshd: signul@pts/4 | 3/1 | login session.scope |
| 3338468 | 3338175/0 | sshd | sshd: signul | 9/1 | login session.scope |
| 3338557 | 3338179/0 | sshd | sshd: signul | 9/1 | login session.scope |
| 3338562 | 3338177/0 | sshd | sshd: signul | 9/1 | login session.scope |
| 3338890 | 3338686/0 | sshd | sshd: signul@notty | 3/1 | login session.scope |

Counts are observed NUL-separated slots, not recoverable original exec argc;
SSH process-title rewriting leaves empty padding. Two other missing executable
links (ENOENT, PIDs 2318309 bash and 2318314 python) were confirmed zombies,
not additional permission denials. A process exited during the first snapshot;
the second had no disappearance. This inventory is point-in-time, not atomic.

Carver approved the revised supplementary-executable contract for merge within
the cooperative-process threat model, as relayed by main on 2026-09-24.
Independent verification: actual VPS scanner 3/3 passed in 90-109 ms; the Mac
scanner correctly refused the running CodexSwitch app; all 39 offline tests
passed. Source and tests are frozen for main to commit with this document and
cherry-pick into integration. Approved source SHA-256:
`64a4c878597be1901d4d933f1a5cb00fd5dc225e152084806cedbba96581e981`.
Frozen test SHA-256:
`f5d6dc20b2443fd78e10606c9c790dbeb5f0cb9e5a6e5d33ab842218ed970745`.
At 2026-09-24 17:34:22 UTC, three consecutive full read-only same-UID VPS scans
passed with the exact source SHA-256
`64a4c878597be1901d4d933f1a5cb00fd5dc225e152084806cedbba96581e981`.
The source was sent in memory over authenticated SSH and only `scan_importers`
was invoked. No production locks were acquired, no stages/credentials were
changed, and no runtime was stopped. Earlier scans of the intermediate revision
also passed; the digest above identifies the final verified source.
Actual authenticated SSHGuard end-to-end entrypoint readiness is NOT verified
by independent scanner approval, socketpair tests or inventory. The real
authenticated read-only `review` under approved quiescence must pass before any
`apply`; it is the mandatory entrypoint readiness gate. Scanner success
does not establish full recovery readiness. Do not stop unrelated processes to
make the scan pass.

Live entrypoint review/apply was not run; read-only process inventory was run.
No Cargo/Swift builds or Git publication occurred.
Main owns the three-file commit, integration cherry-pick, fresh build attestation,
permission to publish/merge, deployment, Mac quiescence, authenticated entrypoint
review and all live recovery actions.
