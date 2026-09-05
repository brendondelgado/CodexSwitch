---
title: Quota and reset policy
description: Canonical interpretation, selection, and banked-reset policy for optional usage windows.
toc:
  - Quota And Reset Policy
  - Purpose
  - Quota Model
  - Contradictory Provider Evidence
  - Weekly-only Operation
  - Account Usability
  - Background Polling
  - Candidate Ranking
  - Banked Reset Policy
  - Durable Redemption
  - Manual Redemption
  - Reset Expiration Urgency
  - Presentation Rules
  - Policy Examples
  - Shared Test Contract
cross_dependencies:
  - system-overview.md
  - runtime-and-host-ownership.md
  - ../../Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - ../../Sources/CodexSwitch/Models/CodexAccount.swift
  - ../../Sources/CodexSwitch/Services/UsageResponseParser.swift
  - ../../Sources/CodexSwitch/Services/SwapEngine.swift
  - ../../Sources/CodexSwitch/Services/RateLimitResetService.swift
  - ../../Sources/CodexSwitch/Services/AccountPersistenceCoordinator.swift
  - ../../Sources/CodexSwitch/Services/AccountPersistenceSubmissionQueue.swift
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
  - ../../crates/codexswitch-cli/src/quota.rs
  - ../../crates/codexswitch-cli/src/account_store.rs
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/rate_limit_resets.rs
  - ../codexswitch-banked-resets.md
  - ../codexswitch-quota-priming.md
version_control:
  branch: main
  commit: pending
  status: canonical
  last_updated: 2026-09-04
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

## Contradictory Provider Evidence

Quota eligibility is fail-closed and negative evidence has precedence. Provider
fields are independent observations, not overrides for one another:

- `allowed == false` or `limitReached == true` blocks the snapshot.
- Any recognized policy window with `hardLimitReached == true` blocks the
  snapshot, even when `allowed == true` or `limitReached == false`.
- Any recognized policy window with `usedPercent >= 100` has definitive zero
  capacity and blocks the snapshot, even when `allowed == true`,
  `limitReached == false`, or `hardLimitReached == false`.
- A stale or future-dated snapshot is ineligible regardless of its last-known
  allowance or remaining percentage.
- A recognized window with a non-finite or negative usage percentage is
  malformed and cannot authorize activation. It remains diagnostic evidence;
  malformed data is not rewritten as provider-confirmed exhaustion.
- A window whose reset boundary has passed is no longer evidence about the
  current quota cycle and cannot authorize activation until it is refreshed.
- A snapshot without a recognized five-hour or weekly window is ineligible for
  activation. `allowed == true` alone does not manufacture measurable capacity;
  unknown windows remain diagnostic-only.

Contradictory observations are preserved for diagnostics, but they are never
resolved in the optimistic direction. Every selection surface must consume the
same derived eligibility result rather than rereading raw provider booleans.

Each non-blocked account has one generation-owned poll task. Replacing a poll
cancels the old generation, and callbacks from a cancelled or superseded
generation are discarded before they reach account state. The Mac coordinator
periodically reconciles the expected account set with the poller's live task
set, restarts missing tasks, and stops tasks for removed or hard-blocked
accounts. A token-expired response may request credential refresh, but failure
or deferral of that refresh must not leave the account permanently unpolled.
Provider failures remain degraded polling state and do not trigger process
restart loops.

## Weekly-only Operation

The service may temporarily omit the five-hour window for paid accounts. In that state:

- Weekly data is sufficient for a valid quota snapshot.
- Five-hour remaining and reset values are `nil` or absent.
- The account is not exhausted merely because five-hour data is absent.
- Polling, candidate selection, menu labels, priming, and reset logic use the weekly window normally.
- The UI hides the five-hour meter rather than displaying zero, 100 percent, unknown-as-full, or a placeholder countdown.
- Legacy two-window cache files may be read, but new state is written using the optional-window schema.

If no recognized quota window is present, the account state is unknown and not
available for activation, even when a global allowance signal is positive.

## Account Usability

An account is immediately usable only when all are true:

1. Its token material is complete and not known to require reauthentication.
2. Its quota snapshot is fresh enough for activation policy.
3. The provider has not explicitly denied usage.
4. Every present blocking window is above the active exhaustion threshold.
5. No unresolved reset or activation operation owns the account.

The quota portion of this decision additionally requires at least one
recognized policy window and no contradictory definitive exhaustion evidence.
For weekly-only operation, one fresh weekly window with remaining capacity
satisfies that requirement; a five-hour window is not required.

Unknown and stale accounts are observable but cannot outrank confirmed usable accounts.

Free-plan accounts are stored and remain visible, but they are not automatic
capacity. An account whose normalized provider plan is Free, Free Workspace,
Guest, or another Free/Guest plan variant is ineligible for automatic rotation,
automatic plan-upgrade selection, automatic pool fallback, and ready-candidate
counts even when its quota is fresh and usable. A Free account therefore cannot
keep readiness green for a blocked active account and cannot become the daemon's
automatic authority target. This exclusion does not delete or rewrite its
credentials and does not broaden or narrow the existing explicit operator
selection contract.

The switching and reset paths share the same candidate eligibility and
deterministic ranking implementation. When a VPS is configured, the VPS daemon
is the sole policy and desired-target authority. Mac manual actions, automatic
quota reactions, and injected runtime limit signals submit idempotent requests
to that authority over the SSH CLI path; they do not rank and activate a local
replacement first. Semantic entry points may narrow the common candidate set,
for example to higher plan tiers, but must not reimplement freshness, usability,
or ordering.

Reset conservation evaluates every immediately usable account, including the
authority-selected target. Switching may exclude that target because it cannot
be its own destination, but that exclusion must not hide usable capacity when
deciding whether another account may spend a reset.

## Background Polling

The authority-selected account is always the first quota observation on a
healthy VPS daemon tick. Background maintenance must not delay that safety check
by polling every stale inactive account serially. A Mac quota observer may
refresh presentation data and submit evidence to the authority, but observation
alone cannot select or activate a target and must not cause polling or inference
side effects on authority reads.

When the authority-selected account remains usable and no cached plan upgrade requires a
rotation, a tick may probe at most one due inactive account. Selection is
deterministic and fair across successive polling buckets, and a failed probe
does not advance that account's quota freshness. A required rotation is
different: before ranking a destination, CodexSwitch refreshes every candidate
whose current observation cannot safely authorize selection.

Quota success does not prove inference readiness. Every active-readiness,
failover, plan-upgrade, reset-conservation, and diagnostic candidate check must
also parse the account's inference access-token JWT and require an `exp` value
strictly beyond the shared five-minute safety window. Missing, malformed,
expired, or near-expiry inference-token evidence is fail-closed even when quota
is fresh and green. A failed quota probe never preserves candidate eligibility
from an older snapshot.

Before quota provider I/O, an account without a usable inference JWT receives
exactly one proactive credential refresh. CodexSwitch validates the replacement
against the same safety window before issuing the quota request. Merely entering
the safety window, or a refresh that returns no usable replacement, does not
create the durable 30-day `token_expired` quarantine; that quarantine requires
provider authentication evidence such as an HTTP 401. A current durable
`token_expired` block still suppresses repeated refresh attempts until its
credential generation changes.

A current non-quota runtime block is negative evidence. In particular, an
account blocked as `token_expired` is not polled or refreshed again until the
block expires or an imported credential generation replaces that account
record. This prevents a daemon tick from retrying the same rejected refresh
token across active and inactive candidates.

## Candidate Ranking

The policy optimizes for fast inference first, usable capacity second, and churn avoidance third.
The VPS daemon evaluates this policy inside one serialized authority transaction.
It commits at most one new desired provider identifier and monotonically
increasing epoch for a request ID; host convergence happens after that durable
decision. A retry with the same request ID returns the original result.

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

Never switch to a candidate already inside the same exhaustion threshold that
triggered the swap. Denied, zero-capacity, stale, failed-poll, token-expired, and
near-expiry candidates are ineligible regardless of plan tier or prior cached
quota. Free-plan candidates are also unconditionally ineligible for automatic
selection: fresh green quota does not make them a last-resort automatic target.

## Banked Reset Policy

A reset is scarce capacity, not an automatic response to every limit.

Before redemption:

1. Confirm the account is genuinely blocked by quota, not stale auth or transport failure.
2. Confirm an unused reset exists in a fresh inventory generation.
3. Confirm there is no unresolved attempt for the same stable provider account.
4. Evaluate usable Pro accounts, then usable Plus accounts, including the authority-selected target.
5. Evaluate time until natural recovery.

A reset is suppressed when the account's natural recovery is within 24 hours
during routine polling, even when the pool is otherwise exhausted or the credit
expires soon. Only a direct runtime usage-limit event or an explicit operator
redemption request may assert that work requires capacity now and override this
guard. The decision and exception reason must be recorded.

This avoids spending a reset shortly before a natural reset that will happen independently and would make the banked reset wasteful.

A stale positive snapshot cannot authorize selection or activation. A stale denied, exhausted, or otherwise blocked snapshot also cannot authorize reset spending, including when a runtime usage-limit signal exists. The coordinator requests a fresh quota observation or leaves the operation in manual-wait state.

## Durable Redemption

Reset ownership is a persisted authority mode independent of endpoint validity:
`standaloneMac` or `vpsAuthority`. A valid remote endpoint migrates and persists
`vpsAuthority`. Missing, unknown, or malformed authority state also resolves to
`vpsAuthority`; it never grants the Mac permission to spend a reset. Once VPS
ownership is recorded, later host, user, port, or key-path corruption leaves
ownership on the VPS and makes both manual and automatic Mac reset actions fail
closed. `standaloneMac` is available only through an explicit stored authority
selection while no valid remote endpoint exists. Adding a valid endpoint
forces the mode back to `vpsAuthority`, preventing concurrent reset owners.

When VPS authority is selected, its daemon is the sole automatic redemption owner as
part of the same serialized policy domain that owns rotation. Mac automatic
policy and manual controls submit requests through the SSH CLI transport and
adopt the returned authority observation. If the configured VPS is unavailable,
the Mac fails closed without redeeming, selecting, or activating another
account. A deliberately unconfigured standalone Mac may use the same journaled
domain locally, but it cannot run concurrently as a second owner of a configured
VPS pool.

The production VPS daemon reads automatic-redemption permission on every tick
from the secure authority-owned sibling file `daemon-policy.json` next to the
account store. Missing, malformed, unsupported-version, oversized, insecure, or
unreadable policy state disables automatic redemption while leaving quota
observation and ordinary rotation available. Writes use the shared secure-file
lock, generation compare-and-swap, atomic rename, directory sync, and exact-byte
readback. The daemon never substitutes a compiled default of enabled, and a
Mac-local preference is not authority for the VPS process.

`codexswitch-cli automatic-reset-policy get --json` observes that authority
without mutation. `codexswitch-cli automatic-reset-policy set enabled --json`
and `... set disabled --json` atomically replace the authority policy. JSON uses
schema version 1 and returns `automaticRateLimitResetRedemption`, `state`
(`configured`, `missing`, or `invalid`), and `authority` (`vps`). A missing or
invalid observation always reports an effective value of `false`; filesystem
security or I/O failures return a nonzero command result rather than pretending
the preference changed.

The `automatic-reset-policy` command is available only on the Linux VPS. A
macOS invocation fails before reading or writing `daemon-policy.json`; Mac UI
and automation must invoke the command through the bounded VPS transport and
must never present a Mac-local policy file as VPS authority.

When VPS authority is selected, the Mac Settings toggle renders only
this VPS observation; its standalone `UserDefaults` preference is neither shown
as VPS truth nor submitted to the daemon. If its transport endpoint is missing
or invalid, the toggle is disabled and no local fallback is offered. Reads and writes use bounded SSH
output and validated schema-version-1 JSON. A toggle write uses the mutating SSH
envelope and may try another transport only when the prior local process
provably never started. A started timeout, missing completion marker, truncated
response, or unverified response is outcome-unknown and is never replayed
automatically. A successful write is followed by a separate read-only `get`
reconciliation before the UI reports the current VPS value. Until a valid VPS
observation exists, the remote toggle displays disabled and rejects mutation.
An unconfigured standalone Mac continues to use its local preference.

`codexswitch-cli redeem-reset <account>` is the manual entrypoint. On a
configured Mac it submits one idempotent request to the VPS daemon; on the VPS
it enters the daemon's local serialized policy transaction. It accepts one
exact account selector, requires a paid account with complete runtime
credentials, a normalized stable provider identity, a fresh blocked quota
observation, and a fresh available credit with an explicit future expiration,
and never changes the authority target or auth file. Each invocation uses the canonical account-store reset journal,
submits at most one credit, reconciles a newer inventory and quota observation,
and commits the refreshed target account before reporting success. A usable
account, a free account, an unknown or stale quota, or an unresolved prior
attempt fails closed without sending a consume request. The command may still
reconcile an existing journaled attempt after quota becomes usable; that replay
is observation-only and cannot submit another credit.

The Mac manual-control transport invokes `codexswitch-cli redeem-reset
<provider-account-id> --json` through the bounded mutating SSH envelope. It
normalizes and shell-quotes one exact stable provider account ID before launch,
accepts only a bounded non-secret response whose account ID matches that target,
and may try another SSH transport candidate only when the local runner proves
the prior candidate never started. A timeout, missing completion marker,
connection loss, or any other failure after launch is outcome-unknown and is
never replayed automatically. The caller must reconcile durable VPS reset and
quota state before offering another manual submission.

Reset-inventory provider backoff is scoped to the exact normalized account and
credential generation. Every inventory call, including final orchestration for
an inactive candidate, checks that account's backoff immediately before I/O.
An authentication block on the active account cannot suppress evaluation of a
different eligible account, and an inactive account's own block cannot be
bypassed by a cached inventory observation.

Reset redemption is a journaled state machine:

```text
prepared -> submitted -> reconciling -> confirmed-pending-persistence -> confirmed
                              |                         |
                              +--> uncertain            +--> failed-safe/manual-review
```

Before the POST, persist and read back account identity, reset credit identity, request UUID, starting inventory, starting quota, owner, and timestamp. Persist and read back every transition to `submitted` before sending the POST and every transition to `reconciling` before returning an uncertain result. Journal mutations use the shared descriptor-anchored, cross-process locked, generation-checked secure-file transaction; only a proven committed generation becomes in-memory authoritative state. A timeout, process crash, HTTP 5xx, malformed body, delayed inventory update, or persistence failure leaves the prior proven state authoritative and never authorizes an immediate second POST.

The initially authorized bank remains the immutable decision baseline through
preflight and final authorization. Every newer inventory observation passes
through one transition classifier before it can become authoritative. A quota
GET followed by a changed inventory cannot silently rebase the decision or
authorize the next credit against the older quota observation.

The final in-process authorization re-fetches quota and inventory and requires
the complete available-credit list and count to match the prepared attempt. It
also revalidates the exact authority epoch and desired provider identifier,
activation generation and phase, mutation lease,
durable configured files, external-redemption hold, and the complete submitted
journal value. The journal readback must exactly equal the expected submitted
attempt, including account, credit, starting count, bank and quota timestamps,
creation and submission times, state, and response code. A submission permit is
valid for at most ten seconds and is single-use. The local-submission expectation
is recorded only after that authorization succeeds and immediately before
transport begins. It is bound to the attempt UUID, credit UUID, provider account,
and starting count, and can explain exactly one decrement of exactly that credit.
Any larger decrement, different removed credit, replacement at the same count,
or later additional decrement is external activity and creates the persisted
15-minute hold.

Success requires fresh evidence that:

- the selected reset inventory decreased or the selected credit became consumed, and
- the account quota became usable in a newer observation.

Fresh bank and quota evidence enters `confirmed-pending-persistence`. The
refreshed account state must be durably committed and read back before the
journal can become terminal `confirmed`; a crash or persistence failure keeps
redemption suppressed.

Reconciliation uses the normalized stable provider account identity at every
journal read, comparison, and write boundary, including legacy records, so a
changed local UUID, case, or surrounding whitespace cannot bypass
duplicate-spend protection.

Provider reconciliation failures are independently backoff-driven. An unresolved
attempt persists its consecutive provider-failure count, last reconciliation
time, and next eligible retry time. Ordinary daemon quota polling and account
rotation continue while that deadline is active; they must not re-enter failed
reset inventory or quota I/O on every daemon tick. Inventory or quota provider
failures back off exponentially from five minutes to a one-hour ceiling. A
successful provider observation clears that backoff even when the available
evidence has not reconciled the attempt yet, so a later fresh inventory or quota
generation can complete the observation-only replay without another POST. A
credit-specific external-inventory
observation becomes terminal audit history after that credit's recorded
expiration, because it can no longer authorize or conflict with a future
redemption. The terminal transition performs no provider request.

## Manual Redemption

The menu app exposes the same one-account manual operation on each eligible
account. With a configured VPS, the action is a remote request rather than a
local effect; authority unavailability disables it with an explicit reason.
The action names the account, confirms before submission, and consumes only
that account's oldest-expiring available credit. It requires a fresh paid
account inventory whose available credits all have normalized identifiers and
explicit future expirations, complete runtime credentials, a fresh quota
observation proving that the account is blocked, no unresolved attempt for the
normalized stable provider account, and exclusive ownership of the
account-mutation lease. Manual intent may override capacity
conservation and the 24-hour natural-recovery guard, but it cannot override
freshness, paid-account eligibility, duplicate-spend protection, or journal safety.
The journal records manual intent. Routine higher-tier promotion excludes that
account while the attempt is unresolved and after successful reconciliation
until failure-driven rotation or explicit operator selection successfully
activates the recovered account. That activation durably releases the
route-specific suppression. An unreadable reset journal blocks both automatic
routing and manual reset submission until a later bounded read restores the
unresolved-attempt and suppression state.
The live suppression index uses normalized provider identity rather than the
local account UUID. Account removal and re-addition therefore preserve the
route hold, a later pending attempt cannot replace an existing durable hold,
and a successfully released pending attempt cannot be re-suppressed when its
reconciliation completes. A release may clear live state only when the
provider-specific suppression revision still matches the value captured before
journal I/O, preventing an older activation from erasing a newer redemption.
Restore uses the same provider revision and skips in-flight releases and
pre-journal pending intent, so a stale journal read cannot reinstate a released
hold or erase a newer one.
An unreleased successful manual-suppression record is retained independently of
ordinary terminal-history age and count pruning; at most the newest unreleased
record per provider account is protected.

The selected credit's disappearance proves a local decrement only while its
recorded expiration remains in the future at the refreshed observation. If the
credit could have expired naturally, count decrease plus absence is inventory
churn and cannot finalize the attempt without explicit consumed evidence.
Inventory `fetchedAt` is the response-completion time, never the request-start
time, so a credit expiring while the GET is in flight cannot appear unexpired.

A manual redemption never changes the authority target or configured account,
writes `auth.json`, initiates a swap, or reloads a local runtime. It may proceed from an exact
`confirmed` or `committed_degraded` activation journal when the durable
configured files and exclusive mutation lease still match. The UI remains in
redeeming or reconciling state until a
newer inventory and quota observation prove the result. An uncertain result is
shown as unresolved and cannot enable a second submission.

The menu owns one account-identified confirmation session above the reusable
account-card views. Opening the inline command or context-menu command replaces
that session with the selected stable provider account and presents the same
confirmation action. Cancel, dismissal, a local authorization rejection, a
transport failure proven not to have started, and a terminal authority response
all clear the local session so the command can be opened again immediately.
Only an authority response that is genuinely outcome-unknown or reconciling may
keep a second submission disabled. Rebuilding, reordering, or dismissing the
menu popover must never leave a hidden card-local presentation flag latched.
The VPS command reports terminal rejection and outcome-unknown as distinct,
bounded, non-secret machine-readable results bound to the account and request
UUID. A confirmed response releases the local operation. An unknown outcome
requires the matching request's terminal journal state from the VPS authority;
bank timestamps alone never release it. The normal bounded account mirror
includes read-only journal metadata, without provider requests or a full health
scan. Missing, unreadable, mismatched, or unresolved journal evidence stays
blocked. Reopening the Mac app also restores unresolved remote-account holds
from that journal observation.

## Reset Expiration Urgency

Available credits are ordered by expiration and attributed to their account in
the menu. Urgency uses one injected `now` and the oldest available credit:

- more than seven days: normal inventory styling;
- seven days or less: advisory styling and one deduplicated notification;
- 72 hours or less: urgent orange styling with a slow pulse;
- 24 hours or less: critical red styling with a faster pulse.

The pulse changes opacity without changing layout and is disabled when Reduce
Motion is enabled. Notifications are deduplicated by stable provider account,
credit expiration, and urgency band, so regular polling cannot repeat the same
alert while escalation to a more urgent band remains visible. A dedupe key is
persisted only after the system accepts the notification. One in-flight key
suppresses concurrent duplicates; enqueue failure clears that transient claim
so a later poll retries.

A cached bank is fresh only when it is both within the time bound and
structurally valid at the current observation time. Natural expiration removes
capacity without implying another client redeemed a credit, so it updates the
inventory and urgency presentation without creating an external-redemption
hold.

The provider credit list, not `total_earned_count`, is the redemption safety
authority. A valid inventory has a nonnegative `available_count` equal to the
complete set of provider-marked available credits, with unique nonempty
identifiers and explicit future expirations. `total_earned_count` is optional
historical telemetry and may be zero while available credits exist; it never
invalidates an otherwise exact inventory and never authorizes redemption.
Swift and Rust treat this field independently of available capacity while
preserving the exact credit-list and count checks.

The five-minute background freshness bound controls cache reuse and refresh
scheduling only. UI labels such as `current` and `verified`, account-card reset
counts, and expiration urgency use the same at-most-sixty-second evidence bound
as manual redemption. Once that bound passes, the UI renders the count as
last-known/unverified, disables redemption, and suppresses actionable expiration
urgency until a fresh observation arrives.

Unknown, stale, expired, and refresh-failed reset inventory is neutral
non-actionable metadata, not an account-health failure. It must not paint an
account card red or reuse a last-known count as current capacity. Red and
pulsing reset styling is reserved for a fresh available credit whose verified
expiration is inside the critical urgency interval. Redemption and
reconciliation in progress may use their distinct operational colors.

## Presentation Rules

- Normalize provider account identifiers through the canonical account identity
  normalizer before excluding the authority target from reset fallback lists.
  Presentation code must not compare a normalized stored identifier with raw
  authority telemetry.
- Render only observed windows.
- Render an observation older than the runtime freshness contract as
  `quota=stale`; never print its cached percentages as current capacity.
- Label weekly-only operation through the meter itself; do not show an alarming missing-five-hour error.
- Present exactly one authority-selected pool target, plus separate Mac and VPS
  convergence details for that target. Never style two accounts as current.
- Separate remaining quota from reset inventory.
- Keep durable reset readability separate from redemption authorization. Every
  paid account with a stored bank shows its last-known count and observation
  age even after the sixty-second authorization window closes. It must be
  labeled `last known` or `unverified`, excluded from verified pooled capacity,
  and rendered without actionable expiration urgency.
- When any available credit in a stored snapshot expires, retain the snapshot's
  last-known count visibly, including known zero. Label it `Last known` with
  `snapshot expired; refresh required`; partial expiry must not become `No current
  banked resets` or a locally recomputed available count. This snapshot remains
  unverified, excluded from verified capacity and expiration urgency, and unable
  to authorize redemption until refreshed. Availability gates are unchanged.
- A successful inventory observation queues the complete bank, including its
  response-completion timestamp, for bounded coalesced persistence even when
  count and credit membership are unchanged. Semantic equality may suppress
  expensive UI work and notifications, but it must not make the durable
  observation generation lag indefinitely.
- Persist each paid account's newest structurally valid inventory under its
  normalized stable provider identity. Account object replacement, list
  reordering, authentication refresh, or a transient provider/transport failure
  must not erase that last-known bank. A failed refresh records its error and
  observation time separately; it never rewrites the saved count to zero.
  Display zero only after a newer structurally valid provider observation
  explicitly reports zero available credits. The failure message and observation
  time live in provider-keyed local diagnostic state; they are not shared
  capacity and may be cleared on process restart. Startup and cross-host merges
  retain the newest valid bank by provider identity while normal freshness rules
  keep stale data non-actionable.
- Coalesced telemetry and durable credential writes use the same merge rule. A
  durable save must absorb a newer valid bank already queued in memory before it
  supersedes that queue. Main-actor submissions are ordered before allocating
  revisions for durable writes, adoption, deletion, and shutdown. An inactive
  account's credential write flushes queued inventories for the other accounts
  before committing. Accepted remote inventories enter the same persistence
  queue. Reset holds use only normalized provider identities on
  disk and in memory, including migration of previously noncanonical keys.
- Associate a refresh failure with the credential generation that made the
  request. If reauthentication changes that generation while the request is in
  flight, discard the old failure and immediately refresh with the new
  credentials. A later valid bank observation supersedes an older failure
  diagnostic instead of leaving the account red or stale indefinitely.
  A missing current fingerprint is not proof of a new credential generation and
  never authorizes an immediate retry loop. A local authorization rejection with
  a readable, resolved journal clears the operation without an authentication
  failure or redemption cooldown; uncertain or unreadable journals stay blocked.
- Attribute the next reset expiration to its account and sort expiration
  notices by urgency, then exact expiration.
- Provide an account-specific redemption control only when current evidence
  and coordinator state can authorize one reset. Unreadable ownership state,
  any active redemption, missing configured or activation state, unresolved
  attempts, and active local or external holds keep unavailable actions disabled
  with an explicit
  reason.
- Each paid account card exposes a labeled `Redeem` command and the same command
  in its context menu. When inventory is stale, unknown, expired, or failed, a
  labeled `Refresh` command replaces the unavailable one; refresh is
  observation-only and never implies redemption. A refreshed eligible account
  still requires explicit confirmation before one credit is submitted.
- A missing redemption handler is an unavailable action, not an enabled menu
  item that silently does nothing.
- Mac-only upgrades keep remote redemption disabled until a fresh account
  mirror proves that the VPS supports request-correlated reset journals. A
  missing or unsupported protocol version displays an explicit VPS-update reason
  before confirmation or submission. It does not create an uncertain attempt,
  discard inventory, fall back to a local redemption, or restart the VPS.
  A later compatible, unblocked observation re-enables the normal eligibility
  checks without restarting the Mac app. Duplicate identities, stale mirrors,
  and observed unresolved journals remain blocked. Protocol support is distinct
  from per-account attempt history: an account with no recorded attempts may
  reach the VPS command's existing journal initialization and preflight checks.
- Show reset attempt states such as pending reconciliation rather than guessing success.
- Show stale or unknown observations as stale or unknown, never as zero or full.
- When the provider reports global exhaustion and still supplies quota windows,
  show the exhausted state and every observed natural-reset timestamp/countdown.
  A denial label must not discard usable recovery metadata.
- Do not let a cached UI percentage override fresher runtime/API evidence.
- Before rotating because of an apparent limit, poll the authority-selected account when
  possible and persist the observation with its fetch time, then submit the
  evidence in an idempotent authority request. A fresh provider
  denial or typed runtime limit overrides an older cached 100-percent value;
  the stale value must not keep an exhausted account selected. The Mac does not
  activate the candidate before receiving the authority epoch.
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
- idempotent request replay and monotonically increasing authority epochs;
- authority unavailable on a configured Mac, with no local selection effect;
- one desired target with independent Mac and VPS convergence outcomes;
- UI absence versus zero semantics.
