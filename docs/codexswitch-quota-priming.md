---
toc:
  - CodexSwitch Quota Priming
  - Confirmation Contract
cross_dependencies:
  - Sources/CodexSwitch/Services/WeeklyPrimer.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Models/AccountManager.swift
  - Tests/CodexSwitchTests/WeeklyPrimerTests.swift
version_control:
  branch: main
  commit: pending
---

# CodexSwitch Quota Priming

## Confirmation Contract

The 5-hour primer must not treat an accepted Codex request as proof that the backend quota window started. Some accounts can return a successful primer response while `/backend-api/wham/usage` still reports a full, sliding 5-hour window. In that state the primer should record only an attempted prime, retry after a short cooldown, and avoid displaying the account as 5h-primed.

A 5-hour prime is confirmed only when quota polling shows the window no longer looks unstarted: either usage is visible or the reset time has moved meaningfully inside the 5-hour window. Weekly priming can still use reset-window tracking, but the same drifting-reset pattern should not create a tight priming loop.

Primer logs must preserve that distinction. `PRIME_REQUEST_ACCEPTED` means the minimal Codex request returned successfully; `five_hour_confirmed=true` is the signal that the local 5-hour primed marker can be persisted into account state.

The primer request model must track the current Codex account lane. As of this note, CodexSwitch uses `gpt-5.5`; falling back to the older `gpt-5.4` lane can return an accepted request without starting the 5-hour Codex quota timer. If a request is accepted but the follow-up `/wham/usage` snapshot still looks unstarted, the app must clear any account-level 5-hour primed marker and retry after the ineffective-prime cooldown. A quota snapshot fetched after a local 5-hour marker is enough to clear that marker when the backend window still looks unstarted; waiting ten minutes leaves known-bad state visible and blocks useful retry routing.

The "unstarted" check should mean essentially full, not merely early in the window. A running 5-hour timer may still show 99.5% remaining for the first few minutes, so CodexSwitch treats only reset times within 99.5% of the full window as unstarted.
