#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AdvisoryLockMode {
    #[cfg(test)]
    Shared,
    Exclusive,
}

struct AdvisoryFileLock {
    file: fs::File,
}

impl AdvisoryFileLock {
    fn try_acquire_at(path: &Path, mode: AdvisoryLockMode) -> Result<Option<Self>> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .with_context(|| format!("failed to open runtime guard {}", path.display()))?;
        use std::os::fd::AsRawFd;
        let operation = match mode {
            #[cfg(test)]
            AdvisoryLockMode::Shared => libc::LOCK_SH,
            AdvisoryLockMode::Exclusive => libc::LOCK_EX,
        } | libc::LOCK_NB;
        let result = unsafe { libc::flock(file.as_raw_fd(), operation) };
        if result == 0 {
            return Ok(Some(Self { file }));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::WouldBlock {
            return Ok(None);
        }
        Err(error).with_context(|| format!("failed to acquire runtime guard {}", path.display()))
    }
}

impl Drop for AdvisoryFileLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

struct RuntimeCommitGuards {
    _start_install: AdvisoryFileLock,
    _daemon_reservation: AdvisoryFileLock,
}

enum GuardAcquire<G> {
    Acquired(G),
    Blocked(String),
}

struct StagedLinuxRuntimeInstall {
    transaction_id: String,
    runtime_temp: PathBuf,
    runtime_destination: PathBuf,
    runtime_backup: PathBuf,
    helper_temp: PathBuf,
    helper_destination: PathBuf,
    helper_backup: PathBuf,
    retained_for_recovery: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct RuntimeFileIdentity {
    path: String,
    canonical_path: String,
    bytes: u64,
    sha256: String,
    device: u64,
    inode: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct RuntimeInstallFileJournal {
    destination: String,
    staged: String,
    backup: String,
    old: Option<RuntimeFileIdentity>,
    new: RuntimeFileIdentity,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
enum RuntimeInstallJournalPhase {
    Prepared,
    HelperRenamed,
    RuntimeRenamed,
    RuntimeDirectorySynced,
    ReadbackVerified,
    StateSaved,
    CleanupComplete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct RuntimeInstallJournal {
    format: String,
    transaction_id: String,
    version: String,
    phase: RuntimeInstallJournalPhase,
    runtime: RuntimeInstallFileJournal,
    helper: RuntimeInstallFileJournal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeInstallFaultPoint {
    AfterHelperRename,
    AfterRuntimeRename,
    AfterRuntimeDirectorySync,
    AfterReadback,
    AfterStateSave,
    AfterCleanup,
    AfterStateFinalized,
}

impl UpdaterOperationLock {
    fn try_acquire() -> Result<Option<Self>> {
        Self::try_acquire_at(&codexswitch_data_dir()?.join("codex-update.lock"))
    }

    fn try_acquire_at(path: &Path) -> Result<Option<Self>> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            use std::os::unix::fs::OpenOptionsExt;

            let file = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .mode(0o600)
                .open(path)
                .with_context(|| format!("failed to open updater lock {}", path.display()))?;
            let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if result == 0 {
                return Ok(Some(Self { file }));
            }

            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                return Ok(None);
            }
            Err(error).with_context(|| format!("failed to acquire updater lock {}", path.display()))
        }

        #[cfg(not(unix))]
        {
            let directory = path.with_extension("lock-directory");
            match fs::create_dir(&directory) {
                Ok(()) => Ok(Some(Self { directory })),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(None),
                Err(error) => Err(error).with_context(|| {
                    format!("failed to acquire updater lock {}", directory.display())
                }),
            }
        }
    }
}

impl Drop for UpdaterOperationLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;

            unsafe {
                libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            }
        }

        #[cfg(not(unix))]
        {
            let _ = fs::remove_dir(&self.directory);
        }
    }
}

impl RuntimeCommitGuards {
    fn try_acquire_at(
        start_install_path: &Path,
        daemon_reservation_path: &Path,
    ) -> GuardAcquire<Self> {
        let start_install = match AdvisoryFileLock::try_acquire_at(
            start_install_path,
            AdvisoryLockMode::Exclusive,
        ) {
            Ok(Some(lock)) => lock,
            Ok(None) => {
                return GuardAcquire::Blocked(format!(
                    "runtime start/install guard {} is held by a starting or active managed service",
                    start_install_path.display()
                ));
            }
            Err(error) => {
                return GuardAcquire::Blocked(format!(
                    "runtime start/install guard {} could not be acquired ({error:#})",
                    start_install_path.display()
                ));
            }
        };
        let daemon_reservation = match AdvisoryFileLock::try_acquire_at(
            daemon_reservation_path,
            AdvisoryLockMode::Exclusive,
        ) {
            Ok(Some(lock)) => lock,
            Ok(None) => {
                return GuardAcquire::Blocked(format!(
                    "managed daemon reservation {} is held by a starting or active daemon",
                    daemon_reservation_path.display()
                ));
            }
            Err(error) => {
                return GuardAcquire::Blocked(format!(
                    "managed daemon reservation {} could not be acquired ({error:#})",
                    daemon_reservation_path.display()
                ));
            }
        };
        GuardAcquire::Acquired(Self {
            _start_install: start_install,
            _daemon_reservation: daemon_reservation,
        })
    }
}

impl StagedLinuxRuntimeInstall {
    fn prepare(prepared_binary: &Path, installed_binary: &Path) -> Result<Self> {
        let transaction_id = uuid::Uuid::new_v4().simple().to_string();
        let prepared_helper = prepared_binary.with_file_name("codex-code-mode-host");
        let helper_destination = installed_binary.with_file_name("codex-code-mode-host");
        let runtime_temp = stage_install_file(prepared_binary, installed_binary, &transaction_id)?;
        let helper_temp =
            match stage_install_file(&prepared_helper, &helper_destination, &transaction_id) {
                Ok(path) => path,
                Err(error) => {
                    let _ = fs::remove_file(&runtime_temp);
                    return Err(error);
                }
            };
        let parent = installed_binary
            .parent()
            .context("installed runtime has no parent directory")?;
        Ok(Self {
            transaction_id: transaction_id.clone(),
            runtime_temp,
            runtime_destination: installed_binary.to_path_buf(),
            runtime_backup: parent.join(format!(".codex.runtime-backup-{transaction_id}")),
            helper_temp,
            helper_destination,
            helper_backup: parent.join(format!(".codex.helper-backup-{transaction_id}")),
            retained_for_recovery: false,
        })
    }

    fn commit_journaled_with<Verify, Fault>(
        mut self,
        journal_path: &Path,
        state_path: &Path,
        state: &mut CodexUpdateState,
        expected_version: &str,
        verify: Verify,
        mut fault: Fault,
    ) -> Result<()>
    where
        Verify: Fn(&Path, &Path, &str) -> Result<()>,
        Fault: FnMut(RuntimeInstallFaultPoint) -> Result<()>,
    {
        if fs::symlink_metadata(journal_path).is_ok() {
            bail!(
                "an interrupted runtime install journal already exists at {}",
                journal_path.display()
            );
        }
        let mut journal = RuntimeInstallJournal {
            format: "codexswitch-runtime-install-v1".to_string(),
            transaction_id: self.transaction_id.clone(),
            version: expected_version.to_string(),
            phase: RuntimeInstallJournalPhase::Prepared,
            runtime: self.file_journal(
                &self.runtime_temp,
                &self.runtime_destination,
                &self.runtime_backup,
            )?,
            helper: self.file_journal(
                &self.helper_temp,
                &self.helper_destination,
                &self.helper_backup,
            )?,
        };
        write_runtime_install_journal(journal_path, &journal)?;
        self.retained_for_recovery = true;

        create_runtime_backup(&journal.helper)?;
        create_runtime_backup(&journal.runtime)?;
        sync_parent_directory(&self.runtime_destination)?;

        state.install_transaction = Some(InstallTransactionState {
            id: self.transaction_id.clone(),
            version: expected_version.to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });
        // The interruption record is durable before the transient Installing
        // state can be observed after a crash.
        save_state_at(state_path, state)?;
        state.status = UpdateStatus::Installing;
        state.updated_at = Utc::now();
        save_state_at(state_path, state)?;

        fs::rename(&self.helper_temp, &self.helper_destination).with_context(|| {
            format!(
                "failed to atomically replace {}",
                self.helper_destination.display()
            )
        })?;
        self.helper_temp = PathBuf::new();
        journal.phase = RuntimeInstallJournalPhase::HelperRenamed;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterHelperRename)?;

        fs::rename(&self.runtime_temp, &self.runtime_destination).with_context(|| {
            format!(
                "failed to atomically replace {}",
                self.runtime_destination.display()
            )
        })?;
        self.runtime_temp = PathBuf::new();
        journal.phase = RuntimeInstallJournalPhase::RuntimeRenamed;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterRuntimeRename)?;

        sync_parent_directory(&self.runtime_destination)?;
        journal.phase = RuntimeInstallJournalPhase::RuntimeDirectorySynced;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterRuntimeDirectorySync)?;

        verify_runtime_install_readback(
            &journal,
            &self.runtime_destination,
            &self.helper_destination,
        )?;
        verify(
            &self.runtime_destination,
            &self.helper_destination,
            expected_version,
        )?;
        journal.phase = RuntimeInstallJournalPhase::ReadbackVerified;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterReadback)?;

        mark_version_installed_for_transaction(
            state,
            expected_version,
            &self.transaction_id,
            Utc::now(),
        );
        save_state_at(state_path, state)?;
        journal.phase = RuntimeInstallJournalPhase::StateSaved;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterStateSave)?;

        cleanup_runtime_install_files(&journal)?;
        sync_parent_directory(&self.runtime_destination)?;
        journal.phase = RuntimeInstallJournalPhase::CleanupComplete;
        write_runtime_install_journal(journal_path, &journal)?;
        fault(RuntimeInstallFaultPoint::AfterCleanup)?;

        state.install_transaction = None;
        save_state_at(state_path, state)?;
        fault(RuntimeInstallFaultPoint::AfterStateFinalized)?;
        remove_runtime_install_journal(journal_path)?;
        self.retained_for_recovery = false;
        Ok(())
    }

    fn file_journal(
        &self,
        staged: &Path,
        destination: &Path,
        backup: &Path,
    ) -> Result<RuntimeInstallFileJournal> {
        Ok(RuntimeInstallFileJournal {
            destination: destination.display().to_string(),
            staged: staged.display().to_string(),
            backup: backup.display().to_string(),
            old: runtime_file_identity_if_present(destination)?,
            new: runtime_file_identity(staged)?,
        })
    }
}

impl Drop for StagedLinuxRuntimeInstall {
    fn drop(&mut self) {
        if self.retained_for_recovery {
            return;
        }
        if !self.runtime_temp.as_os_str().is_empty() {
            let _ = fs::remove_file(&self.runtime_temp);
        }
        if !self.helper_temp.as_os_str().is_empty() {
            let _ = fs::remove_file(&self.helper_temp);
        }
    }
}

fn stage_install_file(source: &Path, destination: &Path, transaction_id: &str) -> Result<PathBuf> {
    if !source.is_file() {
        bail!("staged install source is missing: {}", source.display());
    }
    let parent = destination
        .parent()
        .with_context(|| format!("{} has no parent directory", destination.display()))?;
    fs::create_dir_all(parent)?;
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("codex");
    let temp = parent.join(format!(
        ".{name}.codexswitch-install-{}-{transaction_id}",
        std::process::id(),
    ));
    let result = (|| -> Result<()> {
        fs::copy(source, &temp).with_context(|| {
            format!(
                "failed to pre-stage {} as {}",
                source.display(),
                temp.display()
            )
        })?;
        set_executable(&temp)?;
        fs::File::open(&temp)
            .and_then(|file| file.sync_all())
            .with_context(|| format!("failed to sync pre-staged runtime {}", temp.display()))?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    Ok(temp)
}

fn runtime_file_identity_if_present(path: &Path) -> Result<Option<RuntimeFileIdentity>> {
    match fs::symlink_metadata(path) {
        Ok(_) => runtime_file_identity(path).map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("failed to inspect runtime file {}", path.display()))
        }
    }
}

fn runtime_file_identity(path: &Path) -> Result<RuntimeFileIdentity> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect runtime file {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!(
            "runtime transaction file must be a regular non-symlink file: {}",
            path.display()
        );
    }
    let canonical_path = fs::canonicalize(path)
        .with_context(|| format!("failed to resolve runtime file {}", path.display()))?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open runtime file {}", path.display()))?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
        || opened.mode() != metadata.mode()
    {
        bail!(
            "runtime file changed identity while opened: {}",
            path.display()
        );
    }
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = reader
            .read(&mut buffer)
            .with_context(|| format!("failed to hash runtime file {}", path.display()))?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    let sha256 = digest
        .finish()
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(RuntimeFileIdentity {
        path: path.display().to_string(),
        canonical_path: canonical_path.display().to_string(),
        bytes: metadata.len(),
        sha256,
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn runtime_identity_matches(path: &Path, expected: &RuntimeFileIdentity) -> Result<bool> {
    let Some(observed) = runtime_file_identity_if_present(path)? else {
        return Ok(false);
    };
    Ok(observed.bytes == expected.bytes
        && observed.sha256 == expected.sha256
        && observed.device == expected.device
        && observed.inode == expected.inode)
}

fn create_runtime_backup(file: &RuntimeInstallFileJournal) -> Result<()> {
    let Some(old) = file.old.as_ref() else {
        return Ok(());
    };
    let destination = Path::new(&file.destination);
    let backup = Path::new(&file.backup);
    if !runtime_identity_matches(destination, old)? {
        bail!(
            "runtime destination changed before backup: {}",
            destination.display()
        );
    }
    match fs::symlink_metadata(backup) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Ok(_) => bail!("runtime backup already exists: {}", backup.display()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect runtime backup {}", backup.display()));
        }
    }
    fs::hard_link(destination, backup).with_context(|| {
        format!(
            "failed to anchor runtime backup {} as {}",
            destination.display(),
            backup.display()
        )
    })?;
    if !runtime_identity_matches(backup, old)? {
        bail!("runtime backup readback failed: {}", backup.display());
    }
    Ok(())
}

fn verify_runtime_install_readback(
    journal: &RuntimeInstallJournal,
    runtime_destination: &Path,
    helper_destination: &Path,
) -> Result<()> {
    if !runtime_identity_matches(runtime_destination, &journal.runtime.new)? {
        bail!(
            "installed runtime identity did not match journaled bytes: {}",
            runtime_destination.display()
        );
    }
    if !runtime_identity_matches(helper_destination, &journal.helper.new)? {
        bail!(
            "installed helper identity did not match journaled bytes: {}",
            helper_destination.display()
        );
    }
    Ok(())
}

fn write_runtime_install_journal(path: &Path, journal: &RuntimeInstallJournal) -> Result<()> {
    let parent = path
        .parent()
        .context("runtime install journal has no parent")?;
    fs::create_dir_all(parent)?;
    if matches!(fs::symlink_metadata(path), Ok(metadata) if metadata.file_type().is_symlink()) {
        bail!("runtime install journal must not be a symlink");
    }
    let encoded = serde_json::to_vec_pretty(journal)?;
    if encoded.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!("runtime install journal exceeded its bounded size");
    }
    let temp = parent.join(format!(
        ".codex-runtime-install.tmp-{}-{}",
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
    result.with_context(|| {
        format!(
            "failed to persist runtime install journal {}",
            path.display()
        )
    })
}

fn read_runtime_install_journal(path: &Path) -> Result<RuntimeInstallJournal> {
    let metadata = fs::symlink_metadata(path).with_context(|| {
        format!(
            "failed to inspect runtime install journal {}",
            path.display()
        )
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > UPDATE_STATE_MAX_BYTES
    {
        bail!("runtime install journal is linked, special, or oversized");
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        bail!("runtime install journal changed identity while opened");
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(UPDATE_STATE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!("runtime install journal exceeded its bounded read limit");
    }
    let journal = serde_json::from_slice::<RuntimeInstallJournal>(&bytes)
        .context("runtime install journal is malformed")?;
    if journal.format != "codexswitch-runtime-install-v1"
        || journal.transaction_id.is_empty()
        || !version_is_stable(&journal.version)
    {
        bail!("runtime install journal has invalid provenance");
    }
    Ok(journal)
}

fn cleanup_runtime_install_files(journal: &RuntimeInstallJournal) -> Result<()> {
    for file in [&journal.helper, &journal.runtime] {
        for (path, expected) in [
            (Path::new(&file.backup), file.old.as_ref()),
            (Path::new(&file.staged), Some(&file.new)),
        ] {
            let metadata = match fs::symlink_metadata(path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to inspect {}", path.display()))
                }
            };
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                bail!(
                    "runtime transaction cleanup path is unsafe: {}",
                    path.display()
                );
            }
            if let Some(expected) = expected {
                if !runtime_identity_matches(path, expected)? {
                    bail!(
                        "runtime transaction cleanup identity drifted: {}",
                        path.display()
                    );
                }
            } else {
                bail!("unexpected runtime backup exists: {}", path.display());
            }
            fs::remove_file(path).with_context(|| {
                format!(
                    "failed to remove runtime transaction file {}",
                    path.display()
                )
            })?;
        }
    }
    Ok(())
}

fn remove_runtime_install_journal(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            fs::remove_file(path)?;
            sync_parent_directory(path)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(_) => bail!("runtime install journal cleanup path is unsafe"),
        Err(error) => Err(error.into()),
    }
}

fn sync_parent_directory(path: &Path) -> Result<()> {
    let parent = path.parent().context("path has no parent directory")?;
    fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("failed to sync directory {}", parent.display()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeInstallRecoveryOutcome {
    Committed,
    RolledBack,
}

fn recover_runtime_install_transaction_at<Verify>(
    journal_path: &Path,
    state_path: &Path,
    state: &mut CodexUpdateState,
    expected_runtime: &Path,
    expected_helper: &Path,
    verify: Verify,
) -> Result<RuntimeInstallRecoveryOutcome>
where
    Verify: Fn(&Path, &Path, &str) -> Result<()>,
{
    let mut journal = read_runtime_install_journal(journal_path)?;
    validate_runtime_install_journal_paths(
        &journal,
        expected_runtime,
        expected_helper,
        journal_path,
    )?;
    let state_committed = state
        .install_transaction
        .as_ref()
        .is_some_and(|transaction| {
            transaction.id == journal.transaction_id
                && transaction.version == journal.version
                && transaction.phase == InstallTransactionStatePhase::Committed
        });
    let state_finalized = journal.phase == RuntimeInstallJournalPhase::CleanupComplete
        && state.install_transaction.is_none()
        && state.installed_version.as_deref() == Some(journal.version.as_str());
    if journal.phase >= RuntimeInstallJournalPhase::StateSaved || state_committed || state_finalized
    {
        if (!state_committed && !state_finalized)
            || state.installed_version.as_deref() != Some(journal.version.as_str())
        {
            bail!(
                "runtime install journal claims a committed pair without matching committed updater state"
            );
        }
        verify_runtime_install_readback(&journal, expected_runtime, expected_helper)?;
        verify(expected_runtime, expected_helper, &journal.version)?;
        cleanup_runtime_install_files(&journal)?;
        sync_parent_directory(expected_runtime)?;
        journal.phase = RuntimeInstallJournalPhase::CleanupComplete;
        write_runtime_install_journal(journal_path, &journal)?;
        state.install_transaction = None;
        if state.unresolved_failure.is_some() {
            restore_unresolved_failure(state);
        } else {
            state.status = UpdateStatus::Installed;
            state.error = None;
        }
        state.updated_at = Utc::now();
        save_state_at(state_path, state)?;
        remove_runtime_install_journal(journal_path)?;
        return Ok(RuntimeInstallRecoveryOutcome::Committed);
    }

    restore_runtime_install_file(&journal.helper)?;
    restore_runtime_install_file(&journal.runtime)?;
    cleanup_runtime_install_files(&journal)?;
    sync_parent_directory(expected_runtime)?;
    state.install_transaction = None;
    state.failed_install_version = Some(journal.version.clone());
    state.install_retry_not_before = Some(Utc::now());
    if state.unresolved_failure.is_none() {
        state.status = UpdateStatus::Failed;
        state.error = Some(format!(
            "recovered interrupted installation transaction {} for Codex {}; the complete old runtime pair was restored",
            journal.transaction_id, journal.version
        ));
        let failed_at = Utc::now();
        record_unresolved_failure(
            state,
            UpdateFailureKind::Installation,
            failed_at,
            Some(journal.version),
            Some(journal.transaction_id),
        );
    } else {
        restore_unresolved_failure(state);
    }
    state.updated_at = Utc::now();
    save_state_at(state_path, state)?;
    remove_runtime_install_journal(journal_path)?;
    Ok(RuntimeInstallRecoveryOutcome::RolledBack)
}

fn validate_runtime_install_journal_paths(
    journal: &RuntimeInstallJournal,
    expected_runtime: &Path,
    expected_helper: &Path,
    journal_path: &Path,
) -> Result<()> {
    for (file, expected_destination, label) in [
        (&journal.runtime, expected_runtime, "runtime"),
        (&journal.helper, expected_helper, "helper"),
    ] {
        let destination = Path::new(&file.destination);
        let staged = Path::new(&file.staged);
        let backup = Path::new(&file.backup);
        if destination != expected_destination
            || !destination.is_absolute()
            || staged.parent() != destination.parent()
            || backup.parent() != destination.parent()
            || !staged.is_absolute()
            || !backup.is_absolute()
        {
            bail!("runtime install journal has unsafe {label} paths");
        }
        let transaction = journal.transaction_id.as_str();
        if !staged
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains(transaction))
            || !backup
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(transaction))
        {
            bail!("runtime install journal {label} paths are not transaction-bound");
        }
    }
    if journal_path.parent() != expected_runtime.parent().and_then(Path::parent) {
        // The normal updater journal is in the CodexSwitch data root while the
        // runtime pair is in its patched-codex child.
        let expected_parent = expected_runtime
            .parent()
            .and_then(Path::parent)
            .context("installed runtime is not below a data root")?;
        if journal_path.parent() != Some(expected_parent) {
            bail!("runtime install journal is outside the updater data root");
        }
    }
    Ok(())
}

fn restore_runtime_install_file(file: &RuntimeInstallFileJournal) -> Result<()> {
    let destination = Path::new(&file.destination);
    let backup = Path::new(&file.backup);
    match file.old.as_ref() {
        Some(old) => {
            if runtime_identity_matches(destination, old)? {
                return Ok(());
            }
            if !runtime_identity_matches(backup, old)? {
                bail!(
                    "cannot recover old runtime identity for {}",
                    destination.display()
                );
            }
            fs::rename(backup, destination).with_context(|| {
                format!(
                    "failed to restore runtime backup {} to {}",
                    backup.display(),
                    destination.display()
                )
            })?;
            if !runtime_identity_matches(destination, old)? {
                bail!(
                    "runtime rollback readback failed: {}",
                    destination.display()
                );
            }
        }
        None => match runtime_file_identity_if_present(destination)? {
            None => {}
            Some(observed)
                if observed.bytes == file.new.bytes
                    && observed.sha256 == file.new.sha256
                    && observed.device == file.new.device
                    && observed.inode == file.new.inode =>
            {
                fs::remove_file(destination)?;
            }
            Some(_) => bail!(
                "refusing to remove unjournaled runtime identity at {}",
                destination.display()
            ),
        },
    }
    Ok(())
}

fn runtime_start_install_guard_path(data_dir: &Path) -> PathBuf {
    data_dir.join(RUNTIME_START_INSTALL_GUARD)
}

fn managed_daemon_reservation_path(codex_home: &Path) -> PathBuf {
    codex_home.join("app-server-daemon/app-server.pid.lock")
}
