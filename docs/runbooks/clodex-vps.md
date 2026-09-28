---
title: Clodex VPS lane
description: Install, authenticate, launch, verify, and roll back the isolated Clodex backend used by claude-vps.
toc:
  - Clodex VPS Lane
  - Contract
  - Install And Readiness
  - Provider Setup
  - Launch And Resume
  - Verification
  - Rollback
cross_dependencies:
  - ../linux-cli-only.md
  - ../../scripts/claude-vps
  - ../../scripts/clodex-credential-helper.py
  - ../../scripts/clodex-ccs-runtime-helper.mjs
  - ../../scripts/patch-clodex-codexswitch.py
  - ../../scripts/configure-clodex-codexswitch.mjs
  - ../../scripts/install-clodex-vps.sh
  - ../../scripts/test_claude_vps.py
version_control:
  branch: main
  status: operator-runbook
  last_updated: 2026-07-26
---

# Clodex VPS Lane

## Contract

`claude-vps clodex` launches the pinned VPS-local
`@bman654/clodex` package through the existing CodexSwitch SSH and tmux
harness. It resumes the newest Claude Code session with the configured exact
title in `/home/signul/SIGNUL` when that session has no live owner. It uses a
separate
`claude-vps-clodex` tmux session and refuses concurrent resume against the
ordinary CCS-backed `claude-vps` lane or any unmanaged process.

Claude Code background workers launched with `--fork-session` write a real
session identity that can become the newest working thread. The fork remains
an eligible target; it must not be replaced with its older parent merely
because it is background-owned. While its background PTY is live, that process
is the sole writer and Clodex refuses takeover. A backend handoff requires an
explicit, identity-verified stop of that exact worker at a safe restart point,
followed by a fresh ownership check and exact-session resume.

The validated session identity is exported inside the tmux pane's initial
launch command. A cold tmux server cannot silently degrade the request from
`--resume <session-id>` to `--continue`; later tmux environment writes are
diagnostic state, not the launch authority.

Clodex and CCS have separate routing ownership inside one Claude Code process:

- ordinary `claude-vps` launches `/usr/bin/ccs claude` and uses the CCS
  Claude-account pool directly;
- `claude-vps clodex` launches
  `/home/signul/.local/bin/clodex claude --proxy`;
- Clodex aliases route through the CodexSwitch OpenAI credential helper;
- ordinary Claude/Fable models pass through the Clodex proxy to the same
  VPS-local CCS Claude-account pool.

Clodex state remains on the VPS. Its OpenAI provider reads the account that
CodexSwitch has committed as active; CodexSwitch remains the sole account
selection and OAuth refresh owner. Do not copy its provider registry,
CodexSwitch credentials, or Claude session data to the Mac.

The Anthropic branch does not copy a selected account token into Clodex.
`clodex-ccs-runtime-helper` resolves only CCS's internal loopback API key and
CLIProxy chooses the eligible Anthropic account under its current
order/affinity/cooldown policy.

## Install And Readiness

Install the pinned package as the unprivileged VPS user:

```bash
scripts/install-clodex-vps.sh --install
scripts/install-clodex-vps.sh --check
claude-vps clodex --check
```

The installer refuses an unexpected Node major version, package version,
global npm prefix, package preimage, patched postimage, or binary path. It
applies only the version-pinned Clodex ownership patch; it does not patch
the shared Claude Code binary, start Clodex, or restart CCS. After provider
models are known, it copies the current pristine Claude binary into the
Clodex-only runtime root and applies Clodex's model-name patch to that inactive
copy. The shared binary hash must remain unchanged.

Install the checked-in credential helper at its stable absolute path:

```bash
install -m 700 scripts/clodex-credential-helper.py \
  /home/signul/.local/bin/clodex-credential-helper
install -m 700 scripts/clodex-ccs-runtime-helper.mjs \
  /home/signul/.local/bin/clodex-ccs-runtime-helper
```

For the reserved OpenAI provider, the helper acquires CodexSwitch's
`accounts.json.lock`, validates the complete active account against
the stable account identity in `~/.codex/auth.json` and the terminal activation
record, then emits the current `auth.json` token generation through a
process-pipe-only credential. It refuses managed `set` and `delete` operations,
so no token copy is created beneath `~/.clodex` or the helper object store.
The helper's age-encrypted object store remains available only for unrelated
providers and disposable Clodex probes.

## Provider Setup

Configure the metadata-only provider reference:

```bash
scripts/install-clodex-vps.sh --configure-codexswitch
```

Do not run `clodex providers auth openai`; that would create a separate OAuth
refresh owner. The configurator refreshes the provider's accessible model
metadata and adds those models to the bounded Clodex favorites catalog while
preserving unrelated favorites. Stable `cs-<model-id>` aliases make the
managed routes first-class entries in the isolated Claude `/model` picker.
Verify only non-secret provider inventory and model metadata:

```bash
ssh signul-vps \
  'CLODEX_CREDENTIAL_HELPER=/home/signul/.local/bin/clodex-credential-helper \
   /home/signul/.local/bin/clodex providers list'
ssh signul-vps \
  'CLODEX_CREDENTIAL_HELPER=/home/signul/.local/bin/clodex-credential-helper \
   /home/signul/.local/bin/clodex models --list'
```

Use `clodex models` on the VPS to choose favorites and aliases. `clodex patch`
is optional and must not be run while any Claude Code process is live; it
modifies the installed Claude Code binary and therefore needs a separate idle
activation decision.

## Launch And Resume

```bash
claude-vps clodex
```

The default Clodex bridge mode is explicitly `--proxy`. Clodex launches Claude
Code and routes configured Clodex model names or aliases to OpenAI. Ordinary
Claude/Fable model names pass through to CCS on `127.0.0.1:8317`, so CCS—not
the native Claude login—selects the Anthropic account. Use `/model` inside
Claude Code to select a configured Clodex favorite or ordinary Claude model.

`CLODEX_VPS_PREFERRED_SESSION_TITLE` requires an exact normalized title. Its
default is `latest working thread -- readiness prep`, matching the ordinary
VPS lane. Set it explicitly to an empty string only to select the newest
session regardless of title. A matching background fork remains the target and
causes an ownership refusal until that exact writer has stopped.

The Clodex lane uses SSH by default so an ownership or readiness refusal is
visible before the terminal closes. `CLODEX_VPS_TRANSPORT=mosh` explicitly
opts back into mosh. A newly created Clodex pane starts with
`--dangerously-skip-permissions`; use `claude-vps clodex --safe` only when
normal permission prompts are intended. `CLODEX_VPS_TMUX_SESSION` overrides
the isolated tmux session name for diagnostics.

`CLODEX_VPS_ANTHROPIC_BACKEND=ccs` is the default and requires the exact
supported CCS installation plus a healthy loopback proxy. Use
`CLODEX_VPS_ANTHROPIC_BACKEND=native` only as an explicit rollback/diagnostic
choice; it disables CCS pooling for ordinary Claude/Fable requests. Changing
this setting requires exiting and recreating the Clodex pane. CCS proxy auth
may disable Claude Remote Control, but does not change terminal session
resume, fullscreen, or bypass-permissions behavior.

## Verification

Readiness requires all of the following:

```bash
claude-vps clodex --check
ssh signul-vps 'tmux list-sessions -F "#{session_name}"'
ssh signul-vps '/usr/bin/ccs cliproxy status --verbose'
```

- the wrapper reports the pinned Clodex version and correct repository;
- the installer reports the exact patched Clodex postimage and managed
  provider reference;
- the Clodex-only Claude binary is current for the 8 managed favorites and the
  shared CCS/native Claude binary is still byte-identical to its pre-install
  state;
- the bridge check proves the current CodexSwitch account/auth/activation
  barrier without printing token data;
- the CCS runtime-helper check proves the supported CCS version, loopback
  origin, proxy health, and internal gateway authentication without printing
  the gateway key;
- the Clodex lane is named `claude-vps-clodex`;
- CLIProxy remains running on its original PID;
- the ordinary `claude-vps` session was neither killed nor renamed;
- a live session is never resumed by two Claude Code processes.
- a synthetic ordinary Claude/Fable request is visible on the CCS provider
  path while a synthetic `cs-*` request remains visible on Clodex's translated
  path.

## Rollback

Exit the Clodex-backed Claude Code session normally, then:

```bash
ssh signul-vps 'tmux kill-session -t claude-vps-clodex'
scripts/install-clodex-vps.sh --unconfigure-codexswitch
scripts/install-clodex-vps.sh --uninstall
```

Rollback removes the metadata-only managed provider and the pinned global npm
package. It does not mutate or delete CodexSwitch accounts, OAuth tokens, CCS
state, unrelated `~/.clodex` providers, or Claude session history. Ordinary
`claude-vps` remains available throughout.
