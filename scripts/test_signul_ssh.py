#!/usr/bin/env python3
import pathlib
import stat
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "signul"


class SignulSSHScriptTests(unittest.TestCase):
    def test_signul_ssh_opens_protected_normalized_tty(self):
        text = SCRIPT.read_text()
        mode = SCRIPT.stat().st_mode

        self.assertTrue(mode & stat.S_IXUSR)
        self.assertIn('REMOTE_HOST="${SIGNUL_SSH_REMOTE_HOST:-signul-vps}"', text)
        self.assertIn('REMOTE_REPO="${SIGNUL_SSH_REMOTE_REPO:-/home/signul/SIGNUL}"', text)
        self.assertIn('REMOTE_TERM="${SIGNUL_SSH_REMOTE_TERM:-xterm-256color}"', text)
        self.assertIn('REMOTE_COLORTERM="${SIGNUL_SSH_REMOTE_COLORTERM:-truecolor}"', text)
        self.assertIn("-o ControlMaster=no", text)
        self.assertIn("-o ControlPath=none", text)
        self.assertIn("-o ControlPersist=no", text)
        self.assertIn("CODEXSWITCH_REMOTE_TTY_ROWS", text)
        self.assertIn("stty rows", text)
        self.assertIn('exec ssh -tt "${selected_ssh_opts[@]}" "$selected_host"', text)


if __name__ == "__main__":
    unittest.main()
