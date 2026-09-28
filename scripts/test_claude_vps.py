#!/usr/bin/env python3
import json
import contextlib
import io
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "claude-vps"
CCS_WRAPPER = ROOT / "scripts" / "ccs-macos-wrapper"
STATUSLINE_SCRIPT = ROOT / "scripts" / "claude-vps-statusline.sh"
TRANSCRIPT_SCRIPT = ROOT / "scripts" / "claude-vps-transcript"


class ClaudeVPSScriptTests(unittest.TestCase):
    def _resolver_function(self) -> str:
        text = SCRIPT.read_text()
        start = text.index("resolve_latest_repo_session_id() {")
        end = text.index("\n\nresolve_live_session_owner()", start)
        return text[start:end]

    def _select_latest_function(self) -> str:
        text = SCRIPT.read_text()
        start = text.index("select_latest_managed_session() {")
        end = text.index("\n\nbind_resume_to_launch_command()", start)
        return text[start:end]

    def _resume_launch_binding_function(self) -> str:
        text = SCRIPT.read_text()
        start = text.index("bind_resume_to_launch_command() {")
        end = text.index("\n\nensure_claude_vps_statusline()", start)
        return text[start:end]

    def test_connects_to_remote_claude_code_without_ssh_mux(self):
        text = SCRIPT.read_text()

        for option in (
            "-o ControlMaster=no",
            "-o ControlPath=none",
            "-o ControlPersist=no",
        ):
            self.assertIn(option, text)

        self.assertIn('REMOTE_HOST="${CLAUDE_VPS_REMOTE_HOST:-signul-vps}"', text)
        self.assertIn('REMOTE_BACKEND_MODE="${CLAUDE_VPS_BACKEND_MODE:-native}"', text)
        self.assertIn('native|ccs|clodex', text)
        self.assertIn('if [ "${1:-}" = "clodex" ]', text)
        self.assertIn('REMOTE_BACKEND_MODE="clodex"', text)
        self.assertIn(
            'REMOTE_CLAUDE="${CLODEX_VPS_REMOTE_CLODEX:-/home/signul/.local/bin/clodex}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_CREDENTIAL_HELPER="${CLODEX_VPS_CREDENTIAL_HELPER:-/home/signul/.local/bin/clodex-credential-helper}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_CCS_RUNTIME_HELPER="${CLODEX_VPS_CCS_RUNTIME_HELPER:-/home/signul/.local/bin/clodex-ccs-runtime-helper}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_ANTHROPIC_BACKEND="${CLODEX_VPS_ANTHROPIC_BACKEND:-ccs}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_CCS_BASE_URL="${CLODEX_VPS_CCS_BASE_URL:-http://127.0.0.1:8317}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_CONFIGURATOR="${CLODEX_VPS_CONFIGURATOR:-/home/signul/.local/bin/configure-clodex-codexswitch}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_PACKAGE_ROOT="${CLODEX_VPS_PACKAGE_ROOT:-/home/signul/.local/lib/node_modules/@bman654/clodex}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_ISOLATED_BIN_DIR="${CLODEX_VPS_ISOLATED_BIN_DIR:-/home/signul/.local/share/clodex-codexswitch/bin}"',
            text,
        )
        self.assertIn(
            'REMOTE_CLODEX_ISOLATED_CLAUDE="${CLODEX_VPS_ISOLATED_CLAUDE:-/home/signul/.local/share/clodex-codexswitch/bin/claude}"',
            text,
        )
        self.assertIn('claude_vps_path="$CLODEX_ISOLATED_BIN_DIR:$PATH"', text)
        self.assertIn(
            'ANTHROPIC_AUTH_TOKEN="$("$CLODEX_CCS_RUNTIME_HELPER" --token)"',
            text,
        )
        self.assertIn(
            'export CLODEX_ANTHROPIC_PASSTHROUGH_BASE_URL="$CLODEX_CCS_BASE_URL"',
            text,
        )
        self.assertIn(
            'unset CLODEX_ANTHROPIC_PASSTHROUGH_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY',
            text,
        )
        self.assertIn(
            'REMOTE_TMUX_SESSION="${CLODEX_VPS_TMUX_SESSION:-claude-vps-clodex}"',
            text,
        )
        self.assertIn(
            'REMOTE_PREFERRED_SESSION_TITLE="${CLODEX_VPS_PREFERRED_SESSION_TITLE-${CLAUDE_VPS_DEFAULT_PREFERRED_SESSION_TITLE}}"',
            text,
        )
        self.assertIn('TAILSCALE_HOST="${CLAUDE_VPS_TAILSCALE_HOST:-signul-hostinger-kvm4}"', text)
        self.assertIn('TAILSCALE_TARGET_IP="${CLAUDE_VPS_TAILSCALE_TARGET_IP:-100.95.84.123}"', text)
        self.assertIn('-o "ProxyCommand=${TAILSCALE_BIN} nc %h %p"', text)
        self.assertIn('MOSH_BIN="${CLAUDE_VPS_MOSH_BIN:-mosh}"', text)
        self.assertIn('MOSH_PREDICT="${CLAUDE_VPS_MOSH_PREDICT:-never}"', text)
        self.assertIn(
            'SESSION_TRANSPORT_REQUESTED="${CLODEX_VPS_TRANSPORT:-ssh}"',
            text,
        )
        self.assertIn('SESSION_TRANSPORT_REQUESTED="${CLAUDE_VPS_TRANSPORT:-auto}"', text)
        self.assertIn('REMOTE_REPO="${CLAUDE_VPS_REMOTE_REPO:-/home/signul/SIGNUL}"', text)
        self.assertIn(
            'CLAUDE_VPS_DEFAULT_PREFERRED_SESSION_TITLE="${CLAUDE_VPS_PREFERRED_SESSION_TITLE-backend agent}"',
            text,
        )
        self.assertIn(
            'REMOTE_PREFERRED_SESSION_TITLE="$CLAUDE_VPS_DEFAULT_PREFERRED_SESSION_TITLE"',
            text,
        )
        self.assertIn('REMOTE_CLAUDE="/home/signul/.local/bin/claude"', text)
        self.assertIn('REMOTE_CLAUDE="/usr/bin/ccs"', text)
        self.assertIn('REMOTE_CLAUDE_SUBCOMMAND="${CLAUDE_VPS_REMOTE_CLAUDE_SUBCOMMAND:-claude}"', text)
        self.assertIn('REMOTE_CLAUDE="$CLAUDE_VPS_REMOTE_CLAUDE"', text)
        self.assertIn('REMOTE_TERM="${CLAUDE_VPS_REMOTE_TERM:-xterm-256color}"', text)
        self.assertIn('REMOTE_COLORTERM="${CLAUDE_VPS_REMOTE_COLORTERM:-truecolor}"', text)
        self.assertIn('REMOTE_FORCE_COLOR="${CLAUDE_VPS_FORCE_COLOR:-3}"', text)
        self.assertIn('REMOTE_AUTO_CONTINUE="${CLAUDE_VPS_AUTO_CONTINUE:-1}"', text)
        self.assertIn('REMOTE_CONTROL_DEFAULT="${CLAUDE_VPS_REMOTE_CONTROL_DEFAULT:-0}"', text)
        self.assertIn('REMOTE_CONTROL_NAME="${CLAUDE_VPS_REMOTE_CONTROL_NAME:-signul-vps}"', text)
        self.assertIn('REMOTE_CONTROL_SPAWN="${CLAUDE_VPS_REMOTE_CONTROL_SPAWN:-same-dir}"', text)
        self.assertIn('REMOTE_DISABLE_TMUX="${CLAUDE_VPS_DISABLE_TMUX:-0}"', text)
        self.assertIn(
            'REMOTE_DANGEROUSLY_SKIP_PERMISSIONS="${CLODEX_VPS_DANGEROUSLY_SKIP_PERMISSIONS:-1}"',
            text,
        )
        self.assertIn(
            'REMOTE_DANGEROUSLY_SKIP_PERMISSIONS="${CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS:-1}"',
            text,
        )
        self.assertIn('REMOTE_TMUX_SESSION="${CLAUDE_VPS_TMUX_SESSION:-claude-vps}"', text)
        self.assertIn('REMOTE_TMUX_SESSION="${CLAUDE_VPS_TMUX_SESSION:-claude-vps-ccs}"', text)
        self.assertIn('REMOTE_TMUX_HISTORY_LIMIT="${CLAUDE_VPS_TMUX_HISTORY_LIMIT:-200000}"', text)
        self.assertIn('REMOTE_TMUX_TERM="${CLAUDE_VPS_TMUX_TERM:-tmux-256color}"', text)
        self.assertIn('REMOTE_TMUX_DETACH_OTHER_CLIENTS="${CLAUDE_VPS_TMUX_DETACH_OTHER_CLIENTS:-1}"', text)
        self.assertIn('REMOTE_TMUX_LOG="${CLAUDE_VPS_TMUX_LOG:-0}"', text)
        self.assertIn('REMOTE_TMUX_STATUS="${CLAUDE_VPS_TMUX_STATUS:-0}"', text)
        self.assertIn('REMOTE_TMUX_STATUS_POSITION="${CLAUDE_VPS_TMUX_STATUS_POSITION:-top}"', text)
        self.assertIn('REMOTE_TMUX_STATUS_INTERVAL="${CLAUDE_VPS_TMUX_STATUS_INTERVAL:-5}"', text)
        self.assertIn('REMOTE_TMUX_FORCE_COPY_SCROLL="${CLAUDE_VPS_TMUX_FORCE_COPY_SCROLL:-0}"', text)
        self.assertIn('REMOTE_TRANSPORT_LABEL="${CLAUDE_VPS_TRANSPORT_LABEL:-ssh}"', text)
        self.assertIn('REMOTE_CLAUDE_NO_FLICKER="${CLAUDE_VPS_CLAUDE_CODE_NO_FLICKER:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_DISABLE_ALTERNATE_SCREEN="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_SCROLL_SPEED="${CLAUDE_VPS_CLAUDE_CODE_SCROLL_SPEED:-3}"', text)
        self.assertIn('REMOTE_CLAUDE_DISABLE_MOUSE="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_MOUSE:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_DISABLE_VIRTUAL_SCROLL="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_STATUSLINE="${CLAUDE_VPS_CLAUDE_STATUSLINE:-1}"', text)
        self.assertIn('SSH_SERVER_ALIVE_INTERVAL="${CLAUDE_VPS_SERVER_ALIVE_INTERVAL:-30}"', text)
        self.assertIn('SSH_SERVER_ALIVE_COUNT_MAX="${CLAUDE_VPS_SERVER_ALIVE_COUNT_MAX:-6}"', text)
        self.assertIn('SSH_AUTO_RECONNECT="${CLAUDE_VPS_AUTO_RECONNECT:-1}"', text)
        self.assertIn('SSH_RECONNECT_DELAY="${CLAUDE_VPS_RECONNECT_DELAY:-2}"', text)
        self.assertIn('SSH_RECONNECT_MAX="${CLAUDE_VPS_RECONNECT_MAX:-0}"', text)
        self.assertIn('SYNC_DESKTOP_SESSION_INDEX="${CLAUDE_VPS_SYNC_DESKTOP_SESSION_INDEX:-0}"', text)
        self.assertIn('REMOTE_RESPAWN_PANE="${CLAUDE_VPS_RESPAWN_PANE:-0}"', text)
        self.assertIn("--remote-control|--rc|--web", text)
        self.assertIn("--tmux|--persistent", text)
        self.assertIn("--raw|--no-tmux|--terminal|--tui", text)
        self.assertIn("-yolo|--yolo|--dangerously-skip-permissions", text)
        self.assertIn("--safe|--ask-permissions", text)
        self.assertIn("--fullscreen", text)
        self.assertIn("--classic|--native-scrollback", text)
        self.assertIn("--repair-scrollback|--respawn-pane", text)
        self.assertIn("REMOTE_CONTROL_DEFAULT=0", text)
        self.assertIn("remote_session_snapshot_script()", text)
        self.assertIn("refresh_claude_desktop_session_index()", text)
        self.assertIn("resolve_latest_repo_session_id()", text)
        self.assertIn("CLAUDE_VPS_PREFERRED_SESSION_TITLE=%s", text)
        self.assertIn("__CLAUDE_VPS_PREFERRED_TITLE_NOT_FOUND__", text)
        self.assertIn("resolve_live_session_owner()", text)
        self.assertIn("bind_resume_to_launch_command()", text)
        self.assertIn(
            'claude_vps_launch="$(bind_resume_to_launch_command "$claude_vps_launch")"',
            text,
        )
        self.assertIn('CLAUDE_VPS_RESUME_SESSION_ID="$latest_session_id"', text)
        self.assertIn('-preserved-$(date +%Y%m%dT%H%M%S)', text)
        self.assertIn("refusing concurrent resume", text)
        self.assertIn("mosh_ssh_command()", text)
        self.assertIn("tailscale_packet_filter_allows_mosh()", text)
        self.assertIn("select_session_transport()", text)
        self.assertIn("selected_session_transport", text)
        self.assertIn("--experimental-remote-ip=remote", text)
        self.assertIn('--predict="$MOSH_PREDICT"', text)
        self.assertIn('exec "$MOSH_BIN"', text)
        self.assertIn('-- /bin/bash -lc "$remote_command"', text)
        self.assertIn("claude-code-sessions", text)
        self.assertIn(".cliSessionId == $session_id", text)
        self.assertIn('refresh_claude_desktop_session_index "$@" >/dev/null 2>&1 &', text)
        self.assertIn("CODEXSWITCH_REMOTE_TTY_ROWS", text)
        self.assertIn("stty rows", text)
        self.assertIn("tmux new-session -d", text)
        self.assertIn('set-option -gq history-limit "$CLAUDE_VPS_TMUX_HISTORY_LIMIT"', text)
        self.assertIn('set-window-option -gq history-limit "$CLAUDE_VPS_TMUX_HISTORY_LIMIT"', text)
        self.assertIn('set-window-option -t "${CLAUDE_VPS_TMUX_SESSION}:0" history-limit "$CLAUDE_VPS_TMUX_HISTORY_LIMIT"', text)
        self.assertIn("focus-events on", text)
        self.assertIn("escape-time 10", text)
        self.assertIn("extended-keys on", text)
        self.assertIn("allow-passthrough on", text)
        self.assertIn("stty -ixon -ixoff", text)
        self.assertIn("default-terminal", text)
        self.assertIn("terminal-features", text)
        self.assertIn("terminal-overrides", text)
        self.assertIn("set-environment", text)
        self.assertIn("set-environment -g REMOTE_CLAUDE_SUBCOMMAND", text)
        self.assertIn("set-environment -g CLAUDE_VPS_BACKEND_MODE", text)
        self.assertIn("set-environment -g CLODEX_CREDENTIAL_HELPER", text)
        self.assertIn("set-environment -g CLODEX_ISOLATED_BIN_DIR", text)
        self.assertIn("set-environment -g TWEAKCC_CC_INSTALLATION_PATH", text)
        self.assertIn("set-environment -g CLAUDE_VPS_AUTO_CONTINUE", text)
        self.assertIn("set-environment -g CLAUDE_VPS_CONTINUE_ARG", text)
        self.assertIn("set-environment -g CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS", text)
        self.assertIn('FORCE_COLOR=%s', text)
        self.assertIn('CLAUDE_VPS_CLAUDE_STATUSLINE=%s', text)
        self.assertIn('CLAUDE_VPS_AUTO_CONTINUE=%s', text)
        self.assertIn('CLAUDE_VPS_CONTINUE_ARG=%s', text)
        self.assertIn('CLAUDE_VPS_REMOTE_CONTROL_DEFAULT=%s', text)
        self.assertIn('CLAUDE_VPS_REMOTE_CONTROL_NAME=%s', text)
        self.assertIn('CLAUDE_VPS_REMOTE_CONTROL_SPAWN=%s', text)
        self.assertIn('CLAUDE_VPS_DISABLE_TMUX=%s', text)
        self.assertIn('CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS=%s', text)
        self.assertIn("history-limit", text)
        self.assertIn("mouse on", text)
        self.assertIn('tmux set-option -t "$CLAUDE_VPS_TMUX_SESSION" status "$claude_vps_status_mode"', text)
        self.assertIn('CLAUDE_VPS_TMUX_STATUS_POSITION=%s', text)
        self.assertIn('tmux set-option -t "$CLAUDE_VPS_TMUX_SESSION" status-position "$claude_vps_status_position"', text)
        self.assertIn("status-interval", text)
        self.assertIn('CLAUDE_VPS_TMUX_FORCE_COPY_SCROLL=%s', text)
        self.assertIn('CLAUDE_VPS_RESPAWN_PANE=%s', text)
        self.assertIn('CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL=%s', text)
        self.assertIn('CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=%s', text)
        self.assertIn("WheelUpPane copy-mode -e", text)
        self.assertIn("mouse_any_flag", text)
        self.assertIn("WheelDownPane send-keys -X -N 5 scroll-down", text)
        self.assertIn("@claude-vps-backend", text)
        self.assertIn("@claude-vps-transport", text)
        self.assertIn("claude-vps #[fg=colour244]#{@claude-vps-backend}/#{@claude-vps-transport}", text)
        self.assertIn("alternate-screen on", text)
        self.assertIn("aggressive-resize on", text)
        self.assertIn("pipe-pane -o", text)
        self.assertIn('tmux pipe-pane -t "${CLAUDE_VPS_TMUX_SESSION}:0"', text)
        self.assertIn("@claude-vps-log", text)
        self.assertIn("CLAUDE_CODE_NO_FLICKER", text)
        self.assertIn("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", text)
        self.assertIn("CLAUDE_CODE_SCROLL_SPEED", text)
        self.assertIn("CLAUDE_CODE_DISABLE_MOUSE", text)
        self.assertIn("CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL", text)
        self.assertIn("ensure_claude_vps_statusline()", text)
        self.assertIn("claude-vps-statusline.sh", text)
        self.assertIn(".statusLine = {\"type\":\"command\",\"command\":$command,\"padding\":0,\"refreshInterval\":5}", text)
        self.assertIn("attach_flags=(-d)", text)
        self.assertNotIn("alternate-screen off", text)
        self.assertIn("exec env TERM=", text)
        self.assertIn("COLORTERM=", text)
        self.assertIn("FORCE_COLOR=", text)
        self.assertIn("CLAUDE_VPS_TMUX_TERM", text)
        self.assertIn("REMOTE_COLORTERM", text)
        self.assertIn("REMOTE_FORCE_COLOR", text)
        self.assertIn("tmux attach-session", text)
        self.assertIn("CLAUDE_VPS_AUTO_CONTINUE", text)
        self.assertIn("CLAUDE_VPS_CONTINUE_ARG", text)
        self.assertIn("CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS", text)
        self.assertIn("--continue", text)
        self.assertIn('claude_vps_permission_arg="--dangerously-skip-permissions"', text)
        self.assertIn('set -- --dangerously-skip-permissions "$@"', text)
        self.assertIn('set -- remote-control --name "$CLAUDE_VPS_REMOTE_CONTROL_NAME" --spawn="${CLAUDE_VPS_REMOTE_CONTROL_SPAWN:-same-dir}"', text)
        self.assertIn('set -- remote-control --spawn="${CLAUDE_VPS_REMOTE_CONTROL_SPAWN:-same-dir}"', text)
        self.assertIn("connecting to Claude Code Remote Control", text)
        self.assertIn("bypass permissions enabled", text)
        self.assertIn("#{pane_dead}", text)
        self.assertIn("tmux respawn-pane -k", text)
        self.assertIn("recreating tmux session with history-limit", text)
        self.assertIn("claude-vps: respawning dead tmux pane", text)
        self.assertIn(
            '"$REMOTE_CLAUDE" "$REMOTE_CLAUDE_SUBCOMMAND" --proxy "$@"',
            text,
        )
        self.assertIn('"$REMOTE_CLAUDE" "$REMOTE_CLAUDE_SUBCOMMAND" "$@"', text)
        self.assertIn('"$REMOTE_CLAUDE" "$@"', text)
        self.assertNotIn("strict-mcp-config", text)
        self.assertNotIn("mcp-config", text)
        self.assertIn('exec ssh -tt "${selected_ssh_opts[@]}" "$selected_host"', text)
        self.assertIn("apply_claude_renderer_env()", text)
        self.assertIn('export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1', text)
        self.assertIn('unset CLAUDE_CODE_NO_FLICKER', text)
        self.assertIn('exec env TERM="$TERM" COLORTERM="$REMOTE_COLORTERM" FORCE_COLOR="$REMOTE_FORCE_COLOR" CLAUDE_CODE_SCROLL_SPEED="$CLAUDE_CODE_SCROLL_SPEED" "$REMOTE_CLAUDE" "$REMOTE_CLAUDE_SUBCOMMAND" "$@"', text)
        self.assertIn('exec env TERM="$TERM" COLORTERM="$REMOTE_COLORTERM" FORCE_COLOR="$REMOTE_FORCE_COLOR" CLAUDE_CODE_SCROLL_SPEED="$CLAUDE_CODE_SCROLL_SPEED" "$REMOTE_CLAUDE" "$@"', text)
        self.assertNotIn('CLAUDE_CODE_NO_FLICKER="$CLAUDE_CODE_NO_FLICKER" "$REMOTE_CLAUDE"', text)
        self.assertNotIn('CLAUDE_CODE_DISABLE_MOUSE="$CLAUDE_CODE_DISABLE_MOUSE" "$REMOTE_CLAUDE"', text)
        self.assertIn('ssh_status="$?"', text)
        self.assertIn('[ "$ssh_status" -ne 255 ]', text)
        self.assertIn("SSH transport dropped; reconnecting", text)
        self.assertIn("terminal renderer (no tmux)", text)

    def _check_invocation(self, backend_mode=None, launcher_args=None):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            calls = temp / "ssh-calls"
            ssh = temp / "ssh"
            ssh.write_text(
                """#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CALLS"
exit 0
"""
            )
            ssh.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{temp}:{os.environ['PATH']}",
                "SSH_CALLS": str(calls),
                "CLAUDE_VPS_DISABLE_TAILSCALE_PROXY": "1",
                "CLAUDE_VPS_TRANSPORT": "ssh",
            }
            if backend_mode is not None:
                env["CLAUDE_VPS_BACKEND_MODE"] = backend_mode

            result = subprocess.run(
                [str(SCRIPT), *(launcher_args or ["--check"])],
                text=True,
                capture_output=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            return calls.read_text()

    def test_unprefixed_launcher_defaults_to_native_claude_lane(self):
        invocation = self._check_invocation()

        self.assertIn("CLAUDE_VPS_BACKEND_MODE=native", invocation)
        self.assertIn("REMOTE_CLAUDE=/home/signul/.local/bin/claude", invocation)
        self.assertIn("REMOTE_CLAUDE_SUBCOMMAND=''", invocation)
        self.assertIn("CLAUDE_VPS_TMUX_SESSION=claude-vps", invocation)

    def test_explicit_ccs_backend_uses_ccs_lane_and_distinct_tmux(self):
        invocation = self._check_invocation("ccs")

        self.assertIn("CLAUDE_VPS_BACKEND_MODE=ccs", invocation)
        self.assertIn("REMOTE_CLAUDE=/usr/bin/ccs", invocation)
        self.assertIn("REMOTE_CLAUDE_SUBCOMMAND=claude", invocation)
        self.assertIn("CLAUDE_VPS_TMUX_SESSION=claude-vps-ccs", invocation)

    def test_numbered_native_lanes_are_fresh_and_isolated(self):
        for slot in ("2", "3"):
            with self.subTest(slot=slot):
                invocation = self._check_invocation(
                    launcher_args=[slot, "--check"],
                )

                self.assertIn("CLAUDE_VPS_BACKEND_MODE=native", invocation)
                self.assertIn(
                    "REMOTE_CLAUDE=/home/signul/.local/bin/claude",
                    invocation,
                )
                self.assertIn("CLAUDE_VPS_AUTO_CONTINUE=0", invocation)
                self.assertIn("REMOTE_AUTO_CONTINUE=0", invocation)
                self.assertIn("CLAUDE_VPS_CONTINUE_ARG=''", invocation)
                self.assertIn(
                    f"CLAUDE_VPS_TMUX_SESSION=claude-vps-{slot}",
                    invocation,
                )

    def test_numbered_lane_refuses_non_native_backend(self):
        result = subprocess.run(
            [str(SCRIPT), "2", "--check"],
            text=True,
            capture_output=True,
            env={**os.environ, "CLAUDE_VPS_BACKEND_MODE": "ccs"},
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("numbered sessions are available only for native Claude", result.stderr)

    def test_cmux_terminal_uses_managed_ssh_and_bootstraps_tmux(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            ssh_calls = temp / "ssh-calls"
            cmux_calls = temp / "cmux-calls"
            ssh = temp / "ssh"
            cmux = temp / "cmux"
            ssh.write_text(
                """#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CALLS"
exit 0
"""
            )
            cmux.write_text(
                """#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_CALLS"
case "$1 $2" in
  "workspace list") exit 0 ;;
esac
exit 0
"""
            )
            ssh.chmod(0o755)
            cmux.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{temp}:{os.environ['PATH']}",
                "SSH_CALLS": str(ssh_calls),
                "CMUX_CALLS": str(cmux_calls),
                "CMUX_BUNDLED_CLI_PATH": str(cmux),
                "CMUX_WORKSPACE_ID": "workspace:test",
                "CLAUDE_VPS_DISABLE_TAILSCALE_PROXY": "1",
                "CLAUDE_VPS_TRANSPORT": "ssh",
                "CLAUDE_VPS_SYNC_DESKTOP_SESSION_INDEX": "0",
            }

            result = subprocess.run(
                [str(SCRIPT), "2"],
                text=True,
                capture_output=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            bootstrap = ssh_calls.read_text()
            cmux_invocations = cmux_calls.read_text()

        self.assertIn("CLAUDE_VPS_BOOTSTRAP_ONLY=1", bootstrap)
        self.assertIn("CLAUDE_VPS_TMUX_SESSION=claude-vps-2", bootstrap)
        self.assertIn("workspace list", cmux_invocations)
        self.assertIn(
            "ssh signul-vps --name claude-vps-2 --ssh-option RequestTTY=force -- "
            "/usr/bin/tmux attach-session -d -t claude-vps-2",
            cmux_invocations,
        )

    def test_non_cmux_terminal_keeps_existing_transport(self):
        text = SCRIPT.read_text()

        self.assertIn('[ -n "${CMUX_WORKSPACE_ID:-}" ] || return 1', text)
        self.assertIn('selected_session_transport="cmux-ssh"', text)
        self.assertIn('if [ "$selected_session_transport" = "mosh" ]; then', text)
        self.assertIn('CLAUDE_VPS_BOOTSTRAP_ONLY=1 $remote_command', text)
        self.assertIn('--ssh-option RequestTTY=force', text)

    def test_ccs_wrapper_dispatches_only_named_vps_lanes(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            fake = temp / "capture"
            fake.write_text(
                """#!/usr/bin/env bash
printf 'mode=%s session=%s continue=%s args=' \
  "${CLAUDE_VPS_BACKEND_MODE:-}" \
  "${CLAUDE_VPS_TMUX_SESSION:-}" \
  "${CLAUDE_VPS_AUTO_CONTINUE:-}"
printf '%s,' "$@"
printf '\n'
"""
            )
            fake.chmod(0o755)
            env = {
                **os.environ,
                "CLAUDE_VPS_BIN": str(fake),
                "CCS_REAL_BIN": str(fake),
            }

            routed = subprocess.run(
                [str(CCS_WRAPPER), "claude-vps", "--check"],
                text=True,
                capture_output=True,
                check=True,
                env=env,
            )
            legacy = subprocess.run(
                [str(CCS_WRAPPER), "claude2", "--safe"],
                text=True,
                capture_output=True,
                check=True,
                env=env,
            )
            passthrough = subprocess.run(
                [str(CCS_WRAPPER), "cliproxy", "pool", "status"],
                text=True,
                capture_output=True,
                check=True,
                env=env,
            )

        self.assertEqual(routed.stdout, "mode=ccs session= continue= args=--check,\n")
        self.assertEqual(legacy.stdout, "mode=ccs session=claude-vps-ccs-2 continue=0 args=--safe,\n")
        self.assertEqual(
            passthrough.stdout,
            "mode= session= continue= args=cliproxy,pool,status,\n",
        )

    def test_clodex_check_uses_isolated_backend_without_starting_a_session(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            calls = temp / "ssh-calls"
            ssh = temp / "ssh"
            ssh.write_text(
                """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$SSH_CALLS"
exit 0
"""
            )
            ssh.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{temp}:{os.environ['PATH']}",
                "SSH_CALLS": str(calls),
                "CLAUDE_VPS_DISABLE_TAILSCALE_PROXY": "1",
                "CLAUDE_VPS_TRANSPORT": "ssh",
            }

            result = subprocess.run(
                [str(SCRIPT), "clodex", "--check"],
                text=True,
                capture_output=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            invocation = calls.read_text()
            self.assertIn("CLAUDE_VPS_BACKEND_MODE=clodex", invocation)
            self.assertIn(
            r"CLAUDE_VPS_PREFERRED_SESSION_TITLE=backend\ agent",
                invocation,
            )
            self.assertIn(
                "CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS=1",
                invocation,
            )
            self.assertIn("REMOTE_CLAUDE=/home/signul/.local/bin/clodex", invocation)
            self.assertIn("REMOTE_CLAUDE_SUBCOMMAND=claude", invocation)
            self.assertIn(
                "CLODEX_CREDENTIAL_HELPER=/home/signul/.local/bin/clodex-credential-helper",
                invocation,
            )
            self.assertIn(
                "CLODEX_CCS_RUNTIME_HELPER=/home/signul/.local/bin/clodex-ccs-runtime-helper",
                invocation,
            )
            self.assertIn("CLODEX_ANTHROPIC_BACKEND=ccs", invocation)
            self.assertIn(
                "CLODEX_CCS_BASE_URL=http://127.0.0.1:8317",
                invocation,
            )
            self.assertIn(
                "CLODEX_CODEXSWITCH_CONFIGURATOR=/home/signul/.local/bin/configure-clodex-codexswitch",
                invocation,
            )
            self.assertIn(
                "CLODEX_CODEXSWITCH_PACKAGE_ROOT=/home/signul/.local/lib/node_modules/@bman654/clodex",
                invocation,
            )
            self.assertIn(
                "CLODEX_ISOLATED_BIN_DIR=/home/signul/.local/share/clodex-codexswitch/bin",
                invocation,
            )
            self.assertIn(
                "TWEAKCC_CC_INSTALLATION_PATH=/home/signul/.local/share/clodex-codexswitch/bin/claude",
                invocation,
            )
            self.assertIn(
                '"$CLODEX_CODEXSWITCH_CONFIGURATOR" --check --package-root '
                '"$CLODEX_CODEXSWITCH_PACKAGE_ROOT" --helper "$CLODEX_CREDENTIAL_HELPER"',
                invocation.replace("\\", ""),
            )
            self.assertIn("clodex:openai-oauth:", invocation)
            self.assertIn('"$CLODEX_CCS_RUNTIME_HELPER" --check', invocation)
            self.assertIn("CLAUDE_VPS_TMUX_SESSION=claude-vps-clodex", invocation)
            self.assertNotIn("tmux new-session", invocation)

    def test_statusline_command_formats_claude_json(self):
        payload = {
            "model": {"display_name": "Fable 5"},
            "workspace": {
                "current_dir": "/home/signul/SIGNUL",
                "git_branch": "source-mesh",
            },
            "context_window": {"used_percentage": 42},
            "rate_limits": {"five_hour": {"used_percentage": 17}},
            "cost": {"total_cost_usd": 1.23},
        }

        result = subprocess.run(
            ["bash", str(STATUSLINE_SCRIPT)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertEqual(
            result.stdout,
            "Fable 5 | /home/signul/SIGNUL | git:source-mesh | ctx:42% | 5h:17% | cost:$1.23",
        )

    def test_preferred_title_selects_newest_exact_match_not_newest_file(self):
        function = self._resolver_function()
        with tempfile.TemporaryDirectory() as raw_temp:
            home = pathlib.Path(raw_temp)
            project = home / ".claude" / "projects" / "-home-signul-SIGNUL"
            project.mkdir(parents=True)
            fixtures = {
                "older-match": ("latest working thread -- readiness prep", 100),
                "newer-match": ("  Latest   Working Thread -- Readiness Prep  ", 200),
                "global-newest": ("Signul + Source Mesh latest work to readiness", 300),
            }
            for session_id, (title, mtime) in fixtures.items():
                path = project / f"{session_id}.jsonl"
                path.write_text(
                    json.dumps({"type": "custom-title", "customTitle": title}) + "\n"
                )
                os.utime(path, (mtime, mtime))

            script = f"""
{function}
REMOTE_REPO=/home/signul/SIGNUL
CLAUDE_VPS_PREFERRED_SESSION_TITLE='latest working thread -- readiness prep'
resolve_latest_repo_session_id
"""
            result = subprocess.run(
                ["bash"],
                input=script,
                text=True,
                capture_output=True,
                check=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(result.stdout, "newer-match\n")

    def test_preferred_title_missing_fails_closed(self):
        function = self._resolver_function()
        with tempfile.TemporaryDirectory() as raw_temp:
            home = pathlib.Path(raw_temp)
            project = home / ".claude" / "projects" / "-home-signul-SIGNUL"
            project.mkdir(parents=True)
            path = project / "other-session.jsonl"
            path.write_text(
                json.dumps({"type": "custom-title", "customTitle": "other thread"}) + "\n"
            )

            script = f"""
{function}
REMOTE_REPO=/home/signul/SIGNUL
CLAUDE_VPS_PREFERRED_SESSION_TITLE='latest working thread -- readiness prep'
resolve_latest_repo_session_id
"""
            result = subprocess.run(
                ["bash"],
                input=script,
                text=True,
                capture_output=True,
                check=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(
                result.stdout,
                "__CLAUDE_VPS_PREFERRED_TITLE_NOT_FOUND__\n",
            )

    def test_empty_preferred_title_uses_newest_file(self):
        function = self._resolver_function()
        with tempfile.TemporaryDirectory() as raw_temp:
            home = pathlib.Path(raw_temp)
            project = home / ".claude" / "projects" / "-home-signul-SIGNUL"
            project.mkdir(parents=True)
            older = project / "older.jsonl"
            newer = project / "newer.jsonl"
            older.write_text("{}\n")
            newer.write_text("{}\n")
            os.utime(older, (100, 100))
            os.utime(newer, (200, 200))

            script = f"""
{function}
REMOTE_REPO=/home/signul/SIGNUL
CLAUDE_VPS_PREFERRED_SESSION_TITLE=''
resolve_latest_repo_session_id
"""
            result = subprocess.run(
                ["bash"],
                input=script,
                text=True,
                capture_output=True,
                check=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(result.stdout, "newer\n")

    def test_latest_session_preserves_mismatched_live_managed_pane(self):
        function = self._select_latest_function()
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            calls = temp / "tmux-calls"
            tmux = temp / "tmux"
            tmux.write_text(
                """#!/usr/bin/env bash
set -eu
case "$1" in
  has-session)
    case "$*" in
      *claude-vps-preserved-*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  list-panes) printf '0\\n' ;;
  rename-session) printf '%s\\n' "$*" >> "$TMUX_CALLS" ;;
  *) exit 2 ;;
esac
"""
            )
            tmux.chmod(0o755)
            script = f"""
resolve_latest_repo_session_id() {{ printf 'session-123\\n'; }}
resolve_live_session_owner() {{ printf 'none\\n'; }}
{function}
CLAUDE_VPS_AUTO_CONTINUE=1
CLAUDE_VPS_TMUX_SESSION=claude-vps
select_latest_managed_session
printf 'session=%s resume=%s\\n' "$CLAUDE_VPS_TMUX_SESSION" "$CLAUDE_VPS_RESUME_SESSION_ID"
"""
            env = {
                **os.environ,
                "PATH": f"{temp}:{os.environ['PATH']}",
                "TMUX_CALLS": str(calls),
            }
            result = subprocess.run(
                ["bash"],
                input=script,
                text=True,
                capture_output=True,
                check=True,
                env=env,
            )

            self.assertIn("session=claude-vps resume=session-123", result.stdout)
            self.assertIn("preserved mismatched live pane", result.stderr)
            self.assertRegex(
                calls.read_text(),
                r"rename-session -t claude-vps claude-vps-preserved-\d{8}T\d{6}",
            )

    def test_latest_session_reuses_exact_managed_owner(self):
        function = self._select_latest_function()
        script = f"""
resolve_latest_repo_session_id() {{ printf 'session-123\\n'; }}
resolve_live_session_owner() {{ printf 'tmux:claude-vps\\n'; }}
{function}
CLAUDE_VPS_AUTO_CONTINUE=1
CLAUDE_VPS_TMUX_SESSION=claude-vps
select_latest_managed_session
printf 'session=%s resume=%s\\n' "$CLAUDE_VPS_TMUX_SESSION" "$CLAUDE_VPS_RESUME_SESSION_ID"
"""
        result = subprocess.run(
            ["bash"],
            input=script,
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertEqual(result.stdout, "session=claude-vps resume=\n")

    def _registered_owner(self, records, requested="current", extra_pane=False):
        text = SCRIPT.read_text()
        start = text.index("resolve_live_session_owner() {")
        end = text.index("\nselect_latest_managed_session()", start)
        code = text[start:end].split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        real_path = pathlib.Path
        with tempfile.TemporaryDirectory() as raw_temp:
            root = real_path(raw_temp)
            home = root / "home"
            registrations = home / ".claude" / "sessions"
            registrations.mkdir(parents=True)
            stats = []
            for pid in (101, 102):
                proc = root / "proc" / str(pid)
                proc.mkdir(parents=True)
                fields = ["S", "1"] + ["0"] * 17 + ["12345"]
                (proc / "stat").write_text(f"{pid} (claude) " + " ".join(fields))
                (proc / "cmdline").write_bytes(b"claude\0--resume\0original\0")
                stats.append(str(proc / "stat"))
            for pid, session, ticks in records:
                (registrations / f"{pid}.json").write_text(json.dumps({
                    "pid": pid, "sessionId": session, "procStart": ticks,
                }))

            def mapped_path(value):
                value = str(value)
                return root / value.lstrip("/") if value.startswith("/proc/") else real_path(value)

            output = io.StringIO()
            panes = "claude-vps\t101\n"
            if extra_pane:
                panes += "other-session\t102\n"
            with mock.patch("pathlib.Path", side_effect=mapped_path) as path_mock, \
                 mock.patch("glob.glob", return_value=stats), \
                 mock.patch("subprocess.check_output", return_value=panes), \
                 mock.patch("sys.argv", ["-", requested, "claude-vps"]), \
                 contextlib.redirect_stdout(output):
                path_mock.home.return_value = home
                try:
                    exec(compile(code, "owner-resolver", "exec"), {})
                except SystemExit as exc:
                    self.assertEqual(exc.code, 0)
            return output.getvalue().strip()

    def test_live_registration_follows_in_process_thread_switch(self):
        self.assertEqual(self._registered_owner([(101, "current", "12345")]), "tmux:claude-vps")
        self.assertEqual(self._registered_owner([(101, "current", "12345"), (102, "elsewhere", "12345")], requested="original"), "none")

    def test_stale_registration_cannot_claim_reused_pid(self):
        self.assertEqual(self._registered_owner([(101, "current", "old-start")]), "none")

    def test_existing_managed_attach_allowed_with_external_owner(self):
        records = [(101, "current", "12345"), (102, "current", "12345")]
        self.assertEqual(self._registered_owner(records), "tmux:claude-vps")
        self.assertEqual(self._registered_owner(records, extra_pane=True), "ambiguous")

    def test_registered_external_owner_blocks_new_resume(self):
        self.assertEqual(self._registered_owner([(102, "current", "12345")]), "external")

    def test_latest_session_refuses_external_concurrent_owner(self):
        function = self._select_latest_function()
        script = f"""
resolve_latest_repo_session_id() {{ printf 'session-123\\n'; }}
resolve_live_session_owner() {{ printf 'external\\n'; }}
{function}
CLAUDE_VPS_AUTO_CONTINUE=1
CLAUDE_VPS_TMUX_SESSION=claude-vps
select_latest_managed_session
"""
        result = subprocess.run(
            ["bash"],
            input=script,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 73)
        self.assertIn("refusing concurrent resume", result.stderr)

    def test_resume_identity_is_bound_into_cold_tmux_launch_command(self):
        function = self._resume_launch_binding_function()
        script = f"""
{function}
CLAUDE_VPS_RESUME_SESSION_ID=session-123
bind_resume_to_launch_command 'exec claude'
"""
        result = subprocess.run(
            ["bash"],
            input=script,
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertEqual(
            result.stdout,
            "export CLAUDE_VPS_RESUME_SESSION_ID=session-123; exec claude",
        )

    def test_cold_tmux_capability_probes_suppress_missing_server_noise(self):
        text = SCRIPT.read_text()

        for option in ("terminal-features", "terminal-overrides"):
            self.assertIn(
                f"tmux show-options -gqv {option} 2>/dev/null | grep",
                text,
            )
            self.assertNotIn(
                f"tmux show-options -gqv {option} | grep",
                text,
            )

    def test_transcript_helper_is_valid_python(self):
        subprocess.run(
            ["python3", "-m", "py_compile", str(TRANSCRIPT_SCRIPT)],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
