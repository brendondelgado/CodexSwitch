---
title: T3 usage hub
description: How T3 Code reads CodexSwitch account usage and redeems banked resets through the VPS authority.
toc:
  - T3 Usage Hub
  - Scope
  - Data Flow
  - Redemption
  - Account Labels
  - Operations
cross_dependencies:
  - ../../integrations/t3-usage-hub/hub.py
  - ../../integrations/t3-usage-hub/test_hub.py
  - ../../integrations/t3-usage-hub/install.sh
  - ../../integrations/t3-usage-hub/codex-usage-hub.service
  - ./quota-and-reset-policy.md
  - ./shared-app-server-client.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-09-28
---

# T3 Usage Hub

## Scope

T3 Code shows a pooled usage view and a "redeem banked reset" button for every
account a configured *usage limit source* reports. T3 only speaks the
CLIProxyAPI management API for such sources. The hub is a small server on the
VPS (`127.0.0.1:8319`, user unit `codex-usage-hub.service`) that implements
exactly the calls T3 makes and answers them from CodexSwitch's own VPS store.
It is an adapter, not a coordinator: it owns no policy and no credentials.

## Data Flow

- `GET /v0/management/auth-files` lists paid accounts from
  `~/.codexswitch/accounts.json`. Tokens are never read into a response.
- `POST /v0/management/api-call` answers the upstream URLs T3 would have
  proxied: `/wham/usage` from the stored quota snapshot and
  `/wham/rate-limit-reset-credits` from the stored reset inventory. Any other
  URL is refused with an upstream 403; the hub never contacts a provider.
- Usage freshness therefore equals the VPS daemon's store freshness; the daemon
  keeps blocked accounts with banked credits fresh for this reason (see
  [quota-and-reset-policy.md](quota-and-reset-policy.md)).

## Redemption

`POST …/rate-limit-reset-credits/consume` runs
`codexswitch-cli redeem-reset <email> --json --request-id <T3 request id>`, so
every T3 redemption goes through the VPS reset journal exactly like a
redemption from the Mac app. T3 derives the request id deterministically from
the account and credit, which makes retries idempotent.

The CLI prints the same envelope message for every refusal, so the hub
classifies from the envelope `disposition` and the `Error:` line on stderr,
never from the message text:

| CLI result | Hub answer to T3 |
| --- | --- |
| exit 0, `submittedReset: false` | `already_redeemed` |
| exit 0 otherwise | `reset` |
| `rejected`, quota observed `Usable` | `nothing_to_reset` |
| `rejected`, transient daemon race (runtime-activation or provider-I/O lease busy, account store changed before provider I/O) | retried with the same request id for up to 8 s, then HTTP 409 |
| any other `rejected` | HTTP 409 (nothing was spent) |
| `outcomeUnknown` or timeout | HTTP 502/504, never retried |

Rationale: `rejected` proves no consume request was sent, so retrying is safe;
an unknown outcome must be reconciled, not replayed. The 8 s retry window keeps
the hub under T3's 15 s management-request timeout. Before 2026-09-28 the hub
matched `"no banked"` in the message, which turned every refusal, including a
routine lease collision with the daemon tick, into a silent `no_credit`.

Every outcome is appended to `redeem.log` in the hub directory.

## Account Labels

T3 labels a source account by its `id` in its account list, and renders
accounts that carry an `email` as initials in the pooled view. The hub uses the
email local part (`bd7349`) as the id, falling back to the full address when two
listed accounts share a local part. The `email` field stays present: T3 matches
it against its own provider accounts, which routes redeem clicks on those rows
through the hub and therefore through the CodexSwitch journal instead of
directly through a Codex app-server.

## Operations

- Install or update: `integrations/t3-usage-hub/install.sh [ssh-host]`. It runs
  the tests, refuses while a redemption is in flight, keeps a timestamped
  backup, restarts only the hub, and restores the backup if the health check
  fails.
- Tests: `python3 integrations/t3-usage-hub/test_hub.py` (real HTTP server,
  fake CLI, temporary store; no network or VPS access).
- Diagnose a T3 redemption: `redeem.log` in the hub directory, then the VPS
  T3 trace `ws.rpc.provider.consumeResetCredit` in
  `~/.t3/userdata/logs/server.trace.ndjson*`.
