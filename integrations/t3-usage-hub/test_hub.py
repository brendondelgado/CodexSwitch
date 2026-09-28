#!/usr/bin/env python3
"""End-to-end tests for the T3 usage hub: real HTTP server, fake codexswitch-cli, temp store."""
import importlib.util
import json
import os
import pathlib
import stat
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
KEY = 'test-management-key'
APPLE_EPOCH = 978307200
BUSY = 'Error: runtime activation is busy: another process owns the cross-process runtime-activation lease'

FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, sys
calls = os.path.join(os.environ['FAKE_DIR'], 'calls')
with open(calls, 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
n = sum(1 for _ in open(calls))
script = json.load(open(os.path.join(os.environ['FAKE_DIR'], 'script.json')))
step = script[min(n, len(script)) - 1]
if step.get('stdout') is not None:
    print(step['stdout'])
if step.get('stderr'):
    print(step['stderr'], file=sys.stderr)
sys.exit(step['rc'])
'''


def envelope(disposition):
    return json.dumps({'schemaVersion': 1, 'status': 'error', 'disposition': disposition,
                       'message': 'No banked reset was applied; refresh this account and try again',
                       'accountId': 'acct', 'requestId': 'r', 'blockingRequestId': None})


def success(submitted=True):
    return json.dumps({'account': 'bd7349@gmail.com', 'accountId': 'acct', 'wasActive': False,
                       'submittedReset': submitted, 'previousBankedResets': 2,
                       'bankedResetsRemaining': 1, 'remainingPercent': 100.0}, indent=2)


def account(email, plan='pro', used=99.0, credits=1):
    return {
        'id': email.upper(), 'email': email, 'planType': plan, 'accessToken': 'SECRET-ACCESS',
        'refreshToken': 'SECRET-REFRESH', 'idToken': 'SECRET-ID',
        'quotaSnapshot': {'windows': [{'durationSeconds': 604800, 'kind': 'weekly', 'resetsAt': 812760543,
                                       'source': {'slot': 'primary'}, 'usedPercent': used}]},
        'rateLimitResetBank': {'availableCount': credits, 'credits': [
            {'id': f'RateLimitResetCredit_{email}_{i}', 'status': 'available', 'resetType': 'codex_rate_limits',
             'expiresAt': 812866716.121 + i} for i in range(credits)]},
    }


class HubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.hub_dir = root / 'hub'
        self.hub_dir.mkdir()
        (self.hub_dir / 'management-key').write_text(KEY + '\n')
        self.fake_dir = root / 'fake'
        self.fake_dir.mkdir()
        cli = self.fake_dir / 'codexswitch-cli'
        cli.write_text(FAKE_CLI)
        cli.chmod(cli.stat().st_mode | stat.S_IEXEC)
        self.store = root / 'accounts.json'
        self.write_store([account('bd7349@gmail.com', credits=2), account('bd7349@me.com', plan='free'),
                          account('shopszn17@gmail.com'), account('a@x.com'), account('a@y.com')])
        env = {'CODEX_USAGE_HUB_DIR': str(self.hub_dir), 'CODEX_USAGE_HUB_STORE': str(self.store),
               'CODEX_USAGE_HUB_CLI': str(cli)}
        self.saved_env = {k: os.environ.get(k) for k in [*env, 'FAKE_DIR']}
        os.environ.update(env, FAKE_DIR=str(self.fake_dir))
        spec = importlib.util.spec_from_file_location('hub_under_test', HERE / 'hub.py')
        self.hub = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.hub)
        self.hub.RETRY_DELAY_SECONDS = 0.01
        self.hub.RETRY_WINDOW_SECONDS = 0.5
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.hub.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def write_store(self, rows):
        self.store.write_text(json.dumps(rows))

    def script(self, *steps):
        (self.fake_dir / 'script.json').write_text(json.dumps(list(steps)))

    def cli_calls(self):
        path = self.fake_dir / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def request(self, path, body=None, key=KEY):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method='GET' if body is None else 'POST')
        if key:
            req.add_header('Authorization', f'Bearer {key}')
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def auth_files(self):
        return self.request('/v0/management/auth-files')[1]['files']

    def index_of(self, email):
        return next(f['auth_index'] for f in self.auth_files() if f['email'] == email)

    def consume(self, email='bd7349@gmail.com', request_id='51ea82d0-01f2-5dbf-a3d5-a9d3e02ec324'):
        status, envelope_ = self.request('/v0/management/api-call', {
            'auth_index': self.index_of(email), 'method': 'POST',
            'url': f'{self.hub.CODEX_BASE}/rate-limit-reset-credits/consume',
            'data': json.dumps({'redeem_request_id': request_id, 'credit_id': 'c1'})})
        self.assertEqual(status, 200)
        return envelope_['status_code'], json.loads(envelope_['body'])

    # --- auth and account listing -------------------------------------------------------------

    def test_requires_management_key(self):
        self.assertEqual(self.request('/v0/management/auth-files', key=None)[0], 401)
        self.assertEqual(self.request('/v0/management/auth-files', key='wrong')[0], 401)

    def test_lists_paid_accounts_labelled_by_unique_local_part(self):
        files = self.auth_files()
        self.assertEqual([(f['id'], f['email']) for f in files], [
            ('bd7349', 'bd7349@gmail.com'), ('shopszn17', 'shopszn17@gmail.com'),
            ('a@x.com', 'a@x.com'), ('a@y.com', 'a@y.com')])
        self.assertEqual(len({f['id'] for f in files}), len(files))

    def test_never_leaks_tokens(self):
        blob = json.dumps(self.auth_files())
        for idx in [f['auth_index'] for f in self.auth_files()]:
            for url in ('usage', 'rate-limit-reset-credits'):
                blob += json.dumps(self.request('/v0/management/api-call', {
                    'auth_index': idx, 'method': 'GET', 'url': f'{self.hub.CODEX_BASE}/{url}'}))
        self.assertNotIn('SECRET', blob)

    def test_usage_and_credits_bodies(self):
        idx = self.index_of('bd7349@gmail.com')
        _, usage = self.request('/v0/management/api-call', {'auth_index': idx, 'method': 'GET',
                                                             'url': f'{self.hub.CODEX_BASE}/usage'})
        body = json.loads(usage['body'])
        self.assertEqual(body['rate_limit']['primary_window'],
                         {'used_percent': 99.0, 'reset_at': 812760543 + APPLE_EPOCH, 'limit_window_seconds': 604800})
        _, credits = self.request('/v0/management/api-call', {'auth_index': idx, 'method': 'GET',
                                                               'url': f'{self.hub.CODEX_BASE}/rate-limit-reset-credits'})
        self.assertEqual(len(json.loads(credits['body'])['credits']), 2)

    def test_unknown_upstream_urls_are_refused(self):
        _, env = self.request('/v0/management/api-call', {'auth_index': self.index_of('bd7349@gmail.com'),
                                                          'method': 'POST', 'url': 'https://chatgpt.com/other'})
        self.assertEqual(env['status_code'], 403)
        self.assertEqual(self.cli_calls(), [])

    # --- redemption ---------------------------------------------------------------------------

    def test_success_redeems_through_cli_with_request_id(self):
        self.script({'rc': 0, 'stdout': success()})
        self.assertEqual(self.consume(), (200, {'code': 'reset'}))
        self.assertEqual(self.cli_calls(), [['redeem-reset', 'bd7349@gmail.com', '--json', '--request-id',
                                             '51ea82d0-01f2-5dbf-a3d5-a9d3e02ec324']])

    def test_reconciled_prior_attempt_is_already_redeemed(self):
        self.script({'rc': 0, 'stdout': success(submitted=False)})
        self.assertEqual(self.consume(), (200, {'code': 'already_redeemed'}))

    def test_lease_contention_is_retried_with_same_request_id(self):
        busy = {'rc': 1, 'stdout': envelope('rejected'), 'stderr': BUSY}
        self.script(busy, busy, busy, {'rc': 0, 'stdout': success()})
        self.assertEqual(self.consume(), (200, {'code': 'reset'}))
        calls = self.cli_calls()
        self.assertEqual(len(calls), 4)
        self.assertEqual(len({json.dumps(c) for c in calls}), 1)

    def test_persistent_contention_is_an_error_not_no_credit(self):
        self.script({'rc': 1, 'stdout': envelope('rejected'), 'stderr': BUSY})
        status, body = self.consume()
        self.assertEqual(status, 409)
        self.assertNotIn('code', body)
        self.assertGreater(len(self.cli_calls()), 1)

    def test_outcome_unknown_is_never_retried(self):
        self.script({'rc': 1, 'stdout': envelope('outcomeUnknown'), 'stderr': BUSY})
        self.assertEqual(self.consume()[0], 502)
        self.assertEqual(len(self.cli_calls()), 1)

    def test_usable_account_is_nothing_to_reset(self):
        self.script({'rc': 1, 'stdout': envelope('rejected'),
                     'stderr': 'Error: banked reset redemption requires a fresh blocked quota for x; observed Usable'})
        self.assertEqual(self.consume(), (200, {'code': 'nothing_to_reset'}))

    def test_other_rejections_surface_as_errors(self):
        self.script({'rc': 1, 'stdout': envelope('rejected'),
                     'stderr': 'Error: banked reset redemption requires a paid account; x is not paid'})
        self.assertEqual(self.consume()[0], 409)
        self.assertEqual(len(self.cli_calls()), 1)

    def test_unparseable_success_output_still_counts_as_reset(self):
        self.script({'rc': 0, 'stdout': 'Redeemed one banked reset'})
        self.assertEqual(self.consume(), (200, {'code': 'reset'}))

    def test_redeem_log_records_attempts(self):
        busy = {'rc': 1, 'stdout': envelope('rejected'), 'stderr': BUSY}
        self.script(busy, {'rc': 0, 'stdout': success()})
        self.consume()
        log = (self.hub_dir / 'redeem.log').read_text()
        self.assertIn('bd7349@gmail.com attempts=2 rc=0', log)


if __name__ == '__main__':
    unittest.main()
