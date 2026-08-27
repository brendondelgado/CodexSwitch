#!/usr/bin/env python3
import os
import pathlib
import io
import subprocess
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CS_SEND_DIR = ROOT / "scripts" / "securedrop" / "cs-send-dir"
CS_EXTRACT = ROOT / "scripts" / "securedrop" / "cs-extract"
CS_AUTOPULL = ROOT / "scripts" / "securedrop" / "cs-autopull"
CS_AUTOPUSH = ROOT / "scripts" / "securedrop" / "cs-autopush"
CS_AUTOPUSH_LOOP = ROOT / "scripts" / "securedrop" / "cs-autopush-loop"
INSTALL_MACOS_AUTOPUSH = ROOT / "scripts" / "securedrop" / "install-macos-autopush"
KNOWLEDGE_SYNC = ROOT / "scripts" / "securedrop" / "knowledge-sync"


class SecureDropScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = pathlib.Path(self.temp_dir.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "item.txt").write_text("payload")
        self.local_root = self.root / "local"
        self.remote_root = self.root / "remote"

    def run_send_dir(self, *args):
        env = os.environ.copy()
        env.update(
            {
                "CODEXSWITCH_SECUREDROP_LOCAL_ROOT": str(self.local_root),
                "CS_SECUREDROP_TEST_REMOTE_ROOT": str(self.remote_root),
            }
        )
        return subprocess.run(
            [str(CS_SEND_DIR), "--local-test", str(self.source), *args],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_directory_name_uses_conservative_archive_characters(self):
        result = self.run_send_dir("safe-name_1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.remote_root / "inbox" / "safe-name_1.0.tar").exists())

    def test_shell_active_archive_name_is_rejected_before_transfer(self):
        marker = pathlib.Path("/tmp/cs-send-dir-injected")
        marker.unlink(missing_ok=True)
        self.addCleanup(lambda: marker.unlink(missing_ok=True))

        result = self.run_send_dir("x'; touch /tmp/cs-send-dir-injected; #")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid name", result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((self.remote_root / "inbox").exists())

    def run_extract(self, archive):
        target = self.root / "extract-target"
        return subprocess.run(
            [str(CS_EXTRACT), str(archive), "--target", str(target)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_extract_rejects_parent_traversal_before_writing(self):
        archive = self.root / "traversal.tar"
        payload = b"escaped"
        with tarfile.open(archive, "w") as handle:
            info = tarfile.TarInfo("safe/../../escaped.txt")
            info.size = len(payload)
            handle.addfile(info, io.BytesIO(payload))

        result = self.run_extract(archive)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe archive path", result.stderr)
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_extract_rejects_links_before_writing(self):
        archive = self.root / "link.tar"
        with tarfile.open(archive, "w") as handle:
            directory = tarfile.TarInfo("safe")
            directory.type = tarfile.DIRTYPE
            handle.addfile(directory)
            link = tarfile.TarInfo("safe/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "/tmp/codexswitch-link-target"
            handle.addfile(link)

        result = self.run_extract(archive)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("links and special files", result.stderr)

    def test_extract_accepts_one_safe_directory(self):
        archive = self.root / "safe.tar"
        payload = b"payload"
        with tarfile.open(archive, "w") as handle:
            directory = tarfile.TarInfo("safe")
            directory.type = tarfile.DIRTYPE
            handle.addfile(directory)
            info = tarfile.TarInfo("safe/item.txt")
            info.size = len(payload)
            handle.addfile(info, io.BytesIO(payload))

        result = self.run_extract(archive)

        self.assertEqual(result.returncode, 0, result.stderr)
        extracted = pathlib.Path(result.stdout.strip())
        self.assertEqual((extracted / "item.txt").read_bytes(), payload)

    def test_knowledge_sync_rejects_identical_endpoints_before_hashing(self):
        knowledge = self.root / "knowledge"
        knowledge.mkdir()
        (knowledge / "large.txt").write_text("payload")
        state = self.root / "state"

        result = subprocess.run(
            [
                str(KNOWLEDGE_SYNC),
                "--local-test",
                "--side",
                "vps",
                "--local",
                str(knowledge),
                "--remote",
                str(knowledge),
                "--state-dir",
                str(state),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("same directory", result.stderr)
        self.assertFalse((knowledge / ".sync-index.tsv").exists())
        self.assertFalse((knowledge / ".synclog.jsonl").exists())

    def test_autopull_remote_delete_cannot_consume_the_file_list(self):
        script = CS_AUTOPULL.read_text()

        self.assertIn(
            'ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "$delete_cmd"',
            script,
        )

    def test_autopush_fails_closed_on_missing_helper_arguments(self):
        script = CS_AUTOPUSH.read_text()

        self.assertIn('local remote_path="${1-}"', script)
        self.assertIn('local file="${1-}"', script)
        self.assertIn('local name="${1-}"', script)
        self.assertIn('autopush-incomplete failures=', script)
        self.assertNotIn('ssh -o BatchMode=yes', script)
        self.assertIn('ssh -n -o BatchMode=yes', script)
        self.assertIn('-e ssh', script)
        self.assertIn('done 3< <(find "$SRC" -maxdepth 1 -type f -print0) <&3', script)

    def test_macos_autopush_agent_has_interval_and_outbox_demand_sources(self):
        script = INSTALL_MACOS_AUTOPUSH.read_text()

        self.assertIn("<key>StartInterval</key>", script)
        self.assertIn("<key>WatchPaths</key>", script)
        self.assertIn("<key>KeepAlive</key>", script)
        self.assertNotIn("<key>SuccessfulExit</key>", script)
        self.assertIn("<key>ThrottleInterval</key>", script)
        self.assertIn('launchctl bootstrap "gui/$uid" "$plist_path"', script)
        self.assertIn("for attempt in 1 2 3", script)

    def test_autopush_loop_owns_cadence_instead_of_launchd_rescheduling(self):
        script = CS_AUTOPUSH_LOOP.read_text()

        self.assertIn("while [ \"$stop\" -eq 0 ]", script)
        self.assertIn('sleep "$INTERVAL" &', script)
        self.assertIn("trap 'stop=1' INT TERM HUP", script)
        self.assertNotIn("rm ", script)
        installer = INSTALL_MACOS_AUTOPUSH.read_text()
        self.assertIn('<string>$loop_path</string>', installer)


if __name__ == "__main__":
    unittest.main()
