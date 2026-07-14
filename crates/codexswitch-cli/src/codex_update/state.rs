#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatus {
    Idle,
    Checking,
    Preparing,
    Installing,
    ReadyToInstall,
    Installed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexUpdateState {
    pub status: UpdateStatus,
    pub last_checked_at: Option<DateTime<Utc>>,
    pub latest_stable_version: Option<String>,
    pub installed_version: Option<String>,
    #[serde(default)]
    pub installed_artifact_manifest_sha256: Option<String>,
    pub prepared_version: Option<String>,
    pub prepared_source_path: Option<String>,
    pub prepared_binary_path: Option<String>,
    #[serde(default)]
    pub prepared_artifact_manifest_sha256: Option<String>,
    #[serde(default)]
    pub failed_prepare_version: Option<String>,
    #[serde(default)]
    pub prepare_retry_not_before: Option<DateTime<Utc>>,
    #[serde(default)]
    pub failed_install_version: Option<String>,
    #[serde(default)]
    pub install_retry_not_before: Option<DateTime<Utc>>,
    #[serde(default)]
    pub cleanup_pending_target_path: Option<String>,
    #[serde(default)]
    unresolved_failure: Option<UnresolvedUpdateFailure>,
    #[serde(default)]
    install_transaction: Option<InstallTransactionState>,
    pub error: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct UnresolvedUpdateFailure {
    #[serde(default = "default_failure_kind")]
    kind: UpdateFailureKind,
    error: String,
    failed_at: DateTime<Utc>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    transaction_id: Option<String>,
    failed_prepare_version: Option<String>,
    prepare_retry_not_before: Option<DateTime<Utc>>,
    failed_install_version: Option<String>,
    install_retry_not_before: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum UpdateFailureKind {
    Metadata,
    Preparation,
    Installation,
    Activation,
}

fn default_failure_kind() -> UpdateFailureKind {
    // Legacy untyped failures are preserved as activation failures so an
    // installed-file observation can never silently clear them.
    UpdateFailureKind::Activation
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct InstallTransactionState {
    id: String,
    version: String,
    phase: InstallTransactionStatePhase,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum InstallTransactionStatePhase {
    Interruptible,
    Committed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexUpdateReport {
    pub status: UpdateStatus,
    pub summary: String,
    pub last_checked_at: Option<DateTime<Utc>>,
    pub latest_stable_version: Option<String>,
    pub installed_version: Option<String>,
    pub installed_artifact_manifest_sha256: Option<String>,
    pub prepared_version: Option<String>,
    pub prepared_source_path: Option<String>,
    pub prepared_binary_path: Option<String>,
    pub prepared_artifact_manifest_sha256: Option<String>,
    pub failed_prepare_version: Option<String>,
    pub prepare_retry_not_before: Option<DateTime<Utc>>,
    pub failed_install_version: Option<String>,
    pub install_retry_not_before: Option<DateTime<Utc>>,
    pub cleanup_pending_target_path: Option<String>,
    pub install_command: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NpmLatest {
    version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum AutomaticUpdateDecision {
    None,
    CheckStableChannel,
    PrepareStableVersion(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HostPlatform {
    MacOs,
    Linux,
    Other,
}

impl HostPlatform {
    fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOs
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Other
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AutomaticUpdatePolicy {
    MetadataOnly,
    PrepareOnly,
}

impl AutomaticUpdatePolicy {
    fn for_platform(platform: HostPlatform) -> Self {
        match platform {
            HostPlatform::Linux => Self::PrepareOnly,
            HostPlatform::MacOs | HostPlatform::Other => Self::MetadataOnly,
        }
    }

    fn permits_preparation(self, platform: HostPlatform) -> bool {
        self == Self::PrepareOnly && platform == HostPlatform::Linux
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AutomaticUpdateContext {
    platform: HostPlatform,
    policy: AutomaticUpdatePolicy,
    available_bytes: u64,
}

impl AutomaticUpdateContext {
    fn current(available_bytes: u64) -> Self {
        let platform = HostPlatform::current();
        Self {
            platform,
            policy: AutomaticUpdatePolicy::for_platform(platform),
            available_bytes,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RuntimeActivityObservation {
    Inactive,
    Active,
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ExactManagedProcessObservation {
    Unrelated,
    Active,
    IdentityDrift(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommandProbeOutput {
    success: bool,
    exit_code: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SystemdOwnerExpectation {
    fragment_path: PathBuf,
    exec_argv: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedDaemonPidRecord {
    pid: u32,
    process_start_time: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ManagedRuntimeActivity {
    systemd_unit: RuntimeActivityObservation,
    app_server_daemon: RuntimeActivityObservation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum OfflineInstallOutcome {
    Installed,
    Staged(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExistingPreparedRuntimeDisposition {
    Absent,
    Reused,
    ClearedInvalid,
}

struct UpdaterOperationLock {
    #[cfg(unix)]
    file: fs::File,
    #[cfg(not(unix))]
    directory: PathBuf,
}
