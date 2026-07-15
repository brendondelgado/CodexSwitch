---
title: Quota and reset policy
description: Canonical interpretation, selection, and banked-reset policy for optional usage windows.
toc:
  - Quota And Reset Policy
  - Purpose
  - Quota Model
  - Weekly-only Operation
  - Account Usability
  - Candidate Ranking
  - Banked Reset Policy
  - Durable Redemption
  - Presentation Rules
  - Policy Examples
  - Shared Test Contract
cross_dependencies:
  - ../../Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - ../../Sources/CodexSwitch/Services/UsageResponseParser.swift
  - ../../Sources/CodexSwitch/Services/SwapEngine.swift
  - ../../Sources/CodexSwitch/Services/RateLimitResetService.swift
  - ../../Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
  - ../../crates/codexswitch-cli/src/quota.rs
  - ../../crates/codexswitch-cli/src/rate_limit_resets.rs
  - ../codexswitch-banked-resets.md
  - ../codexswitch-quota-priming.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-15
---

# Quota And Reset Policy

## Purpose

This contract defines how every CodexSwitch surface interprets quota and decides between switching accounts, waiting for natural recovery, and redeeming a banked usage reset.

## Quota Model

A quota snapshot is a timestamped observation containing:

- `allowed`: the provider's global allowance when supplied.
- `limitReached`: an explicit provider exhaustion signal when supplied.
- `windows`: the windows actually returned by the provider.
- `fetchedAt`: freshness boundary for all derived decisions.

Known window kinds include five-hour and weekly. Unknown windows are retained for diagnostics but do not become synthetic available capacity.

For each window, CodexSwitch stores duration, used percentage, remaining percentage, and reset time when supplied. Duration and metadata determine kind; array position does not.

The effective remaining capacity for an allowed account is the minimum remaining value among present blocking windows. An account recovers when every blocking window has recovered, so its next full recovery is the latest reset time among currently blocking windows.

All policy decisions use one injected `now` and one quota maximum age of 15 minutes. This covers the normal ten-minute relaxed polling interval plus scheduling and network jitter, while a missed relaxed poll makes the snapshot stale before a second full interval elapses; urgent polling updates sooner. An observation is fresh from its fetch instant through exactly that boundary; future-dated or older observations are stale. Freshness is policy input, not presentation state.

## Weekly-only Operation

The service may temporarily omit the five-hour window for paid accounts. In that state:

- Weekly data is sufficient for a valid quota snapshot.
- Five-hour remaining and reset values are `nil` or absent.
- The account is not exhausted merely because five-hour data is absent.
- Polling, candidate selection, menu labels, priming, and reset logic use the weekly window normally.
- The UI hides the five-hour meter rather than displaying zero, 100 percent, unknown-as-full, or a placeholder countdown.
- Legacy two-window cache files may be read, but new state is written using the optional-window schema.

If no recognized quota window and no global allowance signal is present, the account state is unknown, not available.

## Account Usability

An account is immediately usable only when all are true:

1. Its token material is complete and not known to require reauthentication.
2. Its quota snapshot is fresh enough for activation policy.
3. The provider has not explicitly denied usage.
4. Every present blocking window is above the active exhaustion threshold.
5. No unresolved reset or activation operation owns the account.

Unknown and stale accounts are observable but cannot outrank confirmed usable accounts.

The switching and reset paths share the same candidate eligibility and deterministic ranking implementation. Semantic entry points may narrow that common candidate set, for example to higher plan tiers, but must not reimplement freshness, usability, or ordering.

Reset conservation evaluates every immediately usable account, including the active account. Switching may exclude the active account because it cannot be its own destination, but that exclusion must not hide usable capacity when deciding whether another account may spend a reset.

## Candidate Ranking

The policy optimizes for fast inference first, usable capacity second, and churn avoidance third.

Use this order:

1. A currently usable Pro account without spending a reset.
2. A Pro account made usable by an already-reconciled reset.
3. A banked reset on a Pro account when the natural-reset guard permits it.
4. A currently usable Plus account without spending a reset.
5. A Plus account made usable by an already-reconciled reset.
6. A banked reset on a Plus account when no better usable capacity exists.
7. Wait for the earliest useful natural recovery or report exhaustion.

Within the same tier and reset cost, prefer:

1. Confirmed immediate usability.
2. For candidates that require redemption, the earliest-expiring available credit.
3. Higher effective remaining capacity.
4. Later exhaustion under the observed consumption trend when available.
5. Fewer recent activations and a stable cooldown.
6. Deterministic account identity as a final tie-breaker.

Never switch to a candidate already inside the same exhaustion threshold that triggered the swap.

## Banked Reset Policy

A reset is scarce capacity, not an automatic response to every limit.

Before redemption:

1. Confirm the account is genuinely blocked by quota, not stale auth or transport failure.
2. Confirm an unused reset exists in a fresh inventory generation.
3. Confirm there is no unresolved attempt for the same stable provider account.
4. Evaluate usable Pro accounts, then usable Plus accounts, including the active account.
5. Evaluate time until natural recovery.

A reset is normally suppressed when the account's natural weekly recovery is within 24 hours. It may be used inside that guard only when all higher-priority capacity is unavailable and work requires capacity now. The decision and exception reason must be recorded.

This avoids spending a reset shortly before a natural reset that will happen independently and would make the banked reset wasteful.

A stale positive snapshot cannot authorize selection or activation. A stale denied, exhausted, or otherwise blocked snapshot also cannot authorize reset spending, including when a runtime usage-limit signal exists. The coordinator requests a fresh quota observation or leaves the operation in manual-wait state.

## Durable Redemption

The Mac menu app is the sole automatic redemption owner. The VPS daemon has no
automatic-reset option. An explicit operator command may request one manual
redemption, but it does not create a second background owner.

Reset redemption is a journaled state machine:

```text
prepared -> submitted -> reconciling -> confirmed-pending-persistence -> confirmed
                              |                         |
                              +--> uncertain            +--> failed-safe/manual-review
```

Before the POST, persist and read back account identity, reset credit identity, request UUID, starting inventory, starting quota, owner, and timestamp. Persist and read back every transition to `submitted` before sending the POST and every transition to `reconciling` before returning an uncertain result. Journal mutations use the shared descriptor-anchored, cross-process locked, generation-checked secure-file transaction; only a proven committed generation becomes in-memory authoritative state. A timeout, process crash, HTTP 5xx, malformed body, delayed inventory update, or persistence failure leaves the prior proven state authoritative and never authorizes an immediate second POST.

Success requires fresh evidence that:

- the selected reset inventory decreased or the selected credit became consumed, and
- the account quota became usable in a newer observation.

Fresh bank and quota evidence enters `confirmed-pending-persistence`. The
refreshed account state must be durably committed and read back before the
journal can become terminal `confirmed`; a crash or persistence failure keeps
redemption suppressed.

Reconciliation uses stable provider account identity so a changed local UUID cannot bypass duplicate-spend protection.

## Presentation Rules

- Render only observed windows.
- Label weekly-only operation through the meter itself; do not show an alarming missing-five-hour error.
- Separate local Mac status from VPS status.
- Separate remaining quota from reset inventory.
- Show reset attempt states such as pending reconciliation rather than guessing success.
- Show stale or unknown observations as stale or unknown, never as zero or full.
- When the provider reports global exhaustion and still supplies quota windows,
  show the exhausted state and every observed natural-reset timestamp/countdown.
  A denial label must not discard usable recovery metadata.
- Do not let a cached UI percentage override fresher runtime/API evidence.
- Before rotating because of an apparent limit, poll the active account when
  possible and persist the observation with its fetch time. A fresh provider
  denial or typed runtime limit overrides an older cached 100-percent value;
  the stale value must not keep an exhausted account selected.
- Quota and reset-inventory network calls never hold the account-store lock.
  Their results commit only after a generation recheck, so a slow poll cannot
  block a manual swap and cannot overwrite a newer activation.

## Policy Examples

| Situation | Result |
| --- | --- |
| Pro has 70 percent weekly and no five-hour window | Continue using Pro; five-hour is absent, not exhausted |
| Pro is exhausted, another Pro is usable | Switch to the usable Pro without spending a reset |
| Active Pro is usable, inactive Plus is exhausted with a banked reset | Keep using Pro; preserve the lower-tier reset |
| Active Plus is usable, inactive Pro is exhausted and naturally recovers in more than 24 hours | Redeem the Pro reset to restore faster-tier capacity |
| All Pro accounts exhausted, best Pro naturally resets in 12 hours, Plus is usable | Use Plus temporarily; preserve the Pro reset |
| All accounts exhausted, Pro reset is available, natural recovery is four days away | Redeem one Pro reset and reconcile it before further mutation |
| Reset request times out | Mark uncertain and poll inventory/quota; do not POST again |
| API returns only an unrecognized window | Mark quota unknown and do not activate based on assumed capacity |

## Shared Test Contract

Swift and Rust must consume the same fixture scenarios and produce equivalent domain results for:

- weekly-only, five-hour-only, dual-window, and unknown-window payloads;
- reordered and additional rate-limit objects;
- stale, globally denied, and explicitly exhausted snapshots;
- candidate ordering across Pro and Plus;
- natural-reset guard boundaries;
- timeout and crash recovery during redemption;
- changed local identity for the same provider account;
- UI absence versus zero semantics.
