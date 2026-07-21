#[cfg(unix)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct CodexSwitchControlFileIdentity {
    device: u64,
    inode: u64,
    length: u64,
    mode: u32,
    owner_uid: u32,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

#[cfg(unix)]
impl CodexSwitchControlFileIdentity {
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            length: metadata.len(),
            mode: metadata.mode(),
            owner_uid: metadata.uid(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
        }
    }
}

#[cfg(unix)]
#[derive(Debug)]
struct CodexSwitchManagedControlLayout {
    public_link: std::path::PathBuf,
    public_target: std::path::PathBuf,
    public_identity: CodexSwitchControlFileIdentity,
    current_link: std::path::PathBuf,
    current_target: std::path::PathBuf,
    current_identity: CodexSwitchControlFileIdentity,
    manifest_path: std::path::PathBuf,
    manifest_identity: CodexSwitchControlFileIdentity,
}

#[cfg(unix)]
#[derive(Debug)]
struct CodexSwitchControlCli {
    canonical_path: std::path::PathBuf,
    executable_identity: CodexSwitchControlFileIdentity,
    expected_sha256: String,
    opened_executable: std::fs::File,
    managed_layout: Option<CodexSwitchManagedControlLayout>,
}

#[cfg(unix)]
impl CodexSwitchControlCli {
    #[cfg(target_os = "linux")]
    fn execution_path(&self) -> Option<std::path::PathBuf> {
        use std::os::fd::AsRawFd;
        let descriptor_path = std::path::PathBuf::from(format!(
            "/proc/self/fd/{}",
            self.opened_executable.as_raw_fd()
        ));
        (std::fs::canonicalize(&descriptor_path).ok()? == self.canonical_path)
            .then_some(descriptor_path)
    }

    #[cfg(not(target_os = "linux"))]
    fn execution_path(&self) -> Option<std::path::PathBuf> {
        Some(self.canonical_path.clone())
    }

    fn is_still_current(&self) -> bool {
        let Ok(metadata) = std::fs::symlink_metadata(&self.canonical_path) else {
            return false;
        };
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || CodexSwitchControlFileIdentity::from_metadata(&metadata) != self.executable_identity
            || std::fs::canonicalize(&self.canonical_path).ok().as_deref()
                != Some(self.canonical_path.as_path())
        {
            return false;
        }
        let Ok(opened_metadata) = self.opened_executable.metadata() else {
            return false;
        };
        if CodexSwitchControlFileIdentity::from_metadata(&opened_metadata)
            != self.executable_identity
        {
            return false;
        }
        let Ok(mut opened_executable) = self.opened_executable.try_clone() else {
            return false;
        };
        if codexswitch_sha256_opened_control_file(&mut opened_executable, &self.executable_identity)
            .as_deref()
            != Some(self.expected_sha256.as_str())
        {
            return false;
        }
        let Some(layout) = self.managed_layout.as_ref() else {
            return true;
        };
        codexswitch_symlink_still_matches(
            &layout.public_link,
            &layout.public_target,
            &layout.public_identity,
        ) && codexswitch_symlink_still_matches(
            &layout.current_link,
            &layout.current_target,
            &layout.current_identity,
        ) && std::fs::canonicalize(&layout.public_link).ok().as_deref()
            == Some(self.canonical_path.as_path())
            && std::fs::canonicalize(layout.current_link.join("codexswitch-cli"))
                .ok()
                .as_deref()
                == Some(self.canonical_path.as_path())
            && codexswitch_regular_file_identity(&layout.manifest_path).as_ref()
                == Some(&layout.manifest_identity)
    }
}

#[cfg(unix)]
fn codexswitch_path_is_normal_absolute(path: &std::path::Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    let mut saw_root = false;
    for component in path.components() {
        match component {
            std::path::Component::RootDir if !saw_root => saw_root = true,
            std::path::Component::Normal(_) if saw_root => {}
            _ => return false,
        }
    }
    saw_root
}

#[cfg(unix)]
fn codexswitch_owned_directory_is_secure(
    path: &std::path::Path,
    owner_uid: u32,
    immutable: bool,
) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    !metadata.file_type().is_symlink()
        && metadata.is_dir()
        && metadata.uid() == owner_uid
        && metadata.permissions().mode() & 0o022 == 0
        && (!immutable || metadata.permissions().mode() & 0o222 == 0)
        && std::fs::canonicalize(path).ok().as_deref() == Some(path)
}

#[cfg(unix)]
fn codexswitch_regular_file_identity(
    path: &std::path::Path,
) -> Option<CodexSwitchControlFileIdentity> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    (!metadata.file_type().is_symlink() && metadata.is_file())
        .then(|| CodexSwitchControlFileIdentity::from_metadata(&metadata))
}

#[cfg(unix)]
fn codexswitch_symlink_still_matches(
    path: &std::path::Path,
    expected_target: &std::path::Path,
    expected_identity: &CodexSwitchControlFileIdentity,
) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    metadata.file_type().is_symlink()
        && CodexSwitchControlFileIdentity::from_metadata(&metadata) == *expected_identity
        && std::fs::read_link(path).ok().as_deref() == Some(expected_target)
}

#[cfg(unix)]
fn codexswitch_open_control_file(
    path: &std::path::Path,
    owner_uid: u32,
    max_bytes: u64,
    executable: bool,
    immutable: bool,
) -> Option<(std::fs::File, CodexSwitchControlFileIdentity)> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let before = std::fs::symlink_metadata(path).ok()?;
    if before.file_type().is_symlink()
        || !before.is_file()
        || before.uid() != owner_uid
        || before.len() == 0
        || before.len() > max_bytes
        || (executable && before.permissions().mode() & 0o111 == 0)
        || (immutable && before.permissions().mode() & 0o222 != 0)
    {
        return None;
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let opened = file.metadata().ok()?;
    let identity = CodexSwitchControlFileIdentity::from_metadata(&before);
    if CodexSwitchControlFileIdentity::from_metadata(&opened) != identity {
        return None;
    }
    Some((file, identity))
}

#[cfg(unix)]
fn codexswitch_read_control_file(
    path: &std::path::Path,
    owner_uid: u32,
    max_bytes: u64,
    immutable: bool,
) -> Option<(Vec<u8>, CodexSwitchControlFileIdentity)> {
    let (mut file, identity) =
        codexswitch_open_control_file(path, owner_uid, max_bytes, false, immutable)?;
    let mut bytes = Vec::with_capacity(identity.length as usize);
    let mut bounded = std::io::Read::take(&mut file, max_bytes + 1);
    std::io::Read::read_to_end(&mut bounded, &mut bytes).ok()?;
    if bytes.len() as u64 != identity.length
        || codexswitch_regular_file_identity(path).as_ref() != Some(&identity)
        || CodexSwitchControlFileIdentity::from_metadata(&file.metadata().ok()?) != identity
    {
        return None;
    }
    Some((bytes, identity))
}

#[cfg(unix)]
fn codexswitch_sha256_opened_control_file(
    file: &mut std::fs::File,
    expected_identity: &CodexSwitchControlFileIdentity,
) -> Option<String> {
    use sha2::Digest;
    use std::io::{Read, Seek};
    file.rewind().ok()?;
    let mut digest = sha2::Sha256::new();
    let mut total = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer).ok()?;
        if count == 0 {
            break;
        }
        total = total.checked_add(count as u64)?;
        if total > expected_identity.length {
            return None;
        }
        digest.update(&buffer[..count]);
    }
    if total != expected_identity.length
        || CodexSwitchControlFileIdentity::from_metadata(&file.metadata().ok()?)
            != *expected_identity
    {
        return None;
    }
    file.rewind().ok()?;
    Some(format!("{:x}", digest.finalize()))
}

#[cfg(unix)]
fn codexswitch_release_manifest(
    bytes: &[u8],
) -> Option<std::collections::BTreeMap<String, String>> {
    const REQUIRED_KEYS: [&str; 21] = [
        "format",
        "release_id",
        "git_sha",
        "package_version",
        "build_epoch",
        "cli_version",
        "cli_sha256",
        "codex_source_sha",
        "upstream_codex_git_sha",
        "source_patch_sha256",
        "sourcePatchSha256",
        "artifact_manifest_sha256",
        "artifact_total_bytes",
        "codex_version",
        "codex_sha256",
        "codex_code_mode_host_sha256",
        "codex_marker_contract",
        "systemd_payload",
        "codexswitch_unit_sha256",
        "codexswitch_dropin_sha256",
        "app_server_unit_sha256",
    ];
    const FINAL_KEY: &str = "app_server_dropin_sha256";
    let text = std::str::from_utf8(bytes).ok()?;
    if !text.ends_with('\n') || text.contains('\0') {
        return None;
    }
    let mut values = std::collections::BTreeMap::new();
    for line in text.lines() {
        let (key, value) = line.split_once('\t')?;
        if key.is_empty()
            || value.is_empty()
            || value.contains('\t')
            || values.insert(key.to_string(), value.to_string()).is_some()
        {
            return None;
        }
    }
    if values.len() != REQUIRED_KEYS.len() + 1
        || REQUIRED_KEYS.iter().any(|key| !values.contains_key(*key))
        || !values.contains_key(FINAL_KEY)
    {
        return None;
    }
    Some(values)
}

#[cfg(unix)]
fn codexswitch_safe_release_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

#[cfg(unix)]
fn codexswitch_lower_hex_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(unix)]
#[allow(dead_code)]
fn codexswitch_resolve_linux_managed_control_cli_at(
    home: &std::path::Path,
    owner_uid: u32,
) -> Option<CodexSwitchControlCli> {
    use std::os::unix::fs::MetadataExt;
    const MANIFEST_MAX_BYTES: u64 = 64 * 1024;
    const CLI_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
    if !codexswitch_path_is_normal_absolute(home)
        || std::fs::canonicalize(home).ok().as_deref() != Some(home)
    {
        return None;
    }
    let local = home.join(".local");
    let bin = local.join("bin");
    let share = local.join("share");
    let install_root = share.join("codexswitch");
    let releases = install_root.join("releases");
    for path in [home, &local, &bin, &share, &install_root, &releases] {
        if !codexswitch_owned_directory_is_secure(path, owner_uid, false) {
            return None;
        }
    }

    let public_link = bin.join("codexswitch-cli");
    let current_link = install_root.join("current");
    let expected_public_target = current_link.join("codexswitch-cli");
    let public_metadata = std::fs::symlink_metadata(&public_link).ok()?;
    let current_metadata = std::fs::symlink_metadata(&current_link).ok()?;
    if !public_metadata.file_type().is_symlink()
        || public_metadata.uid() != owner_uid
        || std::fs::read_link(&public_link).ok()? != expected_public_target
        || !current_metadata.file_type().is_symlink()
        || current_metadata.uid() != owner_uid
    {
        return None;
    }

    let current_target = std::fs::read_link(&current_link).ok()?;
    let mut components = current_target.components();
    let release_id = match (components.next(), components.next(), components.next()) {
        (
            Some(std::path::Component::Normal(releases_component)),
            Some(std::path::Component::Normal(release_component)),
            None,
        ) if releases_component == "releases" => release_component.to_str()?,
        _ => return None,
    };
    if !codexswitch_safe_release_id(release_id) {
        return None;
    }
    let release_dir = install_root.join(&current_target);
    if release_dir.parent() != Some(releases.as_path())
        || !codexswitch_owned_directory_is_secure(&release_dir, owner_uid, true)
        || std::fs::canonicalize(&current_link).ok().as_deref() != Some(release_dir.as_path())
    {
        return None;
    }

    let manifest_path = release_dir.join("release-manifest.tsv");
    let (manifest_bytes, manifest_identity) =
        codexswitch_read_control_file(&manifest_path, owner_uid, MANIFEST_MAX_BYTES, true)?;
    let manifest = codexswitch_release_manifest(&manifest_bytes)?;
    if manifest.get("format").map(String::as_str) != Some("codexswitch-release-v3")
        || manifest.get("release_id").map(String::as_str) != Some(release_id)
    {
        return None;
    }
    let expected_sha256 = manifest.get("cli_sha256")?.to_string();
    if !codexswitch_lower_hex_sha256(&expected_sha256) {
        return None;
    }

    let canonical_path = release_dir.join("codexswitch-cli");
    let (mut opened_executable, executable_identity) =
        codexswitch_open_control_file(&canonical_path, owner_uid, CLI_MAX_BYTES, true, true)?;
    if std::fs::canonicalize(&canonical_path).ok().as_deref() != Some(canonical_path.as_path())
        || std::fs::canonicalize(&public_link).ok().as_deref() != Some(canonical_path.as_path())
        || codexswitch_sha256_opened_control_file(&mut opened_executable, &executable_identity)?
            != expected_sha256
        || codexswitch_regular_file_identity(&canonical_path).as_ref() != Some(&executable_identity)
        || codexswitch_regular_file_identity(&manifest_path).as_ref() != Some(&manifest_identity)
    {
        return None;
    }

    Some(CodexSwitchControlCli {
        canonical_path,
        executable_identity,
        expected_sha256,
        opened_executable,
        managed_layout: Some(CodexSwitchManagedControlLayout {
            public_link,
            public_target: expected_public_target,
            public_identity: CodexSwitchControlFileIdentity::from_metadata(&public_metadata),
            current_link,
            current_target,
            current_identity: CodexSwitchControlFileIdentity::from_metadata(&current_metadata),
            manifest_path,
            manifest_identity,
        }),
    })
}

#[cfg(target_os = "linux")]
fn codexswitch_control_cli() -> Option<CodexSwitchControlCli> {
    let home = std::path::PathBuf::from(std::env::var_os("HOME")?);
    let resolved =
        codexswitch_resolve_linux_managed_control_cli_at(&home, unsafe { libc::geteuid() })?;
    resolved.execution_path()?;
    Some(resolved)
}

#[cfg(all(unix, not(target_os = "linux")))]
fn codexswitch_control_cli() -> Option<CodexSwitchControlCli> {
    const CLI_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
    let home = std::path::PathBuf::from(std::env::var_os("HOME")?);
    if !codexswitch_path_is_normal_absolute(&home)
        || std::fs::canonicalize(&home).ok().as_deref() != Some(home.as_path())
    {
        return None;
    }
    let canonical_path = home.join(".local/bin/codexswitch-cli");
    let (mut opened_executable, executable_identity) = codexswitch_open_control_file(
        &canonical_path,
        unsafe { libc::geteuid() },
        CLI_MAX_BYTES,
        true,
        false,
    )?;
    if std::fs::canonicalize(&canonical_path).ok().as_deref() != Some(canonical_path.as_path()) {
        return None;
    }
    let expected_sha256 =
        codexswitch_sha256_opened_control_file(&mut opened_executable, &executable_identity)?;
    Some(CodexSwitchControlCli {
        canonical_path,
        executable_identity,
        expected_sha256,
        opened_executable,
        managed_layout: None,
    })
}

#[cfg(unix)]
fn codexswitch_auth_handoff_matches(
    cached_fingerprint: Option<&str>,
    cached_provider_account_id: Option<&str>,
    cached_generation: u64,
    handoff_fingerprint: &str,
    handoff_provider_account_id: &str,
    handoff_generation: u64,
    pre_rotation_generation: u64,
) -> bool {
    handoff_generation > pre_rotation_generation
        && cached_generation == handoff_generation
        && cached_fingerprint == Some(handoff_fingerprint)
        && cached_provider_account_id == Some(handoff_provider_account_id)
}

#[cfg(unix)]
fn codexswitch_external_auth_handoff_matches(
    cached_fingerprint: Option<&str>,
    cached_provider_account_id: Option<&str>,
    cached_generation: u64,
    disk_fingerprint: Option<&str>,
    disk_provider_account_id: Option<&str>,
    handoff_fingerprint: &str,
    handoff_provider_account_id: &str,
    handoff_generation: u64,
    request_auth_generation: u64,
) -> bool {
    disk_fingerprint == Some(handoff_fingerprint)
        && disk_provider_account_id == Some(handoff_provider_account_id)
        && codexswitch_auth_handoff_matches(
            cached_fingerprint,
            cached_provider_account_id,
            cached_generation,
            handoff_fingerprint,
            handoff_provider_account_id,
            handoff_generation,
            request_auth_generation,
        )
}
