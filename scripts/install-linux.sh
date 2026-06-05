#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CODEXSWITCH_REPO_URL:-https://github.com/brendondelgado/CodexSwitch.git}"
INSTALL_DIR="${CODEXSWITCH_INSTALL_DIR:-$HOME/.local/share/codexswitch}"
BIN_DIR="${CODEXSWITCH_BIN_DIR:-$HOME/.local/bin}"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
IMPORT_BUNDLE="${CODEXSWITCH_IMPORT_BUNDLE:-${1:-}}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Linux devboxes. On macOS, build/run the CodexSwitch app instead." >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

install_system_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y build-essential ca-certificates curl git
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y ca-certificates curl gcc gcc-c++ git make
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --needed --noconfirm base-devel ca-certificates curl git
  fi
}

if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    install_system_packages
  fi
fi

need_cmd git
need_cmd curl

if ! command -v cargo >/dev/null 2>&1; then
  echo "Installing Rust toolchain with rustup..."
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

need_cmd cargo

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

cargo build --release -p codexswitch-cli --manifest-path "$INSTALL_DIR/Cargo.toml"
install -m 755 "$INSTALL_DIR/target/release/codexswitch-cli" "$BIN_DIR/codexswitch-cli"

if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$SERVICE_DIR"
  install -m 644 "$INSTALL_DIR/crates/codexswitch-cli/systemd/codexswitch.service" "$SERVICE_DIR/codexswitch.service"
  systemctl --user daemon-reload || true
fi

if [[ -n "$IMPORT_BUNDLE" ]]; then
  "$BIN_DIR/codexswitch-cli" import "$IMPORT_BUNDLE"
  "$BIN_DIR/codexswitch-cli" doctor || true
fi

if [[ "${CODEXSWITCH_ENABLE_DAEMON:-0}" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user enable --now codexswitch
fi

cat <<EOF
CodexSwitch CLI installed.

If ~/.local/bin is not on PATH yet:
  export PATH="\$HOME/.local/bin:\$PATH"

Next:
  1. Export a Linux bundle from CodexSwitch on your Mac.
  2. Copy it here.
  3. Run: codexswitch-cli import ~/codexswitch-linux-devbox-*.csbundle
  4. Run: codexswitch-cli tui

Optional daemon:
  systemctl --user enable --now codexswitch
EOF
