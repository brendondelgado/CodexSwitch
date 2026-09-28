---
title: Clodex CodexSwitch credential bridge
description: Ownership, consistency, and persistence contract for using the active CodexSwitch account from the VPS-local Clodex lane.
toc:
  - Clodex CodexSwitch Credential Bridge
  - Authority And Scope
  - Read Barrier
  - Clodex Runtime Contract
  - CCS Anthropic Passthrough
  - Persistence And Secrets
  - Installation And Rollback
cross_dependencies:
  - credential-bundle-format.md
  - runtime-and-host-ownership.md
  - ../runbooks/clodex-vps.md
  - ../../scripts/clodex-credential-helper.py
  - ../../scripts/clodex-ccs-runtime-helper.mjs
  - ../../scripts/patch-clodex-codexswitch.py
  - ../../scripts/configure-clodex-codexswitch.mjs
version_control:
  branch: main
  status: architecture-contract
  last_updated: 2026-07-26
---

# Clodex CodexSwitch Credential Bridge

## Authority And Scope

The VPS-local Clodex lane may use the Codex account that CodexSwitch has
already committed as active. CodexSwitch remains the sole owner of account
selection, OAuth refresh, token replacement, and rollback. Clodex is a
read-through consumer and must never refresh, replace, delete, or durably copy
that managed credential.

This bridge covers both routing branches used by `claude-vps clodex`:

- Clodex model aliases such as `cs-gpt-5.6-sol` resolve the current
  CodexSwitch-managed OpenAI credential through the read barrier below.
- Ordinary Claude/Fable model names pass through the Clodex selective proxy to
  the already-running VPS-local CCS CLIProxy. CCS remains the sole owner of
  Claude-account selection, round-robin/fill-first policy, affinity, retry,
  cooldown, and Anthropic OAuth tokens.

Plain `claude-vps` continues to use CCS directly. The Clodex lane composes the
two routers by model class; it must not let ordinary Anthropic requests bypass
CCS and bind themselves to whichever native Claude account happens to be
logged in.

## Read Barrier

Every managed credential resolution acquires the same cross-process
`accounts.json.lock` used by CodexSwitch activation. While holding that lock,
the bridge securely opens and validates:

- `~/.codexswitch/accounts.json`;
- `~/.codexswitch/accounts.activation.json`;
- `~/.codex/auth.json`.

The read succeeds only when all of these facts are proven:

- files and traversed directories are owned by the current VPS user, have
  private modes, and are not symlinks;
- the account-store schema is understood and has exactly one active account;
- the active account contains the complete access, refresh, ID, and account
  token set;
- the auth file is ChatGPT mode, contains a complete current token generation,
  and its stable account identity exactly matches the active account;
- the activation record uses the supported version and is in a terminal,
  non-ambiguous state;
- the activation record target identity matches the active account (the
  account-store byte generation may advance later for quota telemetry while
  the active token identity remains unchanged);
- the access-token JWT has a valid future expiration.

Prepared, manual-review, missing, unknown-version, incomplete, mismatched,
expired, path-replaced, or ambiguous state fails closed. No prior token is used
as a fallback.

Codex may refresh `auth.json` after activation, so its access, refresh, and ID
tokens can legitimately be newer than the account-store snapshot. The store
and terminal activation record select the stable account identity; `auth.json`
is authoritative for that selected account's current token generation.

## Clodex Runtime Contract

The Clodex provider credential contains a non-secret
`credentialOwner=codexswitch` marker. The pinned Clodex runtime recognizes that
marker and:

- bypasses its OAuth credential cache so each model request observes the
  currently committed CodexSwitch account;
- refuses to run Clodex's OAuth refresh flow;
- refuses the request when the current token is rejected or within Clodex's
  normal refresh safety window, leaving refresh/swap ownership with
  CodexSwitch;
- never calls credential replacement for the managed account.

The external credential helper independently refuses `set` and `delete` for
the reserved managed account. This is a second ownership boundary, not a
substitute for the runtime patch.

## CCS Anthropic Passthrough

Clodex proxy mode remains the outer selective gateway. Its patched passthrough
target is the loopback-only CCS endpoint, currently
`http://127.0.0.1:8317`, instead of the public Anthropic origin. The patched
runtime preserves the request method, path, body, model, streaming behavior,
and CCS authorization header. It continues to intercept Clodex aliases for the
OpenAI adapter before the passthrough branch.

The stable `clodex-ccs-runtime-helper` validates the exact supported CCS
package, resolves CCS's effective internal proxy API key through CCS's own
read-only API, and proves the loopback proxy accepts it. The key is a local
gateway credential, not an Anthropic account access or refresh token. It is
resolved into the child environment at pane creation, never placed in a
command argument, tmux option, repository file, Clodex registry, or Mac-side
state. CLIProxy resolves the eligible Anthropic account for each request, so a
CCS default/order/pause change does not require a new Clodex login.

The default is `CLODEX_VPS_ANTHROPIC_BACKEND=ccs`. Startup fails closed when
the helper, supported CCS version, loopback origin, internal credential,
CLIProxy health, or patched Clodex postimage cannot be proven. Explicit
`CLODEX_VPS_ANTHROPIC_BACKEND=native` is the rollback/diagnostic mode; it
restores upstream Clodex native-auth behavior and intentionally opts out of
CCS pooling.

CCS proxy authentication can make Claude Remote Control unavailable. `/rc`
state is not a routing-readiness signal; the end-to-end proof is a normal
Anthropic-model request observed on the CCS provider path plus a Clodex alias
request observed on the translated path.

## Persistence And Secrets

The Clodex provider registry stores only a helper reference, provider
configuration, model metadata, bounded favorite-model selections, stable
non-secret model aliases, and the non-secret ownership marker returned at
runtime. Access, refresh, and ID tokens are not written to `~/.clodex`, the
repository, the Mac, logs, command arguments, or shell environment.

The helper's encrypted general-purpose storage remains available for unrelated
Clodex providers and disposable store probes. It is never used for the
CodexSwitch-managed OpenAI provider.

The CCS internal proxy key is read at launch through the runtime helper and
exists only in the local process environment, matching the ordinary CCS Claude
launcher contract. It must never be printed, logged, copied to the Mac, or
confused with the per-account Anthropic OAuth credentials retained by
CLIProxy.

## Installation And Rollback

The integration is pinned to exact Clodex and CCS package versions and exact
Clodex pre-patch/post-patch hashes. Installation refuses source drift, applies
the managed-OAuth and CCS-passthrough runtime patch atomically, verifies the
complete postimage, installs the stable helpers/configurator paths, and
creates only provider metadata.

Clodex custom model names require its Claude Code compatibility patch. The
integration must never apply that patch to the shared native Claude binary used
by the CCS lane. It creates a private copy under
`~/.local/share/clodex-codexswitch`, patches that inactive copy, verifies the
shared binary hash did not change, and launches only the Clodex lane with an
explicit isolated binary path and PATH prefix.

Runtime rollback first sets `CLODEX_VPS_ANTHROPIC_BACKEND=native` for a newly
created Clodex pane. Full rollback removes the provider reference and can
discard the isolated patched Claude copy after its Clodex session has exited.
It restores the exact original Clodex runtime bytes and does not mutate
CodexSwitch accounts, OAuth tokens, the shared native Claude binary, CCS
state, Claude sessions, or the running plain `claude-vps` lane.
