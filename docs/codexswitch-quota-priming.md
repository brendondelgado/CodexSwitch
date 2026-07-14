---
toc:
  - CodexSwitch Quota Priming
  - Current Capability State
  - Confirmation Contract
  - Countdown Presentation Contract
cross_dependencies:
  - docs/architecture/quota-and-reset-policy.md
  - Sources/CodexSwitch/Services/WeeklyPrimer.swift
  - Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Models/AccountManager.swift
  - Tests/CodexSwitchTests/QuotaModelTests.swift
  - Tests/CodexSwitchTests/AccountManagerSyncTests.swift
  - Tests/CodexSwitchTests/WeeklyPrimerTests.swift
version_control:
  branch: main
  commit: pending
---

# CodexSwitch Quota Priming

## Current Capability State

Quota priming is capability-driven, not a permanent product requirement. While
paid accounts expose only weekly usage, CodexSwitch must not send primer
requests, synthesize five-hour state, retain stale five-hour markers, or show a
five-hour countdown. Weekly quota observation continues normally.

If the provider restores a five-hour window, priming can run only for accounts
whose fresh quota response actually exposes that window. The implementation
must not hardcode a model name to force a window to appear; it uses a currently
supported Codex request lane and verifies the result through quota observation.

## Confirmation Contract

The 5-hour primer must not treat an accepted Codex request as proof that the backend quota window started. Some accounts can return a successful primer response while `/backend-api/wham/usage` still reports a full, sliding 5-hour window. In that state the primer should record only an attempted prime, retry after a short cooldown, and avoid displaying the account as 5h-primed.

A 5-hour prime is confirmed only when quota polling shows the window no longer looks unstarted: either usage is visible or the reset time has moved meaningfully inside the 5-hour window. Weekly priming can still use reset-window tracking, but the same drifting-reset pattern should not create a tight priming loop.

Primer logs must preserve that distinction. `PRIME_REQUEST_ACCEPTED` means the minimal Codex request returned successfully; `five_hour_confirmed=true` is the signal that the local 5-hour primed marker can be persisted into account state.

The primer request model must track a currently supported Codex account lane. If a request is accepted but the follow-up `/wham/usage` snapshot still looks unstarted, the app must clear any account-level five-hour primed marker and retry after the ineffective-prime cooldown. A quota snapshot fetched after a local five-hour marker is enough to clear that marker when the backend window still looks unstarted; waiting ten minutes leaves known-bad state visible and blocks useful retry routing.

The "unstarted" check should mean essentially full, not merely early in the window. A running 5-hour timer may still show 99.5% remaining for the first few minutes, so CodexSwitch treats only reset times within 99.5% of the full window as unstarted. Tiny visible usage does not prove the timer is anchored: a window showing 99% remaining with the reset still effectively 5 hours away must be treated as unstarted, clear stale local markers, and retry priming after the ineffective-prime cooldown.

## Countdown Presentation Contract

The account card's parenthetical reset countdown is a live wall-clock value,
not the interval captured when the quota snapshot arrived. It must refresh at
least once per minute while the popover is open. The backend `resetsAt` date is
authoritative; a card that continues to display `4h 59m` while its absolute
reset time is approaching is a presentation failure, not evidence that the
primer request failed.

Quota updates can arrive for several accounts at nearly the same time. The app
must coalesce those callbacks into one priming pass so stale snapshots cannot
queue repeated requests or repeated `PRIME_OBSERVED_STARTED` state writes. If
another update arrives during that pass, one trailing pass must evaluate the
freshest snapshots so no account is skipped. A window already confirmed as
running remains observed until its backend reset returns it to the unstarted
state.
