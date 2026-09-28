---
title: September 28 Mac and VPS sync recovery
description: Evidence, fixes, deployment record, and remaining risk for the Mac/VPS desync and banked-reset failures of 2026-09-27/28.
toc:
  - Mac And VPS Sync Recovery
  - Symptoms
  - Root Causes
  - Fixes
  - Deployment Record
  - Verification
  - Operational Findings
  - Remaining Risk
  - Rollback
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../architecture/quota-and-reset-policy.md
  - ../architecture/macos-runtime-discovery.md
  - ../architecture/t3-usage-hub.md
  - ../runbooks/credential-sync-hold-recovery.md
  - ../runbooks/linux-repository-deployment.md
version_control:
  branch: main
  status: record
  last_updated: 2026-09-28
---

# Mac And VPS Sync Recovery

## Symptoms

- 2026-09-27 17:57 to 2026-09-28 03:05 UTC: the Mac presented shopszn17 (99% used)
  as current while Codex drew from brendondelgado07. Activation retried 106 times.
- 2026-09-28 02:49 UTC: a banked reset redeemed from T3 Code was reported as
  "no credit"; nothing was spent.
- The VPS copy of bd7349@gmail.com was dead (HTTP 401 on refresh at
  2026-09-27 18:33 UTC); amazonforest40 and bd7349@me.com were dead on the Mac.
- Mac to VPS credential sync had been held since 2026-09-09.

## Root Causes

1. A 2026-09-09 legacy credential-sync hold with no receipt could never resolve.
   Re-posting it every ~7.5 s discarded every in-flight VPS readiness check
   (`stale_after_account_mirror`), so the Mac never accepted a fresh VPS status.
2. A foreign-hosted `codex app-server`, for example one started by T3 Code, was
   treated as the ChatGPT desktop child. It was unverifiable, so it wedged
   activation in `committedDegraded`.
3. Display surfaces read a stale VPS pool target instead of the credentials
   committed on the Mac.
4. `redeem-reset` failed on the first collision with the daemon's
   runtime-activation lease, which is held ~0.5-1.2 s of every ~6 s tick. The
   T3 hub then mapped every refusal to `no_credit`.
5. Both hosts refreshed single-use OAuth refresh tokens, but refreshed tokens
   only flowed Mac to VPS, so whichever host refreshed second held a dead chain.
6. After deployment: import receipts completed only after a runtime reload, and
   zero running runtimes could never converge. This produced a fresh hold and a
   `degraded` authority whenever the VPS had no Codex app-server running.
7. The routine authority poll forced a credential sync every ~70 s even when
   converged.

## Fixes

- PR #7 (`2416278`):
  - reset lease wait and macOS `redeem-reset` guard;
  - VPS holder freshness and external redemption detection;
  - versioned T3 usage hub;
  - hold supersession, unmanaged-runtime classification and a single display
    read model;
  - external hold clear fix and stale-usage labels;
  - newest-generation token convergence in both directions.
- PR #8 (`d4060c5`):
  - receipts attest committed credentials;
  - positive zero-runtime discovery converges on Linux;
  - holds only for possibly-changed credentials, and `HELD` is deduplicated;
  - metadata failures no longer block macOS artifact staging;
  - dead reconciliation code removed.
- PR #9: the authority poll honors the unchanged-pool shortcut.

## Deployment Record

- VPS:
  - Linux artifacts from runs `36382667004` (`2416278`) and `36392414644`
    (`d4060c5`) reused the attested upstream Codex 0.153.2 binary.
  - Activation requires every account-bearing app-server to be inactive and the
    runtime start/install lock to be free.
  - The desktop app-server was stopped through `vps-codex-restart.py --stop-only`.
    ChatGPT on the Mac was quit so it would not respawn the server.
  - T3's app-server received one identity-checked SIGINT.
  - `kittylitter.service` was stopped briefly because its app-server proxy has
    held a shared runtime start/install lock since 2026-09-05.
- Mac:
  - macOS runtime artifacts from runs `36382686254` and `36392417071`;
  - app via `scripts/build-app.sh --install`, ad-hoc signed with
    `CODEXSWITCH_CODESIGN_IDENTITY=-`. The "iPhone Developer" identity prompts
    for keychain access and hangs unattended.
- Credential recovery followed `credential-sync-hold-recovery.md`, with backups
  under `~/.codexswitch/backups/credsync-*` on both hosts.

## Verification

At 2026-09-28 07:55 UTC:
- Every one of the 11 accounts had an identical refresh-token hash prefix and
  expiry on both hosts, and all were valid.
- Both hosts had brendondelgado07 active.
- The VPS authority was `stable`, the VPS `doctor` reported ready, and the Mac
  logged `LINUX_DEVBOX_READY`.
- One banked reset (brenchat7795) was redeemed through the VPS CLI at the
  owner's request.

## Operational Findings

- `kittylitter.service` keeps a shared hold on
  `~/.local/share/codexswitch/runtime-start-install.lock` through a long-lived
  `codex app-server proxy`. Every release activation must stop it briefly.
- Stale artifacts were archived to `~/Archive/CodexSwitch-scratch-20260928`, not
  deleted:
  - a July 30 desktop install journal in phase `validating`;
  - ~4 GB of old ChatGPT/CodexSwitch bundles in `/Applications`;
  - the VPS's July `codex-cli-update.json`, which advertised a downgrade to 0.144.6.
- The main checkout's uncommitted July work (runtime-storage hardening, the
  clodex/CCS VPS bridge, which is live on the VPS) is preserved on
  `archive/main-checkout-wip-20260928` and is not merged.

## Remaining Risk

- Two hosts can still refresh the same chain inside one convergence round. The
  loser recovers within ~5 min when the newer generation arrives.
- The VPS `hotswap-ack` directory scan exceeded its 250 ms budget once, under
  deploy I/O load.
- Linux releases do not record `installedVersion` in the updater state.

## Rollback

- VPS: `~/.local/share/codexswitch/previous` points at the prior release. Follow
  the Rollback section of `linux-repository-deployment.md`.
- Mac: rebuild the prior commit with `scripts/build-app.sh --install`, and
  reinstall the prior macOS runtime artifact.
