---
title: Credential sync hold recovery
description: Retire the receipt-less September 9 credential-sync hold and deliver fresh Mac credentials to the VPS through the verified import path.
toc:
  - Scope
  - Preconditions
  - 1. Backups
  - 2. Baseline Evidence
  - 3. Install The Mac Build
  - 4. Observe Supersession And Fresh Sync
  - 5. Verify
  - Failure Handling
  - Rollback
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../plans/2026-09-24-credential-import-receipts.md
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../scripts/credential-freshness-report.py
version_control:
  branch: claude/fix-cred-sync
  status: ready-not-executed
  last_updated: 2026-09-27
---

# Scope

This runbook retires the unresolved, receipt-less operation
`6bcae028-1fdf-4e44-a003-e8b659719670`, created on 2026-09-09. Its journal
SHA-256 at 2026-09-28T03:5xZ was
`5af82d389874369df96fee89d9780373ca2b575d497cc65718c263c618013d3e`.
The Mac app then runs one normal authority-preserving full-pool sync. The VPS
merges per account: a Mac generation replaces a VPS generation only when its
access token expires later. The fresh sync therefore delivers `bd7349@gmail.com`
(VPS copy expired 09-27, blocked `token_expired`) and `rainystarforest@gmail.com`
(VPS copy expired 09-09). It also clears the VPS runtime block on both accounts.

No step restarts Codex, redeems a reset, or edits credential files by hand.
Step 3 restarts the CodexSwitch menu-bar app only.

# Preconditions

- The new VPS release is active and passed the `linux-repository-deployment.md`
  verification.
- The Mac build contains the bounded-supersession commit from
  `claude/fix-cred-sync`.

```sh
ssh signul-vps 'readlink -f ~/.local/share/codexswitch/current'
ssh signul-vps '~/.local/share/codexswitch/current/codexswitch-cli credential-import-status --help >/dev/null && ~/.local/share/codexswitch/current/codexswitch-cli update-bundle --help | grep -c -e --receipt-operation-id -e --receipt-baseline-fingerprint'
```

The first command must print the new release directory, not
`0.1.0-7f60ba3c...`. The second must print `2`. Stop if either check fails. The
old CLI keeps the hold by design.

# 1. Backups

```sh
TS=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 ~/.codexswitch/backups/credsync-$TS
cp -p ~/.codexswitch/linux-devbox-credential-sync.json ~/.codexswitch/accounts.json ~/.codexswitch/backups/credsync-$TS/
shasum -a 256 ~/.codexswitch/linux-devbox-credential-sync.json
ssh signul-vps "umask 077; d=~/.codexswitch/backups/credsync-$TS; mkdir -p \$d && cp -p ~/.codexswitch/accounts.json ~/.codexswitch/pool-authority.json ~/.codex/auth.json \$d/ && ls -l \$d"
```

The digest must equal the Scope value. If it differs, the hold changed, so stop
and review it.

# 2. Baseline Evidence

The report prints expiry, a refresh-token hash prefix, and runtime blocks. It
never prints token values.

```sh
python3 scripts/credential-freshness-report.py > ~/.codexswitch/backups/credsync-$TS/mac-before.txt
ssh signul-vps 'python3 - ~/.codexswitch/accounts.json' < scripts/credential-freshness-report.py > ~/.codexswitch/backups/credsync-$TS/vps-before.txt
grep -E 'bd7349@gmail|rainystarforest' ~/.codexswitch/backups/credsync-$TS/*-before.txt
```

Expected: on the Mac, `bd7349@gmail.com` shows `exp=2026-10-05T15:55Z ok` and
`rainystarforest@gmail.com` shows `ok`. On the VPS, both show `EXPIRED` with
`block=token_expired`. If the Mac copy of `bd7349@gmail.com` is expired or
blocked, stop; a sync cannot deliver it.

# 3. Install The Mac Build

Use the standard Mac build/deploy checklist from the merged checkout containing
the fix (build, stop the old app, copy both binaries, re-sign, clear quarantine,
relaunch):

```sh
swift build -c release
kill $(pgrep -f "CodexSwitch.app")
cp -f .build/release/CodexSwitch /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
cp -f .build/release/CodexSwitch ~/.codexswitch/CodexSwitch
codesign --force --deep --sign - /Applications/CodexSwitch.app && xattr -cr /Applications/CodexSwitch.app
open -a CodexSwitch
```

# 4. Observe Supersession And Fresh Sync

Within about 3 minutes the app should log one `SUPERSEDED` line, followed by
`SYNCED` or an explained `FAILED`:

```sh
LOG=~/.codexswitch/logs/codexswitch-$(date -u +%F).log
tail -n 0 -F "$LOG" | grep --line-buffered -E 'LINUX_DEVBOX_CREDENTIAL_SYNC_(SUPERSEDED|SYNCED|FAILED|HELD)'
```

Expected:

```text
LINUX_DEVBOX_CREDENTIAL_SYNC_SUPERSEDED operation=6bcae028-... outcome=superseded_unknown_outcome remote_active=... backup=.../linux-devbox-credential-sync.json.superseded.json
LINUX_DEVBOX_CREDENTIAL_SYNC_SYNCED context=authority-reconciliation accounts=11 output=...
```

`HELD` lines with `context=historical-receipt-reconciliation` carry the reason
that blocks supersession. See Failure Handling.

# 5. Verify

```sh
test ! -e ~/.codexswitch/linux-devbox-credential-sync.json && echo journal-retired
shasum -a 256 ~/.codexswitch/linux-devbox-credential-sync.json.superseded.json   # must equal the Scope digest
python3 scripts/credential-freshness-report.py > ~/.codexswitch/backups/credsync-$TS/mac-after.txt
ssh signul-vps 'python3 - ~/.codexswitch/accounts.json' < scripts/credential-freshness-report.py > ~/.codexswitch/backups/credsync-$TS/vps-after.txt
grep -E 'bd7349@gmail|rainystarforest' ~/.codexswitch/backups/credsync-$TS/*-after.txt
ssh signul-vps 'python3 -c "import json,os;d=json.load(open(os.path.expanduser(\"~/.codexswitch/accounts.json.credential-import-receipts.json\")));print([r[\"state\"] for r in d[\"records\"]][-3:])"'
ssh signul-vps 'journalctl --user -u codexswitch.service --since "-30 min" --no-pager | grep -E "bd7349@gmail.com|rainystarforest" | tail -5'
```

Pass criteria:

- On the VPS, `bd7349@gmail.com` shows the Mac's `exp`, the same `rt=` prefix
  as the Mac, `ok`, and `block=-`. The same holds for `rainystarforest@gmail.com`.
- The last receipt record is `completed`.
- There are no new `failed to refresh`/`401` lines for those accounts, and no
  new `CREDENTIAL_SYNC_HELD` lines in the Mac log.
- Accounts whose VPS generation expires later keep their VPS `rt=` prefix. The
  merge never regresses them.

A banked-reset redemption on the VPS for `bd7349@gmail.com` is a separate owner
action. Run it only after the checks above pass.

# Failure Handling

| `HELD` reason | Meaning | Action |
| --- | --- | --- |
| `Historical credential receipt unavailable` | The VPS CLI lacks `credential-import-status` | Recheck the Preconditions; the release is not active |
| `remote importer is not proven absent` | A process mentions the operation stage, or `pgrep` failed | Run `ssh signul-vps "pgrep -af '[c]odexswitch-auto-sync-6bcae028'"`; do not kill it; review |
| `staging is not proven absent` | `/tmp/codexswitch-auto-sync-6bcae028-...` exists on the VPS | Review the stage; never delete it blindly |
| `Fresh remote credential evidence is unavailable` | The VPS store/auth read failed | Fix connectivity or store readability; the app retries every 2 minutes |
| `pending` status (reviewed recovery) | The VPS holds a durable intent for the operation | Not auto-superseded; escalate |

If `SYNCED` never follows `SUPERSEDED`, read the `FAILED` line. A new hold now
belongs to a fresh, receipt-bound operation, so historical receipt recovery
handles it.

# Rollback

Supersession never writes credentials. Restore the hold (rare, only for
review) by quitting CodexSwitch and running
`cp -p ~/.codexswitch/linux-devbox-credential-sync.json.superseded.json ~/.codexswitch/linux-devbox-credential-sync.json`.
Do not roll back VPS credentials after a successful receipt. The merge already
kept every newer VPS generation. The VPS copies in `backups/credsync-$TS` are
evidence only: restoring them would reinstall the dead `bd7349@gmail.com`
refresh token.
