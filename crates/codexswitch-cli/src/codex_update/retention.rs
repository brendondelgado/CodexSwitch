#[derive(Debug, Clone)]
struct UpdaterArtifact {
    path: PathBuf,
    canonical_path: PathBuf,
    modified: SystemTime,
    bytes: u64,
}

#[derive(Debug)]
struct RetentionEnumerationBudget {
    seen: usize,
    max: usize,
}

impl RetentionEnumerationBudget {
    fn new(max: usize) -> Self {
        Self { seen: 0, max }
    }

    fn observe(&mut self, path: &Path) -> Result<()> {
        self.seen = self.seen.saturating_add(1);
        if self.seen > self.max {
            bail!(
                "updater retention inventory exceeded the {} entry limit before mutation at {}",
                self.max,
                path.display()
            );
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
struct UpdaterRetentionPolicy {
    max_count: usize,
    max_total_bytes: u64,
    max_age: Duration,
}

fn enforce_updater_retention_at(
    state: &CodexUpdateState,
    data_dir: &Path,
    now: SystemTime,
) -> Result<()> {
    fs::create_dir_all(data_dir)?;
    let mut protected = updater_protected_paths(state, data_dir);
    let mut enumeration = RetentionEnumerationBudget::new(UPDATER_RETENTION_MAX_ENUM_ENTRIES);

    // Complete every inventory before the first deletion. A bound failure in
    // prepared generations must not occur after source retention has mutated.
    let sources = collect_source_trees(data_dir, SOURCE_TREE_MAX_TOTAL_BYTES, &mut enumeration)?;
    let prepared =
        collect_prepared_generations(data_dir, PREPARED_TREE_MAX_TOTAL_BYTES, &mut enumeration)?;

    protect_newest_pair(&sources, &mut protected);
    retain_updater_artifacts(
        sources,
        &protected,
        now,
        UpdaterRetentionPolicy {
            max_count: SOURCE_TREE_MAX_COUNT,
            max_total_bytes: SOURCE_TREE_MAX_TOTAL_BYTES,
            max_age: SOURCE_TREE_MAX_AGE,
        },
        data_dir,
        "Codex source tree",
    )?;

    protect_newest_pair(&prepared, &mut protected);
    retain_updater_artifacts(
        prepared,
        &protected,
        now,
        UpdaterRetentionPolicy {
            max_count: PREPARED_TREE_MAX_COUNT,
            max_total_bytes: PREPARED_TREE_MAX_TOTAL_BYTES,
            max_age: PREPARED_TREE_MAX_AGE,
        },
        data_dir,
        "prepared Codex generation",
    )
}

fn updater_protected_paths(state: &CodexUpdateState, data_dir: &Path) -> HashSet<PathBuf> {
    let mut protected = HashSet::new();
    if let Some(path) = state.prepared_source_path.as_deref().map(PathBuf::from) {
        if path.parent() == Some(data_dir) {
            protected.insert(path);
        }
    }
    if let Some(generation) = state
        .prepared_binary_path
        .as_deref()
        .map(Path::new)
        .and_then(Path::parent)
    {
        if generation.starts_with(data_dir.join("prepared-codex")) {
            protected.insert(generation.to_path_buf());
        }
    }
    if let Some(source) = state
        .cleanup_pending_target_path
        .as_deref()
        .map(Path::new)
        .and_then(Path::parent)
        .and_then(Path::parent)
    {
        if source.parent() == Some(data_dir) {
            protected.insert(source.to_path_buf());
        }
    }
    if let Ok(installed) = patched_codex::default_installed_binary() {
        let Ok(runtime) = installed_runtime_binary(&installed) else {
            return protected;
        };
        if let Some(generation) = runtime.parent() {
            if generation.starts_with(data_dir.join("prepared-codex")) {
                protected.insert(generation.to_path_buf());
            }
        }
    }
    protected
}

fn protect_newest_pair(artifacts: &[UpdaterArtifact], protected: &mut HashSet<PathBuf>) {
    let mut newest = artifacts.iter().collect::<Vec<_>>();
    newest.sort_by(|left, right| {
        right
            .modified
            .cmp(&left.modified)
            .then_with(|| left.canonical_path.cmp(&right.canonical_path))
    });
    for artifact in newest.into_iter().take(2) {
        protected.insert(artifact.path.clone());
    }
}

fn collect_source_trees(
    data_dir: &Path,
    byte_ceiling: u64,
    enumeration: &mut RetentionEnumerationBudget,
) -> Result<Vec<UpdaterArtifact>> {
    let mut artifacts = Vec::new();
    for entry in fs::read_dir(data_dir)
        .with_context(|| format!("failed to inspect updater root {}", data_dir.display()))?
    {
        let entry = entry?;
        enumeration.observe(&entry.path())?;
        let name = entry.file_name();
        let Some(version) = name
            .to_str()
            .and_then(|name| name.strip_prefix("codex-source-stable-"))
        else {
            continue;
        };
        if !version_is_stable(version) {
            continue;
        }
        artifacts.push(inspect_updater_tree(
            &entry.path(),
            data_dir,
            byte_ceiling,
            enumeration,
        )?);
    }
    Ok(artifacts)
}

fn collect_prepared_generations(
    data_dir: &Path,
    byte_ceiling: u64,
    enumeration: &mut RetentionEnumerationBudget,
) -> Result<Vec<UpdaterArtifact>> {
    let root = data_dir.join("prepared-codex");
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to inspect {}", root.display()))
        }
    };
    let mut artifacts = Vec::new();
    for version_entry in entries {
        let version_entry = version_entry?;
        enumeration.observe(&version_entry.path())?;
        let metadata = fs::symlink_metadata(version_entry.path())?;
        if metadata.file_type().is_symlink() {
            bail!(
                "prepared Codex version path must not be a symlink: {}",
                version_entry.path().display()
            );
        }
        if !metadata.is_dir()
            || !version_entry
                .file_name()
                .to_str()
                .is_some_and(version_is_stable)
        {
            continue;
        }

        let version_path = version_entry.path();
        let mut generations = Vec::new();
        for generation_entry in fs::read_dir(&version_path)? {
            let generation_entry = generation_entry?;
            enumeration.observe(&generation_entry.path())?;
            let metadata = fs::symlink_metadata(generation_entry.path())?;
            if metadata.file_type().is_symlink() {
                bail!(
                    "prepared Codex generation must not be a symlink: {}",
                    generation_entry.path().display()
                );
            }
            if metadata.is_dir() {
                generations.push(generation_entry.path());
            }
        }
        if generations.is_empty() {
            artifacts.push(inspect_updater_tree(
                &version_path,
                data_dir,
                byte_ceiling,
                enumeration,
            )?);
        } else {
            for generation in generations {
                artifacts.push(inspect_updater_tree(
                    &generation,
                    data_dir,
                    byte_ceiling,
                    enumeration,
                )?);
            }
        }
    }
    Ok(artifacts)
}

fn inspect_updater_tree(
    path: &Path,
    data_dir: &Path,
    byte_ceiling: u64,
    enumeration: &mut RetentionEnumerationBudget,
) -> Result<UpdaterArtifact> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect updater artifact {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!(
            "updater artifact must be a regular directory: {}",
            path.display()
        );
    }
    let modified = metadata
        .modified()
        .with_context(|| format!("failed to read modification time for {}", path.display()))?;
    let canonical_root = fs::canonicalize(data_dir)
        .with_context(|| format!("failed to resolve updater root {}", data_dir.display()))?;
    let canonical_path = fs::canonicalize(path)
        .with_context(|| format!("failed to resolve updater artifact {}", path.display()))?;
    if !canonical_path.starts_with(&canonical_root) {
        bail!(
            "updater artifact resolved outside updater root: {}",
            path.display()
        );
    }
    let bytes = updater_tree_bytes(path, byte_ceiling, enumeration)?;
    Ok(UpdaterArtifact {
        path: path.to_path_buf(),
        canonical_path,
        modified,
        bytes,
    })
}

fn updater_tree_bytes(
    path: &Path,
    ceiling: u64,
    enumeration: &mut RetentionEnumerationBudget,
) -> Result<u64> {
    let mut total = 0_u64;
    for entry in fs::read_dir(path)
        .with_context(|| format!("failed to size updater tree {}", path.display()))?
    {
        let entry = entry?;
        enumeration.observe(&entry.path())?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let bytes = if metadata.is_dir() && !metadata.file_type().is_symlink() {
            updater_tree_bytes(&entry.path(), ceiling.saturating_sub(total), enumeration)?
        } else if metadata.is_file() {
            metadata.len()
        } else {
            0
        };
        total = total.saturating_add(bytes);
        if total > ceiling {
            return Ok(ceiling.saturating_add(1));
        }
    }
    Ok(total)
}

fn retain_updater_artifacts(
    mut artifacts: Vec<UpdaterArtifact>,
    protected: &HashSet<PathBuf>,
    now: SystemTime,
    policy: UpdaterRetentionPolicy,
    data_dir: &Path,
    description: &str,
) -> Result<()> {
    if policy.max_count < 2 || policy.max_total_bytes == 0 {
        bail!("updater retention policy cannot protect current and rollback artifacts");
    }
    artifacts.sort_by(|left, right| {
        left.modified
            .cmp(&right.modified)
            .then_with(|| left.canonical_path.cmp(&right.canonical_path))
    });
    let mut retained_count = artifacts.len();
    let mut retained_bytes = artifacts.iter().fold(0_u64, |total, artifact| {
        total.saturating_add(artifact.bytes)
    });
    for artifact in artifacts {
        let expired = now.duration_since(artifact.modified).unwrap_or_default() >= policy.max_age;
        let over_limit =
            retained_count > policy.max_count || retained_bytes > policy.max_total_bytes;
        if !protected.contains(&artifact.path) && (expired || over_limit) {
            remove_owned_updater_path(&artifact.path, data_dir, description)?;
            retained_count = retained_count.saturating_sub(1);
            retained_bytes = retained_bytes.saturating_sub(artifact.bytes);
        }
    }
    if retained_count > policy.max_count || retained_bytes > policy.max_total_bytes {
        bail!("protected {description} artifacts exceed count or byte retention limits");
    }
    Ok(())
}

fn rotate_and_retain_update_logs_at(data_dir: &Path, now: SystemTime) -> Result<()> {
    rotate_and_retain_update_logs_with_limit(data_dir, now, UPDATER_RETENTION_MAX_ENUM_ENTRIES)
}

fn rotate_and_retain_update_logs_with_limit(
    data_dir: &Path,
    now: SystemTime,
    max_entries: usize,
) -> Result<()> {
    let current = data_dir.join("codex-update.log");
    let mut enumeration = RetentionEnumerationBudget::new(max_entries);
    let mut artifacts = collect_update_logs(data_dir, &mut enumeration)?;
    let rotate_current = artifacts
        .iter()
        .find(|artifact| artifact.path == current)
        .is_some_and(|artifact| artifact.bytes >= UPDATE_LOG_ROTATE_BYTES);
    if rotate_current || !artifacts.iter().any(|artifact| artifact.path == current) {
        // Reserve the current log that will be created after rotation before
        // performing the first filesystem mutation.
        enumeration.observe(&current)?;
    }

    if rotate_current {
        let rotated = data_dir.join(format!(
            "codex-update.log.{}-{}",
            now.duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            uuid::Uuid::new_v4().simple()
        ));
        match fs::symlink_metadata(&rotated) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Ok(_) => bail!("refusing to replace an existing Codex update log rotation"),
            Err(error) => return Err(error).context("failed to inspect log rotation target"),
        }
        fs::rename(&current, &rotated).context("failed to rotate Codex update log")?;
        artifacts.retain(|artifact| artifact.path != current);
        artifacts.push(inspect_update_log(&rotated, data_dir)?);
    }
    let current_file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&current)
        .context("failed to create bounded Codex update log")?;
    current_file.set_permissions(fs::Permissions::from_mode(0o600))?;
    drop(current_file);

    artifacts.retain(|artifact| artifact.path != current);
    artifacts.push(inspect_update_log(&current, data_dir)?);
    let protected = HashSet::from([current]);
    retain_updater_artifacts(
        artifacts,
        &protected,
        now,
        UpdaterRetentionPolicy {
            max_count: UPDATE_LOG_MAX_COUNT,
            max_total_bytes: UPDATE_LOG_MAX_TOTAL_BYTES,
            max_age: UPDATE_LOG_MAX_AGE,
        },
        data_dir,
        "Codex update log",
    )
}

fn collect_update_logs(
    data_dir: &Path,
    enumeration: &mut RetentionEnumerationBudget,
) -> Result<Vec<UpdaterArtifact>> {
    let mut artifacts = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        enumeration.observe(&entry.path())?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name != "codex-update.log" && !name.starts_with("codex-update.log.") {
            continue;
        }
        artifacts.push(inspect_update_log(&entry.path(), data_dir)?);
    }
    Ok(artifacts)
}

fn inspect_update_log(path: &Path, data_dir: &Path) -> Result<UpdaterArtifact> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("Codex update logs must be regular non-symlink files");
    }
    let canonical_root = fs::canonicalize(data_dir)?;
    let canonical_path = fs::canonicalize(path)?;
    if !canonical_path.starts_with(&canonical_root) {
        bail!("Codex update log resolved outside updater root");
    }
    Ok(UpdaterArtifact {
        path: path.to_path_buf(),
        canonical_path,
        modified: metadata.modified()?,
        bytes: metadata.len(),
    })
}
