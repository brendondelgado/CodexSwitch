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
        self.assertIn('REMOTE_TMUX_SESSION="${CLAUDE_VPS_TMUX_SESSION:-claude-vps}"', text)
        self.assertIn('REMOTE_TMUX_HISTORY_LIMIT="${CLAUDE_VPS_TMUX_HISTORY_LIMIT:-200000}"', text)
        self.assertIn("CODEXSWITCH_REMOTE_TTY_ROWS", text)
        self.assertIn("stty rows", text)
        self.assertIn("tmux new-session -d", text)
        self.assertIn("history-limit", text)
        self.assertIn("mouse on", text)
        self.assertIn("status off", text)
        self.assertIn("alternate-screen off", text)
        self.assertIn("tmux attach-session", text)
        self.assertNotIn("strict-mcp-config", text)
        self.assertNotIn("mcp-config", text)
        self.assertIn('exec ssh -tt "${selected_ssh_opts[@]}" "$selected_host"', text)
        self.assertIn('exec \\"\\$REMOTE_CLAUDE\\" \\"\\$@\\"', text)


if __name__ == "__main__":
    unittest.main()
