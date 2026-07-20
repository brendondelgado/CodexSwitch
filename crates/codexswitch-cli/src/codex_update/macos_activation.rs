const MACOS_LAUNCHER_JOURNAL_FORMAT: &str = "codexswitch-macos-runtime-activation-v1";
const MACOS_RUNTIME_ARTIFACT_FORMAT: &str = "codexswitch-macos-runtime-artifact-v1";
const MACOS_RUNTIME_CONTRACT_FORMAT: &str = "codexswitch-macos-runtime-contract-v1";
const MACOS_LAUNCHER_FILE_MAX_BYTES: u64 = 1024 * 1024;
const MACOS_ARTIFACT_MANIFEST_MAX_BYTES: u64 = 64 * 1024;
const MACOS_ARTIFACT_EXECUTABLE_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MacOsRuntimeArtifactManifest {
    format: String,
    codex_switch_git_sha: String,
    codex_switch_build_version: String,
    upstream_codex_version: String,
    upstream_codex_git_sha: String,
    source_patch_sha256: String,
    target_triple: String,
    architecture: String,
    build_epoch: u64,
    files: Vec<MacOsRuntimeArtifactFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MacOsRuntimeArtifactFile {
    name: String,
    bytes: u64,
    sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MacOsRuntimeContractReport {
    contract_format: String,
    artifact_format: String,
    activation_journal_format: String,
    target_triple: String,
    architecture: String,
    commands: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
enum MacOsActivationPhase {
    Prepared,
    LaunchersPublished,
    ReadbackVerified,
    StateSaved,
    CleanupComplete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct MacOsLauncherFileJournal {
    destination: String,
    staged: String,
    backup: String,
    old: Option<RuntimeFileIdentity>,
    new: RuntimeFileIdentity,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct MacOsActivationJournal {
    format: String,
    transaction_id: String,
    version: String,
    previous_installed_version: Option<String>,
    phase: MacOsActivationPhase,
    published_count: usize,
    runtime: RuntimeFileIdentity,
    helper: RuntimeFileIdentity,
    control_cli: RuntimeFileIdentity,
    manifest_file: RuntimeFileIdentity,
    artifact_manifest: MacOsRuntimeArtifactManifest,
    launchers: Vec<MacOsLauncherFileJournal>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MacOsActivationRecoveryOutcome {
    Committed,
    RolledBack,
}

pub(crate) fn macos_runtime_contract_report() -> MacOsRuntimeContractReport {
    MacOsRuntimeContractReport {
        contract_format: MACOS_RUNTIME_CONTRACT_FORMAT.to_string(),
        artifact_format: MACOS_RUNTIME_ARTIFACT_FORMAT.to_string(),
        activation_journal_format: MACOS_LAUNCHER_JOURNAL_FORMAT.to_string(),
        target_triple: "aarch64-apple-darwin".to_string(),
        architecture: "arm64".to_string(),
        commands: vec![
            "activate-macos-runtime-artifact".to_string(),
            "install-prepared-codex".to_string(),
        ],
    }
}

pub fn stage_macos_runtime_artifact(directory: &Path) -> Result<CodexUpdateReport> {
    if HostPlatform::current() != HostPlatform::MacOs {
        bail!("macOS runtime artifacts can be staged only on macOS");
    }
    let _operation_lock = acquire_macos_artifact_lease()?;
    stage_macos_runtime_artifact_with_lock_held(directory)
}

pub fn activate_macos_runtime_artifact(directory: &Path) -> Result<CodexUpdateReport> {
    if HostPlatform::current() != HostPlatform::MacOs {
        bail!("macOS runtime artifacts can be activated only on macOS");
    }
    let _operation_lock = acquire_macos_artifact_lease()?;

    let data_dir = codexswitch_data_dir()?;
    let pending_journal = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
    let state = load_state()?;
    if path_exists_without_following(&pending_journal)?
        || state.status == UpdateStatus::Installing
        || state.install_transaction.is_some()
    {
        install_prepared_macos_with_lock_held()
            .context("failed to reconcile the prior macOS runtime activation")?;
    }

    let staged = stage_macos_runtime_artifact_with_lock_held(directory)?;
    if staged.status != UpdateStatus::ReadyToInstall {
        bail!("macOS runtime artifact staging did not reach ready_to_install");
    }
    let expected_version = staged
        .prepared_version
        .clone()
        .context("staged macOS runtime report omitted its version")?;
    let installed = install_prepared_macos_with_lock_held()?;
    if installed.status != UpdateStatus::Installed
        || installed.installed_version.as_deref() != Some(expected_version.as_str())
    {
        bail!("macOS runtime artifact activation did not commit the staged version");
    }
    Ok(installed)
}

fn acquire_macos_artifact_lease() -> Result<UpdaterOperationLock> {
    acquire_macos_artifact_lease_at(&codexswitch_data_dir()?.join("codex-update.lock"))
}

fn acquire_macos_artifact_lease_at(path: &Path) -> Result<UpdaterOperationLock> {
    UpdaterOperationLock::try_acquire_at(path)?
        .context("another Codex updater operation holds the macOS artifact lease")
}

fn stage_macos_runtime_artifact_with_lock_held(directory: &Path) -> Result<CodexUpdateReport> {
    let (artifact_dir, manifest, manifest_identity) = validate_macos_runtime_artifact(directory)?;
    let data_dir = codexswitch_data_dir()?;
    let mut state = load_state()?;
    let pending_journal = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
    if path_exists_without_following(&pending_journal)? {
        bail!("cannot stage a macOS runtime while activation recovery is pending");
    }
    fail_if_macos_activation_journal_is_missing(&state_path()?, &mut state)?;
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(&mut state);
        bail!("cannot stage a macOS runtime while an updater failure requires reconciliation");
    }
    if busy_update_state_is_fresh(&state, Utc::now()) {
        bail!("another fresh updater operation prevents macOS artifact staging");
    }
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;

    if state.prepared_version.as_deref() == Some(manifest.upstream_codex_version.as_str())
        && state
            .prepared_binary_path
            .as_deref()
            .map(Path::new)
            .is_some_and(|runtime| {
                validate_prepared_runtime(runtime, &manifest.upstream_codex_version).is_ok()
                    && validate_macos_prepared_control_cli(
                        &runtime.with_file_name("codexswitch-cli"),
                        Some(&manifest.codex_switch_build_version),
                    )
                    .is_ok()
                    && state.prepared_artifact_manifest_sha256.as_deref()
                        == Some(manifest_identity.sha256.as_str())
                    && prepared_generation_matches_manifest(runtime, &manifest)
            })
    {
        state.status = UpdateStatus::ReadyToInstall;
        observe_installed_version(&mut state, installed_codex_version());
        state.error = None;
        state.updated_at = Utc::now();
        save_state(&state)?;
        return Ok(report_from_state(state));
    }

    let prepared_dir = new_prepared_generation_dir(&data_dir, &manifest.upstream_codex_version);
    let prepared_binary = with_new_prepared_generation(&prepared_dir, |generation| {
        for name in ["codex", "codex-code-mode-host", "codexswitch-cli"] {
            let source = artifact_dir.join(name);
            let destination = generation.join(name);
            let member = manifest
                .files
                .iter()
                .find(|member| member.name == name)
                .context("validated macOS manifest lost an expected member")?;
            copy_macos_artifact_member(
                &source,
                &destination,
                member.bytes,
                &member.sha256,
                0o755,
                MACOS_ARTIFACT_EXECUTABLE_MAX_BYTES,
            )?;
            #[cfg(target_os = "macos")]
            validate_existing_macos_signature(&destination)?;
        }
        copy_macos_artifact_member(
            &artifact_dir.join("manifest.json"),
            &generation.join("manifest.json"),
            manifest_identity.bytes,
            &manifest_identity.sha256,
            0o444,
            MACOS_ARTIFACT_MANIFEST_MAX_BYTES,
        )?;
        let (_, staged_manifest, staged_manifest_identity) =
            validate_macos_runtime_artifact(generation)?;
        if staged_manifest != manifest
            || staged_manifest_identity.bytes != manifest_identity.bytes
            || staged_manifest_identity.sha256 != manifest_identity.sha256
        {
            bail!("staged macOS artifact manifest lost its original identity");
        }
        let runtime = generation.join("codex");
        validate_prepared_runtime(&runtime, &manifest.upstream_codex_version)?;
        validate_macos_prepared_control_cli(
            &generation.join("codexswitch-cli"),
            Some(&manifest.codex_switch_build_version),
        )?;
        Ok(runtime)
    })?;

    state.status = UpdateStatus::ReadyToInstall;
    state.latest_stable_version = Some(manifest.upstream_codex_version.clone());
    observe_installed_version(&mut state, installed_codex_version());
    state.prepared_version = Some(manifest.upstream_codex_version.clone());
    state.prepared_source_path = None;
    state.prepared_binary_path = Some(prepared_binary.display().to_string());
    state.prepared_artifact_manifest_sha256 = Some(manifest_identity.sha256);
    clear_prepare_failure(&mut state);
    clear_install_failure(&mut state);
    state.error = None;
    state.updated_at = Utc::now();
    save_state(&state)?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
    Ok(report_from_state(state))
}

fn prepared_generation_matches_manifest(
    runtime: &Path,
    manifest: &MacOsRuntimeArtifactManifest,
) -> bool {
    let Some(generation) = runtime.parent() else {
        return false;
    };
    validate_macos_runtime_artifact(generation)
        .is_ok_and(|(_, prepared_manifest, _)| prepared_manifest == *manifest)
}

fn validate_macos_runtime_artifact(
    directory: &Path,
) -> Result<(PathBuf, MacOsRuntimeArtifactManifest, RuntimeFileIdentity)> {
    if !directory.is_absolute() {
        bail!("macOS runtime artifact directory must be absolute");
    }
    let metadata = fs::symlink_metadata(directory)
        .with_context(|| format!("failed to inspect {}", directory.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!("macOS runtime artifact must be a regular directory");
    }
    let canonical = fs::canonicalize(directory)?;
    if canonical != directory {
        bail!("macOS runtime artifact directory must be a canonical non-linked path");
    }
    let expected_names = HashSet::from([
        "manifest.json".to_string(),
        "codex".to_string(),
        "codex-code-mode-host".to_string(),
        "codexswitch-cli".to_string(),
    ]);
    let mut observed_names = HashSet::new();
    for entry in fs::read_dir(&canonical)? {
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow::anyhow!("macOS artifact filename is not UTF-8"))?;
        if !observed_names.insert(name) || observed_names.len() > expected_names.len() {
            bail!("macOS runtime artifact has duplicate or extra members");
        }
    }
    if observed_names != expected_names {
        bail!("macOS runtime artifact must contain exactly three executables and manifest.json");
    }

    let manifest_path = canonical.join("manifest.json");
    let manifest_bytes = read_bounded_regular_file(
        &manifest_path,
        MACOS_ARTIFACT_MANIFEST_MAX_BYTES,
        "macOS runtime artifact manifest",
    )?;
    let manifest = serde_json::from_slice::<MacOsRuntimeArtifactManifest>(&manifest_bytes)
        .context("macOS runtime artifact manifest is malformed")?;
    validate_macos_runtime_artifact_manifest(&canonical, &manifest)?;
    let manifest_identity = runtime_file_identity(&manifest_path)?;
    Ok((canonical, manifest, manifest_identity))
}

fn validate_macos_runtime_artifact_manifest(
    directory: &Path,
    manifest: &MacOsRuntimeArtifactManifest,
) -> Result<()> {
    if manifest.format != MACOS_RUNTIME_ARTIFACT_FORMAT
        || manifest.target_triple != "aarch64-apple-darwin"
        || manifest.architecture != "arm64"
        || manifest.build_epoch == 0
        || !version_is_stable(&manifest.upstream_codex_version)
        || manifest.codex_switch_git_sha.len() != 40
        || !manifest
            .codex_switch_git_sha
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || manifest.upstream_codex_git_sha.len() != 40
        || !manifest
            .upstream_codex_git_sha
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || manifest.source_patch_sha256.len() != 64
        || !manifest
            .source_patch_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || manifest.codex_switch_build_version.is_empty()
        || manifest.codex_switch_build_version.len() > 512
        || !manifest
            .codex_switch_build_version
            .contains(&format!("git {}", manifest.codex_switch_git_sha))
        || !manifest
            .codex_switch_build_version
            .contains(&format!("built {}", manifest.build_epoch))
        || manifest.codex_switch_build_version.contains("-dirty")
        || manifest.files.len() != 3
    {
        bail!("macOS runtime artifact manifest provenance is invalid");
    }
    let expected_names = HashSet::from([
        "codex".to_string(),
        "codex-code-mode-host".to_string(),
        "codexswitch-cli".to_string(),
    ]);
    let mut observed_names = HashSet::new();
    for member in &manifest.files {
        if !expected_names.contains(&member.name)
            || !observed_names.insert(member.name.clone())
            || member.bytes == 0
            || member.bytes > MACOS_ARTIFACT_EXECUTABLE_MAX_BYTES
            || member.sha256.len() != 64
            || !member
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            bail!("macOS runtime artifact file manifest is invalid");
        }
        let path = directory.join(&member.name);
        let identity = runtime_file_identity(&path)?;
        if identity.bytes != member.bytes || identity.sha256 != member.sha256 {
            bail!("macOS runtime artifact member failed length or hash validation");
        }
        #[cfg(target_os = "macos")]
        {
            validate_macos_artifact_native_executable(&path)?;
        }
    }
    if observed_names != expected_names {
        bail!("macOS runtime artifact file manifest is incomplete");
    }

    let runtime = directory.join("codex");
    validate_prepared_runtime(&runtime, &manifest.upstream_codex_version)?;
    validate_macos_prepared_control_cli(
        &directory.join("codexswitch-cli"),
        Some(&manifest.codex_switch_build_version),
    )?;
    Ok(())
}

fn copy_macos_artifact_member(
    source: &Path,
    destination: &Path,
    expected_bytes: u64,
    expected_sha256: &str,
    mode: u32,
    max_bytes: u64,
) -> Result<()> {
    let source_identity = runtime_file_identity(source)?;
    if source_identity.bytes != expected_bytes
        || source_identity.sha256 != expected_sha256
        || source_identity.bytes == 0
        || source_identity.bytes > max_bytes
    {
        bail!(
            "macOS artifact member changed before staging: {}",
            source.display()
        );
    }
    let source_metadata = fs::symlink_metadata(source)?;
    if source_metadata.file_type().is_symlink() || !source_metadata.is_file() {
        bail!(
            "macOS artifact member is linked or special: {}",
            source.display()
        );
    }
    let mut source_file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(source)?;
    let opened = source_file.metadata()?;
    if opened.dev() != source_identity.device
        || opened.ino() != source_identity.inode
        || opened.len() != expected_bytes
    {
        bail!("macOS artifact member changed identity while opened");
    }
    let mut destination_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(destination)
        .with_context(|| format!("failed to create {}", destination.display()))?;
    let copied = std::io::copy(&mut source_file, &mut destination_file)?;
    if copied != expected_bytes {
        bail!("macOS artifact member copy was incomplete");
    }
    fs::set_permissions(destination, fs::Permissions::from_mode(mode))?;
    destination_file.sync_all()?;
    let destination_identity = runtime_file_identity(destination)?;
    if destination_identity.bytes != expected_bytes
        || destination_identity.sha256 != expected_sha256
    {
        bail!("staged macOS artifact member failed identity readback");
    }
    Ok(())
}

fn read_bounded_regular_file(path: &Path, max_bytes: u64, description: &str) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > max_bytes {
        bail!("{description} is linked, special, or oversized");
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        bail!("{description} changed identity while opened");
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        bail!("{description} exceeded its bounded read limit");
    }
    Ok(bytes)
}

fn install_prepared_macos_with_lock_held() -> Result<CodexUpdateReport> {
    let data_dir = codexswitch_data_dir()?;
    let state_path = state_path()?;
    let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
    let managed_launcher = patched_codex::default_installed_binary()?;
    let user_launcher = patched_codex::default_user_launcher()?;
    let homebrew_launcher = patched_codex::default_homebrew_launcher();
    let mut state = load_state_at(&state_path)?;

    if path_exists_without_following(&journal_path)? {
        let outcome = recover_macos_activation_at(
            &journal_path,
            &state_path,
            &mut state,
            &data_dir,
            &managed_launcher,
            &user_launcher,
            &homebrew_launcher,
        )?;
        if outcome == MacOsActivationRecoveryOutcome::Committed {
            return Ok(report_from_state(state));
        }
        state = load_state_at(&state_path)?;
    }
    fail_if_macos_activation_journal_is_missing(&state_path, &mut state)?;

    if state.status == UpdateStatus::Installed {
        return Ok(report_from_state(state));
    }
    if !matches!(
        state.status,
        UpdateStatus::ReadyToInstall | UpdateStatus::Installing | UpdateStatus::Failed
    ) {
        bail!("no patched Codex update is ready to install");
    }
    let prepared_binary = state
        .prepared_binary_path
        .as_deref()
        .map(PathBuf::from)
        .context("update state is missing prepared binary path")?;
    let expected_version = state
        .prepared_version
        .clone()
        .context("update state is missing prepared version")?;
    let expected_manifest_sha256 = state
        .prepared_artifact_manifest_sha256
        .clone()
        .context("update state is missing prepared artifact manifest identity")?;
    validate_macos_prepared_generation_path(&data_dir, &prepared_binary, &expected_version)?;
    let generation = prepared_binary
        .parent()
        .context("prepared macOS runtime has no generation directory")?;
    let (validated_generation, artifact_manifest, manifest_identity) =
        validate_macos_runtime_artifact(generation)?;
    if validated_generation != generation
        || validated_generation.join("codex") != prepared_binary
        || artifact_manifest.upstream_codex_version != expected_version
        || manifest_identity.sha256 != expected_manifest_sha256
    {
        bail!("prepared macOS runtime no longer matches updater state");
    }

    let activation = activate_macos_prepared_runtime_at(
        &journal_path,
        &state_path,
        &mut state,
        &data_dir,
        &prepared_binary,
        &expected_version,
        &artifact_manifest,
        &managed_launcher,
        &user_launcher,
        &homebrew_launcher,
    );
    if let Err(error) = activation {
        let recovery = if path_exists_without_following(&journal_path).unwrap_or(false) {
            recover_macos_activation_at(
                &journal_path,
                &state_path,
                &mut state,
                &data_dir,
                &managed_launcher,
                &user_launcher,
                &homebrew_launcher,
            )
        } else {
            Ok(MacOsActivationRecoveryOutcome::RolledBack)
        };
        match recovery {
            Ok(MacOsActivationRecoveryOutcome::Committed) => {
                state = load_state_at(&state_path)?;
                return Ok(report_from_state(state));
            }
            Ok(MacOsActivationRecoveryOutcome::RolledBack) => {}
            Err(recovery_error) => {
                state.status = UpdateStatus::Failed;
                state.error = Some(format!(
                    "macOS runtime activation failed and recovery is incomplete: {error:#}; recovery: {recovery_error:#}"
                ));
                state.failed_install_version = Some(expected_version.clone());
                state.install_retry_not_before = Some(Utc::now());
                state.updated_at = Utc::now();
                let failed_at = state.updated_at;
                let transaction_id = state
                    .install_transaction
                    .as_ref()
                    .map(|transaction| transaction.id.clone());
                record_unresolved_failure(
                    &mut state,
                    UpdateFailureKind::Installation,
                    failed_at,
                    Some(expected_version.clone()),
                    transaction_id,
                );
                save_state_at(&state_path, &state)?;
                return Err(error).context("macOS runtime activation recovery is incomplete");
            }
        }

        state = load_state_at(&state_path)?;
        state.status = UpdateStatus::ReadyToInstall;
        state.error = Some(format!(
            "macOS runtime activation rolled back safely: {error:#}"
        ));
        state.updated_at = Utc::now();
        save_state_at(&state_path, &state)?;
        return Err(error).context("macOS runtime activation rolled back safely");
    }

    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
    Ok(report_from_state(state))
}

fn fail_if_macos_activation_journal_is_missing(
    state_path: &Path,
    state: &mut CodexUpdateState,
) -> Result<()> {
    if state.status != UpdateStatus::Installing && state.install_transaction.is_none() {
        return Ok(());
    }
    let message =
        "macOS runtime activation state is installing but its transaction journal is missing";
    record_interrupted_install_block(state, message.to_string());
    save_state_at(state_path, state)?;
    bail!("{message}; refusing to guess a rollback baseline")
}

#[allow(clippy::too_many_arguments)]
fn activate_macos_prepared_runtime_at(
    journal_path: &Path,
    state_path: &Path,
    state: &mut CodexUpdateState,
    data_dir: &Path,
    prepared_binary: &Path,
    expected_version: &str,
    artifact_manifest: &MacOsRuntimeArtifactManifest,
    managed_launcher: &Path,
    user_launcher: &Path,
    homebrew_launcher: &Path,
) -> Result<()> {
    validate_macos_prepared_generation_path(data_dir, prepared_binary, expected_version)?;
    freeze_macos_prepared_generation(prepared_binary)?;
    let generation = prepared_binary
        .parent()
        .context("prepared macOS runtime has no generation directory")?;
    let (_, frozen_manifest, manifest_file_identity) = validate_macos_runtime_artifact(generation)?;
    if &frozen_manifest != artifact_manifest {
        bail!("prepared macOS artifact manifest changed before activation");
    }
    let runtime_identity = runtime_file_identity(prepared_binary)?;
    let helper_path = prepared_binary.with_file_name("codex-code-mode-host");
    let helper_identity = runtime_file_identity(&helper_path)?;
    let control_cli_path = prepared_binary.with_file_name("codexswitch-cli");
    validate_macos_prepared_control_cli(&control_cli_path, None)?;
    let control_cli_identity = runtime_file_identity(&control_cli_path)?;
    let previous_installed_version = state.installed_version.clone();
    let managed_contents = patched_codex::launcher_script_for_runtime(prepared_binary)?;
    if runtime_file_identity(prepared_binary)? != runtime_identity
        || runtime_file_identity(&helper_path)? != helper_identity
        || runtime_file_identity(&control_cli_path)? != control_cli_identity
    {
        bail!("prepared macOS runtime changed while launcher provenance was generated");
    }
    let bridge_contents = patched_codex::bridge_script_for_managed_launcher(managed_launcher)?;
    let transaction_id = uuid::Uuid::new_v4().simple().to_string();
    let control_cli_destination = user_launcher.with_file_name("codexswitch-cli");
    let mut launchers = Vec::with_capacity(4);
    match stage_macos_launcher(managed_launcher, &managed_contents, &transaction_id) {
        Ok(launcher) => launchers.push(launcher),
        Err(error) => return Err(error),
    }
    match stage_macos_executable(&control_cli_path, &control_cli_destination, &transaction_id) {
        Ok(launcher) => launchers.push(launcher),
        Err(error) => {
            cleanup_staged_macos_launchers(&launchers)?;
            return Err(error);
        }
    }
    for (destination, contents) in [
        (user_launcher, bridge_contents.as_str()),
        (homebrew_launcher, bridge_contents.as_str()),
    ] {
        match stage_macos_launcher(destination, contents, &transaction_id) {
            Ok(launcher) => launchers.push(launcher),
            Err(error) => {
                let cleanup = cleanup_staged_macos_launchers(&launchers);
                return match cleanup {
                    Ok(()) => Err(error),
                    Err(cleanup_error) => Err(error).with_context(|| {
                        format!("also failed to clean staged macOS launchers: {cleanup_error:#}")
                    }),
                };
            }
        }
    }

    let mut journal = MacOsActivationJournal {
        format: MACOS_LAUNCHER_JOURNAL_FORMAT.to_string(),
        transaction_id: transaction_id.clone(),
        version: expected_version.to_string(),
        previous_installed_version,
        phase: MacOsActivationPhase::Prepared,
        published_count: 0,
        runtime: runtime_identity,
        helper: helper_identity,
        control_cli: control_cli_identity,
        manifest_file: manifest_file_identity,
        artifact_manifest: artifact_manifest.clone(),
        launchers,
    };
    if let Err(error) = write_macos_activation_journal(journal_path, &journal) {
        let cleanup = cleanup_staged_macos_launchers(&journal.launchers);
        return match cleanup {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(error).with_context(|| {
                format!("also failed to clean staged macOS launchers: {cleanup_error:#}")
            }),
        };
    }
    for launcher in &journal.launchers {
        create_macos_launcher_backup(launcher)?;
    }

    state.status = UpdateStatus::Installing;
    state.install_transaction = Some(InstallTransactionState {
        id: transaction_id.clone(),
        version: expected_version.to_string(),
        phase: InstallTransactionStatePhase::Interruptible,
    });
    state.error = None;
    state.updated_at = Utc::now();
    save_state_at(state_path, state)?;

    for index in 0..journal.launchers.len() {
        publish_macos_launcher(&journal.launchers[index])?;
        journal.published_count = index + 1;
        write_macos_activation_journal(journal_path, &journal)?;
    }
    journal.phase = MacOsActivationPhase::LaunchersPublished;
    write_macos_activation_journal(journal_path, &journal)?;

    verify_macos_activation_readback(&journal, prepared_binary, &helper_path)?;
    journal.phase = MacOsActivationPhase::ReadbackVerified;
    write_macos_activation_journal(journal_path, &journal)?;

    mark_version_installed_for_transaction(state, expected_version, &transaction_id, Utc::now());
    state.installed_artifact_manifest_sha256 = Some(journal.manifest_file.sha256.clone());
    let resolves_prior_install_failure = state.unresolved_failure.as_ref().is_some_and(|failure| {
        failure.kind == UpdateFailureKind::Installation
            && failure.version.as_deref() == Some(expected_version)
    });
    if resolves_prior_install_failure {
        clear_install_failure(state);
        clear_unresolved_failure(state);
        state.status = UpdateStatus::Installed;
        state.error = None;
    }
    save_state_at(state_path, state)?;
    journal.phase = MacOsActivationPhase::StateSaved;
    write_macos_activation_journal(journal_path, &journal)?;

    cleanup_macos_activation_files(&journal)?;
    journal.phase = MacOsActivationPhase::CleanupComplete;
    write_macos_activation_journal(journal_path, &journal)?;
    state.install_transaction = None;
    save_state_at(state_path, state)?;
    remove_macos_activation_journal(journal_path)?;
    Ok(())
}

fn validate_macos_prepared_generation_path(
    data_dir: &Path,
    prepared_binary: &Path,
    expected_version: &str,
) -> Result<()> {
    validate_macos_prepared_generation_shape(data_dir, prepared_binary, expected_version)?;
    let prepared_root = data_dir.join("prepared-codex");
    let canonical_root = fs::canonicalize(&prepared_root)
        .with_context(|| format!("failed to resolve {}", prepared_root.display()))?;
    let canonical_binary = fs::canonicalize(prepared_binary)
        .with_context(|| format!("failed to resolve {}", prepared_binary.display()))?;
    if canonical_binary != prepared_binary || !canonical_binary.starts_with(&canonical_root) {
        bail!("prepared macOS runtime must be an unlinked canonical updater path");
    }
    for path in [
        prepared_binary,
        &prepared_binary.with_file_name("codex-code-mode-host"),
        &prepared_binary.with_file_name("codexswitch-cli"),
        &prepared_binary.with_file_name("manifest.json"),
    ] {
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("failed to inspect {}", path.display()))?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            bail!(
                "prepared macOS runtime member is not a regular file: {}",
                path.display()
            );
        }
    }
    Ok(())
}

fn validate_macos_prepared_generation_shape(
    data_dir: &Path,
    prepared_binary: &Path,
    expected_version: &str,
) -> Result<()> {
    if !data_dir.is_absolute()
        || !prepared_binary.is_absolute()
        || !version_is_stable(expected_version)
    {
        bail!("prepared macOS runtime path or version is invalid");
    }
    let prepared_root = data_dir.join("prepared-codex");
    let relative = prepared_binary
        .strip_prefix(&prepared_root)
        .context("prepared runtime escaped its updater root")?;
    let components = relative.components().collect::<Vec<_>>();
    if components.len() != 3
        || components[0].as_os_str() != std::ffi::OsStr::new(expected_version)
        || components[2].as_os_str() != std::ffi::OsStr::new("codex")
    {
        bail!("prepared macOS runtime does not match <version>/<attempt-id>/codex");
    }
    let attempt = components[1].as_os_str().to_string_lossy();
    if attempt.len() != 32
        || !attempt
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        bail!("prepared macOS runtime attempt id is invalid");
    }
    Ok(())
}

fn freeze_macos_prepared_generation(runtime: &Path) -> Result<()> {
    let helper = runtime.with_file_name("codex-code-mode-host");
    let control_cli = runtime.with_file_name("codexswitch-cli");
    let manifest = runtime.with_file_name("manifest.json");
    let generation = runtime
        .parent()
        .context("prepared runtime has no generation directory")?;
    for path in [runtime, helper.as_path(), control_cli.as_path()] {
        fs::set_permissions(path, fs::Permissions::from_mode(0o555))
            .with_context(|| format!("failed to freeze {}", path.display()))?;
        fs::File::open(path)
            .and_then(|file| file.sync_all())
            .with_context(|| format!("failed to sync {}", path.display()))?;
    }
    fs::set_permissions(&manifest, fs::Permissions::from_mode(0o444))
        .with_context(|| format!("failed to freeze {}", manifest.display()))?;
    fs::File::open(&manifest)
        .and_then(|file| file.sync_all())
        .with_context(|| format!("failed to sync {}", manifest.display()))?;
    // Keep the directory owner-writable so bounded retention can unlink old
    // generations without first weakening file permissions.
    fs::set_permissions(generation, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to freeze {}", generation.display()))?;
    fs::File::open(generation)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("failed to sync {}", generation.display()))
}

fn stage_macos_launcher(
    destination: &Path,
    contents: &str,
    transaction_id: &str,
) -> Result<MacOsLauncherFileJournal> {
    if !destination.is_absolute() || contents.len() as u64 > MACOS_LAUNCHER_FILE_MAX_BYTES {
        bail!("macOS launcher destination or contents are invalid");
    }
    let parent = destination
        .parent()
        .context("macOS launcher has no parent")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create launcher parent {}", parent.display()))?;
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .context("macOS launcher filename is not UTF-8")?;
    let staged = parent.join(format!(".{name}.codexswitch-new-{transaction_id}"));
    let backup = parent.join(format!(".{name}.codexswitch-old-{transaction_id}"));
    for path in [&staged, &backup] {
        if path_exists_without_following(path)? {
            bail!(
                "macOS launcher transaction path already exists: {}",
                path.display()
            );
        }
    }
    let result = (|| -> Result<MacOsLauncherFileJournal> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o755)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&staged)
            .with_context(|| format!("failed to stage launcher {}", staged.display()))?;
        file.write_all(contents.as_bytes())?;
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))?;
        file.sync_all()?;
        let new = runtime_file_identity(&staged)?;
        let old = runtime_file_identity_if_present(destination)?;
        Ok(MacOsLauncherFileJournal {
            destination: destination.display().to_string(),
            staged: staged.display().to_string(),
            backup: backup.display().to_string(),
            old,
            new,
        })
    })();
    if result.is_err() && path_exists_without_following(&staged).unwrap_or(false) {
        let _ = fs::remove_file(&staged);
        let _ = sync_parent_directory(&staged);
    }
    result
}

fn stage_macos_executable(
    source: &Path,
    destination: &Path,
    transaction_id: &str,
) -> Result<MacOsLauncherFileJournal> {
    let source_metadata = fs::symlink_metadata(source)
        .with_context(|| format!("failed to inspect {}", source.display()))?;
    if source_metadata.file_type().is_symlink()
        || !source_metadata.is_file()
        || source_metadata.len() == 0
        || source_metadata.len() > MACOS_ARTIFACT_EXECUTABLE_MAX_BYTES
    {
        bail!("macOS control-plane source is linked, special, empty, or oversized");
    }
    if !destination.is_absolute() {
        bail!("macOS control-plane destination must be absolute");
    }
    let parent = destination
        .parent()
        .context("macOS control-plane destination has no parent")?;
    fs::create_dir_all(parent)?;
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .context("macOS control-plane filename is not UTF-8")?;
    let staged = parent.join(format!(".{name}.codexswitch-new-{transaction_id}"));
    let backup = parent.join(format!(".{name}.codexswitch-old-{transaction_id}"));
    for path in [&staged, &backup] {
        if path_exists_without_following(path)? {
            bail!(
                "macOS control-plane transaction path already exists: {}",
                path.display()
            );
        }
    }
    let result = (|| -> Result<MacOsLauncherFileJournal> {
        let mut source_file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(source)
            .with_context(|| {
                format!(
                    "failed to open {} without following links",
                    source.display()
                )
            })?;
        let opened_source = source_file.metadata()?;
        if opened_source.dev() != source_metadata.dev()
            || opened_source.ino() != source_metadata.ino()
            || opened_source.mode() != source_metadata.mode()
            || opened_source.len() != source_metadata.len()
        {
            bail!("macOS control-plane source changed identity while opened");
        }
        let mut staged_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o755)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&staged)
            .with_context(|| {
                format!("failed to create staged control plane {}", staged.display())
            })?;
        let copied = std::io::copy(&mut source_file, &mut staged_file)?;
        if copied != source_metadata.len() {
            bail!("staged macOS control-plane copy was incomplete");
        }
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))?;
        staged_file.sync_all()?;
        let new = runtime_file_identity(&staged)?;
        let old = runtime_file_identity_if_present(destination)?;
        Ok(MacOsLauncherFileJournal {
            destination: destination.display().to_string(),
            staged: staged.display().to_string(),
            backup: backup.display().to_string(),
            old,
            new,
        })
    })();
    if result.is_err() && path_exists_without_following(&staged).unwrap_or(false) {
        let _ = fs::remove_file(&staged);
        let _ = sync_parent_directory(&staged);
    }
    result
}

fn validate_macos_prepared_control_cli(
    control_cli: &Path,
    expected_build_version: Option<&str>,
) -> Result<()> {
    let metadata = fs::symlink_metadata(control_cli)
        .with_context(|| format!("failed to inspect {}", control_cli.display()))?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() == 0
        || metadata.len() > MACOS_ARTIFACT_EXECUTABLE_MAX_BYTES
        || metadata.permissions().mode() & 0o111 == 0
    {
        bail!("prepared codexswitch-cli is linked, special, empty, oversized, or not executable");
    }
    #[cfg(target_os = "macos")]
    {
        validate_macos_artifact_native_executable(control_cli)?;
    }
    let contract_output = bounded_command::output(
        Command::new(control_cli).arg("macos-runtime-contract"),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .with_context(|| {
        format!(
            "failed to run {} macos-runtime-contract",
            control_cli.display()
        )
    })?;
    if !contract_output.status.success() {
        bail!("prepared codexswitch-cli runtime contract probe failed");
    }
    let observed_contract: MacOsRuntimeContractReport =
        serde_json::from_slice(&contract_output.stdout)
            .context("prepared codexswitch-cli runtime contract is not valid JSON")?;
    if observed_contract != macos_runtime_contract_report() {
        bail!("prepared codexswitch-cli reported the wrong macOS activation contract");
    }
    let output = bounded_command::output(
        Command::new(control_cli).arg("--version"),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .with_context(|| format!("failed to run {} --version", control_cli.display()))?;
    if !output.status.success() {
        bail!("prepared codexswitch-cli version probe failed");
    }
    if let Some(expected) = expected_build_version {
        let observed = String::from_utf8(output.stdout)
            .context("prepared codexswitch-cli version output is not UTF-8")?;
        if observed.trim() != expected {
            bail!("prepared codexswitch-cli build version did not match its manifest");
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_thin_arm64_macho(path: &Path) -> Result<()> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let mut header = [0_u8; 8];
    file.read_exact(&mut header)?;
    if header[..4] != [0xcf, 0xfa, 0xed, 0xfe]
        || u32::from_le_bytes(header[4..8].try_into().expect("four-byte CPU type")) != 0x0100_000c
    {
        bail!("macOS runtime artifact member is not a thin arm64 Mach-O executable");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_existing_macos_signature(path: &Path) -> Result<()> {
    let status = bounded_command::status(
        Command::new("/usr/bin/codesign")
            .args(["--verify", "--strict"])
            .arg(path),
        PROBE_COMMAND_TIMEOUT,
    )?;
    if !status.success() {
        bail!(
            "macOS runtime artifact signature is invalid: {}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_macos_artifact_native_executable(path: &Path) -> Result<()> {
    #[cfg(test)]
    {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let mut fixture_header = [0_u8; 10];
        if file.read(&mut fixture_header)? == fixture_header.len()
            && fixture_header == *b"#!/bin/sh\n"
        {
            return Ok(());
        }
    }
    validate_thin_arm64_macho(path)?;
    validate_existing_macos_signature(path)
}

fn create_macos_launcher_backup(launcher: &MacOsLauncherFileJournal) -> Result<()> {
    let Some(old) = launcher.old.as_ref() else {
        return Ok(());
    };
    let destination = Path::new(&launcher.destination);
    let backup = Path::new(&launcher.backup);
    if !runtime_identity_matches(destination, old)? {
        bail!(
            "macOS launcher changed before backup: {}",
            destination.display()
        );
    }
    fs::hard_link(destination, backup).with_context(|| {
        format!(
            "failed to anchor launcher backup {} as {}",
            destination.display(),
            backup.display()
        )
    })?;
    if !runtime_identity_matches(backup, old)? {
        bail!(
            "macOS launcher backup readback failed: {}",
            backup.display()
        );
    }
    sync_parent_directory(destination)
}

fn publish_macos_launcher(launcher: &MacOsLauncherFileJournal) -> Result<()> {
    let destination = Path::new(&launcher.destination);
    let staged = Path::new(&launcher.staged);
    match launcher.old.as_ref() {
        Some(old) if !runtime_identity_matches(destination, old)? => {
            bail!(
                "macOS launcher changed before publication: {}",
                destination.display()
            )
        }
        None if path_exists_without_following(destination)? => {
            bail!(
                "macOS launcher appeared before publication: {}",
                destination.display()
            )
        }
        _ => {}
    }
    if !runtime_identity_matches(staged, &launcher.new)? {
        bail!(
            "staged macOS launcher changed before publication: {}",
            staged.display()
        );
    }
    fs::rename(staged, destination).with_context(|| {
        format!(
            "failed to publish macOS launcher {} as {}",
            staged.display(),
            destination.display()
        )
    })?;
    sync_parent_directory(destination)?;
    if !runtime_identity_matches(destination, &launcher.new)? {
        bail!(
            "published macOS launcher readback failed: {}",
            destination.display()
        );
    }
    Ok(())
}

fn verify_macos_activation_readback(
    journal: &MacOsActivationJournal,
    runtime: &Path,
    helper: &Path,
) -> Result<()> {
    if !runtime_identity_matches(runtime, &journal.runtime)?
        || !runtime_identity_matches(helper, &journal.helper)?
        || !runtime_identity_matches(
            &runtime.with_file_name("codexswitch-cli"),
            &journal.control_cli,
        )?
        || !runtime_identity_matches(
            &runtime.with_file_name("manifest.json"),
            &journal.manifest_file,
        )?
    {
        bail!("immutable macOS runtime generation changed during activation");
    }
    let generation = runtime
        .parent()
        .context("journaled macOS runtime has no generation directory")?;
    let (_, observed_manifest, observed_manifest_identity) =
        validate_macos_runtime_artifact(generation)?;
    if observed_manifest != journal.artifact_manifest
        || observed_manifest_identity != journal.manifest_file
    {
        bail!("immutable macOS artifact provenance changed during activation");
    }
    for launcher in &journal.launchers {
        if !runtime_identity_matches(Path::new(&launcher.destination), &launcher.new)? {
            bail!(
                "macOS launcher set readback failed: {}",
                launcher.destination
            );
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn recover_macos_activation_at(
    journal_path: &Path,
    state_path: &Path,
    state: &mut CodexUpdateState,
    data_dir: &Path,
    managed_launcher: &Path,
    user_launcher: &Path,
    homebrew_launcher: &Path,
) -> Result<MacOsActivationRecoveryOutcome> {
    let mut journal = read_macos_activation_journal(journal_path)?;
    validate_macos_activation_journal_paths(
        &journal,
        data_dir,
        managed_launcher,
        user_launcher,
        homebrew_launcher,
    )?;
    let transaction_committed = state
        .install_transaction
        .as_ref()
        .is_some_and(|transaction| {
            transaction.id == journal.transaction_id
                && transaction.version == journal.version
                && transaction.phase == InstallTransactionStatePhase::Committed
                && state.installed_version.as_deref() == Some(journal.version.as_str())
        });
    let state_finalized = journal.phase == MacOsActivationPhase::CleanupComplete
        && state.install_transaction.is_none()
        && state.installed_version.as_deref() == Some(journal.version.as_str());
    let committed = transaction_committed || state_finalized;
    if committed {
        let runtime = Path::new(&journal.runtime.path);
        let helper = Path::new(&journal.helper.path);
        validate_macos_prepared_generation_path(data_dir, runtime, &journal.version)?;
        verify_macos_activation_readback(&journal, runtime, helper)?;
        cleanup_macos_activation_files(&journal)?;
        journal.phase = MacOsActivationPhase::CleanupComplete;
        write_macos_activation_journal(journal_path, &journal)?;
        state.install_transaction = None;
        state.installed_artifact_manifest_sha256 = Some(journal.manifest_file.sha256.clone());
        if state.unresolved_failure.is_some() {
            restore_unresolved_failure(state);
        } else {
            state.status = UpdateStatus::Installed;
            state.error = None;
        }
        state.updated_at = Utc::now();
        save_state_at(state_path, state)?;
        remove_macos_activation_journal(journal_path)?;
        return Ok(MacOsActivationRecoveryOutcome::Committed);
    }

    rollback_macos_activation_files(&journal)?;
    if state
        .install_transaction
        .as_ref()
        .is_some_and(|transaction| transaction.id == journal.transaction_id)
    {
        state.install_transaction = None;
    }
    state.status = UpdateStatus::ReadyToInstall;
    state.installed_version = journal.previous_installed_version.clone();
    state.error = Some("interrupted macOS runtime activation rolled back safely".to_string());
    state.updated_at = Utc::now();
    save_state_at(state_path, state)?;
    remove_macos_activation_journal(journal_path)?;
    Ok(MacOsActivationRecoveryOutcome::RolledBack)
}

fn rollback_macos_activation_files(journal: &MacOsActivationJournal) -> Result<()> {
    for launcher in journal.launchers.iter().rev() {
        let destination = Path::new(&launcher.destination);
        let staged = Path::new(&launcher.staged);
        let backup = Path::new(&launcher.backup);
        let destination_is_new = runtime_identity_matches(destination, &launcher.new)?;
        let destination_is_old = match launcher.old.as_ref() {
            Some(old) => runtime_identity_matches(destination, old)?,
            None => !path_exists_without_following(destination)?,
        };
        if destination_is_new {
            if let Some(old) = launcher.old.as_ref() {
                if !runtime_identity_matches(backup, old)? {
                    bail!(
                        "macOS launcher rollback backup is missing or changed: {}",
                        backup.display()
                    );
                }
                fs::rename(backup, destination)?;
            } else {
                fs::remove_file(destination)?;
            }
            sync_parent_directory(destination)?;
        } else if !destination_is_old {
            bail!(
                "macOS launcher changed outside its activation transaction: {}",
                destination.display()
            );
        }
        remove_macos_transaction_file_if_owned(staged, Some(&launcher.new))?;
        remove_macos_transaction_file_if_owned(backup, launcher.old.as_ref())?;
    }
    Ok(())
}

fn cleanup_macos_activation_files(journal: &MacOsActivationJournal) -> Result<()> {
    for launcher in &journal.launchers {
        remove_macos_transaction_file_if_owned(Path::new(&launcher.staged), Some(&launcher.new))?;
        remove_macos_transaction_file_if_owned(Path::new(&launcher.backup), launcher.old.as_ref())?;
    }
    Ok(())
}

fn cleanup_staged_macos_launchers(launchers: &[MacOsLauncherFileJournal]) -> Result<()> {
    for launcher in launchers {
        remove_macos_transaction_file_if_owned(Path::new(&launcher.staged), Some(&launcher.new))?;
    }
    Ok(())
}

fn remove_macos_transaction_file_if_owned(
    path: &Path,
    expected: Option<&RuntimeFileIdentity>,
) -> Result<()> {
    if !path_exists_without_following(path)? {
        return Ok(());
    }
    let Some(expected) = expected else {
        bail!(
            "unexpected macOS launcher transaction file exists: {}",
            path.display()
        );
    };
    if !runtime_identity_matches(path, expected)? {
        bail!(
            "macOS launcher transaction file changed: {}",
            path.display()
        );
    }
    fs::remove_file(path)?;
    sync_parent_directory(path)
}

fn validate_macos_activation_journal_paths(
    journal: &MacOsActivationJournal,
    data_dir: &Path,
    managed_launcher: &Path,
    user_launcher: &Path,
    homebrew_launcher: &Path,
) -> Result<()> {
    if journal.format != MACOS_LAUNCHER_JOURNAL_FORMAT
        || !version_is_stable(&journal.version)
        || journal.transaction_id.len() != 32
        || !journal
            .transaction_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
        || journal.launchers.len() != 4
        || journal.published_count > journal.launchers.len()
    {
        bail!("macOS runtime activation journal provenance is invalid");
    }
    let control_cli_destination = user_launcher.with_file_name("codexswitch-cli");
    let expected = [
        managed_launcher,
        control_cli_destination.as_path(),
        user_launcher,
        homebrew_launcher,
    ];
    for (launcher, expected_destination) in journal.launchers.iter().zip(expected) {
        if Path::new(&launcher.destination) != expected_destination {
            bail!("macOS activation journal names an unexpected launcher destination");
        }
        let parent = expected_destination
            .parent()
            .context("journaled launcher destination has no parent")?;
        for path in [Path::new(&launcher.staged), Path::new(&launcher.backup)] {
            if path.parent() != Some(parent)
                || !path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.ends_with(&journal.transaction_id))
            {
                bail!("macOS activation journal transaction path is invalid");
            }
        }
    }
    let runtime = Path::new(&journal.runtime.path);
    validate_macos_prepared_generation_shape(data_dir, runtime, &journal.version)?;
    if Path::new(&journal.helper.path) != runtime.with_file_name("codex-code-mode-host") {
        bail!("macOS activation journal helper is not paired with its runtime");
    }
    if Path::new(&journal.control_cli.path) != runtime.with_file_name("codexswitch-cli") {
        bail!("macOS activation journal control plane is not paired with its runtime");
    }
    if Path::new(&journal.manifest_file.path) != runtime.with_file_name("manifest.json") {
        bail!("macOS activation journal manifest is not paired with its runtime");
    }
    if journal.artifact_manifest.upstream_codex_version != journal.version {
        bail!("macOS activation journal manifest version is inconsistent");
    }
    let generation = runtime
        .parent()
        .context("journaled macOS runtime has no generation directory")?;
    let (_, observed_manifest, observed_manifest_file) =
        validate_macos_runtime_artifact(generation)?;
    if observed_manifest != journal.artifact_manifest
        || observed_manifest_file != journal.manifest_file
    {
        bail!("macOS activation journal no longer binds its prepared artifact");
    }
    Ok(())
}

fn write_macos_activation_journal(path: &Path, journal: &MacOsActivationJournal) -> Result<()> {
    let parent = path
        .parent()
        .context("macOS activation journal has no parent")?;
    fs::create_dir_all(parent)?;
    if matches!(fs::symlink_metadata(path), Ok(metadata) if metadata.file_type().is_symlink()) {
        bail!("macOS activation journal must not be a symlink");
    }
    let encoded = serde_json::to_vec_pretty(journal)?;
    if encoded.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!("macOS activation journal exceeded its bounded size");
    }
    let temp = parent.join(format!(
        ".macos-runtime-activation.tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temp)?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        sync_parent_directory(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result.with_context(|| format!("failed to persist {}", path.display()))
}

fn read_macos_activation_journal(path: &Path) -> Result<MacOsActivationJournal> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > UPDATE_STATE_MAX_BYTES
    {
        bail!("macOS activation journal is linked, special, or oversized");
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        bail!("macOS activation journal changed identity while opened");
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(UPDATE_STATE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!("macOS activation journal exceeded its bounded read limit");
    }
    serde_json::from_slice(&bytes).context("macOS activation journal is malformed")
}

fn remove_macos_activation_journal(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            fs::remove_file(path)?;
            sync_parent_directory(path)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(_) => bail!("macOS activation journal cleanup path is unsafe"),
        Err(error) => Err(error.into()),
    }
}

fn path_exists_without_following(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("failed to inspect {}", path.display())),
    }
}

#[cfg(test)]
mod macos_activation_tests {
    use super::*;

    const TEST_VERSION: &str = "0.144.3";
    const TEST_ATTEMPT: &str = "0123456789abcdef0123456789abcdef";

    fn write_fake_runtime(data_dir: &Path) -> Result<PathBuf> {
        let generation = data_dir
            .join("prepared-codex")
            .join(TEST_VERSION)
            .join(TEST_ATTEMPT);
        fs::create_dir_all(&generation)?;
        let runtime = generation.join("codex");
        let helper = generation.join("codex-code-mode-host");
        let control_cli = generation.join("codexswitch-cli");
        fs::write(
            &runtime,
            format!(
                "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-headless-idle-v1 codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective>\nif [ \"${{1:-}}\" = --version ]; then echo 'codex-cli {TEST_VERSION}'; exit 0; fi\nprintf 'runtime:%s\\n' \"$*\"\n"
            ),
        )?;
        fs::write(&helper, "#!/bin/sh\nexit 0\n")?;
        fs::write(
            &control_cli,
            "#!/bin/sh\nif [ \"${1:-}\" = macos-runtime-contract ]; then printf '%s\\n' '{\"contractFormat\":\"codexswitch-macos-runtime-contract-v1\",\"artifactFormat\":\"codexswitch-macos-runtime-artifact-v1\",\"activationJournalFormat\":\"codexswitch-macos-runtime-activation-v1\",\"targetTriple\":\"aarch64-apple-darwin\",\"architecture\":\"arm64\",\"commands\":[\"activate-macos-runtime-artifact\",\"install-prepared-codex\"]}'; exit 0; fi\nif [ \"${1:-}\" = --version ]; then echo 'codexswitch-cli 0.1.0 (git 0123456789abcdef0123456789abcdef01234567, built 1783915200)'; exit 0; fi\nexit 0\n",
        )?;
        set_executable(&runtime)?;
        set_executable(&helper)?;
        set_executable(&control_cli)?;
        write_artifact_manifest(&generation)?;
        Ok(runtime)
    }

    fn ready_state(runtime: &Path) -> CodexUpdateState {
        let mut state = CodexUpdateState::default();
        state.status = UpdateStatus::ReadyToInstall;
        state.latest_stable_version = Some(TEST_VERSION.to_string());
        state.prepared_version = Some(TEST_VERSION.to_string());
        state.prepared_binary_path = Some(runtime.display().to_string());
        state.prepared_artifact_manifest_sha256 = Some(
            patched_codex::sha256_file(&runtime.with_file_name("manifest.json"))
                .expect("test manifest hash"),
        );
        state
    }

    fn activation_paths(root: &Path) -> (PathBuf, PathBuf, PathBuf) {
        (
            root.join("managed/codex"),
            root.join("user-bin/codex"),
            root.join("homebrew-bin/codex"),
        )
    }

    fn write_artifact_manifest(directory: &Path) -> Result<()> {
        let mut files = Vec::new();
        for name in ["codex", "codex-code-mode-host", "codexswitch-cli"] {
            let path = directory.join(name);
            files.push(serde_json::json!({
                "name": name,
                "bytes": fs::metadata(&path)?.len(),
                "sha256": patched_codex::sha256_file(&path)?,
            }));
        }
        let manifest = serde_json::json!({
            "format": MACOS_RUNTIME_ARTIFACT_FORMAT,
            "codexSwitchGitSha": "0123456789abcdef0123456789abcdef01234567",
            "codexSwitchBuildVersion": "codexswitch-cli 0.1.0 (git 0123456789abcdef0123456789abcdef01234567, built 1783915200)",
            "upstreamCodexVersion": TEST_VERSION,
            "upstreamCodexGitSha": "76543210fedcba9876543210fedcba9876543210",
            "sourcePatchSha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            "targetTriple": "aarch64-apple-darwin",
            "architecture": "arm64",
            "buildEpoch": 1_783_915_200_u64,
            "files": files,
        });
        fs::write(
            directory.join("manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        Ok(())
    }

    fn staged_first_install_journal(
        root: &Path,
        runtime: &Path,
        transaction_id: &str,
    ) -> Result<(MacOsActivationJournal, PathBuf, PathBuf, PathBuf)> {
        let (managed, user, homebrew) = activation_paths(root);
        let control_cli_destination = user.with_file_name("codexswitch-cli");
        let managed_contents = patched_codex::launcher_script_for_runtime(runtime)?;
        let bridge = patched_codex::bridge_script_for_managed_launcher(&managed)?;
        let launchers = vec![
            stage_macos_launcher(&managed, &managed_contents, transaction_id)?,
            stage_macos_executable(
                &runtime.with_file_name("codexswitch-cli"),
                &control_cli_destination,
                transaction_id,
            )?,
            stage_macos_launcher(&user, &bridge, transaction_id)?,
            stage_macos_launcher(&homebrew, &bridge, transaction_id)?,
        ];
        assert!(launchers.iter().all(|launcher| launcher.old.is_none()));
        let (_, artifact_manifest, manifest_file) =
            validate_macos_runtime_artifact(runtime.parent().unwrap())?;
        let journal = MacOsActivationJournal {
            format: MACOS_LAUNCHER_JOURNAL_FORMAT.to_string(),
            transaction_id: transaction_id.to_string(),
            version: TEST_VERSION.to_string(),
            previous_installed_version: None,
            phase: MacOsActivationPhase::Prepared,
            published_count: 0,
            runtime: runtime_file_identity(runtime)?,
            helper: runtime_file_identity(&runtime.with_file_name("codex-code-mode-host"))?,
            control_cli: runtime_file_identity(&runtime.with_file_name("codexswitch-cli"))?,
            manifest_file,
            artifact_manifest,
            launchers,
        };
        Ok((journal, managed, user, homebrew))
    }

    #[test]
    fn macos_artifact_manifest_binds_exact_three_binary_set() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("source");
        let runtime = write_fake_runtime(&data_dir)?;
        let artifact = runtime.parent().unwrap();
        write_artifact_manifest(artifact)?;

        let (validated_dir, manifest, _) = validate_macos_runtime_artifact(artifact)?;

        assert_eq!(validated_dir, artifact);
        assert_eq!(manifest.upstream_codex_version, TEST_VERSION);
        assert_eq!(manifest.files.len(), 3);
        assert!(prepared_generation_matches_manifest(&runtime, &manifest));
        fs::write(artifact.join("codex-code-mode-host"), "#!/bin/sh\nexit 1\n")?;
        set_executable(&artifact.join("codex-code-mode-host"))?;
        assert!(!prepared_generation_matches_manifest(&runtime, &manifest));
        Ok(())
    }

    #[test]
    fn macos_runtime_contract_report_is_exact() {
        assert_eq!(
            macos_runtime_contract_report(),
            MacOsRuntimeContractReport {
                contract_format: "codexswitch-macos-runtime-contract-v1".to_string(),
                artifact_format: "codexswitch-macos-runtime-artifact-v1".to_string(),
                activation_journal_format: "codexswitch-macos-runtime-activation-v1".to_string(),
                target_triple: "aarch64-apple-darwin".to_string(),
                architecture: "arm64".to_string(),
                commands: vec![
                    "activate-macos-runtime-artifact".to_string(),
                    "install-prepared-codex".to_string(),
                ],
            }
        );
    }

    #[test]
    fn macos_artifact_rejects_hash_drift_and_extra_members() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("source");
        let runtime = write_fake_runtime(&data_dir)?;
        let artifact = runtime.parent().unwrap();
        write_artifact_manifest(artifact)?;
        fs::write(artifact.join("unexpected"), "not allowed")?;
        assert!(validate_macos_runtime_artifact(artifact).is_err());
        fs::remove_file(artifact.join("unexpected"))?;
        fs::write(artifact.join("codex-code-mode-host"), "#!/bin/sh\nexit 1\n")?;
        set_executable(&artifact.join("codex-code-mode-host"))?;
        assert!(validate_macos_runtime_artifact(artifact).is_err());
        Ok(())
    }

    #[test]
    fn macos_artifact_requires_exact_source_provenance() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let runtime = write_fake_runtime(&root.join("source"))?;
        let artifact = runtime.parent().unwrap();
        let manifest_path = artifact.join("manifest.json");
        let mut manifest: serde_json::Value = serde_json::from_slice(&fs::read(&manifest_path)?)?;
        manifest["upstreamCodexGitSha"] = serde_json::json!("not-a-commit");
        fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest)?)?;

        assert!(validate_macos_runtime_artifact(artifact).is_err());
        Ok(())
    }

    #[test]
    fn macos_artifact_lease_contention_is_an_error() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let lock_path = temp.path().join("codex-update.lock");
        let held = UpdaterOperationLock::try_acquire_at(&lock_path)?
            .context("test failed to acquire the first updater lease")?;

        let error = match acquire_macos_artifact_lease_at(&lock_path) {
            Ok(_) => bail!("contended macOS artifact lease unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(format!("{error:#}").contains("holds the macOS artifact lease"));
        drop(held);
        assert!(acquire_macos_artifact_lease_at(&lock_path).is_ok());
        Ok(())
    }

    #[test]
    fn missing_activation_journal_blocks_installing_state_durably() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let state_path = temp.path().join("codex-cli-update.json");
        let mut state = CodexUpdateState::default();
        state.status = UpdateStatus::Installing;
        state.prepared_version = Some(TEST_VERSION.to_string());
        state.install_transaction = Some(InstallTransactionState {
            id: "abcdefabcdefabcdefabcdefabcdefab".to_string(),
            version: TEST_VERSION.to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });

        let error = fail_if_macos_activation_journal_is_missing(&state_path, &mut state)
            .expect_err("missing journal must fail closed");

        assert!(format!("{error:#}").contains("refusing to guess a rollback baseline"));
        let persisted = load_state_at(&state_path)?;
        assert_eq!(persisted.status, UpdateStatus::Failed);
        assert!(persisted.unresolved_failure.is_some());
        assert!(persisted.install_transaction.is_some());
        assert_eq!(
            persisted.failed_install_version.as_deref(),
            Some(TEST_VERSION)
        );
        Ok(())
    }

    #[test]
    fn prepared_manifest_substitution_blocks_activation_before_publication() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let generation = runtime.parent().unwrap();
        let (_, original_manifest, _) = validate_macos_runtime_artifact(generation)?;
        let mut substituted_manifest = original_manifest.clone();
        substituted_manifest.source_patch_sha256 =
            "1111111111111111111111111111111111111111111111111111111111111111".to_string();
        fs::write(
            generation.join("manifest.json"),
            serde_json::to_vec_pretty(&substituted_manifest)?,
        )?;
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
        let (managed, user, homebrew) = activation_paths(&root);
        let mut state = ready_state(&runtime);

        let result = activate_macos_prepared_runtime_at(
            &journal_path,
            &state_path,
            &mut state,
            &data_dir,
            &runtime,
            TEST_VERSION,
            &original_manifest,
            &managed,
            &user,
            &homebrew,
        );

        assert!(result.is_err());
        assert!(!managed.exists());
        assert!(!user.exists());
        assert!(!homebrew.exists());
        assert!(!journal_path.exists());
        Ok(())
    }

    #[test]
    fn macos_activation_publishes_attempt_generation_and_constant_time_routes() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
        let (managed, user, homebrew) = activation_paths(&root);
        let mut state = ready_state(&runtime);
        let (_, artifact_manifest, _) = validate_macos_runtime_artifact(runtime.parent().unwrap())?;

        activate_macos_prepared_runtime_at(
            &journal_path,
            &state_path,
            &mut state,
            &data_dir,
            &runtime,
            TEST_VERSION,
            &artifact_manifest,
            &managed,
            &user,
            &homebrew,
        )?;

        assert_eq!(state.status, UpdateStatus::Installed);
        assert_eq!(state.installed_version.as_deref(), Some(TEST_VERSION));
        assert_eq!(
            state.installed_artifact_manifest_sha256.as_deref(),
            Some(patched_codex::sha256_file(&runtime.with_file_name("manifest.json"))?.as_str())
        );
        assert_eq!(patched_codex::resolve_installed_runtime(&managed)?, runtime);
        let managed_script = fs::read_to_string(&managed)?;
        assert!(!managed_script.contains("shasum"));
        assert!(!managed_script.contains("sha256sum"));
        assert!(!managed_script.contains("codex_version_base"));
        assert!(!managed_script.contains("--version"));
        let expected_bridge = patched_codex::bridge_script_for_managed_launcher(&managed)?;
        assert_eq!(fs::read_to_string(&user)?, expected_bridge);
        assert_eq!(fs::read_to_string(&homebrew)?, expected_bridge);
        assert!(files_equal(
            &user.with_file_name("codexswitch-cli"),
            &runtime.with_file_name("codexswitch-cli")
        ));
        assert!(!journal_path.exists());
        assert_eq!(
            fs::metadata(runtime.parent().unwrap())?
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(fs::metadata(&runtime)?.permissions().mode() & 0o777, 0o555);
        assert_eq!(
            fs::metadata(runtime.with_file_name("manifest.json"))?
                .permissions()
                .mode()
                & 0o777,
            0o444
        );
        Ok(())
    }

    #[test]
    fn macos_activation_rejects_guessed_or_linked_generation_paths() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let guessed = data_dir
            .join("prepared-codex")
            .join(TEST_VERSION)
            .join("codex");
        fs::copy(&runtime, &guessed)?;
        set_executable(&guessed)?;
        assert!(
            validate_macos_prepared_generation_path(&data_dir, &guessed, TEST_VERSION).is_err()
        );

        let linked_attempt = data_dir
            .join("prepared-codex")
            .join(TEST_VERSION)
            .join("fedcba9876543210fedcba9876543210");
        std::os::unix::fs::symlink(runtime.parent().unwrap(), &linked_attempt)?;
        let linked_runtime = linked_attempt.join("codex");
        assert!(
            validate_macos_prepared_generation_path(&data_dir, &linked_runtime, TEST_VERSION)
                .is_err()
        );
        Ok(())
    }

    #[test]
    fn macos_prejournal_staging_failure_removes_transaction_temps() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let transaction_id = "abcdefabcdefabcdefabcdefabcdefab";

        for (destination, result) in [
            {
                let destination = root.join("launcher-destination");
                fs::create_dir_all(&destination)?;
                let result = stage_macos_launcher(&destination, "#!/bin/sh\n", transaction_id);
                (destination, result)
            },
            {
                let destination = root.join("control-destination");
                fs::create_dir_all(&destination)?;
                let result = stage_macos_executable(
                    &runtime.with_file_name("codexswitch-cli"),
                    &destination,
                    transaction_id,
                );
                (destination, result)
            },
        ] {
            assert!(result.is_err());
            let name = destination.file_name().unwrap().to_string_lossy();
            let staged = root.join(format!(".{name}.codexswitch-new-{transaction_id}"));
            assert!(!path_exists_without_following(&staged)?);
        }
        Ok(())
    }

    #[test]
    fn first_install_recovery_restores_absence_at_every_uncommitted_prefix() -> Result<()> {
        let cases = [
            (0, MacOsActivationPhase::Prepared),
            (1, MacOsActivationPhase::Prepared),
            (2, MacOsActivationPhase::Prepared),
            (3, MacOsActivationPhase::Prepared),
            (4, MacOsActivationPhase::Prepared),
            (4, MacOsActivationPhase::LaunchersPublished),
            (4, MacOsActivationPhase::ReadbackVerified),
        ];
        for (published_count, phase) in cases {
            let temp = tempfile::tempdir()?;
            let root = fs::canonicalize(temp.path())?;
            let data_dir = root.join("data");
            let runtime = write_fake_runtime(&data_dir)?;
            let state_path = data_dir.join("codex-cli-update.json");
            let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
            let transaction_id = "abcdefabcdefabcdefabcdefabcdefab";
            let (mut journal, managed, user, homebrew) =
                staged_first_install_journal(&root, &runtime, transaction_id)?;
            for launcher in &journal.launchers {
                create_macos_launcher_backup(launcher)?;
            }
            let mut state = ready_state(&runtime);
            state.status = UpdateStatus::Installing;
            state.install_transaction = Some(InstallTransactionState {
                id: transaction_id.to_string(),
                version: TEST_VERSION.to_string(),
                phase: InstallTransactionStatePhase::Interruptible,
            });
            save_state_at(&state_path, &state)?;
            for launcher in journal.launchers.iter().take(published_count) {
                publish_macos_launcher(launcher)?;
            }
            journal.published_count = published_count;
            journal.phase = phase;
            write_macos_activation_journal(&journal_path, &journal)?;

            let outcome = recover_macos_activation_at(
                &journal_path,
                &state_path,
                &mut state,
                &data_dir,
                &managed,
                &user,
                &homebrew,
            )?;

            assert_eq!(outcome, MacOsActivationRecoveryOutcome::RolledBack);
            let control_cli = user.with_file_name("codexswitch-cli");
            for path in [&managed, &control_cli, &user, &homebrew] {
                assert!(
                    !path_exists_without_following(path)?,
                    "first-install prefix {published_count}/{phase:?} left {}",
                    path.display()
                );
            }
            assert!(!journal_path.exists());
            let recovered = load_state_at(&state_path)?;
            assert_eq!(recovered.status, UpdateStatus::ReadyToInstall);
            assert!(recovered.installed_version.is_none());
            assert!(recovered.install_transaction.is_none());
        }
        Ok(())
    }

    #[test]
    fn first_install_recovery_finishes_only_after_state_commit() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
        let transaction_id = "abcdefabcdefabcdefabcdefabcdefab";
        let (mut journal, managed, user, homebrew) =
            staged_first_install_journal(&root, &runtime, transaction_id)?;
        for launcher in &journal.launchers {
            create_macos_launcher_backup(launcher)?;
            publish_macos_launcher(launcher)?;
        }
        journal.published_count = journal.launchers.len();
        journal.phase = MacOsActivationPhase::ReadbackVerified;
        write_macos_activation_journal(&journal_path, &journal)?;
        let mut state = ready_state(&runtime);
        state.status = UpdateStatus::Installing;
        state.install_transaction = Some(InstallTransactionState {
            id: transaction_id.to_string(),
            version: TEST_VERSION.to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });
        mark_version_installed_for_transaction(
            &mut state,
            TEST_VERSION,
            transaction_id,
            Utc::now(),
        );
        save_state_at(&state_path, &state)?;

        let outcome = recover_macos_activation_at(
            &journal_path,
            &state_path,
            &mut state,
            &data_dir,
            &managed,
            &user,
            &homebrew,
        )?;

        assert_eq!(outcome, MacOsActivationRecoveryOutcome::Committed);
        assert_eq!(patched_codex::resolve_installed_runtime(&managed)?, runtime);
        assert!(user.exists());
        assert!(homebrew.exists());
        assert!(!journal_path.exists());
        let recovered = load_state_at(&state_path)?;
        assert_eq!(recovered.status, UpdateStatus::Installed);
        assert_eq!(recovered.installed_version.as_deref(), Some(TEST_VERSION));
        assert_eq!(
            recovered.installed_artifact_manifest_sha256.as_deref(),
            Some(journal.manifest_file.sha256.as_str())
        );
        assert!(recovered.install_transaction.is_none());
        Ok(())
    }

    #[test]
    fn interrupted_uncommitted_launcher_publication_rolls_back_exactly() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        let data_dir = root.join("data");
        let runtime = write_fake_runtime(&data_dir)?;
        let helper = runtime.with_file_name("codex-code-mode-host");
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(MACOS_LAUNCHER_INSTALL_JOURNAL);
        let (managed, user, homebrew) = activation_paths(&root);
        let control_cli_destination = user.with_file_name("codexswitch-cli");
        for (path, value) in [
            (&managed, "old-managed\n"),
            (&user, "old-user\n"),
            (&homebrew, "old-homebrew\n"),
            (&control_cli_destination, "old-control\n"),
        ] {
            fs::create_dir_all(path.parent().unwrap())?;
            fs::write(path, value)?;
            set_executable(path)?;
        }
        let transaction_id = "abcdefabcdefabcdefabcdefabcdefab";
        let managed_contents = patched_codex::launcher_script_for_runtime(&runtime)?;
        let bridge = patched_codex::bridge_script_for_managed_launcher(&managed)?;
        let launchers = vec![
            stage_macos_launcher(&managed, &managed_contents, transaction_id)?,
            stage_macos_executable(
                &runtime.with_file_name("codexswitch-cli"),
                &control_cli_destination,
                transaction_id,
            )?,
            stage_macos_launcher(&user, &bridge, transaction_id)?,
            stage_macos_launcher(&homebrew, &bridge, transaction_id)?,
        ];
        let (_, artifact_manifest, manifest_file) =
            validate_macos_runtime_artifact(runtime.parent().unwrap())?;
        let mut journal = MacOsActivationJournal {
            format: MACOS_LAUNCHER_JOURNAL_FORMAT.to_string(),
            transaction_id: transaction_id.to_string(),
            version: TEST_VERSION.to_string(),
            previous_installed_version: Some("0.144.1".to_string()),
            phase: MacOsActivationPhase::Prepared,
            published_count: 0,
            runtime: runtime_file_identity(&runtime)?,
            helper: runtime_file_identity(&helper)?,
            control_cli: runtime_file_identity(&runtime.with_file_name("codexswitch-cli"))?,
            manifest_file,
            artifact_manifest,
            launchers,
        };
        write_macos_activation_journal(&journal_path, &journal)?;
        for launcher in &journal.launchers {
            create_macos_launcher_backup(launcher)?;
        }
        let mut state = ready_state(&runtime);
        state.status = UpdateStatus::Installing;
        state.install_transaction = Some(InstallTransactionState {
            id: transaction_id.to_string(),
            version: TEST_VERSION.to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });
        save_state_at(&state_path, &state)?;
        publish_macos_launcher(&journal.launchers[0])?;
        publish_macos_launcher(&journal.launchers[1])?;
        journal.published_count = 2;
        write_macos_activation_journal(&journal_path, &journal)?;

        let outcome = recover_macos_activation_at(
            &journal_path,
            &state_path,
            &mut state,
            &data_dir,
            &managed,
            &user,
            &homebrew,
        )?;

        assert_eq!(outcome, MacOsActivationRecoveryOutcome::RolledBack);
        assert_eq!(fs::read_to_string(&managed)?, "old-managed\n");
        assert_eq!(fs::read_to_string(&user)?, "old-user\n");
        assert_eq!(fs::read_to_string(&homebrew)?, "old-homebrew\n");
        assert_eq!(
            fs::read_to_string(&control_cli_destination)?,
            "old-control\n"
        );
        assert!(!journal_path.exists());
        let recovered = load_state_at(&state_path)?;
        assert_eq!(recovered.status, UpdateStatus::ReadyToInstall);
        assert_eq!(recovered.installed_version.as_deref(), Some("0.144.1"));
        assert!(recovered.install_transaction.is_none());
        Ok(())
    }
}
