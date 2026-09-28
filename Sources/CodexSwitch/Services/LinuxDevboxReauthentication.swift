import CryptoKit
import Darwin
import Foundation

enum LinuxDevboxReauthentication {
    static let queueKey = "linuxDevboxPendingReauthV1"
    static let pendingNotice = "Mac sign-in succeeded; VPS credential delivery is pending and will retry."

    static func acknowledge(_ queue: [String: String], accountID: String, fingerprint: String) -> [String: String] {
        var result = queue
        if result[accountID] == fingerprint { result.removeValue(forKey: accountID) }
        return result
    }

    static func fingerprint(_ account: CodexAccount) -> String {
        let data = try! JSONEncoder().encode([
            account.accountId, account.email, account.idToken,
            account.accessToken, account.refreshToken
        ])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deliver(_ account: CodexAccount, settings: LinuxDevboxMonitorSettings) -> Bool {
        guard settings.isConfigured, account.hasCompleteRuntimeCredentials else { return false }
        // Unlink before spawning SSH: cancellation or an app crash leaves no token file.
        var template = Array((NSTemporaryDirectory() + "codexswitch-reauth-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return false }
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard unlink(path) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        do {
            let payload = try JSONEncoder().encode(account)
            guard payload.count <= 128 * 1024 else { return false }
            try input.write(contentsOf: payload)
            let result = LinuxDevboxMonitor.runSSHWithCandidates(
                LinuxDevboxMonitor.sshArgumentCandidates(settings: settings),
                remoteCommand: "python3 -c " + LinuxDevboxMonitor.shellQuote(remoteScript),
                timeout: 40,
                retryPolicy: .preExecutionTransportOnly
            ) { executable, arguments, timeout in
                do { try input.seek(toOffset: 0) } catch {
                    return ProcessRunResult(terminationStatus: -1, stdout: Data(), stderr: Data(), timedOut: false)
                }
                return ProcessRunner.run(
                    executableURL: executable, arguments: arguments, timeout: timeout,
                    maxOutputBytes: 4096, standardInput: input
                )
            }
            guard !result.timedOut, result.terminationStatus == 0,
                  let response = try JSONSerialization.jsonObject(with: result.stdout) as? [String: String]
            else { return false }
            return response["status"] == "verified" && response["accountId"] == account.accountId
        } catch { return false }
    }

    static let remoteScript = #"""
import base64, fcntl, json, os, pathlib, stat, sys, tempfile, time, urllib.request

TOKEN_KEYS = ('idToken', 'accessToken', 'refreshToken')

def claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '==='))

def validate(candidate):
    identity = claims(candidate['idToken'])
    access = claims(candidate['accessToken'])
    assert identity.get('email', '').lower() == candidate['email'].lower()
    assert access.get('https://api.openai.com/auth', {}).get('chatgpt_account_id') == candidate['accountId']
    assert access['exp'] > time.time() + 60
    request = urllib.request.Request('https://chatgpt.com/backend-api/wham/usage', headers={
        'Authorization': 'Bearer ' + candidate['accessToken'],
        'ChatGPT-Account-Id': candidate['accountId'],
        'Accept': 'application/json', 'User-Agent': 'codex-cli'})
    with urllib.request.urlopen(request, timeout=15) as response:
        assert response.status == 200
        usage = json.load(response)
        assert isinstance(usage, dict) and isinstance(usage.get('rate_limit'), dict)

def regular(fd):
    info = os.fstat(fd)
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
    assert stat.S_IMODE(info.st_mode) & 0o077 == 0

def update(candidate, directory, validator=validate):
    assert all(isinstance(candidate.get(k), str) and candidate[k] for k in (*TOKEN_KEYS, 'accountId', 'email'))
    validator(candidate)
    info = directory.lstat()
    assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022
    root = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock = os.open('accounts.json.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=root)
    temporary = None
    try:
        regular(lock)
        deadline = time.monotonic() + 8
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline: raise TimeoutError()
                time.sleep(0.1)
        fd = os.open('accounts.json', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root)
        with os.fdopen(fd) as source:
            regular(source.fileno())
            accounts = json.load(source)
        assert isinstance(accounts, list) and sum(bool(a.get('isActive')) for a in accounts) == 1
        matches = [a for a in accounts if a.get('accountId') == candidate['accountId']]
        assert len(matches) == 1
        target = matches[0]
        assert target['email'].lower() == candidate['email'].lower()
        identical = all(target.get(k) == candidate[k] for k in TOKEN_KEYS)
        if not identical:
            assert not target.get('isActive'), 'active target needs runtime activation'
            try: previous_iat = claims(target['accessToken']).get('iat', 0)
            except (ValueError, KeyError, IndexError): previous_iat = 0
            assert claims(candidate['accessToken'])['iat'] > previous_iat, 'newer or ambiguous remote credential exists'
            for key in TOKEN_KEYS: target[key] = candidate[key]
        if not identical or target.get('runtimeUnusableReason') or target.get('runtimeUnusableUntil'):
            target['lastRefreshed'] = time.time() - 978307200
            target.pop('runtimeUnusableReason', None)
            target.pop('runtimeUnusableUntil', None)
            fd, temporary = tempfile.mkstemp(prefix='.reauth-', dir=directory)
            with os.fdopen(fd, 'w') as destination:
                json.dump(accounts, destination, separators=(',', ':'))
                destination.flush()
                os.fsync(destination.fileno())
            # The locked directory must still be the store's named directory.
            assert os.stat(directory).st_ino == os.fstat(root).st_ino
            os.replace(pathlib.Path(temporary).name, 'accounts.json', src_dir_fd=root, dst_dir_fd=root)
            temporary = None
            os.fsync(root)
        return {'status': 'verified', 'accountId': candidate['accountId']}
    finally:
        if temporary is not None: os.unlink(temporary)
        os.close(lock)
        os.close(root)

if __name__ == '__main__':
    try:
        payload = sys.stdin.buffer.read(131073)
        assert len(payload) <= 131072
        print(json.dumps(update(json.loads(payload), pathlib.Path.home() / '.codexswitch')))
    except Exception:
        print(json.dumps({'status': 'pending'}))
        sys.exit(1)
"""#
}
