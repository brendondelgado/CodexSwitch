#!/usr/bin/env python3
import os
import pathlib
import shlex
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "codex-vps"


class CodexVPSScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = pathlib.Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.events = self.root / "events.log"
        self.lock_dir = self.root / "tunnel.lock"
        self._write_shims()

        self.env = os.environ.copy()
        self.env.update(
            {
                "CODEX_VPS_SOURCE_ONLY": "1",
                "CODEX_VPS_SCRIPT_PATH": str(SCRIPT),
                "CODEX_VPS_TUNNEL_LOCK_DIR": str(self.lock_dir),
                "CODEX_VPS_SSH_BIN": str(self.bin_dir / "ssh"),
                "CODEX_VPS_LSOF_BIN": str(self.bin_dir / "lsof"),
                "CODEX_VPS_CURL_BIN": str(self.bin_dir / "curl"),
                "CODEX_VPS_KILL_BIN": str(self.bin_dir / "kill"),
                "CODEX_VPS_SLEEP_BIN": str(self.bin_dir / "sleep"),
                "CODEX_VPS_PS_BIN": str(self.bin_dir / "ps"),
                "SHIM_EVENTS": str(self.events),
                "SHIM_PROCESS_START_NONCE": f"test-start-{os.getpid()}-{id(self)}",
            }
        )

    def _write_executable(self, name, text):
        path = self.bin_dir / name
        path.write_text(text)
        path.chmod(0o755)

    def _write_shims(self):
        self._write_executable(
            "ssh",
            """#!/usr/bin/env zsh
print -r -- "ssh $*" >> "$SHIM_EVENTS"
if [[ "$SHIM_SSH_MODE" == "exit" ]]; then
  attempts=0
  while (( attempts < 100 )); do
    recorded="$(awk -F= '$1 == "ssh_pid" { print $2 }' \
      "$CODEX_VPS_TUNNEL_LOCK_DIR/owner" 2>/dev/null)"
    [[ "$recorded" == "$$" ]] && break
    attempts=$((attempts + 1))
    /bin/sleep 0.005
  done
  exit 17
fi
if [[ "$SHIM_SSH_MODE" == "transport-fallback" ]]; then
  [[ "$*" == *"ProxyCommand="* ]] && exit 0
  exit 17
fi
trap 'exit 0' TERM INT
while true; do /bin/sleep 0.1; done
""",
        )
        self._write_executable(
            "lsof",
            """#!/usr/bin/env zsh
case "$SHIM_LISTENER_MODE" in
  unknown) print -r -- "$SHIM_UNKNOWN_PID" ;;
  owned)
    owner="$CODEX_VPS_TUNNEL_LOCK_DIR/owner"
    [[ -f "$owner" ]] && awk -F= '$1 == "ssh_pid" && $2 != "" { print $2 }' "$owner"
    ;;
esac
""",
        )
        self._write_executable(
            "curl",
            """#!/usr/bin/env zsh
print -r -- "curl" >> "$SHIM_EVENTS"
[[ "$SHIM_HEALTH_MODE" == "ok" ]]
""",
        )
        self._write_executable(
            "kill",
            """#!/usr/bin/env zsh
if [[ "$1" != "-0" ]]; then
  print -r -- "kill $*" >> "$SHIM_EVENTS"
fi
exec /bin/kill "$@"
""",
        )
        self._write_executable(
            "ps",
            """#!/usr/bin/env zsh
pid=""
field=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    -o) field="$2"; shift 2 ;;
    *) shift ;;
  esac
done
/bin/kill -0 "$pid" 2>/dev/null || exit 1
owner=""
supervisor=""
ssh_child=""
if [[ -f "$CODEX_VPS_TUNNEL_LOCK_DIR/owner" ]]; then
  owner="$(awk -F= '$1 == "owner_pid" { print $2 }' "$CODEX_VPS_TUNNEL_LOCK_DIR/owner")"
  supervisor="$(awk -F= '$1 == "supervisor_pid" { print $2 }' "$CODEX_VPS_TUNNEL_LOCK_DIR/owner")"
  ssh_child="$(awk -F= '$1 == "ssh_pid" { print $2 }' "$CODEX_VPS_TUNNEL_LOCK_DIR/owner")"
fi
case "$field" in
  stat=) print -r -- "S" ;;
  uid=) /usr/bin/id -u ;;
  comm=) print -r -- "/bin/zsh" ;;
  lstart=) print -r -- "$SHIM_PROCESS_START_NONCE-$pid" ;;
  ppid=)
    if [[ -n "$SHIM_KNOWN_SUPERVISOR_PID" && "$pid" == "$SHIM_KNOWN_SUPERVISOR_PID" ]]; then
      print -r -- "$SHIM_KNOWN_OWNER_PID"
    elif [[ -n "$supervisor" && "$pid" == "$supervisor" ]]; then
      print -r -- "$owner"
    else
      print -r -- "$supervisor"
    fi
    ;;
  args=)
    if [[ "$pid" == "$SHIM_KNOWN_OWNER_PID" || "$pid" == "$SHIM_KNOWN_SUPERVISOR_PID" ||
          "$pid" == "$owner" || "$pid" == "$supervisor" ]]; then
      print -r -- "zsh $CODEX_VPS_SCRIPT_PATH --remote-client"
    else
      print -r -- "ssh -N -L 18390:127.0.0.1:8390 signul@100.95.84.123"
    fi
    ;;
esac
""",
        )
        self._write_executable(
            "sleep",
            """#!/usr/bin/env zsh
print -r -- "sleep $1" >> "$SHIM_EVENTS"
if [[ -n "$SHIM_SLEEP_TICK" ]]; then
  /bin/sleep "$SHIM_SLEEP_TICK"
fi
""",
        )

    def run_zsh(self, body, **env_overrides):
        env = self.env.copy()
        env.update({key: str(value) for key, value in env_overrides.items()})
        return subprocess.run(
            ["zsh", "-c", f'source "$CODEX_VPS_SCRIPT_PATH"\n{body}'],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def event_lines(self):
        if not self.events.exists():
            return []
        return self.events.read_text().splitlines()

    def write_tunnel_metadata_fixture(self, lock_dir, evidence):
        lock_dir.mkdir(mode=0o700)
        owner_file = lock_dir / "owner"
        owner_file.write_text(
            "".join(f"{key}={value}\n" for key, value in evidence.items())
        )
        owner_file.chmod(0o600)
        return owner_file

    def start_sleeper(self):
        process = subprocess.Popen(["/bin/sleep", "30"])

        def stop():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=2)

        self.addCleanup(stop)
        return process

    def start_tunnel_helper(self):
        ready = self.root / "helper-ready"
        helper_log = self.root / "helper.log"
        env = self.env.copy()
        env.update(
            {
                "SHIM_LISTENER_MODE": "owned",
                "SHIM_SSH_MODE": "hold",
                "SHIM_HEALTH_MODE": "ok",
                "SHIM_SLEEP_TICK": "0.03",
            }
        )
        body = f"""
source {shlex.quote(str(SCRIPT))}
trap cleanup_tunnel_supervisor EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
acquire_tunnel_lock
run_tunnel_supervisor &
TUNNEL_SUPERVISOR_PID="$!"
wait_for_health
print -r -- ready > {shlex.quote(str(ready))}
wait "$TUNNEL_SUPERVISOR_PID"
"""
        with helper_log.open("w") as log_handle:
            process = subprocess.Popen(
                ["zsh", "-c", body],
                cwd=ROOT,
                env=env,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
            )

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

        self.addCleanup(stop)
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and not ready.exists():
            if process.poll() is not None:
                self.fail(
                    f"tunnel helper exited before readiness: {process.returncode}\n"
                    f"{helper_log.read_text()}"
                )
            time.sleep(0.02)
        if not ready.exists():
            metadata = (
                (self.lock_dir / "owner").read_text()
                if (self.lock_dir / "owner").exists()
                else "<missing metadata>\n"
            )
            self.fail(
                "tunnel helper did not publish readiness\n"
                f"{helper_log.read_text()}\n{metadata}"
                f"events={self.event_lines()}"
            )
        return process

    def test_configurable_ssh_tolerance_defaults_are_cpu_starvation_safe(self):
        result = self.run_zsh(
            'validate_runtime_config\nprintf "%s %s %s" "$SSH_CONNECT_TIMEOUT" '
            '"$SSH_SERVER_ALIVE_INTERVAL" "$SSH_SERVER_ALIVE_COUNT_MAX"'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "30 15 6")

    def test_tailscale_check_failure_does_not_abort_normal_transport_fallbacks(self):
        result = self.run_zsh(
            """timeout() { shift; "$@" }
TAILSCALE_BIN=/usr/bin/true
maybe_run_tailscale_ssh_check() {
  print -r -- "tailscale-check" >> "$SHIM_EVENTS"
  return 1
}
select_ssh_transport
print -r -- "selected=$USE_TAILSCALE_PROXY"
""",
            SHIM_SSH_MODE="transport-fallback",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "selected=1")
        events = self.event_lines()
        self.assertEqual(events.count("tailscale-check"), 1)
        self.assertEqual(sum(line.startswith("ssh ") for line in events), 2)

    def test_repository_paths_are_portable_and_configurable(self):
        defaults = self.run_zsh(
            'printf "%s\\n%s" "$LOCAL_REPO" "$REMOTE_REPO"',
            HOME=self.root,
        )
        configured = self.run_zsh(
            'printf "%s\\n%s" "$LOCAL_REPO" "$REMOTE_REPO"',
            CODEX_VPS_LOCAL_REPO=self.root / "local repo",
            CODEX_VPS_REMOTE_REPO="/srv/codex repo",
        )

        self.assertEqual(defaults.returncode, 0, defaults.stderr)
        self.assertEqual(defaults.stdout.splitlines(), [str(self.root / "SIGNUL"), "/home/signul/SIGNUL"])
        self.assertEqual(configured.returncode, 0, configured.stderr)
        self.assertEqual(configured.stdout.splitlines(), [str(self.root / "local repo"), "/srv/codex repo"])
        self.assertNotIn("/Users/brendondelgado", SCRIPT.read_text())

    def test_thread_ids_must_be_canonical_uuids(self):
        valid = self.run_zsh(
            'require_valid_thread_id "019ddf25-8e5d-7d93-9006-54488876f0fa"'
        )
        injected = self.run_zsh(
            "require_valid_thread_id \"x'; touch /tmp/codex-vps-injected; #\""
        )

        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(injected.returncode, 2)
        self.assertIn("expected a canonical UUID", injected.stderr)
        self.assertFalse(pathlib.Path("/tmp/codex-vps-injected").exists())

    def test_sol_reasoning_efforts_are_forwarded_to_remote_sessions(self):
        result = self.run_zsh(
            """for effort in max ultra; do
  safe_reasoning_effort_value "$effort" || exit 9
done
CODEX_VPS_REASONING_EFFORT=ultra
codex_launch_config_args
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("model_reasoning_effort=ultra", result.stdout)

    def test_invalid_resume_id_is_rejected_before_network_or_persistence(self):
        thread_file = self.root / "thread-id"
        result = self.run_zsh(
            """set +e
THREAD_ID_FILE="$TEST_THREAD_FILE"
codex_vps_main resume "bad'; touch /tmp/codex-vps-main-injected; #"
exit_code=$?
print -r -- "$exit_code"
""",
            TEST_THREAD_FILE=thread_file,
            CODEX_VPS_FORCE_TUNNEL=1,
        )

        self.assertEqual(result.stdout.strip(), "2")
        self.assertEqual(self.event_lines(), [])
        self.assertFalse(thread_file.exists())
        self.assertFalse(pathlib.Path("/tmp/codex-vps-main-injected").exists())

    def test_help_and_local_thread_selection_do_not_touch_network(self):
        thread_file = self.root / "state" / "thread-id"
        thread_id = "019ddf25-8e5d-7d93-9006-54488876f0fa"

        help_result = self.run_zsh("codex_vps_main help")
        use_result = self.run_zsh(
            'THREAD_ID_FILE="$TEST_THREAD_FILE"\n'
            f'codex_vps_main use "{thread_id}"',
            TEST_THREAD_FILE=thread_file,
        )

        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("codex-vps sync-client", help_result.stdout)
        self.assertEqual(use_result.returncode, 0, use_result.stderr)
        self.assertEqual(thread_file.read_text(), f"{thread_id}\n")
        self.assertEqual(stat.S_IMODE(thread_file.stat().st_mode), 0o600)
        self.assertEqual(self.event_lines(), [])

    def test_service_start_and_client_install_are_explicit_commands(self):
        source = SCRIPT.read_text()

        self.assertNotIn(
            'systemctl --user start ${SERVICE_NAME} >/dev/null 2>&1 || true',
            source,
        )
        self.assertIn('if [ "${1:-}" = "start" ]', source)
        self.assertIn('if [ "${1:-}" = "sync-client" ]', source)
        self.assertIn("run 'codex-vps sync-client'", source)

    def test_check_rejects_remote_version_change_without_printing_equality(self):
        client = self.root / "codex-0.144.4"
        client.write_text("#!/usr/bin/env zsh\nprint -r -- 'codex-cli 0.144.4'\n")
        client.chmod(0o755)
        result = self.run_zsh(
            """NPM_REMOTE_CLIENT="$TEST_CLIENT"
APP_BUNDLED_CLIENT="$TEST_MISSING_APP"
PATCHED_REMOTE_CLIENT="$TEST_MISSING_PATCHED"
LOCAL_CLIENT="$TEST_MISSING_LOCAL"
direct_tailscale_app_server_available() { return 0 }
remote_codex_version() { print -r -- "0.144.4" }
app_server_codex_version() { print -r -- "0.144.6" }
remote_doctor_json() { print -r -- '{"ready":true}' }
set +e
output="$(codex_vps_main --check 2>&1)"
exit_code=$?
set -e
print -r -- "$exit_code"
print -r -- "$output"
""",
            TEST_CLIENT=client,
            TEST_MISSING_APP=self.root / "missing-app",
            TEST_MISSING_PATCHED=self.root / "missing-patched",
            TEST_MISSING_LOCAL=self.root / "missing-local",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "1")
        self.assertIn(
            "remote app-server version changed during transport setup "
            "(selected 0.144.4, established 0.144.6)",
            result.stdout,
        )
        self.assertNotIn(" == ", result.stdout)

    def test_check_rejects_healthy_doctor_report_with_missing_app_server_ack(self):
        client = self.root / "codex-0.144.6"
        client.write_text("#!/usr/bin/env zsh\nprint -r -- 'codex-cli 0.144.6'\n")
        client.chmod(0o755)
        result = self.run_zsh(
            """NPM_REMOTE_CLIENT="$TEST_CLIENT"
APP_BUNDLED_CLIENT="$TEST_MISSING_APP"
PATCHED_REMOTE_CLIENT="$TEST_MISSING_PATCHED"
LOCAL_CLIENT="$TEST_MISSING_LOCAL"
direct_tailscale_app_server_available() { return 0 }
remote_codex_version() { print -r -- "0.144.6" }
app_server_codex_version() { print -r -- "0.144.6" }
remote_doctor_json() {
  print -r -- '{"ready":true,"summary":"healthy endpoint",'\
'"accountStoreOk":true,"authWritable":true,"daemonRunning":true,'\
'"accountCount":2,"activeEmail":"active@example.com",'\
'"readyCandidateCount":1,"activationBarrier":false,'\
'"activationBarrierClear":true,"activationState":"confirmed","processes":[],'\
'"appServers":[{"pid":42,"executable":"/release/codex",'\
'"hotSwapReady":false,"reason":"live process has not acknowledged a reload"}],'\
'"issues":[]}'
}
set +e
output="$(codex_vps_main --check 2>&1)"
exit_code=$?
set -e
print -r -- "$exit_code"
print -r -- "$output"
""",
            TEST_CLIENT=client,
            TEST_MISSING_APP=self.root / "missing-app",
            TEST_MISSING_PATCHED=self.root / "missing-patched",
            TEST_MISSING_LOCAL=self.root / "missing-local",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "1")
        self.assertIn("app-server acknowledgement missing for pid(s): 42", result.stdout)
        self.assertNotIn("codex-vps ready:", result.stdout)
        self.assertNotIn(" == ", result.stdout)

    def test_doctor_accepts_full_camel_case_rust_report(self):
        result = self.run_zsh(
            """print -r -- '{"ready":true,"summary":"ready with ACK",'\
'"accountStoreOk":true,"authWritable":true,"daemonRunning":true,'\
'"accountCount":2,"activeEmail":"active@example.com",'\
'"readyCandidateCount":1,"activationBarrier":false,'\
'"activationBarrierClear":true,"activationState":"confirmed","processes":[],'\
'"appServers":[{"pid":42,"executable":"/release/codex",'\
'"hotSwapReady":true,"reason":"current version-3 acknowledgement"}],'\
'"issues":[]}' | validate_remote_doctor_json
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ready with ACK")

    def test_doctor_requires_explicit_clear_activation_barrier(self):
        result = self.run_zsh(
            """set +e
output="$(print -r -- '{"ready":true,"processes":[],'\
'"appServers":[{"pid":42,"hotSwapReady":true}]}' | '\
'validate_remote_doctor_json 2>&1)"
exit_code=$?
set -e
print -r -- "$exit_code"
print -r -- "$output"
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "1")
        self.assertIn("activation barrier state is missing", result.stdout)

    def test_check_without_existing_tunnel_is_read_only(self):
        client = self.root / "codex-0.144.6-read-only"
        client.write_text("#!/usr/bin/env zsh\nprint -r -- 'codex-cli 0.144.6'\n")
        client.chmod(0o755)
        result = self.run_zsh(
            """NPM_REMOTE_CLIENT="$TEST_CLIENT"
APP_BUNDLED_CLIENT="$TEST_MISSING_APP"
PATCHED_REMOTE_CLIENT="$TEST_MISSING_PATCHED"
LOCAL_CLIENT="$TEST_MISSING_LOCAL"
direct_tailscale_app_server_available() { return 1 }
refuse_unknown_tunnel_listener() { return 0 }
select_ssh_transport() { return 0 }
remote_codex_version() { print -r -- "0.144.6" }
ssh_remote() {
  if [[ "$*" == *"systemctl --user is-active"* ]]; then
    print -r -- "active"
    return 0
  fi
  return 9
}
owned_tunnel_listener_ok() { return 1 }
ensure_tunnel() { print -r -- "ensure_tunnel" >> "$SHIM_EVENTS"; return 97 }
start_tunnel_supervisor_for_interactive_attach() {
  print -r -- "start_tunnel_supervisor" >> "$SHIM_EVENTS"
  return 97
}
set +e
output="$(codex_vps_main --check 2>&1)"
exit_code=$?
set -e
print -r -- "$exit_code"
print -r -- "$output"
""",
            TEST_CLIENT=client,
            TEST_MISSING_APP=self.root / "missing-app",
            TEST_MISSING_PATCHED=self.root / "missing-patched",
            TEST_MISSING_LOCAL=self.root / "missing-local",
            CODEX_VPS_FORCE_TUNNEL=1,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "1")
        self.assertIn("--check does not create or repair a tunnel", result.stdout)
        self.assertEqual(self.event_lines(), [])
        self.assertFalse(self.lock_dir.exists())

    def test_check_accepts_healthy_tunnel_owned_by_another_verified_helper(self):
        helper = self.start_tunnel_helper()
        owner_file = self.lock_dir / "owner"
        metadata = owner_file.read_text()

        client = self.root / "codex-0.144.6-existing"
        client.write_text("#!/usr/bin/env zsh\nprint -r -- 'codex-cli 0.144.6'\n")
        client.chmod(0o755)
        result = self.run_zsh(
            """NPM_REMOTE_CLIENT="$TEST_CLIENT"
APP_BUNDLED_CLIENT="$TEST_MISSING_APP"
PATCHED_REMOTE_CLIENT="$TEST_MISSING_PATCHED"
LOCAL_CLIENT="$TEST_MISSING_LOCAL"
direct_tailscale_app_server_available() { return 1 }
select_ssh_transport() { return 0 }
remote_codex_version() { print -r -- "0.144.6" }
app_server_codex_version() { print -r -- "0.144.6" }
ssh_remote() {
  case "$*" in
    *"systemctl --user is-active"*) print -r -- "active" ;;
    *"doctor --json"*)
      print -r -- '{"ready":true,"summary":"existing helper ready",'\
'"activationBarrier":false,"activationBarrierClear":true,"processes":[],'\
'"appServers":[{"pid":42,"hotSwapReady":true}]}'
      ;;
    *) return 9 ;;
  esac
}
ensure_tunnel() { print -r -- "ensure_tunnel" >> "$SHIM_EVENTS"; return 97 }
start_tunnel_supervisor_for_interactive_attach() {
  print -r -- "start_tunnel_supervisor" >> "$SHIM_EVENTS"
  return 97
}
codex_vps_main --check
""",
            TEST_CLIENT=client,
            TEST_MISSING_APP=self.root / "missing-app",
            TEST_MISSING_PATCHED=self.root / "missing-patched",
            TEST_MISSING_LOCAL=self.root / "missing-local",
            SHIM_LISTENER_MODE="owned",
            SHIM_HEALTH_MODE="ok",
            CODEX_VPS_FORCE_TUNNEL=1,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("codex-vps ready: existing local", result.stdout)
        self.assertIn("existing helper ready", result.stdout)
        self.assertIn("Mac remote client 0.144.6 == VPS app-server 0.144.6", result.stdout)
        self.assertEqual(owner_file.read_text(), metadata)
        self.assertIsNone(helper.poll())
        self.assertEqual(owner_file.stat().st_uid, os.getuid())
        self.assertEqual(stat.S_IMODE(owner_file.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.lock_dir.stat().st_mode), 0o700)
        events = self.event_lines()
        self.assertNotIn("ensure_tunnel", events)
        self.assertNotIn("start_tunnel_supervisor", events)
        self.assertFalse(any(line.startswith("kill ") for line in events))

    def test_tunnel_metadata_rejects_tampered_process_evidence_and_mode(self):
        helper = self.start_tunnel_helper()
        source_metadata = (self.lock_dir / "owner").read_text().splitlines()
        evidence = dict(line.split("=", 1) for line in source_metadata)

        cases = {}
        for prefix in ("owner", "supervisor", "ssh"):
            cases[f"{prefix}_uid"] = str(int(evidence[f"{prefix}_uid"]) + 1)
            cases[f"{prefix}_executable"] = evidence[f"{prefix}_executable"] + "-other"
            cases[f"{prefix}_start"] = evidence[f"{prefix}_start"] + " other"

        for index, (field, replacement) in enumerate(cases.items()):
            with self.subTest(field=field):
                case_lock = self.root / f"tampered-{index}.lock"
                case_lock.mkdir(mode=0o700)
                case_file = case_lock / "owner"
                tampered = dict(evidence)
                tampered[field] = replacement
                case_file.write_text(
                    "".join(f"{key}={value}\n" for key, value in tampered.items())
                )
                case_file.chmod(0o600)
                result = self.run_zsh(
                    """if known_helper_tunnel_metadata_ok; then
  exit 9
fi
print -r -- rejected
                    """,
                    CODEX_VPS_TUNNEL_LOCK_DIR=case_lock,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "rejected")

        mode_lock = self.root / "bad-mode.lock"
        mode_lock.mkdir(mode=0o700)
        mode_file = mode_lock / "owner"
        mode_file.write_text("\n".join(source_metadata) + "\n")
        mode_file.chmod(0o644)
        mode_result = self.run_zsh(
            """if known_helper_tunnel_metadata_ok; then
  exit 9
fi
print -r -- rejected
            """,
            CODEX_VPS_TUNNEL_LOCK_DIR=mode_lock,
        )
        self.assertEqual(mode_result.returncode, 0, mode_result.stderr)
        self.assertEqual(mode_result.stdout.strip(), "rejected")

        self._write_executable(
            "foreign-stat",
            """#!/usr/bin/env zsh
if { [[ "$1" == "-f" && "$2" == "%u" ]] ||
     [[ "$1" == "-c" && "$2" == "%u" ]]; } &&
   [[ "$3" == "$SHIM_FOREIGN_METADATA" ]]; then
  print -r -- "$SHIM_FOREIGN_UID"
  exit 0
fi
exec /usr/bin/stat "$@"
""",
        )
        owner_result = self.run_zsh(
            """if known_helper_tunnel_metadata_ok; then
  exit 9
fi
print -r -- rejected
            """,
            CODEX_VPS_STAT_BIN=self.bin_dir / "foreign-stat",
            SHIM_FOREIGN_METADATA=self.lock_dir / "owner",
            SHIM_FOREIGN_UID=os.getuid() + 1,
        )
        self.assertEqual(owner_result.returncode, 0, owner_result.stderr)
        self.assertEqual(owner_result.stdout.strip(), "rejected")
        self.assertIsNone(helper.poll())

    def test_lock_acquisition_fails_closed_for_reused_or_mismatched_owner_pid(self):
        helper = self.start_tunnel_helper()
        reused_pid = self.start_sleeper().pid
        evidence = dict(
            line.split("=", 1)
            for line in (self.lock_dir / "owner").read_text().splitlines()
        )
        reused = dict(evidence)
        reused["owner_pid"] = str(reused_pid)
        reused["owner_token"] = f"{reused_pid}-1-2-3"

        cases = {
            "pid-reuse": reused,
            "uid": {
                **evidence,
                "owner_uid": str(int(evidence["owner_uid"]) + 1),
            },
            "start": {
                **evidence,
                "owner_start": evidence["owner_start"] + "-reused",
            },
            "executable": {
                **evidence,
                "owner_executable": evidence["owner_executable"] + "-reused",
            },
        }

        kill_events_before = [
            line for line in self.event_lines() if line.startswith("kill ")
        ]
        for name, case_evidence in cases.items():
            with self.subTest(case=name):
                case_lock = self.root / f"owner-provenance-{name}.lock"
                owner_file = self.write_tunnel_metadata_fixture(
                    case_lock, case_evidence
                )
                original_metadata = owner_file.read_text()
                result = self.run_zsh(
                    """set +e
acquire_tunnel_lock
exit_code=$?
set -e
print -r -- "$exit_code"
""",
                    CODEX_VPS_TUNNEL_LOCK_DIR=case_lock,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "1")
                self.assertIn("owner UID/start-time/executable provenance", result.stderr)
                self.assertEqual(owner_file.read_text(), original_metadata)
                self.assertFalse(
                    list(self.root.glob(f"{case_lock.name}.stale.*")),
                    "mismatched live owner evidence must not be cleaned",
                )

        kill_events_after = [
            line for line in self.event_lines() if line.startswith("kill ")
        ]
        self.assertEqual(kill_events_after, kill_events_before)
        self.assertIsNone(helper.poll())

    def test_check_rejects_unknown_listener_without_signaling_or_takeover(self):
        listener = self.start_sleeper()
        client = self.root / "codex-0.144.6-unknown-listener"
        client.write_text("#!/usr/bin/env zsh\nprint -r -- 'codex-cli 0.144.6'\n")
        client.chmod(0o755)
        result = self.run_zsh(
            """NPM_REMOTE_CLIENT="$TEST_CLIENT"
APP_BUNDLED_CLIENT="$TEST_MISSING_APP"
PATCHED_REMOTE_CLIENT="$TEST_MISSING_PATCHED"
LOCAL_CLIENT="$TEST_MISSING_LOCAL"
direct_tailscale_app_server_available() { return 1 }
select_ssh_transport() { return 0 }
remote_codex_version() { print -r -- "0.144.6" }
ssh_remote() { print -r -- "active" }
set +e
output="$(codex_vps_main --check 2>&1)"
exit_code=$?
set -e
print -r -- "$exit_code"
print -r -- "$output"
""",
            TEST_CLIENT=client,
            TEST_MISSING_APP=self.root / "missing-app",
            TEST_MISSING_PATCHED=self.root / "missing-patched",
            TEST_MISSING_LOCAL=self.root / "missing-local",
            SHIM_LISTENER_MODE="unknown",
            SHIM_UNKNOWN_PID=listener.pid,
            CODEX_VPS_FORCE_TUNNEL=1,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "1")
        self.assertIn("not an active tunnel with exact codex-vps provenance", result.stdout)
        self.assertIsNone(listener.poll())
        self.assertFalse(self.lock_dir.exists())
        self.assertFalse(any(line.startswith("kill ") for line in self.event_lines()))

    def test_fallback_probe_and_direct_session_route_through_current_release(self):
        result = self.run_zsh(
            """REMOTE_RELEASE_ROOT=/home/signul/.local/share/codexswitch/current
REMOTE_RELEASE_CODEX="$REMOTE_RELEASE_ROOT/patched-codex/codex"
app_server_codex_version() { return 1 }
ssh_remote() {
  case "$*" in
    *current/patched-codex/codex*) print -r -- "codex-cli 2.0.0" ;;
    *codexswitch/patched-codex/codex*) print -r -- "codex-cli 1.0.0" ;;
    *) return 9 ;;
  esac
}
print -r -- "version=$(remote_codex_version)"
print -r -- "command=$(direct_ssh_session_command '-c features.goals=true')"
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version=2.0.0", result.stdout)
        self.assertIn(
            "exec /home/signul/.local/share/codexswitch/current/"
            "patched-codex/codex",
            result.stdout,
        )
        self.assertNotIn(
            "exec /home/signul/.local/share/codexswitch/patched-codex/codex",
            result.stdout,
        )
        self.assertNotIn(
            "~/.local/share/codexswitch/patched-codex/codex",
            SCRIPT.read_text(),
        )

    def test_implicit_thread_healing_has_been_removed(self):
        source = SCRIPT.read_text()

        self.assertNotIn("heal_remote_thread_state", source)
        self.assertNotIn("os.replace(tmp_path, rollout_path)", source)

    def test_owned_ssh_child_is_verified_and_stopped(self):
        result = self.run_zsh(
            """set -e
acquire_tunnel_lock
TUNNEL_SUPERVISOR_PID="$(current_process_pid)"
write_tunnel_metadata "$TUNNEL_SUPERVISOR_PID" ""
spawn_tunnel_ssh_child
/bin/sleep 0.1
owned_tunnel_listener_ok
owned_pid="$TUNNEL_SSH_PID"
stop_owned_ssh_child
if /bin/kill -0 "$owned_pid" 2>/dev/null; then exit 9; fi
release_tunnel_lock
print -r -- "$owned_pid"
""",
            SHIM_LISTENER_MODE="owned",
            SHIM_SSH_MODE="hold",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^\d+$")
        self.assertFalse(self.lock_dir.exists())
        self.assertTrue(any(line.startswith("kill -TERM ") for line in self.event_lines()))

    def test_disabled_auto_reconnect_preserves_tunnel_owner_identity(self):
        self._write_executable(
            "identity-client",
            """#!/usr/bin/python3
import os
import pathlib
import subprocess

owner_file = pathlib.Path(os.environ["CODEX_VPS_TUNNEL_LOCK_DIR"]) / "owner"
metadata = dict(line.split("=", 1) for line in owner_file.read_text().splitlines())
owner_pid = int(metadata["owner_pid"])
owner_executable = metadata["owner_executable"]
actual_executable = subprocess.run(
    [os.environ["CODEX_VPS_PS_BIN"], "-p", str(owner_pid), "-o", "comm="],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()

if owner_pid == os.getpid() or actual_executable != owner_executable:
    raise SystemExit(91)
with open(os.environ["SHIM_EVENTS"], "a", encoding="utf-8") as handle:
    handle.write("client observed valid tunnel owner identity\\n")
raise SystemExit(23)
""",
        )

        result = self.run_zsh(
            """direct_tailscale_app_server_available() { return 1 }
refuse_unknown_tunnel_listener() { return 0 }
select_ssh_transport() { return 0 }
check_remote_disk_headroom() { return 0 }
require_matching_local_remote_client() {
  LOCAL_CLIENT="$TEST_CLIENT"
  REMOTE_VERSION_SNAPSHOT="0.144.6"
  LOCAL_CLIENT_VERSION_SNAPSHOT="0.144.6"
}
start_tunnel_supervisor_for_interactive_attach() { acquire_tunnel_lock }
verify_remote_version_snapshot() { return 0 }
codex_launch_config_args() { return 0 }
codex_vps_main
""",
            TEST_CLIENT=self.bin_dir / "identity-client",
            CODEX_VPS_AUTO_RECONNECT=0,
            CODEX_VPS_FORCE_TUNNEL=1,
            CODEX_VPS_LOCAL_REPO=self.root,
        )

        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn(
            "client observed valid tunnel owner identity",
            self.event_lines(),
        )
        self.assertFalse(self.lock_dir.exists(), result.stderr)

    def test_unknown_listener_is_refused_and_never_signaled(self):
        listener = subprocess.Popen(["/bin/sleep", "30"])
        def stop_listener():
            if listener.poll() is None:
                listener.terminate()
                listener.wait(timeout=2)

        self.addCleanup(stop_listener)

        result = self.run_zsh(
            """if start_tunnel_supervisor_for_interactive_attach; then
  exit 9
fi
""",
            SHIM_LISTENER_MODE="unknown",
            SHIM_UNKNOWN_PID=listener.pid,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(listener.poll())
        self.assertIn("refusing listener", result.stderr)
        self.assertFalse(any(str(listener.pid) in line for line in self.event_lines()))

    def test_health_failures_are_debounced_before_owned_child_cleanup(self):
        result = self.run_zsh(
            """set -e
acquire_tunnel_lock
( run_tunnel_supervisor )
release_tunnel_lock
""",
            SHIM_LISTENER_MODE="owned",
            SHIM_SSH_MODE="hold",
            SHIM_HEALTH_MODE="fail",
            SHIM_SLEEP_TICK="0.02",
            CODEX_VPS_TUNNEL_HEALTH_FAILURE_LIMIT=3,
            CODEX_VPS_TEST_TUNNEL_SUPERVISOR_MAX_ITERATIONS=3,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.event_lines()
        first_kill = next(i for i, line in enumerate(events) if line.startswith("kill -TERM "))
        self.assertEqual(sum(line == "curl" for line in events[:first_kill]), 3)
        self.assertIn("failed (1/3); keeping owned child open", result.stderr)
        self.assertIn("failed (2/3); keeping owned child open", result.stderr)

    def test_tunnel_retries_use_bounded_exponential_backoff_without_service_restart(self):
        result = self.run_zsh(
            """set -e
acquire_tunnel_lock
( run_tunnel_supervisor )
release_tunnel_lock
""",
            SHIM_LISTENER_MODE="none",
            SHIM_SSH_MODE="exit",
            SHIM_HEALTH_MODE="fail",
            SHIM_SLEEP_TICK="0.03",
            CODEX_VPS_TUNNEL_HEALTH_FAILURE_LIMIT=20,
            CODEX_VPS_TUNNEL_RECONNECT_DELAY=2,
            CODEX_VPS_TUNNEL_RECONNECT_DELAY_MAX=4,
            CODEX_VPS_TEST_TUNNEL_SUPERVISOR_MAX_ITERATIONS=5,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("retrying SSH tunnel in 2s", result.stderr)
        self.assertIn("retrying SSH tunnel in 4s", result.stderr)
        self.assertNotIn("retrying SSH tunnel in 8s", result.stderr)
        self.assertGreaterEqual(sum(line.startswith("ssh ") for line in self.event_lines()), 3)
        self.assertFalse(any("systemctl" in line for line in self.event_lines()))


if __name__ == "__main__":
    unittest.main()
