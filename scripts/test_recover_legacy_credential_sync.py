#!/usr/bin/env python3
"""Offline fixtures only: no SSH, provider requests, or user credential files."""

import contextlib
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import time
import unittest
import uuid
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "legacy_recovery", Path(__file__).with_name("recover-legacy-credential-sync.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(value if isinstance(value, bytes) else json.dumps(value).encode())
    path.chmod(0o600)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "local"
        self.private = self.home / ".codexswitch"
        self.private.mkdir(parents=True, mode=0o700)
        self.stage_root = self.root / "stage"
        self.stage_root.mkdir(mode=0o700)
        self.id = str(uuid.uuid4())
        self.target = "a" * 64
        self.op = {"version": 2, "operationID": self.id, "targetFingerprint": self.target,
                   "credentialFingerprint": "b" * 64,
                   "expectedAccountIdentityFingerprint": "c" * 64,
                   "expectedCredentialSetFingerprint": "d" * 64,
                   "expectedActiveProviderAccountId": "old-provider",
                   "expectedActiveTokenHashPrefix": "e" * 12,
                   "baselineAccountIdentityFingerprint": "f" * 64,
                   "baselineCredentialSetFingerprint": "1" * 64,
                   "baselineActiveProviderAccountId": "old-provider",
                   "baselineActiveTokenHashPrefix": "2" * 12,
                   "baselineAuthMatchesActiveStoreToken": True,
                   "localDirectory": str(self.stage_root / ("codexswitch-linux-credential-sync-" + self.id)),
                   "remoteDirectory": "/tmp/codexswitch-auto-sync-" + self.id,
                   "createdAt": "2026-09-09T00:00:00Z", "phase": "unresolved",
                   "reason": "legacy lost reply"}
        self.journal = self.private / "linux-devbox-credential-sync.json"
        write(self.journal, self.op)
        write(self.private / "codexswitch-app.lock", b"old-pid\n")
        write(Path(str(self.journal) + ".lock"), b"")
        self.remote = self.root / "remote"
        self.rprivate = self.remote / ".codexswitch"
        self.rprivate.mkdir(parents=True, mode=0o700)
        self.runtime = self.remote / ".local/share/codexswitch"
        self.release = self.runtime / "releases/fixture"
        self.release.mkdir(parents=True, mode=0o700)
        write(self.release / "codexswitch-cli", b"fixture-cli")
        (self.runtime / "current").symlink_to(self.release)
        for path in M.remote_lock_paths(self.remote):
            write(path[0], b"")
        self.account = {"id": str(uuid.uuid4()), "accountId": "current-provider", "isActive": True,
                        "idToken": "FIXTURE-ID-SECRET", "accessToken": "FIXTURE-ACCESS-SECRET",
                        "refreshToken": "FIXTURE-REFRESH-SECRET"}
        write(self.rprivate / "accounts.json", [self.account])
        write(self.remote / ".codex/auth.json", {"tokens": {
            "account_id": self.account["accountId"], "id_token": self.account["idToken"],
            "access_token": self.account["accessToken"], "refresh_token": self.account["refreshToken"]}})
        write(self.rprivate / "pool-authority.json", {
            "version": 1, "epoch": 42, "phase": "stable", "desiredProviderAccountId": "current-provider",
            "requestId": str(uuid.uuid4()), "rotationOperations": []})
        write(self.rprivate / "accounts.activation.json", {
            "version": 3, "state": "confirmed", "kind": "rotation", "targetAccountId": "current-provider",
            "authFingerprint": M.token_fingerprint(self.account), "rollback": None})
        self.scan = lambda *args: None
        self.guard = M.RemoteGuard(self.remote, self.release, self.id, self.target, self.scan)

    def tearDown(self):
        self.temp.cleanup()

    @contextlib.contextmanager
    def local(self):
        with M.LocalGuard(self.home, self.target, self.stage_root, self.scan) as guard:
            yield guard

    def test_review_is_read_only_and_success_preserves_exact_unknown_journal(self):
        original = self.journal.read_bytes()
        with self.guard, self.local() as local:
            before = local.review()
            self.assertFalse(local.backup.exists())
            result = local.apply(before["confirmation"], self.guard)
        self.assertFalse(self.journal.exists())
        self.assertEqual(Path(result["backupPath"]).read_bytes(), original)
        self.assertEqual(result["disposition"], "supersededUnknownOutcome")
        backup = json.loads(original)
        self.assertEqual(backup["phase"], "unresolved")
        self.assertNotIn("importReceipt", backup)

    def test_approval_bound_to_exact_generation(self):
        with self.guard, self.local() as local:
            confirmation = local.review()["confirmation"]
            changed = dict(self.op, reason="new hold")
            write(self.journal, changed)
            with self.assertRaises(M.Refused):
                local.apply(confirmation, self.guard)
            self.assertEqual(json.loads(self.journal.read_bytes()), changed)
            self.assertFalse(local.backup.exists())

    def test_same_bytes_new_inode_is_not_the_reviewed_journal(self):
        with self.guard, self.local() as local:
            confirmation = local.review()["confirmation"]
            alternate = self.private / "replacement"
            write(alternate, self.journal.read_bytes())
            alternate.replace(self.journal)
            with self.assertRaises(M.Refused):
                local.apply(confirmation, self.guard)
            self.assertTrue(self.journal.exists())

    def test_changed_evidence_after_backup_keeps_both_files(self):
        with self.guard, self.local() as local:
            real = self.guard.observe
            count = 0
            def observe():
                nonlocal count
                count += 1
                value = real()
                if count == 2:
                    value["authorityEpoch"] += 1
                return value
            self.guard.observe = observe
            with self.assertRaises(M.Refused):
                local.apply(local.review()["confirmation"], self.guard)
            self.assertEqual(local.backup.read_bytes(), self.journal.read_bytes())

    def test_guard_loss_after_backup_keeps_original(self):
        with self.guard, self.local() as local:
            real = self.guard.observe
            count = 0
            def observe():
                nonlocal count
                count += 1
                if count == 2:
                    raise M.Refused("fixture guard disconnected")
                return real()
            self.guard.observe = observe
            with self.assertRaises(M.Refused):
                local.apply(local.review()["confirmation"], self.guard)
            self.assertTrue(self.journal.exists())
            self.assertEqual(local.backup.read_bytes(), self.journal.read_bytes())

    def test_different_backup_is_never_overwritten(self):
        with self.guard, self.local() as local:
            write(local.backup, b"different backup")
            with self.assertRaises(M.Refused):
                local.apply(local.review()["confirmation"], self.guard)
            self.assertEqual(local.backup.read_bytes(), b"different backup")
            self.assertTrue(self.journal.exists())

    def test_staging_symlink_is_not_absence(self):
        Path(self.op["localDirectory"]).symlink_to("/nonexistent-fixture")
        with self.assertRaises(M.Refused):
            with self.local():
                pass

    def test_local_owner_or_remote_activation_contention_refuses(self):
        for path, guard in [(self.private / "codexswitch-app.lock", self.local),
                            (self.rprivate / "accounts.runtime-activation.lock", lambda: self.guard)]:
            fd = os.open(path, os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(M.Refused):
                    with guard():
                        pass
            finally:
                os.close(fd)
        self.assertTrue(self.journal.exists())

    def test_missing_lock_does_not_get_created(self):
        path = self.rprivate / "accounts.runtime-activation.lock"
        path.unlink()
        with self.assertRaises((M.Refused, OSError)):
            with self.guard:
                pass
        self.assertFalse(path.exists())

    def test_store_auth_mismatch_or_unconfirmed_activation_refuses(self):
        with self.guard:
            write(self.remote / ".codex/auth.json", {"tokens": {}})
            with self.assertRaises(M.Refused):
                self.guard.observe()

    def test_release_route_and_lock_replacement_refuse(self):
        with self.guard:
            path = self.rprivate / "accounts.runtime-activation.lock"
            alternate = self.rprivate / "new-lock"
            write(alternate, b"")
            alternate.replace(path)
            with self.assertRaises(M.Refused):
                self.guard.observe()

    def test_receipt_or_unknown_fields_cannot_be_superseded(self):
        for update in [{"importReceipt": {"version": 1}}, {"accessToken": "FIXTURE-SECRET"}, {"phase": "pending"}]:
            write(self.journal, dict(self.op, **update))
            with self.assertRaises(M.Refused):
                with self.local():
                    pass

    def test_evidence_contains_no_credentials_and_does_not_mutate_remote(self):
        before = {str(p): p.read_bytes() for p in self.remote.rglob("*") if p.is_file() and not p.is_symlink()}
        with self.guard:
            evidence = self.guard.observe()
        serialized = json.dumps(evidence)
        for value in ["FIXTURE-ID-SECRET", "FIXTURE-ACCESS-SECRET", "FIXTURE-REFRESH-SECRET", "current-provider"]:
            self.assertNotIn(value, serialized)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.remote.rglob("*") if p.is_file() and not p.is_symlink()})

    def test_importer_arguments_and_stage_shell_are_rejected(self):
        for args in [[b"codexswitch-cli", b"update-bundle", b"bundle"],
                     [b"sh", b"-c", ("rm -rf " + self.op["remoteDirectory"]).encode()],
                     [b"codexswitch-cli", b"import", b"bundle"]]:
            self.assertTrue(M.importer_arguments(args, self.id))
        self.assertFalse(M.importer_arguments([b"codex", b"app-server"], self.id))

    def fake_proc(self, args, comm=b"fixture name"):
        root = self.root / "proc"
        process = root / "999999"
        process.mkdir(parents=True, mode=0o700)
        write(process / "stat", b"999999 (" + comm + b") " + b" ".join([b"S"] + [b"0"] * 18 + [b"123"]))
        uid = str(os.geteuid()).encode()
        write(process / "status", b"Tgid:\t999999\nUid:\t" + b"\t".join([uid] * 4) + b"\n")
        write(process / "cmdline", b"\0".join(args) + b"\0")
        executable = self.root / "fixture-executable"
        write(executable, b"fixture")
        (process / "exe").symlink_to(executable)
        return root, process

    def test_real_proc_parser_rejects_importer_and_incomplete_inventory(self):
        root, process = self.fake_proc([b"codexswitch-cli", b"update-bundle", b"fixture-bundle"])
        with self.assertRaises(M.Refused):
            M.scan_importers(self.id, True, root)
        write(process / "cmdline", b"codex\0app-server\0")
        M.scan_importers(self.id, True, root)
        write(process / "cmdline", b"")
        with self.assertRaises(M.Refused):
            M.scan_importers(self.id, True, root)

    def test_pid_reuse_is_rejected(self):
        root, process = self.fake_proc([b"codex", b"app-server"])
        original = M.proc_bytes
        calls = 0
        def changed(path, limit):
            nonlocal calls
            data = original(path, limit)
            if path.name == "stat":
                calls += 1
                if calls == 2:
                    return data.replace(b"123", b"124")
            return data
        with mock.patch.object(M, "proc_bytes", side_effect=changed):
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    @contextlib.contextmanager
    def denied_exe(self, process, code=errno.EACCES):
        original = Path.stat
        def controlled_stat(path, *args, **kwargs):
            if path == process / "exe":
                raise OSError(code, "fixture executable access failure")
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, "stat", controlled_stat):
            yield

    def test_denied_exe_unrelated_stable_process_is_accepted(self):
        root, process = self.fake_proc([b"/usr/bin/fixture-worker", b"--idle"], b"fixture-worker")
        for code in (errno.EACCES, errno.EPERM):
            with self.subTest(code=code), self.denied_exe(process, code):
                M.scan_importers(self.id, True, root)

    def test_denied_exe_importer_and_stage_remain_rejected(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        commands = [[b"codexswitch-cli", b"update-bundle", b"fixture"],
                    [b"codexswitch-cli", b"import", b"fixture"],
                    [b"sh", b"-c", ("rm " + self.op["remoteDirectory"]).encode()],
                    [b"sh", b"-c", self.op["localDirectory"].encode()]]
        with self.denied_exe(process):
            for args in commands:
                with self.subTest(args=args):
                    write(process / "cmdline", b"\0".join(args) + b"\0")
                    with self.assertRaisesRegex(M.Refused, "importer or staging"):
                        M.scan_importers(self.id, True, root)

    def test_denied_exe_missing_truncated_oversized_or_empty_argv_rejects(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        with self.denied_exe(process):
            for data in (b"", b"\0", b"fixture-worker\0--truncated", b"x" * (1024 * 1024) + b"\0"):
                with self.subTest(length=len(data)):
                    write(process / "cmdline", data)
                    with self.assertRaises(M.Refused):
                        M.scan_importers(self.id, True, root)
            (process / "cmdline").unlink()
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    def test_denied_exe_changed_argv_rejects(self):
        root, process = self.fake_proc([b"fixture-worker", b"idle"], b"fixture-worker")
        original = M.proc_bytes
        calls = 0
        def changed(path, limit):
            nonlocal calls
            data = original(path, limit)
            if path.name == "cmdline":
                calls += 1
                if calls == 2:
                    return data.replace(b"idle", b"busy")
            return data
        with self.denied_exe(process), mock.patch.object(M, "proc_bytes", side_effect=changed):
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    def test_denied_exe_unreadable_argv_is_not_accepted(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        original = M.proc_bytes
        def unreadable(path, limit):
            if path.name == "cmdline":
                raise PermissionError(errno.EACCES, "fixture argv unreadable")
            return original(path, limit)
        with self.denied_exe(process), mock.patch.object(M, "proc_bytes", side_effect=unreadable):
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    def test_executable_access_transition_is_not_accepted(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        original = Path.stat
        for first_denied in (True, False):
            calls = 0
            def changing(path, *args, **kwargs):
                nonlocal calls
                if path == process / "exe":
                    calls += 1
                    if (calls == 1) == first_denied:
                        raise PermissionError(errno.EACCES, "fixture access transition")
                return original(path, *args, **kwargs)
            with self.subTest(first_denied=first_denied), mock.patch.object(Path, "stat", changing):
                with self.assertRaises(M.Refused):
                    M.scan_importers(self.id, True, root)

    def test_denied_exe_pid_reuse_rejects_at_final_observation(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        original = M.proc_bytes
        calls = 0
        def reused(path, limit):
            nonlocal calls
            data = original(path, limit)
            if path.name == "stat":
                calls += 1
                if calls == 3:
                    return data.replace(b"123", b"124")
            return data
        with self.denied_exe(process), mock.patch.object(M, "proc_bytes", side_effect=reused):
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    def test_denied_exe_changed_real_uid_rejects(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        original = M.proc_bytes
        calls = 0
        def changed(path, limit):
            nonlocal calls
            data = original(path, limit)
            if path.name == "status":
                calls += 1
                if calls == 3:
                    uids = [str(os.geteuid()).encode()] * 4
                    uids[0] = str(os.geteuid() + 1).encode()
                    return b"Tgid:\t999999\nUid:\t" + b"\t".join(uids) + b"\n"
            return data
        with self.denied_exe(process), mock.patch.object(M, "proc_bytes", side_effect=changed):
            with self.assertRaises(M.Refused):
                M.scan_importers(self.id, True, root)

    def test_denied_exe_unexplained_launch_rejects(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        with self.denied_exe(process):
            for argv0 in (b"other-worker", b"fixture-worker --hidden", b"fixture-worker:\nsecret", b"-"):
                write(process / "cmdline", argv0 + b"\0")
                with self.assertRaisesRegex(M.Refused, "launch form"):
                    M.scan_importers(self.id, True, root)

    def test_unexpected_executable_errors_and_nonregular_file_reject(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        for code in (errno.EIO, errno.ELOOP, errno.ENOENT):
            with self.subTest(code=code), self.denied_exe(process, code):
                with self.assertRaises(M.Refused):
                    M.scan_importers(self.id, True, root)
        (process / "exe").unlink()
        (process / "exe").mkdir()
        with self.assertRaises(M.Refused):
            M.scan_importers(self.id, True, root)

    def test_denied_exe_nonidentity_status_metrics_need_not_freeze(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        original = M.proc_bytes
        count = 0
        def changing_metrics(path, limit):
            nonlocal count
            data = original(path, limit)
            if path.name == "status":
                count += 1
                return data + b"voluntary_ctxt_switches:\t" + str(count).encode() + b"\n"
            return data
        with self.denied_exe(process), mock.patch.object(M, "proc_bytes", side_effect=changing_metrics):
            M.scan_importers(self.id, True, root)

    def test_mac_full_last_column_rejects_actual_codexswitch_path(self):
        # Actual PID 60733 shape: comm before args yielded /Applications/Co;
        # comm as the final column yields this full executable path.
        uid = str(os.geteuid()).encode()
        row = uid + b" 60733 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch\n"
        commands = []
        def output(argv, **kwargs):
            commands.append(argv)
            return type("Result", (), {"stdout": row})()
        with mock.patch.object(M.subprocess, "run", side_effect=output):
            with self.assertRaisesRegex(M.Refused, "local CodexSwitch process remains"):
                M.scan_importers(self.id)
        self.assertEqual(commands, [["/bin/ps", "-ww", "-axo", "uid=,pid=,comm="],
                                    ["/bin/ps", "-ww", "-axo", "uid=,pid=,args="]])

    def test_mac_paths_with_spaces_and_local_importer_remain_blocked(self):
        uid = str(os.geteuid()).encode()
        with self.assertRaises(M.Refused):
            M.check_mac_process_output(uid + b" 60733 /Applications/Local Apps/CodexSwitch.app/Contents/MacOS/CodexSwitch\n",
                                       b"", self.id)
        with self.assertRaises(M.Refused):
            M.check_mac_process_output(uid + b" 60733 /usr/bin/ssh\n",
                                       uid + b" 60733 ssh host codexswitch-cli update-bundle fixture\n", self.id)

    def test_generic_title_and_truncated_comm_need_no_role_exception(self):
        root, process = self.fake_proc([b"fixture-worker: idle", b"", b""], b"fixture-worker")
        with self.denied_exe(process):
            M.scan_importers(self.id, True, root)
            write(process / "cmdline", b"/usr/bin/fixture-worker-long\0")
            write(process / "stat", (process / "stat").read_bytes().replace(b"(fixture-worker)", b"(fixture-worker-)"))
            M.scan_importers(self.id, True, root)

    def test_observed_denied_exe_shapes_share_the_generic_contract(self):
        root, process = self.fake_proc([b"fixture-worker"], b"fixture-worker")
        shapes = [(b"systemd", [b"/usr/lib/systemd/systemd", b"--user"]),
                  (b"(sd-pam)", [b"(sd-pam)"]),
                  (b"gpg-agent", [b"/usr/bin/gpg-agent", b"--daemon"]),
                  (b"sftp-server", [b"/usr/lib/openssh/sftp-server"]),
                  (b"sshd", [b"sshd: fixture@notty", b"", b""]),
                  (b"sshd", [b"sshd: fixture"] + [b""] * 8)]
        with self.denied_exe(process):
            for comm, args in shapes:
                with self.subTest(comm=comm):
                    write(process / "stat", b"999999 (" + comm + b") " + b" ".join([b"S"] + [b"0"] * 18 + [b"123"]))
                    write(process / "cmdline", b"\0".join(args) + b"\0")
                    M.scan_importers(self.id, True, root)

    def test_remote_stage_reappearing_after_final_scan_is_rejected(self):
        with self.guard, mock.patch.object(M, "absent", side_effect=[True, False]):
            with self.assertRaisesRegex(M.Refused, "remote stage reappeared"):
                self.guard.observe()
        self.assertTrue(self.journal.exists())

    def test_pending_activation_stale_evidence_and_attestation_mismatch_refuse(self):
        with self.guard:
            evidence = self.guard.observe()
            stale = dict(evidence, observedAt=time.time() - 20)
            with self.assertRaises(M.Refused):
                M.validate_evidence(stale, self.id, self.target)
            self.guard.expected_cli = "0" * 64
            with self.assertRaises(M.Refused):
                self.guard.observe()
            self.guard.expected_cli = None
            path = self.rprivate / "accounts.activation.json"
            record = json.loads(path.read_bytes())
            record["state"] = "prepared"
            write(path, record)
            with self.assertRaises(M.Refused):
                self.guard.observe()

    def test_durable_receipts_preclude_legacy_supersession(self):
        path = self.rprivate / "accounts.json.credential-import-receipts.json"
        with self.guard:
            for operation, state in [(self.id, "completed"), (str(uuid.uuid4()), "pending")]:
                write(path, {"version": 1, "records": [{"state": state, "receipt": {"operationId": operation}}]})
                with self.assertRaises(M.Refused):
                    self.guard.observe()
        self.assertTrue(self.journal.exists())

    def start_wire_guard(self):
        parent, child = socket.socketpair()
        pid = os.fork()
        if pid == 0:
            parent.close()
            try:
                M.serve_guard(self.guard, child.fileno(), child.fileno(), grace=0.2)
            except BaseException:
                pass
            finally:
                child.close()
            os._exit(0)
        child.close()
        self.addCleanup(lambda: parent.close())
        self.addCleanup(lambda: os.waitpid(pid, 0))
        return parent

    def test_wire_challenges_keep_real_locks_held_until_release(self):
        peer = self.start_wire_guard()
        M.send_line(peer.fileno(), {"command": "observe", "sequence": 1})
        first = M.read_line(peer.fileno(), 2)
        self.assertEqual(first["sequence"], 1)
        with self.assertRaises(M.Refused):
            with M.Locks([(self.rprivate / "accounts.runtime-activation.lock", fcntl.LOCK_EX)]):
                pass
        M.send_line(peer.fileno(), {"command": "observe", "sequence": 2})
        second = M.read_line(peer.fileno(), 2)
        self.assertEqual(M.stable_evidence(first["evidence"]), M.stable_evidence(second["evidence"]))
        M.send_line(peer.fileno(), {"command": "release", "sequence": 3})

    def test_wire_replay_rejected_and_eof_has_hold_grace(self):
        peer = self.start_wire_guard()
        M.send_line(peer.fileno(), {"command": "observe", "sequence": 1})
        M.read_line(peer.fileno(), 2)
        M.send_line(peer.fileno(), {"command": "observe", "sequence": 1})
        with self.assertRaises(M.Refused):
            M.read_line(peer.fileno(), 2)
        self.assertTrue(self.journal.exists())

    def test_transport_eof_does_not_immediately_release_remote_lease(self):
        peer = self.start_wire_guard()
        M.send_line(peer.fileno(), {"command": "observe", "sequence": 1})
        M.read_line(peer.fileno(), 2)
        peer.shutdown(socket.SHUT_WR)
        with self.assertRaises(M.Refused):
            with M.Locks([(self.rprivate / "accounts.runtime-activation.lock", fcntl.LOCK_EX)]):
                pass
        self.assertTrue(self.journal.exists())

    def test_backup_write_failure_preserves_original(self):
        with self.guard, self.local() as local:
            before = self.journal.read_bytes()
            with mock.patch.object(M.os, "write", side_effect=OSError("fixture-disk-full")):
                with self.assertRaises(OSError):
                    local.apply(local.review()["confirmation"], self.guard)
            self.assertEqual(self.journal.read_bytes(), before)

    def test_symlink_backup_refuses_without_touching_target(self):
        target = self.private / "foreign-file"
        write(target, b"keep")
        with self.guard, self.local() as local:
            local.backup.symlink_to(target)
            with self.assertRaises(OSError):
                local.apply(local.review()["confirmation"], self.guard)
            self.assertEqual(target.read_bytes(), b"keep")
            self.assertTrue(self.journal.exists())


if __name__ == "__main__":
    unittest.main()
