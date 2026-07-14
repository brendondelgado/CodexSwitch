---
toc:
  - CodexSwitch Banked Resets
  - Product Contract
  - Backend Contract
  - Automatic Redemption Policy
  - Redemption Ownership
  - State And Synchronization
  - Verification Contract
cross_dependencies:
  - docs/architecture/quota-and-reset-policy.md
  - Sources/CodexSwitch/Models/CodexAccount.swift
  - Sources/CodexSwitch/Services/RateLimitResetService.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Views/AccountCardView.swift
  - Sources/CodexSwitch/Views/PooledUsageMeterView.swift
  - crates/codexswitch-cli/src/account_store.rs
  - crates/codexswitch-cli/src/rate_limit_resets.rs
  - crates/codexswitch-cli/src/main.rs
  - crates/codexswitch-cli/src/daemon.rs
  - scripts/test-banked-resets.swift
version_control:
  branch: main
  commit: pending
---

# CodexSwitch Banked Resets

## Product Contract

The canonical selection and natural-reset policy is
`docs/architecture/quota-and-reset-policy.md`. This page documents the backend
adapter, ownership, and verification details and must not redefine that policy.

Eligible Codex Plus and Pro accounts can hold banked rate-limit resets. OpenAI
documents that these rewards can expire 30 days after grant and that applying a
reset is a separate user action after a usage limit is reached. A reset is not
an API credit balance and is not transferable.

CodexSwitch treats reset availability as account-scoped capacity. It displays
the available count and nearest expiration without exposing reset identifiers,
tokens, or referral metadata.

Official product references:

- https://help.openai.com/en/articles/6825453-chatgpt-app-features
- https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan
- https://help.openai.com/en/articles/20001271-codex-referral-promotions

## Backend Contract

The current ChatGPT desktop client reads reset inventory from:

- `GET /backend-api/wham/rate-limit-reset-credits`

It redeems a reset with:

- `POST /backend-api/wham/rate-limit-reset-credits/consume`
- JSON body: `credit_id` and an idempotent `redeem_request_id`

The inventory response contains `available_count`, `total_earned_count`, and a
`credits` array. Available credits include an identifier, status, reset type,
grant time, expiration time, title, and description. The consume response uses
codes including `reset`, `already_redeemed`, `no_credit`, and
`nothing_to_reset`.

`available_count` is observable inventory metadata, not redemption authority.
Automatic redemption requires a concrete, unexpired `available` credit with a
non-empty identifier. A positive count with no usable credit object fails
closed and must not issue a consume request with a missing or inferred ID.

These are ChatGPT product-backend endpoints, not a public OpenAI API contract.
CodexSwitch must isolate them behind one client, reject malformed responses,
and fall back to ordinary account rotation when they change or fail.

## Automatic Redemption Policy

Automatic redemption on its designated owner follows a conservation policy.
The Mac menu app is the only automatic owner. The VPS daemon cannot consume
banked resets automatically. A reset candidate may be active or inactive, but
it must have a fresh quota observation with a resettable usage limit and a
fresh bank containing at least one available, unexpired credit. CodexSwitch
selects the oldest-expiring credit for the chosen account.

A natural quota reset does not move when a banked reset is consumed. Spending a
credit shortly before that scheduled recovery therefore discards capacity. When
the blocking natural reset is within 24 hours, CodexSwitch preserves the credit
and rotates to another immediately usable account when one exists. The guard is
overridden only when the pool would otherwise be unable to serve a request.

Replacement and reset selection is pool-wide and follows this order:

1. Use immediately usable capacity in the same or a higher plan tier. This
   capacity check includes the active account even though the active account is
   not a rotation destination.
2. Rank eligible reset candidates by plan priority, then by stable account
   identity within a tier.
3. For an exhausted Pro account with only usable lower-tier capacity available,
   apply the Pro reset when its blocking natural reset is more than 24 hours
   away. After inventory and quota reconcile, activate that Pro account before
   continuing work.
4. When that Pro natural reset is at or within 24 hours, continue on the usable
   lower-tier account and preserve the Pro credit.
5. Apply a reset on any tier when no account is immediately usable and doing so
   is required to keep the pool working.
6. Consider lower-tier banked resets only after immediately usable Pro capacity
   and eligible Pro resets have been exhausted.

Consequently, an active usable Plus account does not suppress an eligible Pro
reset whose natural recovery is more than 24 hours away, but it does suppress
that reset at the 24-hour boundary. An active or inactive usable Pro account
suppresses another Pro reset, and any usable same-or-higher-tier account
suppresses a lower-tier reset.

Within that hierarchy, a reset is useful when any of these conditions is true:

1. The weekly window is exhausted or at the auto-swap threshold.
2. No other account is immediately usable, so redemption prevents an idle
   pool.
3. The oldest credit expires within 24 hours and the account currently has an
   exhausted resettable window.
4. Codex reports a direct runtime usage-limit error and no ready replacement
   account exists.

A five-hour-only limit rotates normally when a same-or-higher-tier replacement
is ready. A higher-tier account may use its reset before falling to a lower tier
only after the 24-hour natural-reset guard is satisfied. Disabling automatic
redemption never removes or mutates bank inventory.

## Redemption Ownership

Exactly one process may own automatic reset redemption for an account pool.
For the normal mirrored Mac/VPS deployment, the CodexSwitch Mac menu app is the
owner. The VPS daemon continues to poll quota and rotate accounts, but automatic
reset redemption has no daemon opt-in. Automatic in-turn recovery calls
`rotate-now` without reset ownership and therefore rotates only. Manual CLI
redemption remains available for an operator-controlled recovery through
`rotate-now --allow-banked-reset`.

Running two automatic owners is a correctness failure even though each consume
request has its own idempotency key. Two owners can select different available
credits and both requests can succeed. Installation and service verification
must therefore assert which host owns redemption before enabling it.

This failure mode was observed on 2026-07-12: the VPS daemon reported a reset
at 09:08:24 UTC with two credits remaining, then the Mac began another
redemption at 09:08:26 UTC and reported one remaining. The VPS daemon started
on 2026-07-13 at 07:09:48 UTC runs without reset redemption. Removing the daemon
opt-in makes that single-owner boundary structural rather than configuration
advice.

As defense in depth, a host that observes `available_count` fall without its own
redemption in flight treats the change as an external redemption. It must force
a fresh quota read and suppress automatic redemption for that account for at
least 15 minutes, unless a newer, non-placeholder quota response first proves
the account usable. It must not consume another credit using the quota snapshot
that preceded the inventory drop.

## State And Synchronization

Each account persists a sanitized reset bank with the count, credit status,
expiration metadata, and fetch time. The Mac uses a five-minute background
freshness window and at-most-sixty-second decision evidence. Ranking
observations must never overwrite the durable "before" bank used to detect an
external redemption.

Mac and VPS account stores use the same camel-case JSON shape. Rotation
ownership and redemption ownership are separate: both hosts may protect their
local runtimes through account rotation, while only the designated reset owner
may issue an automatic consume request. The other host may mirror newer
inventory but must not issue a second consume request. A successful consume is
followed by fresh inventory and quota reads before the account is considered
usable.

Redemption persists one UUID request identifier before the initial request. An
uncertain transport result enters reconciliation and does not automatically
issue a second POST. `already_redeemed` is accepted only as reconciliation
evidence for that same persisted identifier and only with fresh inventory and
quota confirmation.

## Verification Contract

Tests must cover inventory parsing, oldest-expiring selection, each policy
branch, pool-wide plan ordering, stable same-tier ordering, active-account
capacity suppression, the 24-hour natural-reset guard and pool-exhaustion
override, count-only inventory suppression, malformed responses,
uncertain-request reconciliation, and consume response codes. Pure policy tests
must prove that an inactive exhausted Pro ranks ahead of an active usable Plus,
while a near natural reset or another usable Pro prevents redemption.
Cross-host tests must prove that the daemon exposes no automatic redemption
option. Mac tests must prove that an external
inventory decrement survives restart and blocks a second redemption for 15
minutes, while newer usable quota evidence may clear the hold early.
Independent-process lock tests launch nested Swift Testing runs through
`swiftpm-testing-helper` when SwiftPM exposes an `.xctest` bundle as argument
zero; the bundle binary itself is not an executable process entrypoint.

Live verification is read-only: inventory GETs may confirm counts and expiry,
but tests and installation checks must not consume a real reset.

When the active Command Line Tools package does not include `TestingMacros`,
compile and run `scripts/test-banked-resets.swift` with the reset model and
service sources as the deterministic local replay. The harness resolves the
macOS temporary-directory alias before creating its journal so the secure
no-symlink storage contract is exercised against the canonical path. The normal
Swift Testing suite remains the canonical CI path when full Xcode is available.

Run the deterministic replay from the repository root:

```bash
swiftc -parse-as-library -o /private/tmp/test-banked-resets \
  scripts/test-banked-resets.swift \
  Sources/CodexSwitch/Models/QuotaSnapshot.swift \
  Sources/CodexSwitch/Models/CodexAccount.swift \
  Sources/CodexSwitch/Models/RateLimitResetBank.swift \
  Sources/CodexSwitch/Services/UsageResponseParser.swift \
  Sources/CodexSwitch/Services/RateLimitResetService.swift \
  Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
/private/tmp/test-banked-resets
```
