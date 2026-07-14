# shellcheck shell=bash
prepare_source_worktree() {
  local metadata=""
  local origin_url=""
  local resolved_sha=""
  local status_text=""

  if ! is_git_worktree "$SOURCE_DIR"; then
    git clone --no-checkout "$REPO_URL" "$SOURCE_DIR"
  fi
  origin_url="$(git -C "$SOURCE_DIR" remote get-url origin)"
  [[ "$origin_url" == "$REPO_URL" ]] || fail "source origin mismatch: expected $REPO_URL, found $origin_url"

  git -C "$SOURCE_DIR" fetch --force --prune --tags origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$SOURCE_DIR" show-ref --verify --quiet "$APPROVED_ORIGIN_REF" || fail "approved origin ref was not fetched: $APPROVED_ORIGIN_REF"
  git -C "$SOURCE_DIR" cat-file -e "$TARGET_SHA^{commit}" || fail "requested Git SHA was not fetched: $TARGET_SHA"
  git -C "$SOURCE_DIR" merge-base --is-ancestor "$TARGET_SHA" "$APPROVED_ORIGIN_REF" || fail "requested Git SHA is not reachable from approved origin ref $APPROVED_ORIGIN_REF"
  resolved_sha="$(git -C "$SOURCE_DIR" rev-parse --verify "$TARGET_SHA^{commit}")"
  [[ "$resolved_sha" == "$TARGET_SHA" ]] || fail "resolved commit $resolved_sha does not match requested $TARGET_SHA"

  BUILD_EPOCH="$(git -C "$SOURCE_DIR" show -s --format=%ct "$TARGET_SHA")"
  [[ "$BUILD_EPOCH" =~ ^[0-9]+$ ]] || fail "commit $TARGET_SHA has no valid build epoch"

  mkdir -p "$WORKTREE_ROOT"
  WORK_DIR="$WORKTREE_ROOT/$TARGET_SHA-$$"
  validate_build_derived_path WORK_DIR "$WORK_DIR"
  [[ ! -e "$WORK_DIR" ]] || fail "build worktree already exists: $WORK_DIR"
  git -C "$SOURCE_DIR" worktree add --detach "$WORK_DIR" "$TARGET_SHA"
  WORKTREE_REGISTERED=1
  status_text="$(git -C "$WORK_DIR" status --porcelain --untracked-files=normal)"
  [[ -z "$status_text" ]] || fail "detached build worktree is dirty"

  metadata="$(cargo metadata --locked --no-deps --format-version 1 --manifest-path "$WORK_DIR/Cargo.toml")"
  PACKAGE_VERSION="$(printf '%s' "$metadata" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(p["version"] for p in data["packages"] if p["name"] == "codexswitch-cli"))')"
  [[ "$PACKAGE_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "Cargo returned an unsafe codexswitch-cli package version"

  RELEASE_ID="$PACKAGE_VERSION-$TARGET_SHA"
  RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
  validate_derived_path RELEASE_DIR "$RELEASES_DIR" "$RELEASE_DIR"
  EXPECTED_CLI_VERSION="codexswitch-cli $PACKAGE_VERSION (git ${TARGET_SHA:0:12}, built $BUILD_EPOCH)"
}

binary_contains_marker() {
  grep -aF -q -- "$2" "$1"
}

validate_hot_swap_markers() {
  local binary="$1"
  local marker=""
  local required_markers=(
    "sighup-verified"
    "SIGHUP: auth reloaded"
    "hotswap-ack"
    "CodexSwitch rotated accounts after a usage limit"
    "CodexSwitch rotated accounts after an auth failure"
    "Auth changed, opening new WebSocket with fresh credentials"
    "codexswitch-runtime-convergence-v3"
    "codexswitch-runtime-rotation-handoff-v1"
    "CodexSwitch account/updated frontend write acknowledged after auth reload"
    "codexswitch-hotswap-contract-v3"
    "codexswitch-hotswap-cli-contract-v3"
    "codex-runtime-storage-leases-v1"
  )

  for marker in "${required_markers[@]}"; do
    binary_contains_marker "$binary" "$marker" || fail "patched Codex runtime is missing marker: $marker"
  done
  if ! binary_contains_marker "$binary" "Usage: /goal <objective>"; then
    binary_contains_marker "$binary" "Pursuing goal" || fail "patched Codex runtime is missing goal markers"
    binary_contains_marker "$binary" "thread/goal/set" || fail "patched Codex runtime is missing goal markers"
  fi
}

validate_runtime_files() {
  local runtime_dir="$1"
  local expected_version="$2"
  local codex="$runtime_dir/codex"
  local helper="$runtime_dir/codex-code-mode-host"
  local reported_version=""

  [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]] || fail "patched Codex runtime must be a real directory: $runtime_dir"
  validate_regular_tree PATCHED_CODEX_RUNTIME "$runtime_dir"
  [[ -f "$codex" && ! -L "$codex" && -x "$codex" ]] || fail "patched Codex must be a regular executable: $codex"
  [[ -f "$helper" && ! -L "$helper" && -x "$helper" && -s "$helper" ]] || fail "codex-code-mode-host must be a nonempty regular executable: $helper"
  reported_version="$("$codex" --version)"
  [[ "$reported_version" == "codex-cli $expected_version" ]] || fail "patched Codex version '$reported_version' did not match 'codex-cli $expected_version'"
  validate_hot_swap_markers "$codex"
  timeout 10 "$codex" app-server --help >/dev/null 2>&1 || fail "patched Codex app-server readiness check failed: $codex"
}

systemd_payload_files() {
  printf '%s\n' \
    "codexswitch.service" \
    "codexswitch.service.d/10-maintenance-resources.conf" \
    "signul-codex-app-server.service" \
    "signul-codex-app-server.service.d/10-runtime-resources.conf"
}

systemd_payload_manifest_value() {
  systemd_payload_files | paste -sd, -
}

validate_systemd_payload() {
  local systemd_dir="$1"
  local actual=""
  local expected=""

  [[ -d "$systemd_dir" && ! -L "$systemd_dir" ]] || fail "release systemd payload is missing or linked: $systemd_dir"
  expected="$(printf '%s\n' \
    "codexswitch.service" \
    "codexswitch.service.d" \
    "codexswitch.service.d/10-maintenance-resources.conf" \
    "signul-codex-app-server.service" \
    "signul-codex-app-server.service.d" \
    "signul-codex-app-server.service.d/10-runtime-resources.conf" | sort)"
  actual="$(python3 - "$systemd_dir" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
max_entries = int(sys.argv[2])
max_depth = int(sys.argv[3])
values = []
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            values.append(str(path.relative_to(root)))
            if len(values) > max_entries:
                raise SystemExit("systemd payload scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"systemd payload scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"systemd payload contains a symlink: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                stack.append((path, next_depth))
            elif not stat.S_ISREG(metadata.st_mode):
                raise SystemExit(f"systemd payload contains a special entry: {path}")
print("\n".join(sorted(values)))
PY
)"
  [[ "$actual" == "$expected" ]] || fail "release systemd payload has missing or unmanifested entries: $systemd_dir"
  while IFS= read -r relative; do
    [[ -f "$systemd_dir/$relative" && ! -L "$systemd_dir/$relative" ]] || fail "release systemd payload entry is not a regular file: $relative"
  done < <(systemd_payload_files)
}

validate_release() {
  local release_dir="$1"
  local manifest="$release_dir/release-manifest.tsv"
  local cli="$release_dir/codexswitch-cli"
  local runtime_dir="$release_dir/patched-codex"
  local systemd_dir="$release_dir/systemd"
  local git_sha=""
  local package_version=""
  local build_epoch=""
  local release_id=""
  local expected_cli=""
  local codex_version=""
  local codex_source_sha=""

  validate_derived_path RELEASE_DIR "$RELEASES_DIR" "$release_dir"
  validate_derived_path RELEASE_RUNTIME_DIR "$release_dir" "$runtime_dir"
  validate_derived_path RELEASE_SYSTEMD_DIR "$release_dir" "$systemd_dir"
  validate_derived_path RELEASE_CODEXSWITCH_DROPIN_DIR "$systemd_dir" "$systemd_dir/codexswitch.service.d"
  validate_derived_path RELEASE_APP_SERVER_DROPIN_DIR "$systemd_dir" "$systemd_dir/signul-codex-app-server.service.d"
  [[ -d "$release_dir" && ! -L "$release_dir" ]] || fail "release is not a regular directory: $release_dir"
  validate_regular_tree IMMUTABLE_RELEASE "$release_dir"
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail "release manifest is missing or linked: $manifest"
  [[ "$(manifest_value "$manifest" format)" == "codexswitch-release-v3" ]] || fail "unsupported release manifest: $manifest"

  release_id="$(manifest_value "$manifest" release_id)"
  git_sha="$(manifest_value "$manifest" git_sha)"
  package_version="$(manifest_value "$manifest" package_version)"
  build_epoch="$(manifest_value "$manifest" build_epoch)"
  expected_cli="$(manifest_value "$manifest" cli_version)"
  codex_version="$(manifest_value "$manifest" codex_version)"
  codex_source_sha="$(manifest_value "$manifest" codex_source_sha)"

  [[ "$git_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "release manifest has an invalid Git SHA: $manifest"
  [[ "$codex_source_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "release manifest has an invalid Codex source SHA: $manifest"
  [[ "$package_version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "release manifest has an invalid package version: $manifest"
  [[ "$codex_version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "release manifest has an invalid Codex version: $manifest"
  [[ "$build_epoch" =~ ^[0-9]+$ ]] || fail "release manifest has an invalid build epoch: $manifest"
  [[ "$release_id" == "$package_version-$git_sha" ]] || fail "release ID does not match version plus SHA: $manifest"
  [[ "$(basename "$release_dir")" == "$release_id" ]] || fail "release directory name does not match manifest: $release_dir"

  expected_cli="codexswitch-cli $package_version (git ${git_sha:0:12}, built $build_epoch)"
  [[ "$(manifest_value "$manifest" cli_version)" == "$expected_cli" ]] || fail "release CLI provenance string is incompatible: $manifest"
  [[ -f "$cli" && ! -L "$cli" && -x "$cli" ]] || fail "release CLI is missing or linked: $cli"
  [[ "$(sha256_file "$cli")" == "$(manifest_value "$manifest" cli_sha256)" ]] || fail "release CLI SHA-256 mismatch: $release_dir"
  [[ "$("$cli" --version)" == "$expected_cli" ]] || fail "release CLI --version mismatch: $release_dir"

  validate_runtime_files "$runtime_dir" "$codex_version"
  [[ "$(sha256_file "$runtime_dir/codex")" == "$(manifest_value "$manifest" codex_sha256)" ]] || fail "release Codex SHA-256 mismatch: $release_dir"
  [[ "$(sha256_file "$runtime_dir/codex-code-mode-host")" == "$(manifest_value "$manifest" codex_code_mode_host_sha256)" ]] || fail "release codex-code-mode-host SHA-256 mismatch: $release_dir"
  [[ "$(manifest_value "$manifest" codex_marker_contract)" == "codexswitch-hotswap-full-v3" ]] || fail "release marker contract mismatch: $manifest"

  validate_systemd_payload "$systemd_dir"
  [[ "$(manifest_value "$manifest" systemd_payload)" == "$(systemd_payload_manifest_value)" ]] || fail "release systemd payload manifest mismatch"
  [[ "$(sha256_file "$systemd_dir/codexswitch.service")" == "$(manifest_value "$manifest" codexswitch_unit_sha256)" ]] || fail "release codexswitch unit SHA-256 mismatch"
  [[ "$(sha256_file "$systemd_dir/codexswitch.service.d/10-maintenance-resources.conf")" == "$(manifest_value "$manifest" codexswitch_dropin_sha256)" ]] || fail "release codexswitch drop-in SHA-256 mismatch"
  [[ "$(sha256_file "$systemd_dir/signul-codex-app-server.service")" == "$(manifest_value "$manifest" app_server_unit_sha256)" ]] || fail "release app-server unit SHA-256 mismatch"
  [[ "$(sha256_file "$systemd_dir/signul-codex-app-server.service.d/10-runtime-resources.conf")" == "$(manifest_value "$manifest" app_server_dropin_sha256)" ]] || fail "release app-server drop-in SHA-256 mismatch"
}

validate_candidate_release() {
  local manifest="$RELEASE_DIR/release-manifest.tsv"

  require_reviewed_runtime_provenance
  validate_release "$RELEASE_DIR"
  [[ "$(manifest_value "$manifest" git_sha)" == "$TARGET_SHA" ]] || fail "candidate release Git SHA mismatch"
  [[ "$(manifest_value "$manifest" package_version)" == "$PACKAGE_VERSION" ]] || fail "candidate release package version mismatch"
  [[ "$(manifest_value "$manifest" build_epoch)" == "$BUILD_EPOCH" ]] || fail "candidate release build epoch mismatch"
  [[ "$(manifest_value "$manifest" cli_version)" == "$EXPECTED_CLI_VERSION" ]] || fail "candidate release CLI version mismatch"
  [[ "$(manifest_value "$manifest" codex_version)" == "$CODEX_VERSION" ]] || fail "candidate release Codex version does not match requested runtime provenance"
  [[ "$(manifest_value "$manifest" codex_source_sha)" == "$CODEX_SOURCE_SHA" ]] || fail "candidate release Codex source SHA does not match requested runtime provenance"
}

run_repository_cargo_build() {
  local scope_name="codexswitch-build-${TARGET_SHA:0:12}-$$"
  local status=0
  BUILD_REAP_PROOF="$BUILD_ROOT/.${scope_name}.reaped"
  validate_build_derived_path BUILD_REAP_PROOF "$BUILD_REAP_PROOF"
  rm -f -- "$BUILD_REAP_PROOF"
  BUILD_DESCENDANTS_REAPED=0

  python3 - \
    "$BUILD_TIMEOUT_SECONDS" \
    "$scope_name" \
    "$BUILD_REAP_PROOF" \
    "$BUILD_MEMORY_HIGH" \
    "$BUILD_MEMORY_MAX" \
    "$BUILD_SWAP_MAX" \
    "$BUILD_NICE" \
    "$WORK_DIR/Cargo.toml" <<'PY' || status=$?
import ctypes
import errno
import os
import signal
import subprocess
import sys
import time
from enum import Enum
from pathlib import Path

timeout_seconds = int(sys.argv[1])
scope_name = sys.argv[2]
proof_path = Path(sys.argv[3])
memory_high, memory_max, swap_max = sys.argv[4:7]
nice_value = sys.argv[7]
manifest_path = sys.argv[8]
scope_unit = f"{scope_name}.scope"

if sys.platform.startswith("linux"):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "failed to become build subreaper")

command = [
    "systemd-run", "--user", "--scope", "--quiet", f"--unit={scope_name}",
    "-p", f"MemoryHigh={memory_high}",
    "-p", f"MemoryMax={memory_max}",
    "-p", f"MemorySwapMax={swap_max}",
    "nice", "-n", nice_value, "ionice", "-c", "3",
    "cargo", "build", "--locked", "--release", "--jobs", "1",
    "-p", "codexswitch-cli", "--manifest-path", manifest_path,
]
process = subprocess.Popen(command, start_new_session=True)
process_group = process.pid
timed_out = False

try:
    return_code = process.wait(timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    timed_out = True
    return_code = 124

def kill_scope_and_group():
    subprocess.run(
        [
            "systemctl", "--user", "kill", "--kill-whom=all",
            "--signal=SIGKILL", scope_unit,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=False,
    )
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass

def group_is_alive():
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

class ScopeState(Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    UNKNOWN = "unknown"

def observe_scope_state():
    try:
        observed = subprocess.run(
            ["systemctl", "--user", "show", scope_unit, "--property=ActiveState", "--value"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ScopeState.UNKNOWN
    if observed.returncode != 0:
        return ScopeState.UNKNOWN

    active_state = observed.stdout.strip()
    if active_state == "inactive":
        return ScopeState.INACTIVE
    if active_state in {
        "active",
        "activating",
        "deactivating",
        "maintenance",
        "refreshing",
        "reloading",
    }:
        return ScopeState.ACTIVE
    return ScopeState.UNKNOWN

def reap_children():
    while True:
        try:
            child, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if child == 0:
            return

scope_state = observe_scope_state()
if timed_out or group_is_alive() or scope_state is not ScopeState.INACTIVE:
    kill_scope_and_group()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        kill_scope_and_group()
        process.wait(timeout=5)

deadline = time.monotonic() + min(10, max(1, timeout_seconds))
while time.monotonic() < deadline:
    reap_children()
    scope_state = observe_scope_state()
    if not group_is_alive() and scope_state is ScopeState.INACTIVE:
        break
    kill_scope_and_group()
    time.sleep(0.05)
else:
    raise SystemExit(
        "build descendants were not reaped or the systemd scope was not "
        f"positively inactive (last scope state: {scope_state.value})"
    )

proof_path.parent.mkdir(parents=True, exist_ok=True)
descriptor = os.open(proof_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as proof:
    proof.write("codexswitch-build-reaped-v1\n")
    proof.flush()
    os.fsync(proof.fileno())
directory = os.open(proof_path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(directory)
finally:
    os.close(directory)
raise SystemExit(return_code)
PY

  if [[ -f "$BUILD_REAP_PROOF" && ! -L "$BUILD_REAP_PROOF" ]] && \
     [[ "$(cat "$BUILD_REAP_PROOF")" == "codexswitch-build-reaped-v1" ]]; then
    rm -f -- "$BUILD_REAP_PROOF"
    fsync_directory "$BUILD_ROOT"
    BUILD_REAP_PROOF=""
    BUILD_DESCENDANTS_REAPED=1
  else
    echo "ERROR: repository Cargo build ended without descendant reap proof; build artifacts are preserved" >&2
    return 125
  fi
  return "$status"
}

publish_release() {
  local cargo_target="$CARGO_TARGET_DIR_PATH"
  local built_cli="$cargo_target/release/codexswitch-cli"
  local source_codex="$CODEX_RUNTIME_DIR/codex"
  local source_helper="$CODEX_RUNTIME_DIR/codex-code-mode-host"
  local runtime_target=""
  local systemd_target=""
  local cli_sha=""
  local codex_sha=""
  local helper_sha=""

  if [[ -e "$RELEASE_DIR" || -L "$RELEASE_DIR" ]]; then
    validate_candidate_release
    echo "Using verified existing release $RELEASE_DIR"
    return
  fi

  [[ -n "$CODEX_VERSION" ]] || fail "CODEXSWITCH_CODEX_VERSION is required for a new release"
  [[ -n "$CODEX_SOURCE_SHA" ]] || fail "CODEXSWITCH_CODEX_SOURCE_SHA is required for a new release"
  validate_runtime_files "$CODEX_RUNTIME_DIR" "$CODEX_VERSION"

  validate_build_derived_path CARGO_TARGET_DIR "$cargo_target"
  mkdir -p "$cargo_target" "$RELEASES_DIR" "$BUILD_STAGE_ROOT"
  SOURCE_DATE_EPOCH="$BUILD_EPOCH" \
  CODEXSWITCH_BUILD_GIT_SHA="$TARGET_SHA" \
  CODEXSWITCH_BUILD_PACKAGE_VERSION="$PACKAGE_VERSION" \
  CARGO_TARGET_DIR="$cargo_target" \
  CARGO_BUILD_JOBS=1 \
    run_repository_cargo_build

  enforce_build_size_bound

  [[ -f "$built_cli" && -x "$built_cli" ]] || fail "Cargo did not produce $built_cli"
  [[ "$("$built_cli" --version)" == "$EXPECTED_CLI_VERSION" ]] || fail "built CLI --version did not match injected SHA/version/build epoch: expected '$EXPECTED_CLI_VERSION'"

  STAGE_DIR="$BUILD_STAGE_ROOT/$RELEASE_ID-$$"
  validate_build_derived_path STAGE_DIR "$STAGE_DIR"
  [[ ! -e "$STAGE_DIR" ]] || fail "release staging directory already exists: $STAGE_DIR"
  runtime_target="$STAGE_DIR/patched-codex"
  systemd_target="$STAGE_DIR/systemd"
  mkdir -p \
    "$runtime_target" \
    "$systemd_target/codexswitch.service.d" \
    "$systemd_target/signul-codex-app-server.service.d"
  install -m 0555 "$built_cli" "$STAGE_DIR/codexswitch-cli"
  install -m 0555 "$source_codex" "$runtime_target/codex"
  install -m 0555 "$source_helper" "$runtime_target/codex-code-mode-host"
  install -m 0444 "$WORK_DIR/crates/codexswitch-cli/systemd/codexswitch.service" "$systemd_target/codexswitch.service"
  install -m 0444 "$WORK_DIR/crates/codexswitch-cli/systemd/codexswitch.service.d/10-maintenance-resources.conf" "$systemd_target/codexswitch.service.d/10-maintenance-resources.conf"
  install -m 0444 "$WORK_DIR/crates/codexswitch-cli/systemd/signul-codex-app-server.service" "$systemd_target/signul-codex-app-server.service"
  install -m 0444 "$WORK_DIR/crates/codexswitch-cli/systemd/signul-codex-app-server.service.d/10-runtime-resources.conf" "$systemd_target/signul-codex-app-server.service.d/10-runtime-resources.conf"

  validate_runtime_files "$runtime_target" "$CODEX_VERSION"
  [[ "$(sha256_file "$source_codex")" == "$(sha256_file "$runtime_target/codex")" ]] || fail "patched Codex changed while staging"
  [[ "$(sha256_file "$source_helper")" == "$(sha256_file "$runtime_target/codex-code-mode-host")" ]] || fail "codex-code-mode-host changed while staging"

  cli_sha="$(sha256_file "$STAGE_DIR/codexswitch-cli")"
  codex_sha="$(sha256_file "$runtime_target/codex")"
  helper_sha="$(sha256_file "$runtime_target/codex-code-mode-host")"
  validate_systemd_payload "$systemd_target"
  printf 'format\tcodexswitch-release-v3\nrelease_id\t%s\ngit_sha\t%s\npackage_version\t%s\nbuild_epoch\t%s\ncli_version\t%s\ncli_sha256\t%s\ncodex_source_sha\t%s\ncodex_version\t%s\ncodex_sha256\t%s\ncodex_code_mode_host_sha256\t%s\ncodex_marker_contract\tcodexswitch-hotswap-full-v3\nsystemd_payload\t%s\ncodexswitch_unit_sha256\t%s\ncodexswitch_dropin_sha256\t%s\napp_server_unit_sha256\t%s\napp_server_dropin_sha256\t%s\n' \
    "$RELEASE_ID" "$TARGET_SHA" "$PACKAGE_VERSION" "$BUILD_EPOCH" "$EXPECTED_CLI_VERSION" "$cli_sha" \
    "$CODEX_SOURCE_SHA" "$CODEX_VERSION" "$codex_sha" "$helper_sha" "$(systemd_payload_manifest_value)" \
    "$(sha256_file "$systemd_target/codexswitch.service")" \
    "$(sha256_file "$systemd_target/codexswitch.service.d/10-maintenance-resources.conf")" \
    "$(sha256_file "$systemd_target/signul-codex-app-server.service")" \
    "$(sha256_file "$systemd_target/signul-codex-app-server.service.d/10-runtime-resources.conf")" \
    > "$STAGE_DIR/release-manifest.tsv"

  [[ "$(directory_size_bytes "$STAGE_DIR")" -le "$RELEASE_MAX_BYTES" ]] || fail "staged release exceeds $RELEASE_MAX_BYTES bytes"
  enforce_build_size_bound
  chmod_tree_bounded "$STAGE_DIR" 0444 0555
  chmod 0555 "$STAGE_DIR/codexswitch-cli" "$runtime_target/codex" "$runtime_target/codex-code-mode-host"
  PUBLISH_DIR="$RELEASES_DIR/.$RELEASE_ID.tmp.$$"
  validate_derived_path PUBLISH_DIR "$RELEASES_DIR" "$PUBLISH_DIR"
  [[ ! -e "$PUBLISH_DIR" ]] || fail "release publish directory already exists: $PUBLISH_DIR"
  mkdir -m 0755 "$PUBLISH_DIR"
  cp -R "$STAGE_DIR/." "$PUBLISH_DIR/"
  [[ "$(directory_size_bytes "$PUBLISH_DIR")" -le "$RELEASE_MAX_BYTES" ]] || fail "publish release exceeds $RELEASE_MAX_BYTES bytes"
  chmod_tree_bounded "$PUBLISH_DIR" 0444 0555
  chmod 0555 "$PUBLISH_DIR/codexswitch-cli" "$PUBLISH_DIR/patched-codex/codex" "$PUBLISH_DIR/patched-codex/codex-code-mode-host"
  fsync_tree "$PUBLISH_DIR"
  mv -T -- "$PUBLISH_DIR" "$RELEASE_DIR"
  fsync_directory "$RELEASES_DIR"
  PUBLISH_DIR=""
  RELEASE_PUBLISHED_THIS_RUN=1
  remove_tree_without_links "$STAGE_DIR"
  STAGE_DIR=""
  validate_candidate_release
}

atomic_symlink() {
  local target="$1"
  local link="$2"
  local parent=""
  local temporary=""

  parent="$(dirname "$link")"
  temporary="$parent/.$(basename "$link").tmp.$$"

  [[ ! -d "$link" || -L "$link" ]] || fail "refusing to replace directory with symlink: $link"
  rm -f -- "$temporary"
  ln -s "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
  fsync_directory "$parent"
}

fsync_directory() {
  python3 - "$1" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

fsync_tree() {
  python3 - "$1" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
max_entries, max_depth, max_bytes = map(int, sys.argv[2:])
count = 0
total = 0
directories = [root]
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit("fsync tree scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"fsync tree scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"refusing to fsync linked publication entry: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                directories.append(path)
                stack.append((path, next_depth))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
                if total > max_bytes:
                    raise SystemExit("fsync tree scan byte bound exceeded")
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    opened = os.fstat(fd)
                    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                        raise SystemExit(f"fsync tree entry changed identity: {path}")
                    os.fsync(fd)
                finally:
                    os.close(fd)
            else:
                raise SystemExit(f"refusing to fsync special publication entry: {path}")
for path in sorted(directories[1:], key=lambda p: len(p.parts), reverse=True):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

validate_regular_tree() {
  local label="$1"
  local root="$2"

  python3 - "$label" "$root" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import stat
import sys
from pathlib import Path

label = sys.argv[1]
root = Path(sys.argv[2])
max_entries, max_depth, max_bytes = map(int, sys.argv[3:])
root_mode = root.lstat().st_mode
if not stat.S_ISDIR(root_mode) or stat.S_ISLNK(root_mode):
    raise SystemExit(f"{label} must be a real directory: {root}")
count = 0
total = 0
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit(f"{label} scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"{label} scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"{label} contains a linked or special entry: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                stack.append((path, next_depth))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
                if total > max_bytes:
                    raise SystemExit(f"{label} scan byte bound exceeded")
            else:
                raise SystemExit(f"{label} contains a linked or special entry: {path}")
PY
}

chmod_tree_bounded() {
  local root="$1"
  local file_mode="$2"
  local directory_mode="$3"

  python3 - "$root" "$file_mode" "$directory_mode" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
file_mode = int(sys.argv[2], 8)
directory_mode = int(sys.argv[3], 8)
max_entries, max_depth, max_bytes = map(int, sys.argv[4:])
count = 0
total = 0
directories = [root]
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit("chmod tree scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"chmod tree scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"chmod tree contains a symlink: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                directories.append(path)
                stack.append((path, next_depth))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
                if total > max_bytes:
                    raise SystemExit("chmod tree scan byte bound exceeded")
                os.chmod(path, file_mode, follow_symlinks=False)
            else:
                raise SystemExit(f"chmod tree contains a special entry: {path}")
for directory in sorted(directories, key=lambda value: len(value.parts), reverse=True):
    os.chmod(directory, directory_mode, follow_symlinks=False)
PY
}

remove_tree_without_links() {
  local root="$1"

  python3 - "$root" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
max_entries, max_depth, max_bytes = map(int, sys.argv[2:])
try:
    root_mode = root.lstat().st_mode
except FileNotFoundError:
    raise SystemExit(0)
if stat.S_ISLNK(root_mode) or not stat.S_ISDIR(root_mode):
    raise SystemExit(f"refusing to remove linked or non-directory tree: {root}")

directories = [root]
files = []
count = 0
total = 0
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit("remove tree scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"remove tree scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"refusing to remove tree containing linked or special entry: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                directories.append(path)
                stack.append((path, next_depth))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
                if total > max_bytes:
                    raise SystemExit("remove tree scan byte bound exceeded")
                files.append((path, metadata.st_mode, metadata.st_dev, metadata.st_ino))
            else:
                raise SystemExit(f"refusing to remove tree containing linked or special entry: {path}")

for path, mode, expected_dev, expected_ino in files:
    observed = path.lstat()
    if (observed.st_dev, observed.st_ino) != (expected_dev, expected_ino):
        raise SystemExit(f"tree file changed during safe removal: {path}")
    os.chmod(path, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
for path in sorted(directories, key=lambda value: len(value.parts), reverse=True):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise SystemExit(f"tree changed during safe removal: {path}")
    os.chmod(path, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
shutil.rmtree(root)
descriptor = os.open(root.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}
