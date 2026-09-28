#!/usr/bin/env python3
"""CodexSwitch usage hub for T3 Code.

T3 Code can show the usage of every account in a "usage limit source" that speaks the
CLIProxyAPI management API. This tiny server implements just the calls T3 makes and answers
them from CodexSwitch's own store (~/.codexswitch/accounts.json): quota snapshots and banked
reset credits that the CodexSwitch daemon already keeps fresh.

Safety:
  * No tokens ever leave this process and no provider request is ever made. Account
    credentials in accounts.json are never read into responses.
  * Banked resets are redeemed ONLY when the operator clicks redeem in T3 (operator 2026-09-26:
    "T3 is just an app so it only uses them if I manually do it which is fine"). The redemption is
    delegated to `codexswitch-cli redeem-reset`, which owns the credentials and its reset journal;
    this hub never touches tokens. Agents must still never redeem resets themselves.
  * Binds to 127.0.0.1 only; every request needs the management key in the key file.
"""
import datetime as dt
import hmac
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HUB_DIR = os.path.expanduser(os.environ.get('CODEX_USAGE_HUB_DIR', '~/.local/share/signul/codex-usage-hub'))
STORE = os.path.expanduser(os.environ.get('CODEX_USAGE_HUB_STORE', '~/.codexswitch/accounts.json'))
KEY_FILE = os.path.join(HUB_DIR, 'management-key')
PORT = int(os.environ.get('CODEX_USAGE_HUB_PORT', '8319'))
APPLE_EPOCH = 978307200  # CodexSwitch stores times as seconds since 2001-01-01 UTC
CODEX_BASE = 'https://chatgpt.com/backend-api/wham'
PLANS = {'pro'}  # accounts shown in T3 (operator asked for the Pro accounts)


def key():
    with open(KEY_FILE) as f:
        return f.read().strip()


def accounts():
    with open(STORE) as f:
        rows = json.load(f)
    shown = [(i, r) for i, r in enumerate(rows) if r.get('planType') in PLANS]
    # T3 labels hub accounts by id, so use the email's local part ("bd7349"), falling back to
    # the full address when two shown accounts share one.
    local = [str(r.get('email') or '').split('@')[0] for _, r in shown]
    out = []
    for (i, r), name in zip(shown, local):
        unique = name and local.count(name) == 1
        out.append((name if unique else str(r.get('email') or r.get('id')), str(i), r))
    return out


def unix(t):
    return None if t is None else int(float(t) + APPLE_EPOCH)


def usage_body(r):
    snap = r.get('quotaSnapshot') or {}
    windows = {}
    for w in snap.get('windows') or []:
        slot = ((w.get('source') or {}).get('slot')) or 'primary'
        windows[slot] = {'used_percent': float(w.get('usedPercent') or 0),
                         'reset_at': unix(w.get('resetsAt')),
                         'limit_window_seconds': int(w.get('durationSeconds') or 0) or None}
    for w in windows.values():
        if w['limit_window_seconds'] is None:
            del w['limit_window_seconds']
    return {'plan_type': r.get('planType'),
            'rate_limit': {'primary_window': windows.get('primary'), 'secondary_window': windows.get('secondary')}}


def credits_body(r):
    bank = r.get('rateLimitResetBank') or {}
    creds = []
    for c in bank.get('credits') or []:
        exp = c.get('expiresAt')
        if exp is None:
            continue
        creds.append({'id': str(c.get('id')), 'status': str(c.get('status')),
                      'reset_type': str(c.get('resetType')),
                      'expires_at': dt.datetime.fromtimestamp(unix(exp), dt.timezone.utc).isoformat()})
    return {'credits': creds}


CS = os.path.expanduser(os.environ.get('CODEX_USAGE_HUB_CLI', '~/.local/share/codexswitch/current/codexswitch-cli'))


# The CLI reports every pre-submission refusal with the same envelope message, so outcomes are
# classified from the envelope disposition plus the error line on stderr, never from the message.
# A "rejected" disposition proves no consume request was sent; these causes are transient races
# with the daemon's per-tick runtime-activation lease (held ~1 s every ~6 s) and are safe to retry
# with the same request id.
TRANSIENT_REJECTIONS = (
    'runtime activation is busy',
    'owns the provider-i/o lease',
    'account store changed before reset provider i/o',
    'account store changed during targeted reset observation',
)
# T3 abandons a management call after 15 s; stop starting new attempts well before that.
RETRY_WINDOW_SECONDS = 8.0
RETRY_DELAY_SECONDS = 0.3


def parse_cli_json(stdout):
    try:
        value = json.loads(stdout.strip() or 'null')
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def redeem(acct, req):
    """Operator-initiated reset redemption through CodexSwitch. Returns an api-call envelope."""
    try:
        data = json.loads(req.get('data') or '{}')
    except ValueError:
        data = {}
    cmd = [CS, 'redeem-reset', str(acct.get('email')), '--json']
    if data.get('redeem_request_id'):
        cmd += ['--request-id', str(data['redeem_request_id'])]
    deadline = time.monotonic() + RETRY_WINDOW_SECONDS
    attempts = 0
    while True:
        attempts += 1
        try:
            # Once started, the CLI owns the journal; never kill it mid-redemption.
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            log_redeem(acct, attempts, None, 'timed out after 120 s; outcome unknown')
            return {'status_code': 504, 'body': '{"error":"codexswitch redeem-reset timed out"}'}
        report = parse_cli_json(r.stdout)
        disposition = (report or {}).get('disposition')
        error_line = r.stderr.strip().lower()
        if (r.returncode != 0 and disposition == 'rejected'
                and any(cause in error_line for cause in TRANSIENT_REJECTIONS)
                and time.monotonic() + RETRY_DELAY_SECONDS < deadline):
            time.sleep(RETRY_DELAY_SECONDS)
            continue
        log_redeem(acct, attempts, r.returncode, (r.stdout + r.stderr)[-600:])
        break
    if r.returncode == 0:
        # The CLI exits 0 only after the reset is reconciled as usable and committed.
        code = 'already_redeemed' if (report or {}).get('submittedReset') is False else 'reset'
        return {'status_code': 200, 'body': json.dumps({'code': code})}
    if disposition == 'rejected' and 'requires a fresh blocked quota' in error_line and 'usable' in error_line:
        return {'status_code': 200, 'body': json.dumps({'code': 'nothing_to_reset'})}
    if disposition == 'rejected':
        # Nothing was spent; surface a real error instead of a misleading "no credit".
        return {'status_code': 409, 'body': json.dumps({'error': 'codexswitch rejected the reset; see redeem.log'})}
    return {'status_code': 502, 'body': json.dumps({'error': 'codexswitch reset outcome unknown; see redeem.log'})}


def log_redeem(acct, attempts, returncode, tail):
    with open(os.path.join(HUB_DIR, 'redeem.log'), 'a') as f:
        f.write(f"{dt.datetime.now().isoformat(timespec='seconds')} {acct.get('email')} attempts={attempts} rc={returncode} {tail!r}\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        # Path and status only; never headers or bodies.
        try:
            with open(os.path.join(HUB_DIR, 'access.log'), 'a') as f:
                f.write(f"{dt.datetime.now().isoformat(timespec='seconds')} {self.command} {self.path} {a[1] if len(a) > 1 else ''}\n")
        except OSError:
            pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        got = self.headers.get('Authorization', '')
        return hmac.compare_digest(got, f'Bearer {key()}')

    def do_GET(self):
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        if self.path.rstrip('/') == '/v0/management/auth-files':
            files = []
            for aid, idx, r in accounts():
                files.append({'id': aid, 'auth_index': idx, 'provider': 'codex', 'email': r.get('email'),
                              'disabled': False,
                              'id_token': {'chatgpt_plan_type': r.get('planType')}})
            return self.reply(200, {'files': files})
        return self.reply(404, {'error': 'not found'})

    def do_POST(self):
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        path = self.path.rstrip('/')
        if path == '/v0/management/reset-quota':
            # CodexSwitch clears its own cooldown state as part of redeem-reset.
            return self.reply(200, {'ok': True})
        if path != '/v0/management/api-call':
            return self.reply(404, {'error': 'not found'})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
        except ValueError:
            return self.reply(400, {'error': 'bad json'})
        acct = next((r for aid, idx, r in accounts() if idx == str(req.get('auth_index'))), None)
        if acct is None:
            return self.reply(200, {'status_code': 404, 'body': '{}'})
        url = str(req.get('url', ''))
        if url == f'{CODEX_BASE}/usage':
            return self.reply(200, {'status_code': 200, 'body': json.dumps(usage_body(acct))})
        if url == f'{CODEX_BASE}/rate-limit-reset-credits':
            return self.reply(200, {'status_code': 200, 'body': json.dumps(credits_body(acct))})
        if url == f'{CODEX_BASE}/rate-limit-reset-credits/consume':
            return self.reply(200, redeem(acct, req))
        # Anything else is refused.
        return self.reply(200, {'status_code': 403, 'body': '{"error":"read-only hub"}'})


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
