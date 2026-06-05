#!/usr/bin/env python3
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "claude-vps"


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
        self.assertIn('-o "ProxyCommand=${TAILSCALE_BIN} nc %h %p"', text)
        self.assertIn('REMOTE_REPO="${CLAUDE_VPS_REMOTE_REPO:-/home/signul/SIGNUL}"', text)
        self.assertIn('REMOTE_CLAUDE="${CLAUDE_VPS_REMOTE_CLAUDE:-/home/signul/.local/bin/claude}"', text)
        self.assertIn('REMOTE_TERM="${CLAUDE_VPS_REMOTE_TERM:-xterm-256color}"', text)
        self.assertIn('REMOTE_COLORTERM="${CLAUDE_VPS_REMOTE_COLORTERM:-truecolor}"', text)
        self.assertIn('REMOTE_FORCE_COLOR="${CLAUDE_VPS_FORCE_COLOR:-3}"', text)
        self.assertIn('REMOTE_AUTO_CONTINUE="${CLAUDE_VPS_AUTO_CONTINUE:-1}"', text)
        self.assertIn('REMOTE_TMUX_SESSION="${CLAUDE_VPS_TMUX_SESSION:-claude-vps}"', text)
        self.assertIn('REMOTE_TMUX_HISTORY_LIMIT="${CLAUDE_VPS_TMUX_HISTORY_LIMIT:-200000}"', text)
        self.assertIn('REMOTE_TMUX_TERM="${CLAUDE_VPS_TMUX_TERM:-tmux-256color}"', text)
        self.assertIn("CODEXSWITCH_REMOTE_TTY_ROWS", text)
        self.assertIn("stty rows", text)
        self.assertIn("tmux new-session -d", text)
        self.assertIn("default-terminal", text)
        self.assertIn("terminal-features", text)
        self.assertIn("terminal-overrides", text)
        self.assertIn("set-environment", text)
        self.assertIn("set-environment -g CLAUDE_VPS_AUTO_CONTINUE", text)
        self.assertIn("set-environment -g CLAUDE_VPS_CONTINUE_ARG", text)
        self.assertIn('FORCE_COLOR=%s', text)
        self.assertIn('CLAUDE_VPS_AUTO_CONTINUE=%s', text)
        self.assertIn('CLAUDE_VPS_CONTINUE_ARG=%s', text)
        self.assertIn("history-limit", text)
        self.assertIn("mouse on", text)
        self.assertIn("status off", text)
        self.assertIn("alternate-screen on", text)
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
        self.assertIn("--continue", text)
        self.assertIn('\\"\\$REMOTE_CLAUDE\\" \\"\\$@\\"', text)
        self.assertNotIn("strict-mcp-config", text)
        self.assertNotIn("mcp-config", text)
        self.assertIn('exec ssh -tt "${selected_ssh_opts[@]}" "$selected_host"', text)
        self.assertIn('exec env TERM=\\"\\$TERM\\" COLORTERM=\\"\\$REMOTE_COLORTERM\\" FORCE_COLOR=\\"\\$REMOTE_FORCE_COLOR\\" \\"\\$REMOTE_CLAUDE\\" \\"\\$@\\"', text)


if __name__ == "__main__":
    unittest.main()
