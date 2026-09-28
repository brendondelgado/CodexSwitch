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


NOW = 1_800_300_000


def token(iat, exp=None):
    payload = base64.urlsafe_b64encode(json.dumps({
        'iat': iat, 'exp': NOW + iat * 60 if exp is None else exp
    }).encode()).decode().rstrip('=')
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
        return MODULE['update'](self.candidate, self.root, self.validate, now=lambda: NOW)

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

    def test_later_issued_but_earlier_expiring_candidate_is_rejected(self):
        self.candidate['accessToken'] = token(1_000, NOW + 600)
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_earlier_issued_but_later_expiring_candidate_is_accepted(self):
        self.candidate['accessToken'] = token(1, NOW + 7_200)
        self.assertEqual(self.deliver()['status'], 'verified')
        self.assertEqual(json.loads(self.path.read_text())[1]['accessToken'], self.candidate['accessToken'])

    def test_issued_at_is_not_required_for_expiry_ordering(self):
        payload = base64.urlsafe_b64encode(json.dumps({'exp': NOW + 7_200}).encode()).decode().rstrip('=')
        self.candidate['accessToken'] = 'header.' + payload + '.signature'
        self.assertEqual(self.deliver()['status'], 'verified')

    def test_missing_expiry_is_not_ordered_by_issued_at(self):
        payload = base64.urlsafe_b64encode(json.dumps({'iat': 1_000}).encode()).decode().rstrip('=')
        self.candidate['accessToken'] = 'header.' + payload + '.signature'
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_equal_expiry_divergence_is_rejected(self):
        self.candidate['accessToken'] = token(1_000, NOW + 1_200)
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_same_access_with_different_complete_set_preserves_destination(self):
        self.candidate['accessToken'] = self.accounts[1]['accessToken']
        before = self.path.read_bytes()
        with self.assertRaises(AssertionError): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_expired_and_safety_window_candidates_do_not_mutate(self):
        before = self.path.read_bytes()
        for expiry in [NOW - 1, NOW, NOW + 300]:
            with self.subTest(expiry=expiry):
                self.candidate['accessToken'] = token(100, expiry)
                with self.assertRaises(AssertionError): self.deliver()
                self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(self.validate_count, 0)

    def test_malformed_and_non_numeric_expirations_fail_closed(self):
        before = self.path.read_bytes()
        for expiry in [True, '9999999999', float('nan'), float('inf')]:
            with self.subTest(expiry=expiry):
                self.candidate['accessToken'] = token(100, expiry)
                with self.assertRaises((AssertionError, ValueError)): self.deliver()
                self.assertEqual(before, self.path.read_bytes())
        self.candidate['accessToken'] = 'malformed'
        with self.assertRaises((AssertionError, ValueError)): self.deliver()
        self.assertEqual(before, self.path.read_bytes())

    def test_malformed_or_incomplete_destination_does_not_get_overwritten(self):
        for key, value in [('accessToken', 'malformed'), ('refreshToken', ''), ('idToken', ' ')]:
            with self.subTest(key=key):
                accounts = [dict(a) for a in self.accounts]
                accounts[1][key] = value
                self.path.write_text(json.dumps(accounts))
                before = self.path.read_bytes()
                with self.assertRaises((AssertionError, ValueError)): self.deliver()
                self.assertEqual(before, self.path.read_bytes())

    def test_expired_destination_can_receive_strictly_newer_complete_generation(self):
        self.accounts[1]['accessToken'] = token(20, NOW - 1)
        self.path.write_text(json.dumps(self.accounts))
        self.assertEqual(self.deliver()['status'], 'verified')

    def test_generation_is_rechecked_after_provider_validation(self):
        changed = [dict(a) for a in self.accounts]
        changed[1]['accessToken'] = token(200, NOW + 12_000)
        def concurrent_refresh(_): self.path.write_text(json.dumps(changed))
        with self.assertRaises(AssertionError):
            MODULE['update'](self.candidate, self.root, concurrent_refresh, now=lambda: NOW)
        self.assertEqual(json.loads(self.path.read_text()), changed)

    def test_candidate_entering_safety_window_during_validation_is_rejected(self):
        before = self.path.read_bytes()
        clock = iter([NOW, NOW + 5_700])
        with self.assertRaises(AssertionError):
            MODULE['update'](self.candidate, self.root, self.validate, now=lambda: next(clock))
        self.assertEqual(self.validate_count, 1)
        self.assertEqual(before, self.path.read_bytes())

    def test_rotation_to_delivery_target_during_validation_preserves_active_tokens(self):
        changed = [dict(a) for a in self.accounts]
        changed[0]['isActive'] = False
        changed[1]['isActive'] = True
        def concurrent_rotation(_): self.path.write_text(json.dumps(changed))
        with self.assertRaises(AssertionError):
            MODULE['update'](self.candidate, self.root, concurrent_rotation, now=lambda: NOW)
        self.assertEqual(json.loads(self.path.read_text()), changed)

    def test_provider_rejection_never_mutates_store(self):
        before = self.path.read_bytes()
        def reject(_): raise ValueError('rejected')
        with self.assertRaises(ValueError): MODULE['update'](self.candidate, self.root, reject, now=lambda: NOW)
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
