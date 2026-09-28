---
title: CCS Claude quota compatibility
description: Contract and operator procedure for preserving Anthropic scoped model quota windows across CCS package upgrades.
toc:
  - CCS Claude Quota Compatibility
  - Contract
  - Failure Mode
  - Install And Verify
  - Rollback
cross_dependencies:
  - ../../scripts/patch-ccs-claude-quota-scoped-limits.py
  - ../../scripts/test_patch_ccs_claude_quota_scoped_limits.py
  - ../architecture/quota-and-reset-policy.md
version_control:
  branch: main
  status: compatibility-runbook
  last_updated: 2026-07-25
---

# CCS Claude Quota Compatibility

## Contract

`ccs cliproxy quota --provider claude` must preserve every usage window that
Anthropic returns. The fixed session and all-model weekly windows remain core
account limits. Entries in Anthropic's self-describing `limits` array,
including model-scoped windows such as Fable, are additional observable
limits. They must not be discarded, synthesized from another window, or used
as a replacement for raw provider data.

Scoped entries are normalized as follows:

- `group=session` becomes the five-hour usage window.
- an unscoped `group=weekly` entry becomes the all-model weekly window.
- `scope.model.display_name` becomes a model-specific weekly window.
- `percent` is provider-reported usage; displayed remaining capacity is
  `100 - percent`, clamped to zero through one hundred.
- a missing reset timestamp remains absent rather than being invented.

## Failure Mode

CCS 8.8.1 reads legacy top-level fields such as `five_hour` and `seven_day`,
but ignores the newer `limits[]` array. Anthropic can therefore return a
valid Fable weekly limit while the CCS checker silently shows only the core
windows. Updating the CCS npm package can also replace a local compatibility
postimage.

The CodexSwitch patcher is pinned to an exact CCS version and exact source
anchor. It refuses unknown versions, partial postimages, and source drift.
Its tests use synthetic quota payloads and never read account tokens.

## Install And Verify

Run the versioned compatibility patch after installing or updating CCS:

```bash
sudo python3 scripts/patch-ccs-claude-quota-scoped-limits.py
sudo python3 scripts/patch-ccs-claude-quota-scoped-limits.py --check
ccs cliproxy quota --provider claude
```

The patch changes only the CCS quota normalizer loaded by new `ccs` command
invocations. It does not require restarting CLIProxy or an active Claude
session.

## Rollback

Rollback is explicit and refuses unless the installed file still matches the
CodexSwitch postimage:

```bash
sudo python3 scripts/patch-ccs-claude-quota-scoped-limits.py --restore
```

After rollback, `--check` must refuse because the scoped-limit postimage is no
longer installed. A later CCS release that handles `limits[]` natively should
replace this compatibility patch; update the pinned contract and tests rather
than weakening the version guard.
