---
toc:
  - CodexSwitch Banked Resets
  - Product Contract
  - Backend Contract
  - Automatic Redemption Policy
  - Redemption Ownership
  - Manual Redemption And Expiration Alerts
  - State And Synchronization
  - Verification Contract
cross_dependencies:
  - docs/architecture/quota-and-reset-policy.md
  - Sources/CodexSwitch/Models/CodexAccount.swift
  - Sources/CodexSwitch/Services/RateLimitResetService.swift
  - Sources/CodexSwitch/Services/NotificationManager.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Models/RateLimitResetPresentation.swift
  - Sources/CodexSwitch/Views/AccountCardView.swift
  - Sources/CodexSwitch/Views/PopoverContentView.swift
  - Sources/CodexSwitch/Views/PooledUsageMeterView.swift
  - crates/codexswitch-cli/src/account_store.rs
  - crates/codexswitch-cli/src/rate_limit_resets.rs
  - crates/codexswitch-cli/src/main.rs
  - crates/codexswitch-cli/src/daemon.rs
  - scripts/test-banked-resets.swift
version_control:
  branch: main
  commit: pending
  status: canonical
  last_updated: 2026-07-21
---

# CodexSwitch Banked Resets

## Product Contract

The canonical selection and natural-reset policy is
`docs/architecture/quota-and-reset-policy.md`. This page documents the backend
adapter, ownership, and verification details and must not redefine that policy.

Paid accounts may report banked rate-limit resets. OpenAI
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
2. Rank eligible reset candidates by plan priority, then by the account's
   oldest available-credit expiration, then by stable account identity.
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
`redeem-reset <account>`. That command accepts one exact blocked paid account,
requires its complete runtime credential set and normalized stable provider
identity, consumes at most one credit, never activates the account, and replays
an existing uncertain journal without submitting a second credit.

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

As defense in depth, every fresh inventory passes one transition classifier
before replacing the previous authoritative bank. The decision baseline is not
rebased by preflight, final authorization, background refresh, or reconciliation.
A host that observes an available credit disappear without an exact one-credit
local expectation treats the change as an external redemption. A local
expectation is bound to one attempt UUID, one credit UUID, one provider account,
and one starting count; it can explain only the transition from `N` to `N - 1`
that removes that selected credit while preserving every other available credit
and while the selected credit's recorded expiration remains in the future. A
selected credit that could have expired naturally cannot prove redemption from
absence and count decrease alone.
The inventory observation timestamp is captured after the provider response
completes, preventing a credit that expires during the request from being
treated as a pre-expiry disappearance.
A submitted expectation remains attached to its exact unresolved journal entry
until that attempt becomes terminal or its one decrement is explained; task
cleanup alone cannot discard it. Provider account identifiers are normalized at
every journal read, comparison, and write boundary, including legacy entries, so
case or surrounding whitespace cannot create a second redemption owner.
A `3 -> 1` transition, a different removed credit, a same-count replacement, or
an additional later decrement creates the persisted 15-minute external hold.
CodexSwitch must force a quota read newer than that observation and must not
consume another credit using the quota snapshot that preceded the change.

## Manual Redemption And Expiration Alerts

Each eligible account card exposes one reset icon button. It is enabled only
for a fresh blocked paid account with complete runtime credentials and a fresh
available reset. An available credit must have a normalized identifier and an
explicit future expiration; missing or expired expiration evidence makes the
inventory malformed and cannot authorize redemption. The confirmation names the
account, spends its oldest-expiring available credit, and explicitly states that
the configured account will not change. Redeeming, reconciling,
error, stale, and external-hold states replace the action until the durable
journal proves another submission is safe.

Manual intent is persisted with the reset attempt. While that attempt is
unresolved and after it reconciles, routine plan-upgrade logic must not switch
to the recovered account until a real usage failure or explicit operator
selection successfully activates it. That activation durably releases the
route-specific suppression. Usage-failure routing remains available throughout.
Live suppression state is keyed by the normalized provider account identity,
not the disposable local account UUID, so removing and re-adding an account
cannot bypass the hold. Starting or failing a later manual attempt cannot
downgrade an older durable hold, and reconciliation cannot restore a hold that
the journal already records as released. An activation release captures the
provider's live suppression revision before journal I/O and clears it only if
no newer manual operation changed that revision while the actor was suspended.
Journal restore applies independently per provider and is discarded when its
captured revision is stale, a release is in flight, or it would erase a local
pending intent that has not reached the journal yet.
The newest unreleased successful suppression per provider account is exempt
from ordinary terminal journal pruning, keeping restart behavior durable without
unbounded per-account history.

If the reset journal is unreadable during startup, automatic routing and manual
redemption remain blocked while the app retries bounded journal reads. No empty
in-memory default is allowed to stand in for unknown reset ownership.

Manual redemption does not reload a desktop or CLI runtime. Immediately before
transport, CodexSwitch requires an unchanged complete available-credit list and
count relative to the immutable decision baseline, a clear persisted
external-redemption hold, the same exact activation generation and phase,
matching durable configured files, the exclusive mutation lease, and an exact
readback of the complete submitted journal value. The resulting lease-only
transport permit expires after ten seconds. Only then does CodexSwitch publish
the attempt-bound one-credit local expectation. Immediately before the POST,
the Linux control plane also acquires a dedicated provider-I/O lease and
revalidates the exact activation-journal identity. Account and reset-journal
locks remain released for network I/O, but activation-journal mutation fails
closed until the POST returns and the lease is released.

The action model receives coordinator authorization as production state, not as
a second copy of reset policy. Unreadable hold storage, any active redemption,
missing configured or activation state, unresolved attempts, and active local or
external holds disable each affected button with the coordinator's reason before
confirmation.

The popover includes an unframed reset-expiration list ordered by exact expiry
and stable account identity. Credits enter advisory styling at seven days,
urgent orange pulsing at 72 hours, and critical red faster pulsing at 24 hours.
Reduce Motion disables pulsing without hiding urgency. System notifications
are deduplicated by provider account, expiration, and urgency band, allowing a
new alert only when the same credit crosses a more urgent boundary. The key is
persisted after successful enqueue, never before it. An in-flight claim blocks a
duplicate enqueue for the same key; failure releases the claim for a later retry.

## State And Synchronization

Each account persists a sanitized reset bank with the count, credit status,
expiration metadata, and fetch time. The Mac uses a five-minute background
freshness window and at-most-sixty-second decision evidence. Ranking
observations must never overwrite the durable "before" bank used to detect an
external redemption.

Timestamp freshness alone is insufficient. Cached inventory is current only
when its complete available-credit list still matches the count at the current
time, every available credit has a normalized identifier and future expiration,
and identifiers are unique. A naturally expired credit is inventory churn, not
an external redemption, and must not create the 15-minute external hold.

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

The Rust reset-attempt journal uses format 3. Each new local attempt preserves
the immutable selected credit, its exact expiration, and the complete sorted
set of normalized credit identifiers that were available at submission. A
missing selected credit proves consumption only when it is still unexpired,
the count changed by exactly one, and every other starting identifier remains.
An explicit terminal provider status for that selected identifier remains
valid evidence. Unresolved format-1 or format-2 attempts that lack the new
inventory proof migrate to manual review and can never authorize another POST.
Inventory time is captured after the response body completes. Credit IDs larger
than the journal evidence bound are rejected before attempt creation, and the
coordinator rechecks the saved journal for a manual-review sentinel plus the
exact request UUID before acquiring the provider-I/O lease.

## Verification Contract

Tests must cover inventory parsing, oldest-expiring selection, each policy
branch, pool-wide plan ordering, same-tier expiration and stable tie ordering,
active-account
capacity suppression, the 24-hour natural-reset guard and pool-exhaustion
override, count-only inventory suppression, zero-count and partial-count
contradictions, malformed responses,
uncertain-request reconciliation, and consume response codes. Pure policy tests
must prove that an inactive exhausted Pro ranks ahead of an active usable Plus,
while a near natural reset or another usable Pro prevents redemption.
Cross-host tests must prove that the daemon exposes no automatic redemption
option. Mac tests must prove that an external
inventory decrement survives restart and blocks a second redemption for 15
minutes, while newer usable quota evidence may clear the hold early.
Mac tests must also prove that manual redemption can use a lease-only durable
activation permit without a runtime reload, while automatic redemption still
requires confirmed runtime evidence, and that any available-credit inventory
change revokes the final submission permit. The orchestration boundary must use
the production mode contract to prove that manual mode requests no runtime
authorization, auth write, swap, or activation, while automatic mode requires
runtime authorization. Transition tests must cover preflight external rebasing,
the exact local `N -> N - 1` explanation, `3 -> 1`, wrong-credit removal, and an
additional later decrement. Journal tests must reject any non-exact submitted
attempt readback. Notification tests must prove enqueue success persistence,
failure and later retry, and duplicate in-flight suppression. UI tests must also cover
account-specific eligibility, confirmation routing,
urgency boundaries, layout-stable pulse values, Reduce Motion behavior, sorted
account attribution, error presentation, and notification deduplication.
Independent-process lock tests launch nested Swift Testing runs through
`swiftpm-testing-helper` when SwiftPM exposes an `.xctest` bundle as argument
zero; the bundle binary itself is not an executable process entrypoint.

Live verification is read-only: inventory GETs may confirm counts and expiry,
but tests and installation checks must not consume a real reset.

When the active Command Line Tools package does not include `TestingMacros`,
compile and run `scripts/test-banked-resets.swift` with the reset model and
service sources as the deterministic local replay. The harness resolves the
macOS temporary-directory alias before creating its journal so the secure
no-symlink storage contract is exercised against the canonical path. It passes
account-bound runtime and lease evidence through the production submission
permit, while an injected scripted transport keeps every request in-process;
the replay cannot make a network request or consume a real reset. The normal
Swift Testing suite remains the canonical CI path when full Xcode is available.

Run the deterministic replay from the repository root:

```bash
replay_root="$(mktemp -d /private/tmp/codexswitch-banked-reset-replay.XXXXXX)"
trap 'find "$replay_root" -depth -delete' EXIT
mkdir -p "$replay_root/module-cache" "$replay_root/tmp"
TMPDIR="$replay_root/tmp" \
CLANG_MODULE_CACHE_PATH="$replay_root/module-cache" \
swiftc -module-cache-path "$replay_root/module-cache" \
  -parse-as-library -o "$replay_root/test-banked-resets" \
  scripts/test-banked-resets.swift \
  Sources/CodexSwitch/Models/QuotaSnapshot.swift \
  Sources/CodexSwitch/Models/CodexAccount.swift \
  Sources/CodexSwitch/Models/RateLimitResetBank.swift \
  Sources/CodexSwitch/Services/UsageResponseParser.swift \
  Sources/CodexSwitch/Services/RateLimitResetService.swift \
  Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
"$replay_root/test-banked-resets"
```
