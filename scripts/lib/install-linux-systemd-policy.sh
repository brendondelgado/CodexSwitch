# shellcheck shell=bash
systemd_contract_value() {
  local category="$1"
  local unit="$2"
  local property="$3"
  manifest_value "$SYSTEMD_CONTRACT_MANIFEST" "$category:$unit:$property"
}

expected_systemd_value() {
  systemd_contract_value unit "$1" "$2"
}

expected_effective_systemd_resource() {
  systemd_contract_value resource "$1" "$2"
}

systemd_start_barrier_root() {
  local runtime_root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  runtime_root="$(canonicalize_path "$runtime_root")"
  printf '%s/systemd/user.control\n' "$runtime_root"
}

systemd_start_barrier_path() {
  printf '%s/%s.d/00-codexswitch-activation-guard.conf\n' \
    "${SYSTEMD_START_BARRIER_ROOT:-$(systemd_start_barrier_root)}" "$1"
}

systemd_start_mask_path() {
  printf '%s/%s\n' \
    "${SYSTEMD_START_BARRIER_ROOT:-$(systemd_start_barrier_root)}" "$1"
}

systemd_start_barrier_helper() {
  python3 "$SYSTEMD_START_BARRIER_HELPER" "$@"
}

systemd_unit_load_state() {
  local unit="$1"
  local observed=""

  observed="$(systemctl --user show "$unit" -p LoadState --value 2>&1)" || \
    fail "failed to classify systemd start barrier: unit=$unit output=${observed:-<empty>}"
  case "$observed" in
    loaded|not-found) printf '%s\n' "$observed" ;;
    *) fail "systemd start barrier unit has unsupported load state: unit=$unit LoadState=${observed:-<empty>}" ;;
  esac
}

initial_systemd_start_barrier_modes() {
  local unit=""
  local load_state=""

  while IFS= read -r unit; do
    load_state="$(systemd_unit_load_state "$unit")" || return $?
    case "$load_state" in
      loaded) printf '%s\tcondition\n' "$unit" ;;
      not-found) printf '%s\tmask\n' "$unit" ;;
    esac
  done < <(activation_blocking_systemd_units)
}

replacement_systemd_start_barrier_modes() {
  local unit=""
  local kind=""

  while IFS= read -r unit; do
    case "$unit" in
      codexswitch.service|signul-codex-app-server.service)
        kind="$(awk -F '\t' -v unit="$unit" '$1 == unit { print $2; found=1 } END { if (!found) exit 1 }' <<< "$SYSTEMD_START_BARRIER_MODES")" || \
          fail "systemd start barrier mode is missing for target unit: $unit"
        printf '%s\t%s\n' "$unit" "$kind"
        ;;
      *) printf '%s\tmask\n' "$unit" ;;
    esac
  done < <(activation_blocking_systemd_units)
}

installed_systemd_start_barrier_modes() {
  local unit=""

  while IFS= read -r unit; do
    case "$unit" in
      codexswitch.service|signul-codex-app-server.service)
        printf '%s\tcondition\n' "$unit"
        ;;
      *) printf '%s\tmask\n' "$unit" ;;
    esac
  done < <(activation_blocking_systemd_units)
}

transition_systemd_start_barriers() {
  local desired_modes="$1"
  local owner_start=""
  local units=""

  [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]] || fail "systemd start barriers are not held"
  owner_start="$(process_start_identity "$$")"
  units="$(activation_blocking_systemd_units)"
  systemd_start_barrier_helper transition \
    --root "$SYSTEMD_START_BARRIER_ROOT" \
    --activation-lock "$ACTIVATION_LOCK_FILE" \
    --owner-pid "$$" \
    --owner-start "$owner_start" \
    --owner-token "$ACTIVATION_LOCK_TOKEN" \
    --units "$units" \
    --modes "$desired_modes" \
    --read-limit "$STATE_FILE_MAX_BYTES" || \
    fail "failed to transition exact owned systemd start barriers"
  SYSTEMD_START_BARRIER_MODES="$desired_modes"
}

prepare_systemd_start_barriers_for_replacement() {
  local desired_modes=""

  desired_modes="$(replacement_systemd_start_barrier_modes)"
  [[ "$desired_modes" == "$SYSTEMD_START_BARRIER_MODES" ]] || {
    transition_systemd_start_barriers "$desired_modes"
    systemctl --user daemon-reload || fail "failed to load replacement-safe systemd start barriers"
  }
  verify_systemd_start_barriers
}

prepare_systemd_start_barriers_for_installed_targets() {
  local desired_modes=""

  desired_modes="$(installed_systemd_start_barrier_modes)"
  [[ "$desired_modes" == "$SYSTEMD_START_BARRIER_MODES" ]] || \
    transition_systemd_start_barriers "$desired_modes"
}

require_activation_systemd_units_inactive() {
  local context="$1"
  local units=""
  local observation=""

  units="$(activation_blocking_systemd_units)"
  if ! observation="$(python3 - "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS" "$STATE_FILE_MAX_BYTES" "$units" <<'PY'
import shutil
import subprocess
import sys

timeout = int(sys.argv[1])
output_limit = int(sys.argv[2])
units = [value for value in sys.argv[3].splitlines() if value]
systemctl = shutil.which("systemctl")
if systemctl is None:
    print("systemctl-missing")
    raise SystemExit(1)
try:
    result = subprocess.run(
        [systemctl, "--user", "is-active", *units],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
except subprocess.TimeoutExpired:
    print("units=activation-blockers status=timeout output=<empty>")
    raise SystemExit(1)
except OSError as error:
    print(f"units=activation-blockers status=spawn-{error.__class__.__name__} output=<empty>")
    raise SystemExit(1)
if len(result.stdout) + len(result.stderr) > output_limit:
    print("units=activation-blockers status=output-limit output=<bounded>")
    raise SystemExit(1)
try:
    stdout = result.stdout.decode("utf-8")
    stderr = result.stderr.decode("utf-8")
except UnicodeDecodeError:
    print(f"units=activation-blockers status={result.returncode} output=<non-utf8>")
    raise SystemExit(1)
states = stdout.splitlines()
if result.returncode != 3 or states != ["inactive"] * len(units) or stderr:
    output = (stdout + stderr).rstrip("\n") or "<empty>"
    unit_states = ",".join(
        f"{unit}={states[index] if index < len(states) else '<missing>'}"
        for index, unit in enumerate(units)
    )
    print(
        f"units=activation-blockers status={result.returncode} "
        f"states={unit_states or '<none>'} output={output}"
    )
    raise SystemExit(1)
PY
)"; then
    fail "$context systemd activity is not positively inactive: ${observation:-<empty>}"
  fi
}

verify_systemd_start_barriers() {
  local owner_start=""
  local units=""
  local records=""
  local reported_modes=""
  local unit=""
  local kind=""
  local barrier=""
  local load_state=""
  local fragment=""
  local observed=""

  [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]] || fail "systemd start barriers are not held"
  owner_start="$(process_start_identity "$$")"
  units="$(activation_blocking_systemd_units)"
  records="$(systemd_start_barrier_helper status \
    --root "$SYSTEMD_START_BARRIER_ROOT" \
    --activation-lock "$ACTIVATION_LOCK_FILE" \
    --owner-pid "$$" \
    --owner-start "$owner_start" \
    --owner-token "$ACTIVATION_LOCK_TOKEN" \
    --units "$units" \
    --read-limit "$STATE_FILE_MAX_BYTES")" || \
    fail "systemd start barrier ownership verification failed"
  reported_modes="$(awk -F '\t' 'NF == 3 { print $1 "\t" $2; next } { exit 1 }' <<< "$records")" || \
    fail "systemd start barrier status is malformed"
  [[ "$reported_modes" == "$SYSTEMD_START_BARRIER_MODES" ]] || \
    fail "systemd start barrier owner manifest disagrees with the held mode set"
  while IFS=$'\t' read -r unit kind barrier; do
    [[ -n "$unit" && -n "$kind" && -n "$barrier" ]] || \
      fail "systemd start barrier status is malformed"
    case "$kind" in
      condition)
        load_state="$(systemctl --user show "$unit" -p LoadState --value 2>&1)" || \
          fail "failed to read condition barrier load state: unit=$unit output=${load_state:-<empty>}"
        [[ "$load_state" == "loaded" ]] || \
          fail "condition start barrier is not attached to a loaded unit: unit=$unit LoadState=${load_state:-<empty>}"
        observed="$(systemctl --user show "$unit" -p DropInPaths --value 2>&1)" || \
          fail "failed to read effective start barrier provenance: unit=$unit output=${observed:-<empty>}"
        python3 - "$observed" "$barrier" <<'PY' || fail "systemd condition start barrier is not manager-visible: unit=$unit path=$barrier"
import os
import sys

tokens = sys.argv[1].split()
expected = sys.argv[2]
if expected not in tokens or len(tokens) != len(set(tokens)):
    raise SystemExit(1)
if any(not os.path.isabs(token) for token in tokens):
    raise SystemExit(1)
PY
        ;;
      mask)
        load_state="$(systemctl --user show "$unit" -p LoadState --value 2>&1)" || \
          fail "failed to read mask barrier load state: unit=$unit output=${load_state:-<empty>}"
        fragment="$(systemctl --user show "$unit" -p FragmentPath --value 2>&1)" || \
          fail "failed to read mask barrier fragment: unit=$unit output=${fragment:-<empty>}"
        observed="$(systemctl --user show "$unit" -p DropInPaths --value 2>&1)" || \
          fail "failed to read mask barrier drop-ins: unit=$unit output=${observed:-<empty>}"
        [[ "$load_state" == "masked" && \
           ( "$fragment" == "/dev/null" || "$fragment" == "$barrier" ) && \
           -z "$observed" ]] || \
          fail "systemd mask start barrier is not manager-visible: unit=$unit path=$barrier LoadState=${load_state:-<empty>} FragmentPath=${fragment:-<empty>} DropInPaths=${observed:-<empty>}"
        ;;
      *) fail "systemd start barrier status has an unsupported kind: unit=$unit kind=$kind" ;;
    esac
  done <<< "$records"
}

verify_systemd_start_barriers_absent() {
  local unit=""
  local barrier=""
  local observed=""

  while IFS= read -r unit; do
    barrier="$(systemd_start_barrier_path "$unit")"
    [[ ! -e "$barrier" && ! -L "$barrier" ]] || \
      fail "owned systemd condition start barrier remains on disk: unit=$unit path=$barrier"
    [[ ! -e "$(systemd_start_mask_path "$unit")" && ! -L "$(systemd_start_mask_path "$unit")" ]] || \
      fail "owned systemd mask start barrier remains on disk: unit=$unit path=$(systemd_start_mask_path "$unit")"
    observed="$(systemctl --user show "$unit" -p DropInPaths --value 2>&1)" || \
      fail "failed to verify start barrier removal: unit=$unit output=${observed:-<empty>}"
    python3 - "$observed" "$barrier" <<'PY' || fail "systemd start barrier remains manager-visible: unit=$unit path=$barrier"
import sys

if sys.argv[2] in sys.argv[1].split():
    raise SystemExit(1)
PY
  done < <(activation_blocking_systemd_units)
}

install_systemd_start_barriers() {
  local owner_start=""
  local units=""
  local modes=""

  [[ "$ACTIVATION_LOCK_HELD" == "1" && "$ACTIVATION_LOCK_TOKEN" =~ ^[0-9a-f]{32}$ ]] || \
    fail "systemd start barriers require the durable activation owner"
  [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "0" ]] || fail "systemd start barriers are already held"
  [[ -f "$SYSTEMD_START_BARRIER_HELPER" && ! -L "$SYSTEMD_START_BARRIER_HELPER" ]] || \
    fail "systemd start barrier helper is missing or unsafe"
  owner_start="$(process_start_identity "$$")"
  units="$(activation_blocking_systemd_units)"
  modes="$(initial_systemd_start_barrier_modes)"
  SYSTEMD_START_BARRIER_ROOT="$(systemd_start_barrier_root)"
  if ! systemd_start_barrier_helper install \
    --root "$SYSTEMD_START_BARRIER_ROOT" \
    --activation-lock "$ACTIVATION_LOCK_FILE" \
    --owner-pid "$$" \
    --owner-start "$owner_start" \
    --owner-token "$ACTIVATION_LOCK_TOKEN" \
    --units "$units" \
    --modes "$modes" \
    --read-limit "$STATE_FILE_MAX_BYTES" >/dev/null; then
    SYSTEMD_START_BARRIER_ROOT=""
    fail "failed to create exact owned systemd start barriers"
  fi
  SYSTEMD_START_BARRIERS_HELD=1
  SYSTEMD_START_BARRIER_MODES="$modes"
  systemctl --user daemon-reload || fail "failed to load systemd start barriers"
  verify_systemd_start_barriers
}

remove_systemd_start_barriers() {
  local owner_start=""
  local units=""

  [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]] || return 0
  owner_start="$(process_start_identity "$$")"
  units="$(activation_blocking_systemd_units)"
  systemd_start_barrier_helper remove \
    --root "$SYSTEMD_START_BARRIER_ROOT" \
    --activation-lock "$ACTIVATION_LOCK_FILE" \
    --owner-pid "$$" \
    --owner-start "$owner_start" \
    --owner-token "$ACTIVATION_LOCK_TOKEN" \
    --units "$units" \
    --read-limit "$STATE_FILE_MAX_BYTES" >/dev/null || \
    fail "failed to remove the exact owned systemd start barriers"
  systemctl --user daemon-reload || fail "failed to unload systemd start barriers"
  verify_systemd_start_barriers_absent
  SYSTEMD_START_BARRIERS_HELD=0
  SYSTEMD_START_BARRIER_MODES=""
  SYSTEMD_START_BARRIER_ROOT=""
}

validate_effective_systemd_resources() {
  local unit=""
  local property=""
  local expected=""
  local observed=""

  verify_runtime_guard_identities || fail "runtime guard path identity changed before effective resource validation"
  verify_systemd_start_barriers

  for unit in codexswitch.service signul-codex-app-server.service; do
    for property in MemoryMax MemorySwapMax; do
      expected="$(expected_effective_systemd_resource "$unit" "$property")"
      observed="$(systemctl --user show "$unit" -p "$property" --value)" || fail "failed to read effective $property for $unit"
      [[ "$observed" == "$expected" ]] || fail "effective systemd resource mismatch: unit=$unit property=$property observed=$observed expected=$expected"
    done
  done
}

systemd_dependency_properties() {
  printf '%s\n' \
    Requires Requisite Wants BindsTo PartOf Upholds Conflicts Before After \
    OnFailure OnSuccess PropagatesStopTo StopPropagatedFrom JoinsNamespaceOf \
    RequiredBy RequisiteOf WantedBy BoundBy ConsistsOf UpheldBy ConflictedBy \
    Triggers TriggeredBy PropagatedFrom References ReferencedBy
}

expected_effective_systemd_dependency() {
  local unit="$1"
  local property="$2"
  if systemd_contract_value dependency "$unit" "$property" 2>/dev/null; then
    return 0
  fi
  case "$property" in
    Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|Before|After|OnFailure|OnSuccess|PropagatesStopTo|StopPropagatedFrom|JoinsNamespaceOf|RequiredBy|RequisiteOf|WantedBy|BoundBy|ConsistsOf|UpheldBy|ConflictedBy|Triggers|TriggeredBy|PropagatedFrom|References|ReferencedBy) printf '%s' "" ;;
    *) return 1 ;;
  esac
}

validate_effective_systemd_dependency() {
  local unit="$1"
  local property="$2"
  local observed="$3"
  local expected="$4"
  local working_directory=""

  if [[ "$unit" == "signul-codex-app-server.service" ]]; then
    working_directory="$(expected_systemd_value "$unit" WorkingDirectory)"
  fi

  python3 - "$unit" "$property" "$observed" "$expected" "$SERVICE_DIR" "$working_directory" <<'PY'
import os
import sys
from pathlib import Path

unit, property_name, observed_text, expected_text, service_dir_text, working_directory = sys.argv[1:]
observed = observed_text.split()
expected = expected_text.split()

if len(observed) != len(set(observed)):
    raise SystemExit("duplicate effective dependency")

missing = sorted(set(expected) - set(observed))
extras = set(observed) - set(expected)
allowed = set()

if property_name == "Requires":
    allowed.update(("app.slice", "basic.target", "sysinit.target"))
elif property_name == "Conflicts":
    allowed.add("shutdown.target")
elif property_name == "Before":
    allowed.add("shutdown.target")
elif property_name == "After":
    allowed.update(("app.slice", "basic.target", "sysinit.target"))

def mount_unit_name(path: Path) -> str:
    if path == Path("/"):
        return "-.mount"
    escaped = []
    for value in str(path).strip("/").encode("utf-8"):
        character = chr(value)
        if character.isascii() and (character.isalnum() or character in "_."):
            escaped.append(character)
        elif character == "/":
            escaped.append("-")
        else:
            escaped.append(f"\\x{value:02x}")
    return "".join(escaped) + ".mount"


if working_directory and property_name in ("Requires", "After"):
    path = Path(working_directory)
    allowed.update(mount_unit_name(parent) for parent in (path, *path.parents))

service_dir = Path(service_dir_text)
enablement = service_dir / "default.target.wants" / unit
if enablement.is_symlink():
    target = os.readlink(enablement)
    if target in (f"../{unit}", str(service_dir / unit)):
        if property_name in ("Before", "WantedBy"):
            allowed.add("default.target")

unexpected = sorted(extras - allowed)
if missing or unexpected:
    detail = []
    if missing:
        detail.append(f"missing={','.join(missing)}")
    if unexpected:
        detail.append(f"unexpected={','.join(unexpected)}")
    raise SystemExit(" ".join(detail))
PY
}

validate_effective_systemd_dependencies() {
  local unit=""
  local property=""
  local expected=""
  local observed=""

  for unit in codexswitch.service signul-codex-app-server.service; do
    while IFS= read -r property; do
      expected="$(expected_effective_systemd_dependency "$unit" "$property")" || fail "missing expected effective dependency policy: $unit $property"
      observed="$(systemctl --user show "$unit" -p "$property" --value)" || fail "failed to read effective dependency property: unit=$unit property=$property"
      validate_effective_systemd_dependency "$unit" "$property" "$observed" "$expected" || \
        fail "effective systemd dependency mismatch: unit=$unit property=$property observed=$observed expected=$expected"
    done < <(systemd_dependency_properties)
  done
}

validate_systemd_source_provenance() {
  local unit="$1"
  local expected_fragment="$SERVICE_DIR/$unit"
  local expected_dropin=""
  local expected_barrier=""
  local fragment=""
  local dropins=""

  if [[ "$unit" == "codexswitch.service" ]]; then
    expected_dropin="$SERVICE_DIR/codexswitch.service.d/10-maintenance-resources.conf"
  else
    expected_dropin="$SERVICE_DIR/signul-codex-app-server.service.d/10-runtime-resources.conf"
  fi
  fragment="$(systemctl --user show "$unit" -p FragmentPath --value)" || fail "failed to read systemd FragmentPath for $unit"
  dropins="$(systemctl --user show "$unit" -p DropInPaths --value)" || fail "failed to read systemd DropInPaths for $unit"
  [[ "$fragment" == "$expected_fragment" ]] || fail "systemd source provenance mismatch: unit=$unit FragmentPath=$fragment"
  if [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]]; then
    expected_barrier="$(systemd_start_barrier_path "$unit")"
    python3 - "$dropins" "$expected_dropin" "$expected_barrier" <<'PY' || \
      fail "systemd source provenance mismatch: unit=$unit DropInPaths=$dropins"
import sys

observed = sys.argv[1].split()
expected = sys.argv[2:]
if len(observed) != len(expected) or set(observed) != set(expected):
    raise SystemExit(1)
PY
  else
    [[ "$dropins" == "$expected_dropin" ]] || fail "systemd source provenance mismatch: unit=$unit DropInPaths=$dropins"
  fi
}

systemd_key_is_dependency() {
  case "$1" in
    Requires*|Wants*|Requisite*|BindsTo*|BoundBy|PartOf*|ConsistsOf|Upholds*|Conflicts*|Before|After) return 0 ;;
    RequiredBy|RequisiteOf|WantedBy|UpheldBy|ConflictedBy|Triggers|TriggeredBy) return 0 ;;
    OnFailure*|OnSuccess*|Propagates*|*PropagatedFrom|JoinsNamespaceOf|References|ReferencedBy) return 0 ;;
    Alias|Also|DefaultInstance|Sockets|Service|Unit|InSlice|SliceOf) return 0 ;;
    DefaultDependencies|StopWhenUnneeded|RefuseManualStart|RefuseManualStop|AllowIsolate|IgnoreOnIsolate) return 0 ;;
    *) return 1 ;;
  esac
}

systemd_key_is_sensitive() {
  systemd_key_is_dependency "$1" && return 0
  case "$1" in
    Exec*|Type|WorkingDirectory|RootDirectory|RootImage|User|Group|SupplementaryGroups|UMask|DynamicUser|PAMName|PermissionsStartOnly|RemainAfterExit|Standard*|TTY*|Syslog*|Log*) return 0 ;;
    Environment*|PassEnvironment|UnsetEnvironment|SetCredential*|LoadCredential*) return 0 ;;
    CPU*|NUMA*|AllowedCPUs|Nice) return 0 ;;
    Memory*|ManagedOOM*|OOM*|LimitMEMLOCK) return 0 ;;
    IO*|BlockIO*) return 0 ;;
    Tasks*|Limit*|FileDescriptorStoreMax) return 0 ;;
    Timeout*|Restart*|StartLimit*|RuntimeMaxSec|RuntimeRandomizedExtraSec|Watchdog*|SuccessExitStatus|KillMode|KillSignal|FinalKillSignal|SendSIGKILL|SendSIGHUP|NotifyAccess|FailureAction|SuccessAction) return 0 ;;
    RuntimeDirectory*|StateDirectory*|CacheDirectory*|ConfigurationDirectory*) return 0 ;;
    NoNewPrivileges|Protect*|Private*|Restrict*|LockPersonality|SystemCall*|CapabilityBoundingSet|AmbientCapabilities|SecureBits|KeyringMode|RemoveIPC|Device*|IPAddress*|IPAccounting|SocketBind*|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountAPIVFS|ProcSubset|NetworkNamespacePath|Slice|Delegate|ControlGroup*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_merged_systemd_unit() {
  local unit="$1"
  local merged=""
  local line=""
  local section=""
  local key=""
  local value=""
  local expected=""
  local has_expected=0
  local conflict_count=0
  local expected_keys=()
  local expected_sources=()
  local observed_sources=()
  local expected_source=""
  local source_match_count=0

  merged="$(systemctl --user cat "$unit" | python3 -c 'import sys; limit=int(sys.argv[1]); data=sys.stdin.buffer.read(limit + 1); len(data) <= limit or (_ for _ in ()).throw(SystemExit("merged systemd unit exceeds bounded read limit")); sys.stdout.buffer.write(data)' "$STATE_FILE_MAX_BYTES")" || fail "failed to inspect merged systemd unit: $unit"
  [[ -n "$merged" ]] || fail "merged systemd unit is empty: $unit"

  if [[ "$unit" == "codexswitch.service" ]]; then
    expected_sources=("$SERVICE_DIR/codexswitch.service" "$SERVICE_DIR/codexswitch.service.d/10-maintenance-resources.conf")
  else
    expected_sources=("$SERVICE_DIR/signul-codex-app-server.service" "$SERVICE_DIR/signul-codex-app-server.service.d/10-runtime-resources.conf")
  fi
  if [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]]; then
    expected_sources+=("$(systemd_start_barrier_path "$unit")")
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    if [[ "$line" == "# /"* ]]; then
      observed_sources+=("${line#\# }")
      continue
    fi
    [[ "$line" != \#* && "$line" != \;* ]] || continue
    if [[ "$line" == \[*\] ]]; then
      section="$line"
      continue
    fi
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    has_expected=0
    if [[ "$key" == "ConditionPathExists" && "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]]; then
      expected="!$ACTIVATION_LOCK_FILE"
      has_expected=1
    elif expected="$(expected_systemd_value "$unit" "$key" 2>/dev/null)"; then
      has_expected=1
    else
      expected=""
    fi
    if [[ "$has_expected" != "1" || "$value" != "$expected" ]]; then
      echo "SYSTEMD_CONFLICT unit=$unit directive=$key=$value expected=${expected:-<unset>}" >&2
      conflict_count=$((conflict_count + 1))
    fi
  done <<< "$merged"

  [[ "${#observed_sources[@]}" -eq "${#expected_sources[@]}" ]] || \
    fail "systemd source provenance mismatch: unit=$unit sources=${observed_sources[*]:-<none>}"
  for expected_source in "${expected_sources[@]}"; do
    source_match_count=0
    for observed_source in "${observed_sources[@]}"; do
      [[ "$observed_source" != "$expected_source" ]] || source_match_count=$((source_match_count + 1))
    done
    [[ "$source_match_count" == "1" ]] || fail "systemd source provenance mismatch: unit=$unit source=$expected_source"
  done

  if [[ "$unit" == "signul-codex-app-server.service" ]]; then
    expected_keys=(Description Wants After StartLimitIntervalSec Type WorkingDirectory Environment EnvironmentFile UMask ExecStart KillSignal KillMode TimeoutStopSec SendSIGKILL Nice CPUWeight IOWeight IOSchedulingClass IOSchedulingPriority MemoryLow MemoryHigh MemoryMax MemorySwapMax TasksMax LimitNOFILE WantedBy)
  else
    expected_keys=(Description StartLimitIntervalSec StartLimitBurst ExecStart Restart RestartSec Nice CPUQuota CPUWeight IOWeight IOSchedulingClass MemoryHigh MemoryMax MemorySwapMax TasksMax LimitNOFILE WantedBy)
  fi
  if [[ "${SYSTEMD_START_BARRIERS_HELD:-0}" == "1" ]]; then
    expected_keys+=(ConditionPathExists)
  fi
  for key in "${expected_keys[@]}"; do
    if [[ "$key" == "ConditionPathExists" ]]; then
      expected="!$ACTIVATION_LOCK_FILE"
    else
      expected="$(expected_systemd_value "$unit" "$key")"
    fi
    if ! grep -Fqx -- "$key=$expected" <<< "$merged"; then
      echo "SYSTEMD_CONFLICT unit=$unit missing=$key=$expected" >&2
      conflict_count=$((conflict_count + 1))
    fi
  done

  if [[ "$conflict_count" -gt 0 ]]; then
    fail "merged systemd state conflicts with release policy; approval only permits removal of known on-disk artifacts"
  fi
  validate_systemd_source_provenance "$unit"
}

validate_systemd_preconditions() {
  local unit=""
  local candidate=""
  local candidate_name=""
  local candidate_relative=""
  local candidate_target=""
  local enablement_dir=""
  local dropin_dir=""
  local expected=""
  local entry=""
  local preserved_relative=""
  local conflict_count=0

  verify_runtime_guard_identities || fail "runtime guard path identity changed before systemd precondition validation"
  verify_systemd_start_barriers
  require_activation_systemd_units_inactive precondition

  for candidate in "$SERVICE_DIR"/*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    candidate_name="$(basename "$candidate")"
    systemd_entry_is_managed "$candidate_name" && continue
    if systemd_entry_is_preserved_adjacent "$candidate_name"; then
      if [[ "$candidate_name" == *.service.d ]]; then
        [[ -d "$candidate" && ! -L "$candidate" ]] || \
          fail "preserved adjacent systemd drop-in directory is linked or special: $candidate"
        for entry in "$candidate"/*; do
          [[ -e "$entry" || -L "$entry" ]] || continue
          preserved_relative="$candidate_name/$(basename "$entry")"
          systemd_entry_is_preserved_adjacent "$preserved_relative" || \
            fail "unexpected preserved adjacent systemd drop-in: $entry"
          [[ -f "$entry" && ! -L "$entry" ]] || \
            fail "preserved adjacent systemd drop-in is linked or special: $entry"
        done
      else
        [[ -f "$candidate" && ! -L "$candidate" ]] || \
          fail "preserved adjacent systemd unit is linked or special: $candidate"
      fi
      continue
    fi
    case "$candidate_name" in
      codexswitch*|*codex*app-server*|signul-codex*)
        fail "unexpected conflicting CodexSwitch unit file: $candidate_name"
        ;;
    esac
  done

  for enablement_dir in "$SERVICE_DIR"/*; do
    [[ -e "$enablement_dir" || -L "$enablement_dir" ]] || continue
    case "$(basename "$enablement_dir")" in
      *.wants|*.requires|*.upholds|*.requisite|*.binds-to|*.part-of|*.conflicts|*.before|*.after|*.on-failure|*.on-success|*.propagates-stop-to|*.stop-propagated-from|*.joins-namespace-of) ;;
      *) continue ;;
    esac
    [[ -d "$enablement_dir" && ! -L "$enablement_dir" ]] || fail "systemd enablement path is not a regular directory: $enablement_dir"
    for candidate in "$enablement_dir"/*; do
      [[ -e "$candidate" || -L "$candidate" ]] || continue
      candidate_name="$(basename "$candidate")"
      case "$candidate_name" in
        codexswitch*|*codex*app-server*|signul-codex*)
          candidate_relative="${candidate#"$SERVICE_DIR/"}"
          if systemd_entry_is_preserved_adjacent "$candidate_relative"; then
            candidate_target="$(readlink "$candidate" 2>/dev/null || true)"
            [[ -L "$candidate" && (
              "$candidate_target" == "../$candidate_name"
                || "$candidate_target" == "$SERVICE_DIR/$candidate_name"
            ) ]] || \
              fail "preserved adjacent systemd enablement is invalid: $candidate"
            continue
          fi
          if ! systemd_entry_is_managed "$candidate_relative"; then
            case "$(basename "$enablement_dir")" in
              *.wants|*.requires) fail "unexpected conflicting CodexSwitch enablement artifact: $candidate" ;;
              *) fail "unexpected conflicting CodexSwitch relationship artifact: $candidate" ;;
            esac
          fi
          ;;
      esac
    done
  done

  for unit in codexswitch.service signul-codex-app-server.service; do
    dropin_dir="$SERVICE_DIR/$unit.d"
    [[ ! -e "$dropin_dir" || -d "$dropin_dir" ]] || fail "managed drop-in path is not a directory: $dropin_dir"
    [[ ! -L "$dropin_dir" ]] || fail "managed drop-in path must not be a symlink: $dropin_dir"
    [[ -d "$dropin_dir" ]] || continue
    dropin_count=0
    if [[ "$unit" == "codexswitch.service" ]]; then
      expected="10-maintenance-resources.conf"
    else
      expected="10-runtime-resources.conf"
    fi
    while IFS= read -r entry; do
      dropin_count=$((dropin_count + 1))
      [[ "$dropin_count" -le "$SCAN_MAX_ENTRIES" ]] || fail "managed systemd drop-in scan entry bound exceeded"
      [[ "$(basename "$entry")" == "$expected" && -f "$entry" && ! -L "$entry" ]] && continue
      case "$unit:$(basename "$entry")" in
        codexswitch.service:zz-restart-bound.conf|signul-codex-app-server.service:env.conf|signul-codex-app-server.service:limits.conf|signul-codex-app-server.service:oom.conf|signul-codex-app-server.service:remote-control.conf|signul-codex-app-server.service:90-runtime-tree.conf)
          [[ -f "$entry" && ! -L "$entry" ]] || fail "known removable systemd artifact is not a regular file: $entry"
          echo "SYSTEMD_CONFLICT unit=$unit removable_dropin=$(basename "$entry")" >&2
          conflict_count=$((conflict_count + 1))
          ;;
        *) fail "unexpected managed systemd drop-in is not approval-removable: $entry" ;;
      esac
    done < <(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print)
  done

  if [[ "$conflict_count" -gt 0 && "$APPROVE_SYSTEMD_CONFLICTS" != "1" ]]; then
    fail "managed systemd drop-ins differ from the exact four-file manifest"
  fi
}

validate_exact_systemd_filesystem_state() {
  if [[ "$TEST_MODE" == "1" && "${CODEXSWITCH_TEST_REPLACE_RUNTIME_GUARD_BEFORE_COMMIT:-0}" == "1" ]]; then
    mv -- "$RUNTIME_START_INSTALL_GUARD" "$RUNTIME_START_INSTALL_GUARD.replaced-before-commit"
    : > "$RUNTIME_START_INSTALL_GUARD"
  fi
  verify_runtime_guard_identities || fail "runtime guard path identity changed before activation commit"
  verify_systemd_start_barriers
  python3 - \
    "$SERVICE_DIR" "$ENABLE_DAEMON" "$ENABLE_APP_SERVER" "$SCAN_MAX_ENTRIES" \
    "$(preserved_adjacent_systemd_entries)" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
enable_daemon = sys.argv[2] == "1"
enable_app = sys.argv[3] == "1"
max_entries = int(sys.argv[4])
preserved = {value for value in sys.argv[5].splitlines() if value}
expected_files = {
    "codexswitch.service",
    "codexswitch.service.d/10-maintenance-resources.conf",
    "signul-codex-app-server.service",
    "signul-codex-app-server.service.d/10-runtime-resources.conf",
}
expected_links = set()
if enable_daemon:
    expected_links.add("default.target.wants/codexswitch.service")
if enable_app:
    expected_links.add("default.target.wants/signul-codex-app-server.service")
relationship_suffixes = (
    ".wants", ".requires", ".upholds", ".requisite", ".binds-to",
    ".part-of", ".conflicts", ".before", ".after", ".on-failure",
    ".on-success", ".propagates-stop-to", ".stop-propagated-from",
    ".joins-namespace-of",
)

def is_codex_name(name: str) -> bool:
    lowered = name.lower()
    return lowered.startswith("codexswitch") or "codex-app-server" in lowered or lowered.startswith("signul-codex")

seen_files = set()
seen_links = set()
count = 0
with os.scandir(root) as entries:
    for entry in entries:
        count += 1
        if count > max_entries:
            raise SystemExit("systemd manifest scan entry bound exceeded")
        top = Path(entry.path)
        metadata = entry.stat(follow_symlinks=False)
        if entry.name.startswith(".codexswitch-activation."):
            continue
        if entry.name in preserved:
            if stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                continue
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                with os.scandir(top) as children:
                    for child in children:
                        count += 1
                        if count > max_entries:
                            raise SystemExit("systemd manifest scan entry bound exceeded")
                        relative = f"{entry.name}/{child.name}"
                        child_metadata = child.stat(follow_symlinks=False)
                        if (
                            relative not in preserved
                            or not stat.S_ISREG(child_metadata.st_mode)
                            or stat.S_ISLNK(child_metadata.st_mode)
                        ):
                            raise SystemExit(
                                f"unexpected preserved adjacent systemd drop-in: {child.path}"
                            )
                continue
            raise SystemExit(f"preserved adjacent systemd artifact is linked or special: {top}")
        if entry.name in {"codexswitch.service", "signul-codex-app-server.service"}:
            if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"managed systemd unit is linked or special: {top}")
            seen_files.add(entry.name)
            continue
        if entry.name in {"codexswitch.service.d", "signul-codex-app-server.service.d"}:
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"managed systemd drop-in directory is linked or special: {top}")
            with os.scandir(top) as children:
                for child in children:
                    count += 1
                    if count > max_entries:
                        raise SystemExit("systemd manifest scan entry bound exceeded")
                    relative = f"{entry.name}/{child.name}"
                    child_metadata = child.stat(follow_symlinks=False)
                    if relative not in expected_files or not stat.S_ISREG(child_metadata.st_mode) or stat.S_ISLNK(child_metadata.st_mode):
                        raise SystemExit(f"unexpected effective systemd drop-in: {child.path}")
                    if child_metadata.st_size == 0:
                        raise SystemExit(f"empty effective systemd drop-in: {child.path}")
                    seen_files.add(relative)
            continue
        if entry.name.endswith(relationship_suffixes):
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"systemd relationship directory is linked or special: {top}")
            with os.scandir(top) as children:
                for child in children:
                    count += 1
                    if count > max_entries:
                        raise SystemExit("systemd manifest scan entry bound exceeded")
                    if not is_codex_name(child.name):
                        continue
                    relative = f"{entry.name}/{child.name}"
                    child_metadata = child.stat(follow_symlinks=False)
                    if relative in preserved:
                        if not stat.S_ISLNK(child_metadata.st_mode):
                            raise SystemExit(f"preserved adjacent systemd relationship is not linked: {child.path}")
                        target = os.readlink(child.path)
                        valid_targets = {
                            f"../{child.name}",
                            str(root / child.name),
                        }
                        if target not in valid_targets:
                            raise SystemExit(f"invalid preserved adjacent systemd relationship target: {child.path}")
                        continue
                    if relative not in expected_links or not stat.S_ISLNK(child_metadata.st_mode):
                        raise SystemExit(f"unexpected effective systemd relationship: {child.path}")
                    target = os.readlink(child.path)
                    valid_targets = {
                        f"../{child.name}",
                        str(root / child.name),
                    }
                    if target not in valid_targets:
                        raise SystemExit(f"invalid effective systemd relationship target: {child.path}")
                    seen_links.add(relative)
            continue
        if is_codex_name(entry.name):
            raise SystemExit(f"unexpected effective CodexSwitch systemd artifact: {top}")

if seen_files != expected_files:
    raise SystemExit(f"effective systemd file manifest mismatch: {sorted(seen_files)}")
if seen_links != expected_links:
    raise SystemExit(f"effective systemd relationship manifest mismatch: {sorted(seen_links)}")
PY
}
