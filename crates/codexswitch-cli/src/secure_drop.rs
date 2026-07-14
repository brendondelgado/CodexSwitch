use crate::{bounded_command, secure_file};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use clap::Subcommand;
use ring::digest::{Context as DigestContext, SHA256};
use serde::Serialize;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{symlink as unix_symlink, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use uuid::Uuid;

const DEFAULT_HOST: &str = "signul-vps";
const DEFAULT_REMOTE_ROOT: &str = "/home/signul/codexswitch-secure-files";
const TRANSPORT: &str = "rsync-over-ssh";
const HASH_BUFFER_BYTES: usize = 64 * 1024;
const MANIFEST_MAX_BYTES: usize = 16 * 1024;
const AUDIT_ENTRY_MAX_BYTES: usize = 16 * 1024;
const AUDIT_LOG_MAX_BYTES: u64 = 8 * 1024 * 1024;
const AUDIT_LOG_RETENTION: usize = 3;
const AUDIT_LOCK_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Subcommand)]
pub enum FilesCommand {
    Doctor(FilesDoctorArgs),
    Init(FilesInitArgs),
    Send(FilesSendArgs),
    Pull(FilesPullArgs),
    Sync(FilesSyncArgs),
    Ls(FilesLsArgs),
    Path(FilesPathArgs),
}

#[derive(Debug, clap::Args)]
pub struct FilesDoctorArgs {
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, clap::Args)]
pub struct FilesInitArgs {
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, clap::Args)]
pub struct FilesSendArgs {
    pub source: PathBuf,
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long, default_value = "inbox")]
    pub to: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, clap::Args)]
pub struct FilesPullArgs {
    pub remote_name: Option<String>,
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long, default_value = "outbox")]
    pub from: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, clap::Args)]
pub struct FilesSyncArgs {
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, clap::Args)]
pub struct FilesLsArgs {
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long, default_value = "inbox")]
    pub folder: String,
}

#[derive(Debug, clap::Args)]
pub struct FilesPathArgs {
    #[arg(long)]
    pub local_root: Option<PathBuf>,
    #[arg(long, default_value = DEFAULT_REMOTE_ROOT)]
    pub remote_root: String,
    #[arg(long, default_value = DEFAULT_HOST)]
    pub host: String,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FilesStatus {
    local_root: String,
    remote_root: String,
    host: String,
    transport: String,
    local_root_exists: bool,
    ssh_alias_configured: bool,
    rsync_available: bool,
    summary: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TransferReport {
    action: String,
    dry_run: bool,
    source: String,
    destination: String,
    sha256: Option<String>,
    bytes: Option<u64>,
    command: String,
    manifest_path: Option<String>,
}

pub fn run(command: FilesCommand) -> Result<()> {
    match command {
        FilesCommand::Doctor(args) => doctor(args),
        FilesCommand::Init(args) => init(args),
        FilesCommand::Send(args) => send(args),
        FilesCommand::Pull(args) => pull(args),
        FilesCommand::Sync(args) => sync(args),
        FilesCommand::Ls(args) => ls(args),
        FilesCommand::Path(args) => path(args),
    }
}

fn doctor(args: FilesDoctorArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    let status = status_report(&config);
    if args.json {
        println!("{}", serde_json::to_string_pretty(&status)?);
    } else {
        println!("CodexSwitch SecureDrop: {}", status.summary);
        println!("local root: {}", status.local_root);
        println!("remote root: {}:{}", status.host, status.remote_root);
        println!("transport: {}", status.transport);
        println!("rsync available: {}", status.rsync_available);
        println!("ssh alias configured: {}", status.ssh_alias_configured);
    }
    Ok(())
}

fn init(args: FilesInitArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    create_local_tree(&config)?;
    let remote_command = remote_mkdir_command(&config);
    if !args.dry_run {
        run_shell(&remote_command).context("failed to initialize SecureDrop remote root")?;
    }
    let report = TransferReport {
        action: "init".to_string(),
        dry_run: args.dry_run,
        source: config.local_root.display().to_string(),
        destination: format!("{}:{}", config.host, config.remote_root),
        sha256: None,
        bytes: None,
        command: remote_command,
        manifest_path: None,
    };
    print_report(&report, args.json);
    Ok(())
}

fn send(args: FilesSendArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    let source = expand_home(&args.source);
    validate_source_file(&source)?;
    create_local_tree(&config)?;
    let folder = validate_remote_folder(&args.to)?;
    let file_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .context("source must have a UTF-8 file name")?;
    let digest = sha256_file(&source)?;
    let sha256 = digest.hex;
    let bytes = digest.bytes;
    let manifest_path = write_manifest(&config, file_name, &sha256, bytes)?;
    let remote_final_dir = format!("{}/{folder}", config.remote_root);
    let transfer_id = Uuid::new_v4().to_string();
    let remote_staging_dir = format!("{}/.incoming/{transfer_id}", config.remote_root);
    let remote_staged_file = format!("{remote_staging_dir}/{file_name}");
    let remote_final_file = format!("{remote_final_dir}/{file_name}");
    let command = format!(
        "{mkdir} && {rsync} && {publish}",
        mkdir = ssh_command(
            &config.host,
            &format!(
                "mkdir -p {} {}",
                shell_quote(&remote_staging_dir),
                shell_quote(&remote_final_dir)
            )
        ),
        rsync = rsync_upload_command(&config.host, &source, &remote_staging_dir),
        publish = ssh_command(
            &config.host,
            &remote_publish_command(&remote_staged_file, &remote_final_file, &sha256)
        )
    );
    if !args.dry_run {
        run_shell(&command).context("SecureDrop send failed")?;
        append_audit(
            &config,
            "send",
            &source.display().to_string(),
            &remote_final_file,
        )?;
    }
    let report = TransferReport {
        action: "send".to_string(),
        dry_run: args.dry_run,
        source: source.display().to_string(),
        destination: format!("{}:{}", config.host, remote_final_file),
        sha256: Some(sha256),
        bytes: Some(bytes),
        command,
        manifest_path: Some(manifest_path.display().to_string()),
    };
    print_report(&report, args.json);
    Ok(())
}

fn pull(args: FilesPullArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    create_local_tree(&config)?;
    let folder = validate_remote_folder(&args.from)?;
    let remote_source = match args.remote_name {
        Some(name) => {
            let name = validate_remote_name(&name)?;
            format!("{}/{folder}/{name}", config.remote_root)
        }
        None => format!("{}/{folder}/", config.remote_root),
    };
    let local_destination = config.local_root.join("inbox");
    let command = rsync_download_command(&config.host, &remote_source, &local_destination);
    if !args.dry_run {
        run_shell(&command).context("SecureDrop pull failed")?;
        append_audit(
            &config,
            "pull",
            &format!("{}:{remote_source}", config.host),
            &local_destination.display().to_string(),
        )?;
    }
    let report = TransferReport {
        action: "pull".to_string(),
        dry_run: args.dry_run,
        source: format!("{}:{remote_source}", config.host),
        destination: local_destination.display().to_string(),
        sha256: None,
        bytes: None,
        command,
        manifest_path: None,
    };
    print_report(&report, args.json);
    Ok(())
}

fn sync(args: FilesSyncArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    create_local_tree(&config)?;
    let upload = rsync_upload_command(
        &config.host,
        &config.local_root.join("outbox").join("."),
        &format!("{}/inbox", config.remote_root),
    );
    let download = rsync_download_command(
        &config.host,
        &format!("{}/outbox/", config.remote_root),
        &config.local_root.join("inbox"),
    );
    let command = format!("{upload} && {download}");
    if !args.dry_run {
        run_shell(&command).context("SecureDrop sync failed")?;
        append_audit(&config, "sync", "outbox", "inbox")?;
    }
    let report = TransferReport {
        action: "sync".to_string(),
        dry_run: args.dry_run,
        source: config.local_root.display().to_string(),
        destination: format!("{}:{}", config.host, config.remote_root),
        sha256: None,
        bytes: None,
        command,
        manifest_path: None,
    };
    print_report(&report, args.json);
    Ok(())
}

fn ls(args: FilesLsArgs) -> Result<()> {
    let folder = validate_remote_folder(&args.folder)?;
    let remote_dir = format!("{}/{folder}", args.remote_root.trim_end_matches('/'));
    let command = ssh_command(
        &args.host,
        &format!(
            "find {} -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %s %f\\n' 2>/dev/null | sort",
            shell_quote(&remote_dir)
        ),
    );
    run_shell(&command).context("SecureDrop list failed")?;
    Ok(())
}

fn path(args: FilesPathArgs) -> Result<()> {
    let config = Config::new(args.local_root, args.remote_root, args.host)?;
    let status = status_report(&config);
    if args.json {
        println!("{}", serde_json::to_string_pretty(&status)?);
    } else {
        println!("local: {}", config.local_root.display());
        println!("remote: {}:{}", config.host, config.remote_root);
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct Config {
    local_root: PathBuf,
    remote_root: String,
    host: String,
    uses_default_local_root: bool,
}

impl Config {
    fn new(local_root: Option<PathBuf>, remote_root: String, host: String) -> Result<Self> {
        let uses_default_local_root = local_root.is_none();
        let local_root = local_root
            .map(|path| expand_home(&path))
            .unwrap_or(default_local_root()?);
        Ok(Self {
            local_root,
            remote_root: remote_root.trim_end_matches('/').to_string(),
            host,
            uses_default_local_root,
        })
    }
}

fn status_report(config: &Config) -> FilesStatus {
    FilesStatus {
        local_root: config.local_root.display().to_string(),
        remote_root: config.remote_root.clone(),
        host: config.host.clone(),
        transport: TRANSPORT.to_string(),
        local_root_exists: config.local_root.exists(),
        ssh_alias_configured: ssh_alias_configured(&config.host),
        rsync_available: command_exists("rsync"),
        summary: "SecureDrop uses rsync over SSH/Tailscale; no public file service is exposed."
            .to_string(),
    }
}

fn create_local_tree(config: &Config) -> Result<()> {
    create_private_directory(&config.local_root)?;
    for name in ["inbox", "outbox", "manifests", "audit"] {
        let path = config.local_root.join(name);
        create_private_directory(&path)?;
    }
    if config.uses_default_local_root {
        ensure_downloads_inbox_link(config)?;
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path).with_context(|| format!("failed to create {}", path.display()))?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!(
            "private directory is not a real directory: {}",
            path.display()
        );
    }
    if metadata.uid() != current_uid() {
        bail!("private directory has the wrong owner: {}", path.display());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to chmod {}", path.display()))?;
    Ok(())
}

fn ensure_downloads_inbox_link(config: &Config) -> Result<()> {
    let downloads_link = home_dir()?.join("Downloads").join("CodexSwitch SecureDrop");
    let inbox = config.local_root.join("inbox");

    if let Ok(metadata) = fs::symlink_metadata(&downloads_link) {
        if metadata.file_type().is_symlink() {
            let target = fs::read_link(&downloads_link)
                .with_context(|| format!("failed to read {}", downloads_link.display()))?;
            if target != inbox {
                fs::remove_file(&downloads_link)
                    .with_context(|| format!("failed to update {}", downloads_link.display()))?;
                unix_symlink(&inbox, &downloads_link)
                    .with_context(|| format!("failed to create {}", downloads_link.display()))?;
            }
        }
        return Ok(());
    }

    if let Some(parent) = downloads_link.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    unix_symlink(&inbox, &downloads_link)
        .with_context(|| format!("failed to create {}", downloads_link.display()))?;
    Ok(())
}

fn validate_source_file(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("source does not exist: {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        bail!("refusing symlink source: {}", path.display());
    }
    if !metadata.is_file() {
        bail!("source must be a regular file: {}", path.display());
    }
    Ok(())
}

fn validate_remote_folder(value: &str) -> Result<String> {
    validate_segment(value, "remote folder")
}

fn validate_remote_name(value: &str) -> Result<String> {
    validate_segment(value, "remote file name")
}

fn validate_segment(value: &str, label: &str) -> Result<String> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.contains('/')
        || value.contains('\\')
        || value.contains('\0')
    {
        bail!("invalid {label}: {value}");
    }
    Ok(value.to_string())
}

fn write_manifest(config: &Config, file_name: &str, sha256: &str, bytes: u64) -> Result<PathBuf> {
    let manifest = config
        .local_root
        .join("manifests")
        .join(format!("{file_name}.sha256"));
    let content = format!(
        "{sha256}  {file_name}\nbytes={bytes}\ncreated_at={}\n",
        Utc::now().to_rfc3339()
    );
    let lock = secure_file::lock(&manifest, true)?;
    let snapshot = lock.load(MANIFEST_MAX_BYTES, true)?;
    lock.commit(
        snapshot.generation(),
        content.as_bytes(),
        MANIFEST_MAX_BYTES,
    )?;
    Ok(manifest)
}

fn append_audit(config: &Config, action: &str, source: &str, destination: &str) -> Result<()> {
    append_audit_with_limits(
        config,
        action,
        source,
        destination,
        AUDIT_LOG_MAX_BYTES,
        AUDIT_LOG_RETENTION,
    )
}

fn append_audit_with_limits(
    config: &Config,
    action: &str,
    source: &str,
    destination: &str,
    max_bytes: u64,
    retention: usize,
) -> Result<()> {
    let audit_directory = config.local_root.join("audit");
    create_private_directory(&audit_directory)?;
    let _lock = AuditLock::acquire(&audit_directory.join("transfers.lock"))?;
    let log = config.local_root.join("audit").join("transfers.jsonl");
    let entry = serde_json::json!({
        "timestamp": Utc::now().to_rfc3339(),
        "action": action,
        "source": source,
        "destination": destination,
        "host": config.host,
        "remoteRoot": config.remote_root,
    });
    let mut encoded = serde_json::to_vec(&entry)?;
    encoded.push(b'\n');
    if encoded.len() > AUDIT_ENTRY_MAX_BYTES {
        bail!("SecureDrop audit entry exceeds the bounded entry size");
    }

    rotate_audit_if_needed(&audit_directory, &log, max_bytes, retention)?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_APPEND)
        .open(&log)
        .with_context(|| format!("failed to open {}", log.display()))?;
    validate_private_file(&file, &log)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", log.display()))?;
    file.write_all(&encoded)
        .with_context(|| format!("failed to append {}", log.display()))?;
    file.flush()
        .with_context(|| format!("failed to flush {}", log.display()))?;
    file.sync_data()
        .with_context(|| format!("failed to sync {}", log.display()))?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileDigest {
    hex: String,
    bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
    bytes: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

impl FileIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            bytes: metadata.len(),
            modified_seconds: metadata.mtime(),
            modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
        }
    }
}

fn sha256_file(path: &Path) -> Result<FileDigest> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    let before_metadata = file
        .metadata()
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if !before_metadata.is_file() {
        bail!("source must remain a regular file: {}", path.display());
    }
    let before = FileIdentity::from_metadata(&before_metadata);
    let digest = sha256_reader(&mut file)?;
    let after = FileIdentity::from_metadata(
        &file
            .metadata()
            .with_context(|| format!("failed to re-inspect {}", path.display()))?,
    );
    if before != after || digest.bytes != before.bytes {
        bail!("source changed while hashing: {}", path.display());
    }
    Ok(digest)
}

fn sha256_reader(reader: &mut impl Read) -> Result<FileDigest> {
    let mut context = DigestContext::new(&SHA256);
    let mut buffer = vec![0_u8; HASH_BUFFER_BYTES];
    let mut bytes = 0_u64;
    loop {
        let read = reader
            .read(&mut buffer)
            .context("failed to stream SHA-256 input")?;
        if read == 0 {
            break;
        }
        context.update(&buffer[..read]);
        bytes = bytes
            .checked_add(read as u64)
            .context("SHA-256 input length overflow")?;
    }
    Ok(FileDigest {
        hex: hex_digest(context.finish().as_ref()),
        bytes,
    })
}

struct AuditLock {
    file: fs::File,
}

impl AuditLock {
    fn acquire(path: &Path) -> Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        validate_private_file(&file, path)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod {}", path.display()))?;

        let started = Instant::now();
        loop {
            let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if result == 0 {
                return Ok(Self { file });
            }
            let error = std::io::Error::last_os_error();
            let raw = error.raw_os_error();
            if raw != Some(libc::EWOULDBLOCK) && raw != Some(libc::EAGAIN) {
                return Err(error).with_context(|| format!("failed to lock {}", path.display()));
            }
            if started.elapsed() >= AUDIT_LOCK_TIMEOUT {
                bail!("timed out locking {}", path.display());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for AuditLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn validate_private_file(file: &fs::File, path: &Path) -> Result<()> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if !metadata.is_file() || metadata.uid() != current_uid() {
        bail!("private file has invalid identity: {}", path.display());
    }
    Ok(())
}

fn rotate_audit_if_needed(
    audit_directory: &Path,
    log: &Path,
    max_bytes: u64,
    retention: usize,
) -> Result<()> {
    let metadata = match private_path_metadata(log)? {
        Some(metadata) => metadata,
        None => return Ok(()),
    };
    if metadata.len() < max_bytes {
        return Ok(());
    }
    if retention == 0 {
        fs::remove_file(log).with_context(|| format!("failed to rotate {}", log.display()))?;
        sync_directory(audit_directory)?;
        return Ok(());
    }

    let oldest = rotated_audit_path(log, retention);
    remove_private_file_if_present(&oldest)?;
    for index in (1..retention).rev() {
        let source = rotated_audit_path(log, index);
        if private_path_metadata(&source)?.is_some() {
            fs::rename(&source, rotated_audit_path(log, index + 1))
                .with_context(|| format!("failed to rotate {}", source.display()))?;
        }
    }
    fs::rename(log, rotated_audit_path(log, 1))
        .with_context(|| format!("failed to rotate {}", log.display()))?;
    sync_directory(audit_directory)?;
    Ok(())
}

fn private_path_metadata(path: &Path) -> Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink()
                || !metadata.is_file()
                || metadata.uid() != current_uid()
            {
                bail!("private path has invalid identity: {}", path.display());
            }
            Ok(Some(metadata))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("failed to inspect {}", path.display())),
    }
}

fn remove_private_file_if_present(path: &Path) -> Result<()> {
    if private_path_metadata(path)?.is_some() {
        fs::remove_file(path).with_context(|| format!("failed to remove {}", path.display()))?;
    }
    Ok(())
}

fn rotated_audit_path(log: &Path, index: usize) -> PathBuf {
    PathBuf::from(format!("{}.{}", log.display(), index))
}

fn sync_directory(path: &Path) -> Result<()> {
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    directory
        .sync_all()
        .with_context(|| format!("failed to sync {}", path.display()))
}

fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn remote_publish_command(staged: &str, final_path: &str, sha256: &str) -> String {
    let staged = shell_quote(staged);
    format!(
        "actual=$(sha256sum {staged} | awk '{{print $1}}') && if [ \"$actual\" != {expected} ]; then rm -f -- {staged}; exit 65; fi && chmod 600 {staged} && mv -f {staged} {final_path}",
        expected = shell_quote(sha256),
        final_path = shell_quote(final_path),
    )
}

fn remote_mkdir_command(config: &Config) -> String {
    let dirs = [
        "inbox",
        "outbox",
        "archive",
        ".incoming",
        "manifests",
        "audit",
    ]
    .iter()
    .map(|name| shell_quote(&format!("{}/{name}", config.remote_root)))
    .collect::<Vec<_>>()
    .join(" ");
    ssh_command(
        &config.host,
        &format!(
            "mkdir -p {root} {dirs} && chmod 700 {root} {dirs}",
            root = shell_quote(&config.remote_root),
        ),
    )
}

fn rsync_upload_command(host: &str, source: &Path, remote_dir: &str) -> String {
    format!(
        "rsync -az --partial --timeout=30 -e ssh {} {}:{}",
        shell_quote(&source.display().to_string()),
        shell_quote(host),
        shell_quote(remote_dir)
    )
}

fn rsync_download_command(host: &str, remote_source: &str, local_destination: &Path) -> String {
    format!(
        "rsync -az --partial --timeout=30 -e ssh {}:{} {}",
        shell_quote(host),
        shell_quote(remote_source),
        shell_quote(&local_destination.display().to_string())
    )
}

fn ssh_command(host: &str, remote_command: &str) -> String {
    format!("ssh {} {}", shell_quote(host), shell_quote(remote_command))
}

fn run_shell(command: &str) -> Result<()> {
    let status = bounded_command::status_inherited(
        Command::new("bash").arg("-lc").arg(command),
        Duration::from_secs(10 * 60),
    )
    .with_context(|| format!("failed to run: {command}"))?;
    if !status.success() {
        bail!("command failed with {status}: {command}");
    }
    Ok(())
}

fn print_report(report: &TransferReport, json: bool) {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(report).expect("report JSON")
        );
    } else {
        println!(
            "SecureDrop {}{}",
            report.action,
            if report.dry_run { " dry-run" } else { "" }
        );
        println!("source: {}", report.source);
        println!("destination: {}", report.destination);
        if let Some(sha256) = &report.sha256 {
            println!("sha256: {sha256}");
        }
        println!("command: {}", report.command);
    }
}

fn command_exists(name: &str) -> bool {
    bounded_command::status(
        Command::new("bash")
            .arg("-lc")
            .arg(format!("command -v {} >/dev/null 2>&1", shell_quote(name))),
        Duration::from_secs(5),
    )
    .map(|status| status.success())
    .unwrap_or(false)
}

fn ssh_alias_configured(host: &str) -> bool {
    bounded_command::output(
        Command::new("ssh").args(["-G", host]),
        Duration::from_secs(5),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .map(|output| output.status.success())
    .unwrap_or(false)
}

fn default_local_root() -> Result<PathBuf> {
    Ok(home_dir()?.join("CodexSwitch SecureDrop"))
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}

fn expand_home(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return home_dir().unwrap_or_else(|_| path.to_path_buf());
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return home_dir()
            .map(|home| home.join(rest))
            .unwrap_or_else(|_| path.to_path_buf());
    }
    path.to_path_buf()
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::io::Cursor;
    use std::sync::{Arc, Barrier};

    fn test_config(root: &Path) -> Config {
        Config {
            local_root: root.to_path_buf(),
            remote_root: "/home/signul/codexswitch-secure-files".to_string(),
            host: "example.invalid".to_string(),
            uses_default_local_root: false,
        }
    }

    #[test]
    fn rejects_path_traversal_segments() {
        assert!(validate_remote_folder("../bad").is_err());
        assert!(validate_remote_folder("bad/name").is_err());
        assert_eq!(validate_remote_folder("inbox").unwrap(), "inbox");
    }

    #[test]
    fn shell_quotes_single_quotes() {
        assert_eq!(shell_quote("a'b"), "'a'\"'\"'b'");
    }

    #[test]
    fn hashing_uses_a_fixed_size_streaming_buffer() -> Result<()> {
        struct BoundedReader {
            remaining: usize,
        }

        impl Read for BoundedReader {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                assert!(buffer.len() <= HASH_BUFFER_BYTES);
                let count = self.remaining.min(buffer.len());
                buffer[..count].fill(b'x');
                self.remaining -= count;
                Ok(count)
            }
        }

        let byte_count = HASH_BUFFER_BYTES * 3 + 17;
        let mut reader = BoundedReader {
            remaining: byte_count,
        };
        let streamed = sha256_reader(&mut reader)?;
        let expected = ring::digest::digest(&SHA256, &vec![b'x'; byte_count]);
        assert_eq!(streamed.bytes, byte_count as u64);
        assert_eq!(streamed.hex, hex_digest(expected.as_ref()));
        Ok(())
    }

    #[test]
    fn file_hash_reports_the_opened_file_length() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("artifact.bin");
        fs::write(&path, b"streamed artifact")?;

        let observed = sha256_file(&path)?;
        let expected = sha256_reader(&mut Cursor::new(b"streamed artifact"))?;
        assert_eq!(observed, expected);
        Ok(())
    }

    #[test]
    fn concurrent_audit_appends_do_not_lose_entries() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let config = Arc::new(test_config(temp.path()));
        create_local_tree(&config)?;
        let worker_count = 24;
        let barrier = Arc::new(Barrier::new(worker_count));
        let mut workers = Vec::new();

        for index in 0..worker_count {
            let config = Arc::clone(&config);
            let barrier = Arc::clone(&barrier);
            workers.push(std::thread::spawn(move || -> Result<()> {
                barrier.wait();
                append_audit(&config, &format!("send-{index}"), "source", "destination")
            }));
        }
        for worker in workers {
            worker.join().expect("audit worker panicked")?;
        }

        let log = fs::read_to_string(temp.path().join("audit/transfers.jsonl"))?;
        let actions = log
            .lines()
            .map(|line| -> Result<String> {
                Ok(serde_json::from_str::<serde_json::Value>(line)?["action"]
                    .as_str()
                    .context("audit action missing")?
                    .to_string())
            })
            .collect::<Result<HashSet<_>>>()?;
        assert_eq!(actions.len(), worker_count);
        Ok(())
    }

    #[test]
    fn audit_rotation_is_bounded() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let config = test_config(temp.path());
        create_local_tree(&config)?;

        for index in 0..6 {
            append_audit_with_limits(
                &config,
                &format!("send-{index}"),
                "source",
                "destination",
                1,
                2,
            )?;
        }

        let log = temp.path().join("audit/transfers.jsonl");
        for path in [
            &log,
            &rotated_audit_path(&log, 1),
            &rotated_audit_path(&log, 2),
        ] {
            let lines = fs::read_to_string(path)?;
            assert_eq!(lines.lines().count(), 1);
            serde_json::from_str::<serde_json::Value>(lines.trim())?;
        }
        assert!(!rotated_audit_path(&log, 3).exists());
        Ok(())
    }

    #[test]
    fn audit_rejects_a_symlink_log_without_touching_its_referent() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let config = test_config(temp.path());
        create_local_tree(&config)?;
        let outside = temp.path().join("outside.log");
        fs::write(&outside, b"preserve")?;
        unix_symlink(&outside, temp.path().join("audit/transfers.jsonl"))?;

        assert!(append_audit(&config, "send", "source", "destination").is_err());
        assert_eq!(fs::read(&outside)?, b"preserve");
        Ok(())
    }

    #[test]
    fn transfer_commands_use_timeout_and_hash_verified_publish() {
        let upload = rsync_upload_command("host", Path::new("/tmp/a"), "/remote");
        let download = rsync_download_command("host", "/remote/a", Path::new("/tmp"));
        let publish = remote_publish_command("/stage/a", "/final/a", "abc123");

        assert!(upload.contains("--timeout=30"));
        assert!(download.contains("--timeout=30"));
        assert!(publish.contains("sha256sum"));
        assert!(publish.contains("rm -f -- '/stage/a'"));
        assert!(publish.contains("mv -f '/stage/a' '/final/a'"));
        assert!(publish.contains("'abc123'"));
    }
}
