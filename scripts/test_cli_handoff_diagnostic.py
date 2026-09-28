import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('handoff_diagnostic', Path(__file__).with_name('diagnose_cli_handoff.py'))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class DiagnosticContractTests(unittest.TestCase):
    def test_reason_codes_do_not_echo_error_text(self):
        for stderr, expected in [
            ('runtime activation is busy: synthetic-secret', 'activation_lease_busy'),
            ('durable Confirmed activation is stale: synthetic-secret', 'journal_stale'),
            ('failed to decode Swift activation witness synthetic-secret', 'swift_witness_rejected'),
            ('Mac activation handoff did not obtain fresh runtime confirmation: synthetic-secret', 'runtime_ack_required'),
            ('unrecognized synthetic-secret', 'unclassified_failure'),
        ]:
            code = diagnostic.reason_code(1, stderr)
            self.assertEqual(code, expected)
            self.assertIn(code, diagnostic.REASONS)
            self.assertNotIn('synthetic-secret', code)

    def test_sandbox_has_all_required_fences(self):
        profile = diagnostic.sandbox_profile('/private/tmp/fixture', '/Users/test', '/Users/test/cli')
        for operation in ('network*', 'signal', 'process-fork', 'file-read*', 'file-write*'):
            self.assertIn('(deny ' + operation, profile)
        self.assertIn('(require-not (literal "/Users/test/cli"))', profile)

    def test_fixture_contains_only_synthetic_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = diagnostic.synthetic_fixture(Path(directory))
            for path in paths:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            store = paths[0].read_text()
            self.assertIn('fixture@example.invalid', store)
            self.assertIn('synthetic-refresh-not-a-credential', store)


@unittest.skipUnless(os.environ.get('HANDOFF_REPLAY_CLI'), 'set HANDOFF_REPLAY_CLI for sandboxed installed-CLI replay')
class InstalledCLIReplayTests(unittest.TestCase):
    def replay(self, variant, explicit_paths=True):
        result = diagnostic.replay(os.environ['HANDOFF_REPLAY_CLI'], variant, explicit_paths)
        self.assertEqual(result['exitStatus'], 1)
        self.assertTrue(result['authUnchanged'])
        self.assertTrue(result['credentialsAndSelectionUnchanged'])
        self.assertTrue(result['swiftWitnessUnchanged'])
        return result

    def test_fresh_witness_enters_unconfirmed_convergence(self):
        result = self.replay('fresh')
        self.assertEqual(result['reason'], 'runtime_ack_required')
        self.assertEqual(result['rustState'], 'committed_degraded')
        self.assertFalse(result['rustJournalUnchanged'])

    def test_app_default_arguments_use_isolated_home(self):
        result = self.replay('fresh', explicit_paths=False)
        self.assertEqual(result['reason'], 'runtime_ack_required')
        self.assertEqual(result['rustState'], 'committed_degraded')

    def test_wrong_target_keeps_original_journal(self):
        result = self.replay('wrong_target')
        self.assertEqual(result['reason'], 'journal_stale')
        self.assertTrue(result['rustJournalUnchanged'])
        self.assertTrue(result['storeUnchanged'])

    def test_stale_witness_keeps_original_journal(self):
        result = self.replay('stale_witness')
        self.assertEqual(result['reason'], 'journal_stale')
        self.assertTrue(result['rustJournalUnchanged'])
        self.assertTrue(result['storeUnchanged'])

    def test_busy_runtime_lease_keeps_all_files(self):
        result = self.replay('lease_busy')
        self.assertEqual(result['reason'], 'activation_lease_busy')
        self.assertTrue(result['rustJournalUnchanged'])
        self.assertTrue(result['storeUnchanged'])


if __name__ == '__main__':
    unittest.main()
