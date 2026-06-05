use anyhow::{bail, Context, Result};
use chrono::Utc;
use clap::Subcommand;
use ring::digest::{digest, SHA256};
use serde::Serialize;
use std::fs;
use std::io::Read;
use std::os::unix::fs::{symlink as unix_symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use uuid::Uuid;

const DEFAULT_HOST: &str = "signul-vps";
const DEFAULT_REMOTE_ROOT: &str = "/home/signul/codexswitch-secure-files";
const TRANSPORT: &str = "rsync-over-ssh";

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
    let sha256 = sha256_file(&source)?;
    let bytes = fs::metadata(&source)?.len();
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
            &format!(
                "chmod 600 {staged} && mv -f {staged} {final}",
                staged = shell_quote(&remote_staged_file),
                final = shell_quote(&remote_final_file)
            )
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

#[derive(Debug)]
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
    for name in ["inbox", "outbox", "manifests", "audit"] {
        let path = config.local_root.join(name);
        fs::create_dir_all(&path)
            .with_context(|| format!("failed to create {}", path.display()))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to chmod {}", path.display()))?;
    }
    fs::set_permissions(&config.local_root, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to chmod {}", config.local_root.display()))?;
    if config.uses_default_local_root {
        ensure_downloads_inbox_link(config)?;
    }
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
    fs::write(&manifest, content)?;
    fs::set_permissions(&manifest, fs::Permissions::from_mode(0o600))?;
    Ok(manifest)
}

fn append_audit(config: &Config, action: &str, source: &str, destination: &str) -> Result<()> {
    let log = config.local_root.join("audit").join("transfers.jsonl");
    let entry = serde_json::json!({
        "timestamp": Utc::now().to_rfc3339(),
        "action": action,
        "source": source,
        "destination": destination,
        "host": config.host,
        "remoteRoot": config.remote_root,
    });
    let mut existing = fs::read_to_string(&log).unwrap_or_default();
    existing.push_str(&serde_json::to_string(&entry)?);
    existing.push('\n');
    fs::write(&log, existing)?;
    fs::set_permissions(&log, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(hex_digest(digest(&SHA256, &bytes).as_ref()))
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
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
        "rsync -az --partial -e ssh {} {}:{}",
        shell_quote(&source.display().to_string()),
        shell_quote(host),
        shell_quote(remote_dir)
    )
}

fn rsync_download_command(host: &str, remote_source: &str, local_destination: &Path) -> String {
    format!(
        "rsync -az --partial -e ssh {}:{} {}",
        shell_quote(host),
        shell_quote(remote_source),
        shell_quote(&local_destination.display().to_string())
    )
}

fn ssh_command(host: &str, remote_command: &str) -> String {
    format!("ssh {} {}", shell_quote(host), shell_quote(remote_command))
}

fn run_shell(command: &str) -> Result<()> {
    let status = Command::new("bash")
        .arg("-lc")
        .arg(command)
        .status()
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
    Command::new("bash")
        .arg("-lc")
        .arg(format!("command -v {} >/dev/null 2>&1", shell_quote(name)))
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn ssh_alias_configured(host: &str) -> bool {
    Command::new("ssh")
        .args(["-G", host])
        .output()
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
}
