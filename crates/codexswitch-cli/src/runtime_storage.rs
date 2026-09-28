use anyhow::{bail, Context, Result};
use clap::Subcommand;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

const LOG_ROW_BUDGET: u64 = 250_000;
const LOG_ESTIMATED_BYTE_BUDGET: u64 = 1024 * 1024 * 1024;
const LOG_WAL_CONFIGURED_CEILING_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Subcommand)]
pub enum RuntimeStorageCommand {
    /// Report aggregate representation, catalog, and log-storage measurements without mutation.
    Status {
        #[arg(long)]
        codex_home: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// Validate local roots, manifests, catalog references, and exact restore hashes read-only.
    Doctor {
        #[arg(long)]
        codex_home: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// List the VPS-local catalog using bounded metadata filters.
    List {
        #[arg(long)]
        codex_home: Option<PathBuf>,
        #[arg(long)]
        thread_id: Option<String>,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        created_from: Option<String>,
        #[arg(long)]
        created_to: Option<String>,
        #[arg(long, default_value_t = 100, value_parser = clap::value_parser!(u32).range(1..=1000))]
        limit: u32,
        #[arg(long)]
        json: bool,
    },
    /// Show one catalog record by stable thread id without reading session contents.
    Show {
        thread_id: String,
        #[arg(long)]
        codex_home: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// HELD: native runtime restore is required; this support CLI never mutates session history.
    Restore {
        thread_id: String,
        #[arg(long)]
        codex_home: Option<PathBuf>,
        #[arg(long)]
        allow_lossless_restore: bool,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Default, Serialize)]
struct RuntimeStorageStatus {
    codex_home: String,
    logical_rollouts: u64,
    plain_rollouts: u64,
    compressed_rollouts: u64,
    dual_rollouts: u64,
    manifest_files: u64,
    plain_bytes: u64,
    compressed_bytes: u64,
    catalog_available: bool,
    catalog_error: Option<String>,
    catalog_records: u64,
    catalog_raw_bytes: u64,
    catalog_compressed_bytes: u64,
    logs_available: bool,
    logs_error: Option<String>,
    logs_rows: u64,
    logs_estimated_bytes: u64,
    logs_thread_partitions: u64,
    logs_process_partitions: u64,
    logs_main_bytes: u64,
    logs_wal_bytes: u64,
    logs_measurement_available: bool,
    logs_measurement_error: Option<String>,
    logs_claim_generation: Option<i64>,
    logs_completed_generation: Option<i64>,
    logs_claim_status: Option<String>,
    logs_last_result: Option<String>,
    logs_measurement_mode: Option<String>,
    logs_row_budget: u64,
    logs_estimated_byte_budget: u64,
    logs_over_row_budget: Option<bool>,
    logs_over_estimated_byte_budget: Option<bool>,
    logs_logical_cap_enforced: Option<bool>,
    logs_physical_maintenance_enabled: Option<bool>,
    logs_checkpoint_status: Option<String>,
    logs_vacuum_status: Option<String>,
    logs_wal_configured_ceiling_bytes: u64,
    logs_wal_ceiling_enforced: bool,
    mutation_enabled: bool,
}

#[derive(Debug, Serialize)]
struct DoctorReport {
    ok: bool,
    complete: bool,
    checked_catalog_records: u64,
    errors: Vec<String>,
    warnings: Vec<String>,
    mutation_enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct CatalogRecord {
    thread_id: String,
    schema_version: i64,
    generation: i64,
    source_host: String,
    project: Option<String>,
    cwd: Option<String>,
    title: Option<String>,
    session_created_at: Option<String>,
    session_updated_at: Option<String>,
    raw_path: String,
    compressed_path: String,
    manifest_path: String,
    raw_sha256: String,
    compressed_sha256: String,
    raw_bytes: i64,
    compressed_bytes: i64,
    codec: String,
    codec_version: i64,
    restore_verified_at: i64,
    installed_at: i64,
    pinned: bool,
    representation_state: String,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    schema_version: u32,
    generation: u64,
    thread_id: String,
    raw_path: String,
    compressed_path: String,
    raw_sha256: String,
    compressed_sha256: String,
    raw_bytes: u64,
    compressed_bytes: u64,
    codec: String,
    codec_version: u32,
    zstd_frame_checksum: bool,
}

#[derive(Debug)]
struct LogObserverState {
    claim_generation: i64,
    completed_generation: i64,
    claim_status: String,
    last_result: String,
    maintenance_mode: String,
    logical_cap_enforced: bool,
    physical_maintenance_enabled: bool,
    checkpoint_status: String,
    vacuum_status: String,
    over_row_budget: bool,
    over_byte_budget: bool,
}

pub fn run(command: RuntimeStorageCommand) -> Result<()> {
    match command {
        RuntimeStorageCommand::Status { codex_home, json } => {
            let home = resolve_home(codex_home)?;
            print_value(&status(&home)?, json)
        }
        RuntimeStorageCommand::Doctor { codex_home, json } => {
            let home = resolve_home(codex_home)?;
            let report = doctor(&home)?;
            let ok = report.ok;
            print_value(&report, json)?;
            if !ok {
                bail!("runtime-storage doctor found fail-closed errors");
            }
            Ok(())
        }
        RuntimeStorageCommand::List {
            codex_home,
            thread_id,
            project,
            title,
            created_from,
            created_to,
            limit,
            json,
        } => {
            let home = resolve_home(codex_home)?;
            let records = list_catalog(
                &home,
                thread_id.as_deref(),
                project.as_deref(),
                title.as_deref(),
                created_from.as_deref(),
                created_to.as_deref(),
                limit,
            )?;
            print_value(&records, json)
        }
        RuntimeStorageCommand::Show {
            thread_id,
            codex_home,
            json,
        } => {
            validate_thread_id(&thread_id)?;
            let home = resolve_home(codex_home)?;
            let record = catalog_record(&home, &thread_id)?
                .with_context(|| format!("thread {thread_id} is not in the local catalog"))?;
            print_value(&record, json)
        }
        RuntimeStorageCommand::Restore { .. } => bail!(
            "HELD: the CodexSwitch support CLI is read-only and cannot restore sessions; exact restore must run through the native Codex runtime's shared lease, generation CAS, durable catalog transition, crash reconciliation, and final readback after separate activation authority"
        ),
    }
}

fn status(home: &Path) -> Result<RuntimeStorageStatus> {
    require_real_home(home)?;
    let mut status = RuntimeStorageStatus {
        codex_home: home.display().to_string(),
        logs_row_budget: LOG_ROW_BUDGET,
        logs_estimated_byte_budget: LOG_ESTIMATED_BYTE_BUDGET,
        logs_wal_configured_ceiling_bytes: LOG_WAL_CONFIGURED_CEILING_BYTES,
        ..Default::default()
    };
    let mut logical = std::collections::HashSet::new();
    for root in [home.join("sessions"), home.join("archived_sessions")] {
        inventory_tree(&root, &mut status, &mut logical)?;
    }
    status.logical_rollouts = logical.len() as u64;
    status.dual_rollouts = logical
        .iter()
        .filter(|path| path.exists() && compressed_path(path).exists())
        .count() as u64;
    match open_catalog(home).and_then(|connection| {
        connection
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(raw_bytes), 0), COALESCE(SUM(compressed_bytes), 0) FROM runtime_storage_manifests",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .map_err(Into::into)
    }) {
        Ok(row) => {
            status.catalog_available = true;
            status.catalog_records = nonnegative(row.0);
            status.catalog_raw_bytes = nonnegative(row.1);
            status.catalog_compressed_bytes = nonnegative(row.2);
        }
        Err(error) => {
            status.catalog_available = false;
            status.catalog_error = Some(format!("{error:#}"));
        }
    }
    let logs = home.join("logs_2.sqlite");
    status.logs_main_bytes = file_len(&logs);
    status.logs_wal_bytes = file_len(&logs.with_file_name("logs_2.sqlite-wal"));
    if logs.exists() {
        match open_readonly(&logs) {
            Ok(connection) => {
                match connection
                    .query_row(
                        "SELECT COUNT(*), COALESCE(SUM(estimated_bytes), 0), COUNT(DISTINCT CASE WHEN thread_id IS NOT NULL THEN thread_id END), COUNT(DISTINCT CASE WHEN thread_id IS NULL THEN COALESCE(process_uuid, '<null-process>') END) FROM logs",
                        [],
                        |row| {
                            Ok((
                                row.get::<_, i64>(0)?,
                                row.get::<_, i64>(1)?,
                                row.get::<_, i64>(2)?,
                                row.get::<_, i64>(3)?,
                            ))
                        },
                    )
                    .map_err(anyhow::Error::from)
                {
                    Ok(row) => {
                        status.logs_available = true;
                        status.logs_rows = nonnegative(row.0);
                        status.logs_estimated_bytes = nonnegative(row.1);
                        status.logs_thread_partitions = nonnegative(row.2);
                        status.logs_process_partitions = nonnegative(row.3);
                    }
                    Err(error) => status.logs_error = Some(format!("{error:#}")),
                }
                match log_observer_state(&connection) {
                    Ok(observer) => {
                        status.logs_measurement_available = true;
                        status.logs_claim_generation = Some(observer.claim_generation);
                        status.logs_completed_generation = Some(observer.completed_generation);
                        status.logs_claim_status = Some(observer.claim_status);
                        status.logs_last_result = Some(observer.last_result);
                        status.logs_measurement_mode = Some(observer.maintenance_mode);
                        status.logs_over_row_budget = Some(observer.over_row_budget);
                        status.logs_over_estimated_byte_budget = Some(observer.over_byte_budget);
                        status.logs_logical_cap_enforced = Some(observer.logical_cap_enforced);
                        status.logs_physical_maintenance_enabled =
                            Some(observer.physical_maintenance_enabled);
                        status.logs_checkpoint_status = Some(observer.checkpoint_status);
                        status.logs_vacuum_status = Some(observer.vacuum_status);
                    }
                    Err(error) => {
                        status.logs_measurement_error = Some(format!("{error:#}"));
                    }
                }
            }
            Err(error) => status.logs_error = Some(format!("{error:#}")),
        }
    } else {
        status.logs_error = Some("logs_2.sqlite is absent".to_string());
        status.logs_measurement_error =
            Some("observe-only maintenance state is unavailable".to_string());
    }
    Ok(status)
}

fn doctor(home: &Path) -> Result<DoctorReport> {
    let mut report = DoctorReport {
        ok: true,
        complete: false,
        checked_catalog_records: 0,
        errors: Vec::new(),
        warnings: Vec::new(),
        mutation_enabled: false,
    };
    if let Err(error) = require_real_home(home) {
        report.errors.push(format!("{error:#}"));
        report.ok = false;
        return Ok(report);
    }
    let (records, catalog_complete) = match all_catalog_records(home) {
        Ok(records) => (records, true),
        Err(error) => {
            report.errors.push(format!("catalog: {error:#}"));
            (Vec::new(), false)
        }
    };
    for record in records {
        report.checked_catalog_records += 1;
        if let Err(error) = verify_record(home, &record) {
            report
                .errors
                .push(format!("thread {}: {error:#}", record.thread_id));
        }
    }
    let logs_complete = verify_log_observer_contract(home, &mut report);
    report.complete = catalog_complete && logs_complete;
    report.ok = report.complete && report.errors.is_empty();
    Ok(report)
}

fn all_catalog_records(home: &Path) -> Result<Vec<CatalogRecord>> {
    let connection = open_catalog(home)?;
    let mut statement = connection.prepare(
        "SELECT thread_id, schema_version, generation, source_host, project, cwd, title, session_created_at, session_updated_at, raw_path, compressed_path, manifest_path, raw_sha256, compressed_sha256, raw_bytes, compressed_bytes, codec, codec_version, restore_verified_at, installed_at, pinned, representation_state
         FROM runtime_storage_manifests
         ORDER BY thread_id",
    )?;
    let rows = statement.query_map([], catalog_from_row)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn list_catalog(
    home: &Path,
    thread_id: Option<&str>,
    project: Option<&str>,
    title: Option<&str>,
    created_from: Option<&str>,
    created_to: Option<&str>,
    limit: u32,
) -> Result<Vec<CatalogRecord>> {
    if let Some(thread_id) = thread_id {
        validate_thread_id(thread_id)?;
    }
    let connection = open_catalog(home)?;
    let mut statement = connection.prepare(
        "SELECT thread_id, schema_version, generation, source_host, project, cwd, title, session_created_at, session_updated_at, raw_path, compressed_path, manifest_path, raw_sha256, compressed_sha256, raw_bytes, compressed_bytes, codec, codec_version, restore_verified_at, installed_at, pinned, representation_state
         FROM runtime_storage_manifests
         WHERE (?1 IS NULL OR thread_id = ?1)
           AND (?2 IS NULL OR project = ?2)
           AND (?3 IS NULL OR title LIKE '%' || ?3 || '%')
           AND (?4 IS NULL OR session_created_at >= ?4)
           AND (?5 IS NULL OR session_created_at <= ?5)
         ORDER BY session_created_at DESC, thread_id
         LIMIT ?6",
    )?;
    let rows = statement.query_map(
        params![thread_id, project, title, created_from, created_to, limit],
        catalog_from_row,
    )?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn catalog_record(home: &Path, thread_id: &str) -> Result<Option<CatalogRecord>> {
    let connection = open_catalog(home)?;
    connection
        .query_row(
            "SELECT thread_id, schema_version, generation, source_host, project, cwd, title, session_created_at, session_updated_at, raw_path, compressed_path, manifest_path, raw_sha256, compressed_sha256, raw_bytes, compressed_bytes, codec, codec_version, restore_verified_at, installed_at, pinned, representation_state FROM runtime_storage_manifests WHERE thread_id = ?1",
            [thread_id],
            catalog_from_row,
        )
        .optional()
        .map_err(Into::into)
}

fn catalog_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CatalogRecord> {
    Ok(CatalogRecord {
        thread_id: row.get(0)?,
        schema_version: row.get(1)?,
        generation: row.get(2)?,
        source_host: row.get(3)?,
        project: row.get(4)?,
        cwd: row.get(5)?,
        title: row.get(6)?,
        session_created_at: row.get(7)?,
        session_updated_at: row.get(8)?,
        raw_path: row.get(9)?,
        compressed_path: row.get(10)?,
        manifest_path: row.get(11)?,
        raw_sha256: row.get(12)?,
        compressed_sha256: row.get(13)?,
        raw_bytes: row.get(14)?,
        compressed_bytes: row.get(15)?,
        codec: row.get(16)?,
        codec_version: row.get(17)?,
        restore_verified_at: row.get(18)?,
        installed_at: row.get(19)?,
        pinned: row.get(20)?,
        representation_state: row.get(21)?,
    })
}

fn verify_record(home: &Path, record: &CatalogRecord) -> Result<Manifest> {
    let manifest_path = checked_catalog_file_path(home, &record.manifest_path)?;
    let manifest: Manifest = serde_json::from_reader(open_regular_nofollow(&manifest_path)?)?;
    if manifest.schema_version != 1
        || manifest.generation != u64::try_from(record.generation).unwrap_or(0)
        || manifest.thread_id != record.thread_id
        || manifest.raw_path != record.raw_path
        || manifest.codec != "zstd"
        || manifest.codec_version != 1
        || !manifest.zstd_frame_checksum
    {
        bail!("unknown or disagreeing manifest version/generation/identity");
    }
    let compressed = checked_catalog_file_path(home, &record.compressed_path)?;
    if compressed != checked_catalog_file_path(home, &manifest.compressed_path)?
        || file_len(&compressed) != manifest.compressed_bytes
        || sha256_file(&compressed)? != manifest.compressed_sha256
        || manifest.compressed_sha256 != record.compressed_sha256
    {
        bail!("compressed representation digest, length, or path mismatch");
    }
    let (decoded_sha, decoded_bytes) = decoded_sha256(&compressed)?;
    if decoded_sha != manifest.raw_sha256
        || decoded_bytes != manifest.raw_bytes
        || manifest.raw_sha256 != record.raw_sha256
        || i64::try_from(manifest.raw_bytes).ok() != Some(record.raw_bytes)
    {
        bail!("decoded representation does not reproduce raw digest and length");
    }
    let raw = checked_catalog_path(home, &record.raw_path)?;
    if let Some(parent) = raw.parent() {
        require_real_ancestors(home, parent)?;
    }
    if raw.exists()
        && (file_len(&raw) != manifest.raw_bytes || sha256_file(&raw)? != manifest.raw_sha256)
    {
        bail!("plain and compressed representations disagree");
    }
    Ok(manifest)
}

fn inventory_tree(
    root: &Path,
    status: &mut RuntimeStorageStatus,
    logical: &mut std::collections::HashSet<PathBuf>,
) -> Result<()> {
    if !root.exists() {
        return Ok(());
    }
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        for entry in std::fs::read_dir(&directory)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                bail!("linked runtime-storage path: {}", entry.path().display());
            }
            if kind.is_dir() {
                stack.push(entry.path());
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".jsonl") {
                status.plain_rollouts += 1;
                status.plain_bytes += file_len(&path);
                logical.insert(path);
            } else if name.ends_with(".jsonl.zst") {
                status.compressed_rollouts += 1;
                status.compressed_bytes += file_len(&path);
                logical.insert(plain_path(&path));
            } else if name.ends_with(".jsonl.zst.manifest.json") {
                status.manifest_files += 1;
            }
        }
    }
    Ok(())
}

fn log_observer_state(connection: &Connection) -> Result<LogObserverState> {
    connection
        .query_row(
            "SELECT claim_generation, completed_generation, claim_status, last_result, maintenance_mode, logical_cap_enforced, physical_maintenance_enabled, checkpoint_status, vacuum_status, over_row_budget, over_byte_budget FROM log_maintenance_state WHERE id = 1",
            [],
            |row| {
                Ok(LogObserverState {
                    claim_generation: row.get(0)?,
                    completed_generation: row.get(1)?,
                    claim_status: row.get(2)?,
                    last_result: row.get(3)?,
                    maintenance_mode: row.get(4)?,
                    logical_cap_enforced: row.get(5)?,
                    physical_maintenance_enabled: row.get(6)?,
                    checkpoint_status: row.get(7)?,
                    vacuum_status: row.get(8)?,
                    over_row_budget: row.get(9)?,
                    over_byte_budget: row.get(10)?,
                })
            },
        )
        .map_err(Into::into)
}

fn verify_log_observer_contract(home: &Path, report: &mut DoctorReport) -> bool {
    let path = home.join("logs_2.sqlite");
    if !path.exists() {
        report
            .warnings
            .push("logs_2.sqlite is absent; log measurements are unavailable".to_string());
        return true;
    }
    let result = open_readonly(&path).and_then(|connection| log_observer_state(&connection));
    match result {
        Ok(state)
            if state.maintenance_mode == "observe_only"
                && !state.logical_cap_enforced
                && !state.physical_maintenance_enabled
                && state.checkpoint_status == "disabled"
                && state.vacuum_status == "disabled" =>
        {
            true
        }
        Ok(state) => {
            report.errors.push(format!(
                "logs: unsafe or ambiguous maintenance state: mode={}, logical_cap_enforced={}, physical_maintenance_enabled={}, checkpoint_status={}, vacuum_status={}",
                state.maintenance_mode,
                state.logical_cap_enforced,
                state.physical_maintenance_enabled,
                state.checkpoint_status,
                state.vacuum_status
            ));
            false
        }
        Err(error) => {
            report
                .errors
                .push(format!("logs maintenance state: {error:#}"));
            false
        }
    }
}

fn resolve_home(value: Option<PathBuf>) -> Result<PathBuf> {
    let value = match value {
        Some(value) => value,
        None => PathBuf::from(std::env::var_os("HOME").context("HOME is unset")?).join(".codex"),
    };
    if !value.is_absolute()
        || value
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        bail!("Codex home must be an absolute traversal-free path");
    }
    Ok(value)
}

fn require_real_home(home: &Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(home)
        .with_context(|| format!("failed to inspect Codex home {}", home.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!("Codex home is linked or not a directory");
    }
    Ok(())
}

fn require_real_ancestors(home: &Path, target: &Path) -> Result<()> {
    let relative = target
        .strip_prefix(home)
        .context("path is outside Codex home")?;
    let mut current = home.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            bail!("invalid path component")
        };
        current.push(name);
        let metadata = std::fs::symlink_metadata(&current)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            bail!("linked or non-directory ancestor: {}", current.display());
        }
    }
    Ok(())
}

fn checked_catalog_path(home: &Path, value: &str) -> Result<PathBuf> {
    let path = PathBuf::from(value);
    if !path.is_absolute()
        || !path.starts_with(home)
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        bail!("catalog path is outside the local runtime root");
    }
    Ok(path)
}

fn checked_catalog_file_path(home: &Path, value: &str) -> Result<PathBuf> {
    let path = checked_catalog_path(home, value)?;
    let parent = path.parent().context("catalog file has no parent")?;
    require_real_ancestors(home, parent)?;
    Ok(path)
}

fn open_catalog(home: &Path) -> Result<Connection> {
    open_readonly(&home.join("state_5.sqlite"))
}

fn open_readonly(path: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.pragma_update(None, "query_only", true)?;
    Ok(connection)
}

fn open_regular_nofollow(path: &Path) -> Result<File> {
    let before = std::fs::symlink_metadata(path)?;
    if before.file_type().is_symlink() || !before.is_file() {
        bail!(
            "runtime-storage file is linked or special: {}",
            path.display()
        );
    }
    #[cfg(unix)]
    if before.nlink() != 1 {
        bail!(
            "runtime-storage file has a hard-link alias: {}",
            path.display()
        );
    }
    #[cfg(unix)]
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    #[cfg(not(unix))]
    let file = File::open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file() {
        bail!("opened runtime-storage descriptor is not a regular file");
    }
    #[cfg(unix)]
    if opened.nlink() != 1
        || before.dev() != opened.dev()
        || before.ino() != opened.ino()
        || before.mode() != opened.mode()
    {
        bail!(
            "runtime-storage path identity changed while opening: {}",
            path.display()
        );
    }
    Ok(file)
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = open_regular_nofollow(path)?;
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        context.update(&buffer[..count]);
    }
    Ok(hex(context.finish().as_ref()))
}

fn decoded_sha256(path: &Path) -> Result<(String, u64)> {
    let input = open_regular_nofollow(path)?;
    let mut decoder = zstd::stream::read::Decoder::new(input)?;
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut total = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = decoder.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        context.update(&buffer[..count]);
        total = total.saturating_add(count as u64);
    }
    Ok((hex(context.finish().as_ref()), total))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn validate_thread_id(value: &str) -> Result<()> {
    let parsed = uuid::Uuid::parse_str(value).context("invalid thread UUID")?;
    if parsed.to_string() != value {
        bail!("thread UUID must use canonical lowercase text");
    }
    Ok(())
}

fn compressed_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".zst");
    path.with_file_name(name)
}

fn plain_path(path: &Path) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(name.strip_suffix(".zst").unwrap_or(name.as_ref()))
}

fn file_len(path: &Path) -> u64 {
    std::fs::symlink_metadata(path)
        .ok()
        .filter(|metadata| metadata.is_file() && !metadata.file_type().is_symlink())
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

fn nonnegative(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

fn print_value(value: &impl Serialize, _json: bool) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    #[test]
    fn out_of_root_and_noncanonical_ids_refuse_before_open() {
        let home = tempfile::tempdir().unwrap();
        assert!(checked_catalog_path(home.path(), "/tmp/live-looking.jsonl").is_err());
        assert!(validate_thread_id("019F5DC3-F317-7F51-A5CA-6B529DD7A15E").is_err());
        assert!(validate_thread_id("../../session").is_err());
    }

    #[test]
    fn support_cli_restore_is_unconditionally_held_before_any_path_access() {
        let error = run(RuntimeStorageCommand::Restore {
            thread_id: "../../must-not-be-validated".to_string(),
            codex_home: Some(PathBuf::from("/synthetic/must-not-be-opened")),
            allow_lossless_restore: true,
            json: true,
        })
        .expect_err("support CLI restore must remain non-executable");
        assert!(
            format!("{error:#}").starts_with("HELD:"),
            "restore must refuse at the command boundary before reading catalog or history paths"
        );
    }

    #[test]
    fn status_exposes_missing_and_invalid_catalogs() {
        let home = tempfile::tempdir().unwrap();
        let missing = status(home.path()).unwrap();
        assert!(!missing.catalog_available);
        assert!(missing.catalog_error.is_some());

        Connection::open(home.path().join("state_5.sqlite")).unwrap();
        let invalid = status(home.path()).unwrap();
        assert!(!invalid.catalog_available);
        assert!(invalid
            .catalog_error
            .as_deref()
            .unwrap_or_default()
            .contains("runtime_storage_manifests"));

        let report = doctor(home.path()).unwrap();
        assert!(!report.ok);
        assert!(!report.complete);
        assert!(!report.errors.is_empty());
    }

    #[test]
    fn status_and_doctor_surface_observe_only_log_contract() {
        let home = tempfile::tempdir().unwrap();
        let catalog = Connection::open(home.path().join("state_5.sqlite")).unwrap();
        catalog
            .execute_batch(
                "CREATE TABLE runtime_storage_manifests (
                    thread_id TEXT PRIMARY KEY, schema_version INTEGER, generation INTEGER,
                    source_host TEXT, project TEXT, cwd TEXT, title TEXT,
                    session_created_at TEXT, session_updated_at TEXT, raw_path TEXT,
                    compressed_path TEXT, manifest_path TEXT, raw_sha256 TEXT,
                    compressed_sha256 TEXT, raw_bytes INTEGER, compressed_bytes INTEGER,
                    codec TEXT, codec_version INTEGER, restore_verified_at INTEGER,
                    installed_at INTEGER, pinned INTEGER, representation_state TEXT
                );",
            )
            .unwrap();
        drop(catalog);
        let logs = Connection::open(home.path().join("logs_2.sqlite")).unwrap();
        logs.execute_batch(
            "CREATE TABLE logs (
                id INTEGER PRIMARY KEY, estimated_bytes INTEGER,
                thread_id TEXT, process_uuid TEXT
            );
            INSERT INTO logs (estimated_bytes, thread_id, process_uuid)
            VALUES (42, 'thread-a', 'process-a');
            CREATE TABLE log_maintenance_state (
                id INTEGER PRIMARY KEY, claim_generation INTEGER,
                completed_generation INTEGER, claim_status TEXT, last_result TEXT,
                maintenance_mode TEXT, logical_cap_enforced INTEGER,
                physical_maintenance_enabled INTEGER, checkpoint_status TEXT,
                vacuum_status TEXT, over_row_budget INTEGER, over_byte_budget INTEGER
            );
            INSERT INTO log_maintenance_state VALUES
                (1, 3, 3, 'idle', 'measurement_complete', 'observe_only',
                 0, 0, 'disabled', 'disabled', 0, 0);",
        )
        .unwrap();
        drop(logs);

        let status = status(home.path()).unwrap();
        assert!(status.logs_available);
        assert!(status.logs_measurement_available);
        assert_eq!(status.logs_rows, 1);
        assert_eq!(status.logs_estimated_bytes, 42);
        assert_eq!(
            status.logs_measurement_mode.as_deref(),
            Some("observe_only")
        );
        assert_eq!(status.logs_logical_cap_enforced, Some(false));
        assert_eq!(status.logs_physical_maintenance_enabled, Some(false));
        assert_eq!(status.logs_checkpoint_status.as_deref(), Some("disabled"));
        assert_eq!(status.logs_vacuum_status.as_deref(), Some("disabled"));
        assert!(!status.logs_wal_ceiling_enforced);

        let report = doctor(home.path()).unwrap();
        assert!(report.complete);
        assert!(report.ok);
    }

    #[test]
    fn doctor_detects_corruption_after_row_one_thousand() {
        let home = tempfile::tempdir().unwrap();
        let directory = home.path().join("archived_sessions");
        std::fs::create_dir_all(&directory).unwrap();
        let compressed = directory.join("shared-synthetic.jsonl.zst");
        let raw_bytes = b"synthetic durable history\n";
        let output = File::create(&compressed).unwrap();
        let mut encoder = zstd::stream::write::Encoder::new(output, 3).unwrap();
        encoder.include_checksum(true).unwrap();
        encoder.write_all(raw_bytes).unwrap();
        encoder.finish().unwrap().sync_all().unwrap();
        let raw_sha = hex(ring::digest::digest(&ring::digest::SHA256, raw_bytes).as_ref());
        let compressed_sha = sha256_file(&compressed).unwrap();
        let compressed_bytes = file_len(&compressed);

        let connection = Connection::open(home.path().join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE runtime_storage_manifests (
                    thread_id TEXT PRIMARY KEY, schema_version INTEGER, generation INTEGER,
                    source_host TEXT, project TEXT, cwd TEXT, title TEXT,
                    session_created_at TEXT, session_updated_at TEXT, raw_path TEXT,
                    compressed_path TEXT, manifest_path TEXT, raw_sha256 TEXT,
                    compressed_sha256 TEXT, raw_bytes INTEGER, compressed_bytes INTEGER,
                    codec TEXT, codec_version INTEGER, restore_verified_at INTEGER,
                    installed_at INTEGER, pinned INTEGER, representation_state TEXT
                );",
            )
            .unwrap();
        for index in 0..=1000 {
            let thread_id = format!("00000000-0000-4000-8000-{index:012}");
            let raw = directory.join(format!("{thread_id}.jsonl"));
            let manifest_path = directory.join(format!("{thread_id}.manifest.json"));
            let manifest_raw_sha = if index == 1000 {
                "0".repeat(64)
            } else {
                raw_sha.clone()
            };
            let manifest = serde_json::json!({
                "schema_version": 1,
                "generation": 1,
                "thread_id": thread_id,
                "raw_path": raw,
                "compressed_path": compressed,
                "raw_sha256": manifest_raw_sha,
                "compressed_sha256": compressed_sha,
                "raw_bytes": raw_bytes.len(),
                "compressed_bytes": compressed_bytes,
                "codec": "zstd",
                "codec_version": 1,
                "zstd_frame_checksum": true
            });
            std::fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
            connection
                .execute(
                    "INSERT INTO runtime_storage_manifests VALUES (?1,1,1,'synthetic-host',NULL,NULL,NULL,NULL,NULL,?2,?3,?4,?5,?6,?7,?8,'zstd',1,1,1,0,'compressed_verified')",
                    params![
                        thread_id,
                        raw.display().to_string(),
                        compressed.display().to_string(),
                        manifest_path.display().to_string(),
                        manifest_raw_sha,
                        compressed_sha,
                        raw_bytes.len() as i64,
                        compressed_bytes as i64,
                    ],
                )
                .unwrap();
        }
        drop(connection);

        let report = doctor(home.path()).unwrap();
        assert!(report.complete);
        assert!(!report.ok);
        assert_eq!(report.checked_catalog_records, 1001);
        assert_eq!(report.errors.len(), 1);
        assert!(report.errors[0].contains("00000000-0000-4000-8000-000000001000"));
    }
}
