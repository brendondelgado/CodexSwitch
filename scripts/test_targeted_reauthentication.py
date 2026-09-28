import base64
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'Sources/CodexSwitch/Services/LinuxDevboxReauthentication.swift'
SCRIPT = SOURCE.read_text().split('static let remoteScript = #"""\n', 1)[1].split('\n"""#', 1)[0]
MODULE = {'__name__': 'fixture'}
exec(compile(SCRIPT, str(SOURCE), 'exec'), MODULE)


def token(iat):
    payload = base64.urlsafe_b64encode(json.dumps({'iat': iat}).encode()).decode().rstrip('=')
    return 'header.' + payload + '.signature'


class TargetedReauthenticationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.path = self.root / 'accounts.json'
        self.accounts = [
            {'id': 'active', 'accountId': 'active-provider', 'email': 'active@test', 'isActive': True,
             'idToken': 'active-id', 'accessToken': token(50), 'refreshToken': 'active-refresh'},
            {'id': 'target', 'accountId': 'target-provider', 'email': 'target@test', 'isActive': False,
             'idToken': 'old-id', 'accessToken': token(20), 'refreshToken': 'old-refresh',
             'runtimeUnusableReason': 'token_expired', 'runtimeUnusableUntil': 123,
             'quotaSnapshot': {'preserve': True}},
        ]
        self.path.write_text(json.dumps(self.accounts))
        self.path.chmod(0o600)
        self.candidate = dict(self.accounts[1], id='mac-id', isActive=True,
                              idToken='new-id', accessToken=token(100), refreshToken='new-refresh')
        self.validate_count = 0

    def tearDown(self):
        self.tmp.cleanup()

    def validate(self, candidate):
        self.validate_count += 1

    def deliver(self):
        return MODULE['update'](self.candidate, self.root, self.validate)

    def test_updates_only_inactive_target_preserving_remote_selection_and_order(self):
        self.assertEqual(self.deliver()['status'], 'verified')
        result = json.loads(self.path.read_text())
        self.assertEqual(result[0], self.accounts[0])
        self.assertEqual(result[1]['id'], 'target')
        self.assertFalse(result[1]['isActive'])
        self.assertEqual(result[1]['quotaSnapshot'], {'preserve': True})
        self.assertEqual(result[1]['refreshToken'], 'new-refresh')
        self.assertNotIn('runtimeUnusableReason', result[1])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.root.glob('.reauth-*')))
        self.assertFalse((self.root / 'auth.json').exists())

    def test_retry_after_lost_ack_is_idempotent(self):
        self.deliver()
        before = self.path.read_bytes()
        self.deliver()
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(self.validate_count, 2)

    def test_valid_identical_credential_clears_stale_auth_block(self):
        self.candidate = dict(self.accounts[1])
        self.deliver()
        target = json.loads(self.path.read_text())[1]
        self.assertNotIn('runtimeUnusableReason', target)
        self.assertEqual(target['accessToken'], self.accounts[1]['accessToken'])

    def test_unrelated_legacy_staging_does_not_block_delivery(self):
        (self.root / 'linux-devbox-credential-sync.json').write_text('unresolved')
        (self.root / 'old-staging').mkdir()
        self.assertEqual(self.deliver()['status'], 'verified')
        self.assertEqual((self.root / 'linux-devbox-credential-sync.json').read_text(), 'unresolved')

    def test_active_remote_target_is_not_changed(self):
        self.candidate = dict(self.accounts[0], accessToken=token(100))
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_email_mismatch_is_rejected(self):
        self.candidate['email'] = 'wrong@test'
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_newer_remote_token_is_preserved(self):
        self.candidate['accessToken'] = token(10)
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_provider_rejection_never_mutates_store(self):
        before = self.path.read_bytes()
        def reject(_): raise ValueError('rejected')
        with self.assertRaises(ValueError): MODULE['update'](self.candidate, self.root, reject)
        self.assertEqual(before, self.path.read_bytes())

    def test_store_symlink_is_rejected(self):
        target = self.root / 'real.json'
        self.path.rename(target)
        self.path.symlink_to(target)
        with self.assertRaises(OSError): self.deliver()
        self.assertEqual(json.loads(target.read_text()), self.accounts)

    def test_duplicate_provider_identity_is_rejected(self):
        self.path.write_text(json.dumps(self.accounts + [self.accounts[1]]))
        with self.assertRaises(AssertionError): self.deliver()

    def test_same_lock_fences_other_writer(self):
        lock = self.root / 'accounts.json.lock'
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            before = self.path.read_bytes()
            with self.assertRaises(TimeoutError): self.deliver()
            self.assertEqual(before, self.path.read_bytes())
        finally: os.close(fd)


if __name__ == '__main__':
    unittest.main()
