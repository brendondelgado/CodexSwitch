#!/usr/bin/env python3
import json
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "claude-vps"
STATUSLINE_SCRIPT = ROOT / "scripts" / "claude-vps-statusline.sh"
TRANSCRIPT_SCRIPT = ROOT / "scripts" / "claude-vps-transcript"


class ClaudeVPSScriptTests(unittest.TestCase):
    def test_connects_to_remote_claude_code_without_ssh_mux(self):
        text = SCRIPT.read_text()

        for option in (
            "-o ControlMaster=no",
            "-o ControlPath=none",
            "-o ControlPersist=no",
        ):
            self.assertIn(option, text)

        self.assertIn('REMOTE_HOST="${CLAUDE_VPS_REMOTE_HOST:-signul-vps}"', text)
        self.assertIn('TAILSCALE_HOST="${CLAUDE_VPS_TAILSCALE_HOST:-signul-hostinger-kvm4}"', text)
        self.assertIn('TAILSCALE_TARGET_IP="${CLAUDE_VPS_TAILSCALE_TARGET_IP:-100.95.84.123}"', text)
        self.assertIn('-o "ProxyCommand=${TAILSCALE_BIN} nc %h %p"', text)
        self.assertIn('MOSH_BIN="${CLAUDE_VPS_MOSH_BIN:-mosh}"', text)
        self.assertIn('MOSH_PREDICT="${CLAUDE_VPS_MOSH_PREDICT:-never}"', text)
        self.assertIn('SESSION_TRANSPORT_REQUESTED="${CLAUDE_VPS_TRANSPORT:-auto}"', text)
        self.assertIn('REMOTE_REPO="${CLAUDE_VPS_REMOTE_REPO:-/home/signul/SIGNUL}"', text)
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
        self.assertIn('REMOTE_DANGEROUSLY_SKIP_PERMISSIONS="${CLAUDE_VPS_DANGEROUSLY_SKIP_PERMISSIONS:-0}"', text)
        self.assertIn('REMOTE_TMUX_SESSION="${CLAUDE_VPS_TMUX_SESSION:-claude-vps}"', text)
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
        self.assertIn('REMOTE_CLAUDE_DISABLE_ALTERNATE_SCREEN="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-1}"', text)
        self.assertIn('REMOTE_CLAUDE_SCROLL_SPEED="${CLAUDE_VPS_CLAUDE_CODE_SCROLL_SPEED:-3}"', text)
        self.assertIn('REMOTE_CLAUDE_DISABLE_MOUSE="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_MOUSE:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_DISABLE_VIRTUAL_SCROLL="${CLAUDE_VPS_CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL:-0}"', text)
        self.assertIn('REMOTE_CLAUDE_STATUSLINE="${CLAUDE_VPS_CLAUDE_STATUSLINE:-1}"', text)
        self.assertIn('SSH_SERVER_ALIVE_INTERVAL="${CLAUDE_VPS_SERVER_ALIVE_INTERVAL:-30}"', text)
        self.assertIn('SSH_SERVER_ALIVE_COUNT_MAX="${CLAUDE_VPS_SERVER_ALIVE_COUNT_MAX:-6}"', text)
        self.assertIn('SSH_AUTO_RECONNECT="${CLAUDE_VPS_AUTO_RECONNECT:-1}"', text)
        self.assertIn('SSH_RECONNECT_DELAY="${CLAUDE_VPS_RECONNECT_DELAY:-2}"', text)
        self.assertIn('SSH_RECONNECT_MAX="${CLAUDE_VPS_RECONNECT_MAX:-0}"', text)
        self.assertIn('SYNC_DESKTOP_SESSION_INDEX="${CLAUDE_VPS_SYNC_DESKTOP_SESSION_INDEX:-1}"', text)
        self.assertIn('REMOTE_RESPAWN_PANE="${CLAUDE_VPS_RESPAWN_PANE:-0}"', text)
        self.assertIn("--remote-control|--rc|--web", text)
        self.assertIn("--tmux|--persistent", text)
        self.assertIn("--raw|--no-tmux|--terminal|--tui", text)
        self.assertIn("-yolo|--yolo|--dangerously-skip-permissions", text)
        self.assertIn("--fullscreen", text)
        self.assertIn("--classic|--native-scrollback", text)
        self.assertIn("--repair-scrollback|--respawn-pane", text)
        self.assertIn("REMOTE_CONTROL_DEFAULT=0", text)
        self.assertIn("remote_session_snapshot_script()", text)
        self.assertIn("refresh_claude_desktop_session_index()", text)
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
        self.assertIn("#{pane_dead}", text)
        self.assertIn("tmux respawn-pane -k", text)
        self.assertIn("recreating tmux session with history-limit", text)
        self.assertIn("claude-vps: respawning dead tmux pane", text)
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

    def test_transcript_helper_is_valid_python(self):
        subprocess.run(
            ["python3", "-m", "py_compile", str(TRANSCRIPT_SCRIPT)],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
