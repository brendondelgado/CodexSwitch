fn stage_prepared_runtime(built_binary: &Path, prepared_dir: &Path) -> Result<PathBuf> {
    let built_code_mode_host = built_binary.with_file_name("codex-code-mode-host");
    if !built_code_mode_host.is_file() {
        bail!(
            "built Codex runtime is missing codex-code-mode-host: {}",
            built_code_mode_host.display()
        );
    }

    with_new_prepared_generation(prepared_dir, |generation_dir| {
        let prepared_binary = generation_dir.join("codex");
        let prepared_code_mode_host = generation_dir.join("codex-code-mode-host");
        for (source, destination) in [
            (built_binary, prepared_binary.as_path()),
            (
                built_code_mode_host.as_path(),
                prepared_code_mode_host.as_path(),
            ),
        ] {
            fs::copy(source, destination).with_context(|| {
                format!(
                    "failed to stage {} at {}",
                    source.display(),
                    destination.display()
                )
            })?;
            set_executable(destination)?;
            ad_hoc_sign_copied_macos_binary(destination)?;
        }
        Ok(prepared_binary)
    })
}

fn stage_and_validate_prepared_runtime(
    built_binary: &Path,
    prepared_dir: &Path,
    expected_version: &str,
) -> Result<PathBuf> {
    let prepared_binary = stage_prepared_runtime(built_binary, prepared_dir)?;
    let validation = validate_prepared_runtime(&prepared_binary, expected_version);
    if let Err(error) = validation {
        return match remove_updater_path(prepared_dir, "failed prepared Codex generation") {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(error).with_context(|| {
                format!(
                    "also failed to clean prepared generation after validation failure: {cleanup_error:#}"
                )
            }),
        };
    }
    Ok(prepared_binary)
}

fn with_new_prepared_generation<T>(
    prepared_dir: &Path,
    operation: impl FnOnce(&Path) -> Result<T>,
) -> Result<T> {
    let prepared_parent = prepared_dir
        .parent()
        .context("prepared generation directory has no parent")?;
    fs::create_dir_all(prepared_parent)?;
    fs::create_dir(prepared_dir).with_context(|| {
        format!(
            "refusing to reuse prepared Codex generation {}",
            prepared_dir.display()
        )
    })?;

    match operation(prepared_dir) {
        Ok(value) => Ok(value),
        Err(error) => {
            match remove_updater_path(prepared_dir, "partial prepared Codex generation") {
                Ok(()) => Err(error),
                Err(cleanup_error) => Err(error).with_context(|| {
                    format!("also failed to clean partial prepared generation: {cleanup_error:#}")
                }),
            }
        }
    }
}

fn validate_prepared_runtime(prepared_binary: &Path, expected_version: &str) -> Result<()> {
    if !patched_codex::binary_has_hot_swap_markers(prepared_binary) {
        bail!(
            "staged Codex binary is missing hot-swap markers: {}",
            prepared_binary.display()
        );
    }
    patched_codex::validate_code_mode_host_for_runtime(prepared_binary)?;
    let prepared_version =
        patched_codex::codex_version(prepared_binary).context("staged Codex has no version")?;
    if prepared_version != expected_version {
        bail!("staged Codex version {prepared_version} did not match expected {expected_version}");
    }
    Ok(())
}

fn verify_installed_runtime_pair(
    runtime: &Path,
    helper: &Path,
    expected_version: &str,
) -> Result<()> {
    if helper != runtime.with_file_name("codex-code-mode-host") {
        bail!("installed helper path is not paired with the runtime");
    }
    validate_prepared_runtime(runtime, expected_version)
        .context("installed runtime/helper readback failed")
}

fn prepared_generation_dir(data_dir: &Path, version: &str, attempt_id: &str) -> PathBuf {
    data_dir
        .join("prepared-codex")
        .join(version)
        .join(attempt_id)
}

fn new_prepared_generation_dir(data_dir: &Path, version: &str) -> PathBuf {
    prepared_generation_dir(
        data_dir,
        version,
        &uuid::Uuid::new_v4().simple().to_string(),
    )
}

#[derive(Debug)]
struct BuildTargetCleanupOutcome<T> {
    value: T,
    cleanup_warning: Option<anyhow::Error>,
}

fn combine_operation_and_cleanup_results<T>(
    operation_result: Result<T>,
    cleanup_result: Result<()>,
) -> Result<BuildTargetCleanupOutcome<T>> {
    match (operation_result, cleanup_result) {
        (Ok(value), Ok(())) => Ok(BuildTargetCleanupOutcome {
            value,
            cleanup_warning: None,
        }),
        (Ok(value), Err(cleanup_error)) => Ok(BuildTargetCleanupOutcome {
            value,
            cleanup_warning: Some(cleanup_error),
        }),
        (Err(error), Ok(())) => Err(error),
        (Err(error), Err(cleanup_error)) => Err(error).with_context(|| {
            format!(
                "also failed to clean updater build target after preparation failure: {cleanup_error:#}"
            )
        }),
    }
}

fn run_with_build_target_cleanup<T>(
    workspace: &Path,
    operation: impl FnOnce() -> Result<T>,
) -> Result<BuildTargetCleanupOutcome<T>> {
    let operation_result = operation();
    let cleanup_result = clean_build_target(workspace);
    combine_operation_and_cleanup_results(operation_result, cleanup_result)
}

fn clean_build_target(workspace: &Path) -> Result<()> {
    let target = workspace.join("target");
    remove_updater_path(&target, "build target")
}

fn remove_updater_path(path: &Path, description: &str) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect {description} {}", path.display()))
        }
    };

    if metadata.file_type().is_symlink() {
        return fs::remove_file(path)
            .or_else(|file_error| {
                fs::remove_dir(path).map_err(|directory_error| {
                    std::io::Error::new(
                        directory_error.kind(),
                        format!(
                            "remove_file failed with {file_error}; remove_dir failed with {directory_error}"
                        ),
                    )
                })
            })
            .with_context(|| {
                format!("failed to remove {description} symlink {}", path.display())
            });
    }

    if metadata.is_dir() {
        remove_directory_idempotently_with(
            || fs::remove_dir_all(path),
            || std::thread::sleep(Duration::from_millis(25)),
        )
        .with_context(|| format!("failed to remove {description} {}", path.display()))
    } else {
        fs::remove_file(path)
            .with_context(|| format!("failed to remove {description} {}", path.display()))
    }
}

fn remove_directory_idempotently_with<Remove, Pause>(
    mut remove: Remove,
    mut pause: Pause,
) -> std::io::Result<()>
where
    Remove: FnMut() -> std::io::Result<()>,
    Pause: FnMut(),
{
    for attempt in 0..BUILD_TARGET_CLEANUP_ATTEMPTS {
        match remove() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error)
                if error.kind() == std::io::ErrorKind::DirectoryNotEmpty
                    && attempt + 1 < BUILD_TARGET_CLEANUP_ATTEMPTS =>
            {
                pause();
            }
            Err(error) => return Err(error),
        }
    }
    Err(std::io::Error::other(
        "bounded directory cleanup exhausted without a result",
    ))
}

fn remove_owned_updater_path(path: &Path, data_dir: &Path, description: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect {description} {}", path.display()))
        }
    }

    let canonical_root = fs::canonicalize(data_dir)
        .with_context(|| format!("failed to resolve updater root {}", data_dir.display()))?;
    let parent = path
        .parent()
        .context("updater cleanup path has no parent")?;
    let canonical_parent = fs::canonicalize(parent)
        .with_context(|| format!("failed to resolve cleanup parent {}", parent.display()))?;
    if !canonical_parent.starts_with(&canonical_root) {
        bail!(
            "refusing to remove {description} outside updater root: {}",
            path.display()
        );
    }
    remove_updater_path(path, description)
}

fn cleanup_prepared_generation(state: &CodexUpdateState) -> Result<()> {
    cleanup_prepared_generation_at(state, &codexswitch_data_dir()?)
}

fn cleanup_prepared_generation_at(state: &CodexUpdateState, data_dir: &Path) -> Result<()> {
    let Some(generation) = prepared_generation_for_state_at(state, data_dir)? else {
        return Ok(());
    };
    remove_owned_updater_path(&generation, data_dir, "prepared Codex generation")
}

fn prepared_generation_for_state_at(
    state: &CodexUpdateState,
    data_dir: &Path,
) -> Result<Option<PathBuf>> {
    let Some(version) = state.prepared_version.as_deref() else {
        return Ok(None);
    };
    let Some(binary_path) = state.prepared_binary_path.as_deref() else {
        return Ok(None);
    };
    let binary = Path::new(binary_path);
    let generation = binary
        .parent()
        .context("prepared binary has no generation directory")?;
    let expected_version_dir = data_dir.join("prepared-codex").join(version);
    if binary.file_name().and_then(|name| name.to_str()) != Some("codex") {
        bail!("unexpected prepared runtime path {}", binary.display());
    }
    if generation == expected_version_dir {
        return Ok(None);
    }
    if generation.parent() != Some(expected_version_dir.as_path()) {
        bail!(
            "refusing to clean non-generation prepared runtime {}",
            binary.display()
        );
    }
    Ok(Some(generation.to_path_buf()))
}

fn recorded_build_target_at(
    state: &CodexUpdateState,
    data_dir: &Path,
    version: &str,
) -> Result<Option<PathBuf>> {
    let Some(source_path) = state.prepared_source_path.as_deref() else {
        return Ok(None);
    };
    let source = PathBuf::from(source_path);
    let expected_source = data_dir.join(format!("codex-source-stable-{version}"));
    if source != expected_source {
        bail!(
            "refusing to clean unexpected updater source {}",
            source.display()
        );
    }
    Ok(Some(source.join("codex-rs/target")))
}

fn cleanup_pending_target_at(state: &mut CodexUpdateState, data_dir: &Path) -> Result<bool> {
    let Some(target_path) = state.cleanup_pending_target_path.clone() else {
        return Ok(false);
    };
    let target = PathBuf::from(&target_path);
    let source = target
        .parent()
        .and_then(Path::parent)
        .context("pending cleanup target has no source directory")?;
    if target.file_name().and_then(|name| name.to_str()) != Some("target")
        || target
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            != Some("codex-rs")
        || source.parent() != Some(data_dir)
        || !source
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("codex-source-stable-"))
    {
        bail!(
            "refusing unexpected pending cleanup path {}",
            target.display()
        );
    }
    remove_owned_updater_path(&target, data_dir, "pending updater build target")?;
    state.cleanup_pending_target_path = None;
    Ok(true)
}

fn cleanup_stale_preparation_artifacts(
    state: &mut CodexUpdateState,
    now: DateTime<Utc>,
) -> Result<bool> {
    cleanup_stale_preparation_artifacts_at(state, now, &codexswitch_data_dir()?)
}

fn cleanup_stale_preparation_artifacts_at(
    state: &mut CodexUpdateState,
    now: DateTime<Utc>,
    data_dir: &Path,
) -> Result<bool> {
    if state.status != UpdateStatus::Preparing
        || now.signed_duration_since(state.updated_at)
            < ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS)
    {
        return Ok(false);
    }

    let version = state
        .prepared_version
        .clone()
        .or_else(|| state.latest_stable_version.clone())
        .context("stale preparation has no version")?;
    let reusable_generation = state.prepared_version.as_deref() == Some(version.as_str())
        && state
            .prepared_binary_path
            .as_deref()
            .map(Path::new)
            .is_some_and(|path| prepared_runtime_is_valid(path, &version));
    let target = recorded_build_target_at(state, data_dir, &version)?;
    let target_cleanup = target.as_ref().map_or(Ok(()), |target| {
        remove_owned_updater_path(target, data_dir, "stale updater build target")
    });

    if reusable_generation {
        state.status = UpdateStatus::ReadyToInstall;
        clear_prepare_failure(state);
        match target_cleanup {
            Ok(()) => {
                state.cleanup_pending_target_path = None;
                state.error = None;
            }
            Err(error) => {
                state.cleanup_pending_target_path =
                    target.as_ref().map(|target| target.display().to_string());
                state.error = Some(format!(
                    "Codex {version} recovered ready to install, but its build target cleanup is pending: {error:#}"
                ));
            }
        }
        state.updated_at = now;
        return Ok(true);
    }

    target_cleanup?;
    cleanup_prepared_generation_at(state, data_dir)?;

    clear_prepared_state(state);
    state.status = UpdateStatus::Failed;
    state.failed_prepare_version = Some(version.clone());
    state.prepare_retry_not_before = Some(now);
    state.error = Some(format!(
        "cleaned interrupted preparation of Codex {version}; preparation may retry"
    ));
    state.updated_at = now;
    record_unresolved_failure(
        state,
        UpdateFailureKind::Preparation,
        now,
        Some(version),
        None,
    );
    Ok(true)
}

#[cfg(target_os = "macos")]
fn ad_hoc_sign_copied_macos_binary(path: &Path) -> Result<()> {
    if !is_macho_binary(path)? {
        return Ok(());
    }

    let status = bounded_command::status(
        Command::new("/usr/bin/codesign")
            .args(["--force", "--sign", "-"])
            .arg(path),
        PROBE_COMMAND_TIMEOUT,
    )
    .with_context(|| format!("failed to ad-hoc sign staged Mach-O {}", path.display()))?;
    if !status.success() {
        bail!(
            "failed to ad-hoc sign staged Mach-O {}: {status}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn ad_hoc_sign_copied_macos_binary(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn is_macho_binary(path: &Path) -> Result<bool> {
    use std::io::Read;

    let mut file = fs::File::open(path)?;
    let mut magic = [0_u8; 4];
    if file.read_exact(&mut magic).is_err() {
        return Ok(false);
    }
    Ok(matches!(
        magic,
        [0xcf, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xcf]
            | [0xce, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xce]
            | [0xca, 0xfe, 0xba, 0xbe]
            | [0xbe, 0xba, 0xfe, 0xca]
            | [0xca, 0xfe, 0xba, 0xbf]
            | [0xbf, 0xba, 0xfe, 0xca]
    ))
}

#[cfg(test)]
fn runtime_has_code_mode_host(codex_binary: &Path) -> bool {
    codex_binary
        .with_file_name("codex-code-mode-host")
        .is_file()
}

fn prepared_runtime_is_valid(codex_binary: &Path, expected_version: &str) -> bool {
    validate_prepared_runtime(codex_binary, expected_version).is_ok()
}

fn runtime_matches_prepared_runtime(installed: &Path, prepared: &Path) -> bool {
    files_equal(installed, prepared)
        && files_equal(
            &installed.with_file_name("codex-code-mode-host"),
            &prepared.with_file_name("codex-code-mode-host"),
        )
}

fn files_equal(left: &Path, right: &Path) -> bool {
    if fs::canonicalize(left).ok() == fs::canonicalize(right).ok() && fs::canonicalize(left).is_ok()
    {
        return true;
    }
    let Ok(left_metadata) = fs::metadata(left) else {
        return false;
    };
    let Ok(right_metadata) = fs::metadata(right) else {
        return false;
    };
    if left_metadata.len() != right_metadata.len() {
        return false;
    }
    let Ok(left_file) = fs::File::open(left) else {
        return false;
    };
    let Ok(right_file) = fs::File::open(right) else {
        return false;
    };
    let mut left_reader = BufReader::with_capacity(1024 * 1024, left_file);
    let mut right_reader = BufReader::with_capacity(1024 * 1024, right_file);
    let mut left_buffer = vec![0_u8; 1024 * 1024];
    let mut right_buffer = vec![0_u8; 1024 * 1024];
    loop {
        let Ok(left_read) = left_reader.read(&mut left_buffer) else {
            return false;
        };
        let Ok(right_read) = right_reader.read(&mut right_buffer) else {
            return false;
        };
        if left_read != right_read || left_buffer[..left_read] != right_buffer[..right_read] {
            return false;
        }
        if left_read == 0 {
            return true;
        }
    }
}
