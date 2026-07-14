#!/usr/bin/env python3
import os
import pathlib
import stat
import subprocess
import tempfile
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
case "$field" in
  stat=) print -r -- "S" ;;
  ppid=) awk -F= '$1 == "supervisor_pid" { print $2 }' "$CODEX_VPS_TUNNEL_LOCK_DIR/owner" ;;
  args=) print -r -- "ssh -N -L 18390:127.0.0.1:8390 signul@100.95.84.123" ;;
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

    def test_configurable_ssh_tolerance_defaults_are_cpu_starvation_safe(self):
        result = self.run_zsh(
            'validate_runtime_config\nprintf "%s %s %s" "$SSH_CONNECT_TIMEOUT" '
            '"$SSH_SERVER_ALIVE_INTERVAL" "$SSH_SERVER_ALIVE_COUNT_MAX"'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "30 15 6")

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
