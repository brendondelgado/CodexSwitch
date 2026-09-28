#!/usr/bin/env bash
set -euo pipefail

PACKAGE="@bman654/clodex"
PINNED_VERSION="2.1.3"
EXPECTED_NODE_MAJOR=22
EXPECTED_PREFIX="${CLODEX_VPS_PREFIX:-$HOME/.local}"
NPM_BIN="${CLODEX_VPS_NPM_BIN:-$(command -v npm || true)}"
NODE_BIN="${CLODEX_VPS_NODE_BIN:-$(command -v node || true)}"
PACKAGE_ROOT="$EXPECTED_PREFIX/lib/node_modules/$PACKAGE"
PACKAGE_JSON="$PACKAGE_ROOT/package.json"
CLODEX_BIN="$EXPECTED_PREFIX/bin/clodex"
CLODEX_CLAUDE_BIN="$EXPECTED_PREFIX/bin/clodex-claude"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SUPPORT_BIN="$EXPECTED_PREFIX/bin"
HELPER_BIN="$SUPPORT_BIN/clodex-credential-helper"
CCS_RUNTIME_HELPER_BIN="$SUPPORT_BIN/clodex-ccs-runtime-helper"
PATCHER_BIN="$SUPPORT_BIN/patch-clodex-codexswitch"
CONFIGURATOR_BIN="$SUPPORT_BIN/configure-clodex-codexswitch"
NATIVE_CLAUDE_BIN="${CLODEX_NATIVE_CLAUDE_BIN:-$HOME/.local/bin/claude}"
ISOLATED_CLAUDE_ROOT="${CLODEX_ISOLATED_ROOT:-$HOME/.local/share/clodex-codexswitch}"
ISOLATED_CLAUDE_BIN_DIR="$ISOLATED_CLAUDE_ROOT/bin"
ISOLATED_CLAUDE_LINK="$ISOLATED_CLAUDE_BIN_DIR/claude"

usage() {
  printf 'usage: %s --install|--check|--configure-codexswitch|--unconfigure-codexswitch|--uninstall\n' "$0" >&2
  exit 64
}

require_runtime() {
  if [ -z "$NPM_BIN" ] || [ ! -x "$NPM_BIN" ]; then
    printf 'clodex-vps: npm is unavailable\n' >&2
    exit 69
  fi
  if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    printf 'clodex-vps: node is unavailable\n' >&2
    exit 69
  fi

  node_major="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
  if [ "$node_major" -lt "$EXPECTED_NODE_MAJOR" ]; then
    printf 'clodex-vps: Node %s or newer is required; found %s\n' \
      "$EXPECTED_NODE_MAJOR" "$("$NODE_BIN" --version)" >&2
    exit 69
  fi

  actual_prefix="$("$NPM_BIN" config get prefix)"
  if [ "$actual_prefix" != "$EXPECTED_PREFIX" ]; then
    printf 'clodex-vps: refusing npm prefix %s; expected %s\n' \
      "$actual_prefix" "$EXPECTED_PREFIX" >&2
    exit 78
  fi
}

installed_version() {
  if [ ! -f "$PACKAGE_JSON" ]; then
    return 1
  fi
  "$NODE_BIN" -p 'require(process.argv[1]).version' "$PACKAGE_JSON"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

check_package_installation() {
  require_runtime
  version="$(installed_version || true)"
  if [ "$version" != "$PINNED_VERSION" ]; then
    printf 'clodex-vps: expected %s@%s; found %s\n' \
      "$PACKAGE" "$PINNED_VERSION" "${version:-not installed}" >&2
    exit 78
  fi

  expected_cli="$PACKAGE_ROOT/dist/cli.js"
  expected_wrapper="$PACKAGE_ROOT/dist/claude-wrapper.js"
  for pair in "$CLODEX_BIN:$expected_cli" "$CLODEX_CLAUDE_BIN:$expected_wrapper"; do
    link="${pair%%:*}"
    target="${pair#*:}"
    if [ ! -x "$link" ] || [ ! -f "$target" ]; then
      printf 'clodex-vps: incomplete binary installation: %s\n' "$link" >&2
      exit 78
    fi
    if [ "$(realpath "$link")" != "$(realpath "$target")" ]; then
      printf 'clodex-vps: binary target mismatch: %s\n' "$link" >&2
      exit 78
    fi
  done

  reported="$("$CLODEX_BIN" --version | tr -d '\r' | tail -n 1)"
  if [ "$reported" != "$PINNED_VERSION" ]; then
    printf 'clodex-vps: binary version mismatch: %s\n' "$reported" >&2
    exit 78
  fi
  for support in \
    "$HELPER_BIN" \
    "$CCS_RUNTIME_HELPER_BIN" \
    "$PATCHER_BIN" \
    "$CONFIGURATOR_BIN"; do
    if [ ! -f "$support" ] || [ ! -x "$support" ] || [ "$(file_mode "$support")" != "700" ]; then
      printf 'clodex-vps: support executable missing or unsafe: %s\n' "$support" >&2
      exit 78
    fi
  done
  "$PATCHER_BIN" --check --package-root "$PACKAGE_ROOT"
}

check_installation() {
  check_package_installation
  "$CONFIGURATOR_BIN" \
    --check \
    --package-root "$PACKAGE_ROOT" \
    --helper "$HELPER_BIN"
  "$CCS_RUNTIME_HELPER_BIN" --check
  check_isolated_claude
  printf 'clodex-vps: ready %s@%s at %s\n' \
    "$PACKAGE" "$PINNED_VERSION" "$CLODEX_BIN"
}

isolated_claude_dry_run() {
  PATH="$ISOLATED_CLAUDE_BIN_DIR:$PATH" \
    TWEAKCC_CC_INSTALLATION_PATH="$ISOLATED_CLAUDE_LINK" \
    CLODEX_CREDENTIAL_HELPER="$HELPER_BIN" \
    "$CLODEX_BIN" claude --proxy --dry-run 2>&1
}

check_isolated_claude() {
  if [ ! -x "$NATIVE_CLAUDE_BIN" ] || [ ! -x "$ISOLATED_CLAUDE_LINK" ]; then
    printf 'clodex-vps: native or isolated Claude binary is unavailable\n' >&2
    exit 78
  fi
  native_real="$(realpath "$NATIVE_CLAUDE_BIN")"
  isolated_real="$(realpath "$ISOLATED_CLAUDE_LINK")"
  if [ "$native_real" = "$isolated_real" ]; then
    printf 'clodex-vps: isolated Claude resolves to the shared native binary\n' >&2
    exit 78
  fi
  dry_run="$(isolated_claude_dry_run)"
  if printf '%s\n' "$dry_run" | grep -Eq 'not patched|stale-patched'; then
    printf '%s\n' "$dry_run" >&2
    printf 'clodex-vps: isolated Claude patch is absent or stale\n' >&2
    exit 78
  fi
  if ! printf '%s\n' "$dry_run" | grep -q 'clodex:openai-oauth:'; then
    printf 'clodex-vps: isolated Claude dry run has no managed models\n' >&2
    exit 78
  fi
}

prepare_isolated_claude() {
  if [ ! -x "$NATIVE_CLAUDE_BIN" ]; then
    printf 'clodex-vps: native Claude binary is unavailable: %s\n' "$NATIVE_CLAUDE_BIN" >&2
    exit 78
  fi
  native_real="$(realpath "$NATIVE_CLAUDE_BIN")"
  version="$("$native_real" --version | awk 'NR == 1 { print $1 }')"
  case "$version" in
    ''|*[!0-9A-Za-z._-]*)
      printf 'clodex-vps: unsafe Claude version label %s\n' "$version" >&2
      exit 78
      ;;
  esac
  destination_dir="$ISOLATED_CLAUDE_ROOT/versions"
  destination="$destination_dir/$version"
  mkdir -p -m 700 "$destination_dir" "$ISOLATED_CLAUDE_BIN_DIR"
  native_before="$(sha256sum "$native_real" | awk '{print $1}')"
  if [ ! -e "$destination" ]; then
    temporary="$destination.tmp-$$"
    rm -f "$temporary"
    if ! cp --reflink=auto "$native_real" "$temporary" 2>/dev/null; then
      cp "$native_real" "$temporary"
    fi
    chmod 755 "$temporary"
    sync -f "$temporary"
    mv "$temporary" "$destination"
    sync -f "$destination_dir"
  fi
  temporary_link="$ISOLATED_CLAUDE_BIN_DIR/.claude-link-$$"
  rm -f "$temporary_link"
  ln -s "$destination" "$temporary_link"
  mv -f "$temporary_link" "$ISOLATED_CLAUDE_LINK"

  PATH="$ISOLATED_CLAUDE_BIN_DIR:$PATH" \
    TWEAKCC_CC_INSTALLATION_PATH="$destination" \
    CLODEX_CREDENTIAL_HELPER="$HELPER_BIN" \
    "$CLODEX_BIN" patch

  native_after="$(sha256sum "$native_real" | awk '{print $1}')"
  if [ "$native_before" != "$native_after" ]; then
    printf 'clodex-vps: shared native Claude binary changed during isolated patch\n' >&2
    exit 78
  fi
  check_isolated_claude
}

install_support() {
  mkdir -p -m 700 "$SUPPORT_BIN"
  install -m 700 "$SCRIPT_DIR/clodex-credential-helper.py" "$HELPER_BIN"
  install -m 700 \
    "$SCRIPT_DIR/clodex-ccs-runtime-helper.mjs" \
    "$CCS_RUNTIME_HELPER_BIN"
  install -m 700 "$SCRIPT_DIR/patch-clodex-codexswitch.py" "$PATCHER_BIN"
  install -m 700 "$SCRIPT_DIR/configure-clodex-codexswitch.mjs" "$CONFIGURATOR_BIN"
}

install_package() {
  require_runtime
  version="$(installed_version || true)"
  if [ -z "$version" ]; then
    "$NPM_BIN" install --global --no-audit --no-fund "$PACKAGE@$PINNED_VERSION"
  elif [ "$version" != "$PINNED_VERSION" ]; then
    printf 'clodex-vps: refusing installed version %s; expected %s\n' \
      "$version" "$PINNED_VERSION" >&2
    exit 78
  fi
  install_support
  "$PATCHER_BIN" --apply --package-root "$PACKAGE_ROOT"
  check_package_installation
  printf 'clodex-vps: installed; run --configure-codexswitch to bind the active CodexSwitch account\n'
}

configure_codexswitch() {
  check_package_installation
  "$CONFIGURATOR_BIN" \
    --configure \
    --package-root "$PACKAGE_ROOT" \
    --helper "$HELPER_BIN"
  CLODEX_CREDENTIAL_HELPER="$HELPER_BIN" \
    "$CLODEX_BIN" providers refresh-models openai-oauth
  "$CONFIGURATOR_BIN" \
    --configure \
    --package-root "$PACKAGE_ROOT" \
    --helper "$HELPER_BIN"
  prepare_isolated_claude
  check_installation
}

unconfigure_codexswitch() {
  check_package_installation
  "$CONFIGURATOR_BIN" \
    --unconfigure \
    --package-root "$PACKAGE_ROOT" \
    --helper "$HELPER_BIN"
}

uninstall_package() {
  require_runtime
  version="$(installed_version || true)"
  if [ -z "$version" ]; then
    printf 'clodex-vps: %s is already absent\n' "$PACKAGE"
    return
  fi
  if [ "$version" != "$PINNED_VERSION" ]; then
    printf 'clodex-vps: refusing to remove unpinned version %s\n' "$version" >&2
    exit 78
  fi
  if [ -x "$PATCHER_BIN" ]; then
    "$PATCHER_BIN" --restore --package-root "$PACKAGE_ROOT"
  fi
  "$NPM_BIN" uninstall --global "$PACKAGE"
  if [ -e "$PACKAGE_ROOT" ] || [ -e "$CLODEX_BIN" ] || [ -e "$CLODEX_CLAUDE_BIN" ]; then
    printf 'clodex-vps: uninstall verification failed\n' >&2
    exit 78
  fi
  printf 'clodex-vps: removed %s@%s; preserved ~/.clodex\n' \
    "$PACKAGE" "$PINNED_VERSION"
}

if [ "$#" -ne 1 ]; then
  usage
fi

case "$1" in
  --install) install_package ;;
  --check) check_installation ;;
  --configure-codexswitch) configure_codexswitch ;;
  --unconfigure-codexswitch) unconfigure_codexswitch ;;
  --uninstall) uninstall_package ;;
  *) usage ;;
esac
