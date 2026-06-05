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
        self.assertNotIn("strict-mcp-config", text)
        self.assertNotIn("mcp-config", text)
        self.assertIn('exec ssh -tt "${selected_ssh_opts[@]}" "$selected_host"', text)
        self.assertIn('exec \\"\\$REMOTE_CLAUDE\\" \\"\\$@\\"', text)


if __name__ == "__main__":
    unittest.main()
