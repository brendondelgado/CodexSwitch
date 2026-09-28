"""Offline replay only: synthetic files, fenced installed CLI, no live recovery."""

import argparse
import base64
import fcntl
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


SWIFT_EPOCH = 978307200
SANDBOX = Path('/usr/bin/sandbox-exec')
REASONS = {
    'runtime_ack_required', 'swift_witness_rejected',
    'activation_lease_busy', 'journal_stale', 'path_identity_mismatch',
    'sandbox_denied', 'unclassified_failure', 'unexpected_success',
}


def reason_code(returncode, stderr):
    if returncode == 0:
        return 'unexpected_success'
    signatures = (
        ('runtime activation is busy', 'activation_lease_busy'),
        ('runtime-activation lease belongs to', 'path_identity_mismatch'),
        ('failed to decode Swift activation witness', 'swift_witness_rejected'),
        ('durable Confirmed activation is stale', 'journal_stale'),
        ('Mac activation handoff did not obtain fresh runtime confirmation', 'runtime_ack_required'),
        ('Operation not permitted', 'sandbox_denied'),
    )
    return next((code for signature, code in signatures if signature in stderr), 'unclassified_failure')


def sandbox_profile(root, real_home, executable):
    quote = lambda value: json.dumps(str(value))
    return '\n'.join([
        '(version 1)', '(allow default)', '(deny network*)', '(deny signal)',
        '(deny process-fork)',
        '(deny file-write* (require-not (subpath ' + quote(root) + ')))',
        '(deny file-read* (require-all (subpath ' + quote(real_home) + ')',
        ' (require-not (literal ' + quote(executable) + '))))',
    ])


def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, separators=(',', ':'))


def synthetic_fixture(root, variant='fresh'):
    now = time.time()
    account_id = str(uuid.uuid4())
    encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    access = encode({'alg': 'none'}) + '.' + encode({'exp': int(now + 7200)}) + '.synthetic'
    account = {
        'id': account_id, 'email': 'fixture@example.invalid',
        'accountId': 'fixture-provider-current', 'accessToken': access,
        'refreshToken': 'synthetic-refresh-not-a-credential',
        'idToken': 'synthetic-identity-not-a-credential', 'isActive': True,
    }
    store = root / '.codexswitch/accounts.json'
    auth = root / '.codex/auth.json'
    rust = store.with_suffix('.activation.json')
    swift = store.parent / 'account-activation.json'
    private_json(store, [account])
    private_json(auth, {
        'auth_mode': 'chatgpt',
        'tokens': {'account_id': account['accountId'], 'access_token': access,
                   'refresh_token': account['refreshToken'], 'id_token': account['idToken']},
    })
    private_json(rust, {
        'version': 3, 'state': 'confirmed', 'kind': 'rotation',
        'previousAccountId': 'fixture-provider-previous',
        'targetAccountId': 'fixture-provider-stale',
        'storeGeneration': 'synthetic-stale-generation',
        'authFingerprint': 'synthetic-stale-fingerprint', 'detail': None,
        'updatedAt': (datetime.now(timezone.utc) - timedelta(days=20)).isoformat(),
    })
    witness = {
        'version': 1, 'phase': 'confirmed', 'activationGeneration': str(uuid.uuid4()),
        'configuredAccountId': account_id, 'runtimeCurrentAccountId': account_id,
        'updatedAt': now - SWIFT_EPOCH, 'retryAttempt': 0,
        'discoveredRuntimeCount': 1, 'acknowledgedRuntimeCount': 1,
        'runtimeEvidenceGeneration': str(uuid.uuid4()),
        'runtimeEvidenceObservedAt': now - SWIFT_EPOCH - 1,
        'runtimeEvidenceExpiresAt': now - SWIFT_EPOCH + 29,
    }
    if variant == 'wrong_target':
        witness['configuredAccountId'] = str(uuid.uuid4())
    elif variant == 'stale_witness':
        witness['updatedAt'] -= 7200
        witness['runtimeEvidenceObservedAt'] -= 7200
        witness['runtimeEvidenceExpiresAt'] -= 7200
    elif variant not in ('fresh', 'lease_busy'):
        raise ValueError('unsupported fixture variant')
    private_json(swift, witness)
    return store, auth, rust, swift


def fenced_run(executable, args, root, timeout=10):
    if not SANDBOX.is_file():
        raise RuntimeError('sandbox_unavailable')
    env = {'HOME': str(root), 'PATH': '/usr/bin:/bin', 'TMPDIR': str(root), 'LANG': 'C'}
    return subprocess.run(
        [str(SANDBOX), '-p', sandbox_profile(root, Path.home(), executable), str(executable), *args],
        env=env, cwd=root, capture_output=True, text=True, timeout=timeout,
    )


def sandbox_readiness(root):
    # These probes can create only disposable fixture data, never a live file.
    probe = root / 'sandbox-probe'
    result = fenced_run('/bin/sh', ['-c', 'printf probe > "$1"', 'probe', str(probe)], root)
    if result.returncode != 0 or probe.read_text() != 'probe':
        raise RuntimeError('sandbox_execution_unavailable')
    with tempfile.TemporaryDirectory(prefix='handoff-denied-') as outside:
        destination = Path(outside).resolve() / 'must-not-exist'
        result = fenced_run('/bin/sh', ['-c', 'printf denied > "$1"', 'probe', str(destination)], root)
        if result.returncode == 0 or destination.exists():
            raise RuntimeError('sandbox_write_fence_failed')


def replay(executable, variant='fresh', explicit_paths=True):
    executable = Path(executable).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='codexswitch-handoff-') as temporary:
        root = Path(temporary).resolve()
        sandbox_readiness(root)
        store, auth, rust, swift = synthetic_fixture(root, variant)
        before = {path: path.read_bytes() for path in (store, auth, rust, swift)}
        args = ['reconcile-activation-handoff', '--json']
        if explicit_paths:
            args = ['--store', str(store), '--auth', str(auth), *args]
        lease_descriptor = None
        try:
            if variant == 'lease_busy':
                lease_descriptor = os.open(store.parent / 'accounts.runtime-activation.lock',
                                           os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
                fcntl.flock(lease_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = fenced_run(executable, args, root)
        finally:
            if lease_descriptor is not None:
                os.close(lease_descriptor)
        after = json.loads(rust.read_text())
        before_accounts = json.loads(before[store])
        after_accounts = json.loads(store.read_bytes())
        credential_keys = ('id', 'accountId', 'accessToken', 'refreshToken', 'idToken', 'isActive')
        inventory = lambda accounts: [tuple(account[key] for key in credential_keys) for account in accounts]
        report = {
            'variant': variant, 'exitStatus': result.returncode,
            'explicitPaths': explicit_paths,
            'reason': reason_code(result.returncode, result.stderr),
            'rustState': after['state'], 'rustJournalUnchanged': rust.read_bytes() == before[rust],
            'storeUnchanged': store.read_bytes() == before[store],
            'credentialsAndSelectionUnchanged': inventory(before_accounts) == inventory(after_accounts),
            'authUnchanged': auth.read_bytes() == before[auth],
            'swiftWitnessUnchanged': swift.read_bytes() == before[swift],
        }
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--variant', choices=['fresh', 'wrong_target', 'stale_witness', 'lease_busy'], default='fresh')
    parser.add_argument('--default-paths', action='store_true', help='Use only the synthetic HOME for path defaults.')
    args = parser.parse_args()
    print(json.dumps(replay(args.cli, args.variant, explicit_paths=not args.default_paths), sort_keys=True))


if __name__ == '__main__':
    main()
