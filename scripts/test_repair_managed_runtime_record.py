import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import socket
import struct

spec = importlib.util.spec_from_file_location("repair", Path(__file__).with_name("repair-managed-runtime-record.py"))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class Probe:
    pid = 456
    state = "same-identity"
    dead = True
    def observe(self):
        return self.state
    def absent(self, pid):
        return self.dead


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.record = self.home / ".codex/app-server-daemon/app-server.pid"
        paths = [".codex/app-server-daemon/app-server.pid.lock",
                 ".codex/app-server-control/app-server-startup.lock",
                 ".codexswitch/accounts.runtime-activation.lock",
                 ".local/share/codexswitch/runtime-start-install.lock"]
        for path in paths:
            file = self.home / path
            file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            file.touch(mode=0o600)
        self.data = json.dumps({"pid": 123, "processStartTime": "old"}).encode()
        self.record.write_bytes(self.data)
        self.record.chmod(0o600)
        self.probe = Probe()

    def execute(self, apply=False, before_commit=lambda: None):
        return repair.repair(self.home, self.probe, 123, apply, before_commit,
                             hashlib.sha256(self.data).hexdigest())

    def test_dry_run_is_nonmutating(self):
        result = self.execute()
        self.assertEqual(result["status"], "repairable")
        self.assertEqual(self.record.read_bytes(), self.data)
        self.assertFalse((self.home / ".codexswitch/backups").exists())

    def test_quarantine_and_replay(self):
        result = self.execute(True)
        self.assertEqual(result["status"], "repaired")
        self.assertFalse(self.record.exists())
        backup = Path(result["backup"])
        self.assertEqual(backup.read_bytes(), self.data)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.execute(True)["status"], "already-clear")

    def test_reused_or_live_pid_refused(self):
        self.probe.dead = False
        with self.assertRaises(repair.Refused):
            self.execute(True)
        self.assertTrue(self.record.exists())

    def test_live_owner_record_refused(self):
        self.record.write_text(json.dumps({"pid": self.probe.pid}))
        with self.assertRaises(repair.Refused):
            self.execute(True)

    def test_identity_drift_refused(self):
        with self.assertRaises(repair.Refused):
            self.execute(True, lambda: setattr(self.probe, "state", "changed-start-time"))
        self.assertTrue(self.record.exists())

    def test_record_replacement_refused(self):
        def replace():
            self.record.unlink()
            self.record.write_bytes(self.data)
        with self.assertRaises(repair.Refused):
            self.execute(True, replace)
        self.assertTrue(self.record.exists())

    def test_record_symlink_refused(self):
        other = self.home / "other"
        self.record.rename(other)
        self.record.symlink_to(other)
        with self.assertRaises(repair.Refused):
            self.execute(True)
        self.assertEqual(other.read_bytes(), self.data)

    def test_lock_contention_refused(self):
        with self.record.with_name("app-server.pid.lock").open("r+") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.execute(True)
        self.assertTrue(self.record.exists())

    def test_lock_replacement_refused(self):
        path = self.record.with_name("app-server.pid.lock")
        def replace():
            path.unlink()
            path.touch(mode=0o600)
        with self.assertRaises(repair.Refused):
            self.execute(True, replace)
        self.assertTrue(self.record.exists())

    def test_nonprivate_backup_refused(self):
        backup = self.home / ".codexswitch/backups"
        backup.mkdir(mode=0o755)
        with self.assertRaises(repair.Refused):
            self.execute(True)
        self.assertTrue(self.record.exists())

    def test_unapproved_stale_pid_refused(self):
        self.record.write_text(json.dumps({"pid": 124}))
        with self.assertRaises(repair.Refused):
            self.execute(True)

    def test_unapproved_record_digest_refused(self):
        self.record.write_text(json.dumps({"pid": 123, "processStartTime": "other"}))
        with self.assertRaises(repair.Refused):
            self.execute(True)

    def test_bounded_reader_handles_short_reads_until_eof(self):
        with patch.object(repair.os, "read", side_effect=[b"codex\0", b"app-", b"server\0", b""]):
            data, _ = repair.read_bounded(self.record)
        self.assertIn(b"app-server", repair.command_arguments(data))

    def test_bounded_reader_rejects_excess_across_reads(self):
        with patch.object(repair.os, "read", side_effect=[b"abc", b"de"]):
            with self.assertRaises(repair.Refused):
                repair.read_bounded(self.record, 4)

    def test_empty_or_truncated_command_is_not_irrelevance_proof(self):
        for data in (b"", b"codex\0app-ser", b"\0"):
            with self.assertRaises(repair.Refused):
                repair.command_arguments(data)


class LiveProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.proc = self.home / "proc"
        self.probe = repair.LiveProbe(self.home, 456, "a" * 40, self.proc)
        self.probe.runtime.parent.mkdir(parents=True)
        self.probe.runtime.write_bytes(b"fixture")
        (self.probe.root / "current").symlink_to(self.probe.release)
        self.probe.control.parent.mkdir(parents=True)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.probe.control))
        self.addCleanup(self.server.close)
        self.add_process(456)
        self.peer = (456, os.geteuid(), os.getegid())

    def add_process(self, pid, remote=False):
        path = self.proc / str(pid)
        path.mkdir(parents=True)
        (path / "exe").symlink_to(self.probe.runtime)
        (path / "stat").write_bytes(b"456 (codex) S " + b"0 " * 18 + b"77 0\n")
        args = [os.fsencode(self.probe.route), b"app-server"]
        if remote:
            args.append(b"--remote-control")
        args.extend([b"--listen", b"unix://"])
        (path / "cmdline").write_bytes(b"\0".join(args) + b"\0")
        (path / "environ").write_bytes(b"HOME=" + os.fsencode(self.home) + b"\0")

    def observe(self, connect_effect=None):
        with patch.object(repair.socket, "SO_PEERCRED", 17, create=True), \
                patch.object(repair.socket, "socket") as factory:
            client = factory.return_value.__enter__.return_value
            client.getsockopt.return_value = struct.pack("3i", *self.peer)
            client.connect.side_effect = connect_effect
            return self.probe.observe()

    def test_real_probe_accepts_exact_owner(self):
        self.assertEqual(self.observe()[0], b"77")

    def test_remote_control_form(self):
        path = self.proc / "456/cmdline"
        path.write_bytes(path.read_bytes().replace(b"app-server\0", b"app-server\0--remote-control\0"))
        self.observe()

    def test_wrong_peer_pid_and_uid(self):
        for peer in [(457, os.geteuid(), os.getegid()), (456, os.geteuid() + 1, os.getegid())]:
            self.peer = peer
            with self.assertRaises(repair.Refused):
                self.observe()

    def test_competing_runtime(self):
        self.add_process(457)
        with self.assertRaises(repair.Refused):
            self.observe()

    def test_proxy_and_daemon_commands_are_not_account_bearing(self):
        self.add_process(457)
        command = self.proc / "457/cmdline"
        for subcommand in (b"proxy", b"daemon"):
            command.write_bytes(os.fsencode(self.probe.route) + b"\0app-server\0" + subcommand + b"\0")
            self.observe()

    def test_changed_release(self):
        current = self.probe.root / "current"
        current.unlink()
        current.symlink_to(self.home)
        with self.assertRaises(repair.Refused):
            self.observe()

    def test_start_time_changes_during_observation(self):
        def change(_):
            path = self.proc / "456/stat"
            path.write_bytes(path.read_bytes().replace(b"77 0", b"88 0"))
        with self.assertRaises(repair.Refused):
            self.observe(change)

    def test_wrong_home(self):
        other = self.home / "foreign"
        (other / ".codex").mkdir(parents=True)
        (self.proc / "456/environ").write_bytes(b"HOME=" + os.fsencode(other) + b"\0")
        with self.assertRaises(repair.Refused):
            self.observe()

    def test_executable_replacement(self):
        other = self.home / "other"
        other.write_bytes(b"other")
        exe = self.proc / "456/exe"
        exe.unlink()
        exe.symlink_to(other)
        with self.assertRaises(repair.Refused):
            self.observe()

    def test_inaccessible_unrelated_executable_is_not_a_runtime(self):
        path = self.proc / "1180"
        path.mkdir()
        command = path / "cmdline"
        command.write_bytes(b"/usr/lib/systemd/systemd\0--user\0")
        original = Path.stat
        def inspect(candidate, *args, **kwargs):
            if candidate == path / "exe":
                raise PermissionError("fixture")
            return original(candidate, *args, **kwargs)
        with patch.object(Path, "stat", inspect):
            self.observe()
            for data in (b"codex\0app-server\0--listen\0unix://\0", b"", b"systemd"):
                command.write_bytes(data)
                with self.assertRaises(repair.Refused):
                    self.observe()


if __name__ == "__main__":
    unittest.main()
