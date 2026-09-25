use crate::activation::RuntimeActivationLease;
use crate::secure_file::{self, SecureFileLock, SecureFileSnapshot};
use crate::CredentialImportReceipt;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const VERSION: u32 = 1;
const MAX_OPERATIONS: usize = 1024;
const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_RECEIPT_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Pending,
    Completed,
    Missing,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    scope_fingerprint: String,
    state: State,
    receipt: CredentialImportReceipt,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ledger {
    version: u32,
    records: Vec<Record>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub version: u32,
    pub operation_id: Uuid,
    pub status: State,
    pub receipt: Option<CredentialImportReceipt>,
}

pub fn parse_fingerprint(value: &str) -> std::result::Result<String, String> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(value.to_string())
    } else {
        Err("expected a lowercase SHA-256 fingerprint".to_string())
    }
}

fn ledger_path(store_path: &Path) -> Result<PathBuf> {
    let mut name = store_path
        .file_name()
        .context("account store filename is missing")?
        .to_os_string();
    name.push(".credential-import-receipts.json");
    Ok(store_path.with_file_name(name))
}

fn scope_fingerprint(store_path: &Path, auth_path: &Path) -> Result<String> {
    use std::os::unix::ffi::OsStrExt;
    let cwd = std::env::current_dir()?;
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    for path in [store_path, auth_path] {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            cwd.join(path)
        };
        let bytes = absolute.as_os_str().as_bytes();
        context.update(&(bytes.len() as u64).to_be_bytes());
        context.update(bytes);
    }
    Ok(crate::hex_digest(context.finish().as_ref()))
}

fn validate_receipt(receipt: &CredentialImportReceipt) -> Result<()> {
    for value in [
        &receipt.baseline_credential_set_fingerprint,
        &receipt.incoming_credential_set_fingerprint,
        &receipt.committed_credential_set_fingerprint,
        &receipt.committed_account_identity_fingerprint,
    ] {
        if parse_fingerprint(value).is_err() {
            bail!("invalid credential import receipt fingerprint");
        }
    }
    let selections = &receipt.credential_selections;
    if receipt.version != VERSION
        || receipt.account_count == 0
        || receipt.account_count != selections.len()
        || receipt.active_token_hash_prefix.len() != 12
        || !receipt
            .active_token_hash_prefix
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || selections
            .iter()
            .any(|s| s.provider_account_id.is_empty() || s.provider_account_id.len() > 256)
        || selections
            .windows(2)
            .any(|pair| pair[0].provider_account_id >= pair[1].provider_account_id)
        || !selections
            .iter()
            .any(|s| s.provider_account_id == receipt.active_provider_account_id)
        || serde_json::to_vec(receipt)?.len() > MAX_RECEIPT_BYTES
    {
        bail!("invalid credential import receipt shape");
    }
    Ok(())
}

fn decode(snapshot: &SecureFileSnapshot) -> Result<Ledger> {
    let Some(bytes) = snapshot.bytes() else {
        return Ok(Ledger {
            version: VERSION,
            records: Vec::new(),
        });
    };
    // Do not propagate a parser error that could echo untrusted file contents.
    let ledger: Ledger = serde_json::from_slice(bytes)
        .map_err(|_| anyhow::anyhow!("invalid credential import receipt ledger"))?;
    if ledger.version != VERSION || ledger.records.len() > MAX_OPERATIONS {
        bail!("unsupported or oversized credential import receipt ledger");
    }
    let mut ids = std::collections::HashSet::new();
    for record in &ledger.records {
        validate_receipt(&record.receipt)?;
        if record.state == State::Missing
            || parse_fingerprint(&record.scope_fingerprint).is_err()
            || !ids.insert(record.receipt.operation_id)
        {
            bail!("invalid credential import receipt record");
        }
    }
    Ok(ledger)
}

/// Observation deliberately avoids the mutation lock, directory creation and cleanup.
pub fn observe(
    store_path: &Path,
    auth_path: &Path,
    operation_id: Uuid,
    baseline: &str,
    incoming: &str,
) -> Result<Status> {
    if parse_fingerprint(baseline).is_err() || parse_fingerprint(incoming).is_err() {
        bail!("invalid credential import status binding");
    }
    let snapshot = secure_file::observe(&ledger_path(store_path)?, MAX_BYTES, true)?;
    let ledger = decode(&snapshot)?;
    let Some(record) = ledger
        .records
        .iter()
        .find(|r| r.receipt.operation_id == operation_id)
    else {
        return Ok(Status {
            version: VERSION,
            operation_id,
            status: State::Missing,
            receipt: None,
        });
    };
    if record.scope_fingerprint != scope_fingerprint(store_path, auth_path)?
        || record.receipt.baseline_credential_set_fingerprint != baseline
        || record.receipt.incoming_credential_set_fingerprint != incoming
    {
        bail!("credential import status operation binding mismatch");
    }
    Ok(Status {
        version: VERSION,
        operation_id,
        status: record.state,
        receipt: (record.state == State::Completed).then(|| record.receipt.clone()),
    })
}

pub struct Journal {
    lock: SecureFileLock,
    snapshot: SecureFileSnapshot,
    ledger: Ledger,
    scope: String,
    operation_id: Uuid,
    incoming: String,
}

impl Journal {
    pub fn acquire(
        lease: &RuntimeActivationLease,
        store_path: &Path,
        auth_path: &Path,
        operation_id: Uuid,
        incoming: &str,
    ) -> Result<Self> {
        lease.require_store(store_path)?;
        let lock = secure_file::lock(&ledger_path(store_path)?, false)?;
        let snapshot = lock.load(MAX_BYTES, true)?;
        let ledger = decode(&snapshot)?;
        let scope = scope_fingerprint(store_path, auth_path)?;
        if let Some(record) = ledger
            .records
            .iter()
            .find(|r| r.receipt.operation_id == operation_id)
        {
            if record.scope_fingerprint != scope
                || record.receipt.incoming_credential_set_fingerprint != incoming
            {
                bail!("credential import operation binding mismatch");
            }
            bail!("credential import operation already recorded; use credential-import-status without reimporting");
        }
        if ledger.records.iter().any(|r| r.state == State::Pending) {
            bail!("an unresolved credential import intent requires review");
        }
        if ledger.records.len() >= MAX_OPERATIONS {
            bail!("credential import receipt capacity exhausted; reviewed retention required");
        }
        Ok(Self {
            lock,
            snapshot,
            ledger,
            scope,
            operation_id,
            incoming: incoming.to_string(),
        })
    }

    pub fn prepare(&mut self, receipt: &CredentialImportReceipt) -> Result<()> {
        validate_receipt(receipt)?;
        if receipt.operation_id != self.operation_id
            || receipt.incoming_credential_set_fingerprint != self.incoming
        {
            bail!("credential import intent binding mismatch");
        }
        if self
            .ledger
            .records
            .iter()
            .any(|r| r.receipt.operation_id == receipt.operation_id)
        {
            bail!("credential import operation already recorded");
        }
        self.ledger.records.push(Record {
            scope_fingerprint: self.scope.clone(),
            state: State::Pending,
            receipt: receipt.clone(),
        });
        // Reserve the completion encoding before permitting the account mutation.
        let last = self.ledger.records.len() - 1;
        self.ledger.records[last].state = State::Completed;
        let completed_size = serde_json::to_vec(&self.ledger)?.len();
        self.ledger.records[last].state = State::Pending;
        if completed_size > MAX_BYTES {
            bail!("credential import receipt byte capacity exhausted");
        }
        self.persist()
    }

    pub fn complete(&mut self, receipt: &CredentialImportReceipt) -> Result<()> {
        let record = self
            .ledger
            .records
            .iter_mut()
            .find(|r| r.receipt.operation_id == receipt.operation_id)
            .context("credential import intent is missing")?;
        if record.receipt != *receipt || record.state != State::Pending {
            bail!("credential import completion does not match its intent");
        }
        record.state = State::Completed;
        self.persist()
    }

    fn persist(&mut self) -> Result<()> {
        let bytes = serde_json::to_vec(&self.ledger)?;
        self.snapshot = self
            .lock
            .commit(self.snapshot.generation(), &bytes, MAX_BYTES)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CredentialGeneration, CredentialImportSelection};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn private_temp() -> Result<TempDir> {
        let temp = TempDir::new()?;
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700))?;
        Ok(temp)
    }

    fn receipt() -> CredentialImportReceipt {
        CredentialImportReceipt {
            version: VERSION,
            operation_id: Uuid::new_v4(),
            account_count: 1,
            baseline_credential_set_fingerprint: "1".repeat(64),
            incoming_credential_set_fingerprint: "2".repeat(64),
            committed_credential_set_fingerprint: "2".repeat(64),
            committed_account_identity_fingerprint: "3".repeat(64),
            active_provider_account_id: "fixture-provider".into(),
            active_token_hash_prefix: "4".repeat(12),
            credential_selections: vec![CredentialImportSelection {
                provider_account_id: "fixture-provider".into(),
                generation: CredentialGeneration::Incoming,
            }],
        }
    }

    fn status(store: &Path, auth: &Path, receipt: &CredentialImportReceipt) -> Result<Status> {
        observe(
            store,
            auth,
            receipt.operation_id,
            &receipt.baseline_credential_set_fingerprint,
            &receipt.incoming_credential_set_fingerprint,
        )
    }

    #[test]
    fn missing_status_is_read_only_and_not_a_nonexecution_claim() -> Result<()> {
        let temp = private_temp()?;
        let before = fs::read_dir(temp.path())?.count();
        let result = status(
            &temp.path().join("accounts.json"),
            &temp.path().join("auth.json"),
            &receipt(),
        )?;
        assert_eq!(result.status, State::Missing);
        assert!(result.receipt.is_none());
        assert_eq!(fs::read_dir(temp.path())?.count(), before);
        Ok(())
    }

    #[test]
    fn lost_reply_replays_history_after_current_files_disappear() -> Result<()> {
        let temp = private_temp()?;
        let store = temp.path().join("accounts.json");
        let auth = temp.path().join("auth.json");
        let receipt = receipt();
        let lease = crate::activation::acquire_runtime_activation_lease(&store)?;
        let mut journal = Journal::acquire(
            &lease,
            &store,
            &auth,
            receipt.operation_id,
            &receipt.incoming_credential_set_fingerprint,
        )?;
        journal.prepare(&receipt)?;
        journal.complete(&receipt)?;
        drop(journal);
        drop(lease);

        // Status requires neither current credentials, auth nor a runtime reload.
        let path = ledger_path(&store)?;
        let bytes = fs::read(&path)?;
        let first = status(&store, &auth, &receipt)?;
        assert_eq!(first.status, State::Completed);
        assert_eq!(first.receipt, Some(receipt.clone()));
        assert_eq!(first, status(&store, &auth, &receipt)?);
        assert_eq!(bytes, fs::read(&path)?);
        for forbidden in ["accessToken", "refreshToken", "idToken", "passphrase", "@"] {
            assert!(!String::from_utf8(bytes.clone())?.contains(forbidden));
        }
        assert!(status(&store, &temp.path().join("other-auth.json"), &receipt).is_err());
        let mut wrong = receipt.clone();
        wrong.baseline_credential_set_fingerprint = "5".repeat(64);
        assert!(status(&store, &auth, &wrong).is_err());
        wrong = receipt.clone();
        wrong.incoming_credential_set_fingerprint = "6".repeat(64);
        assert!(status(&store, &auth, &wrong).is_err());
        let lease = crate::activation::acquire_runtime_activation_lease(&store)?;
        assert!(Journal::acquire(
            &lease,
            &store,
            &auth,
            receipt.operation_id,
            &receipt.incoming_credential_set_fingerprint
        )
        .is_err());
        assert_eq!(bytes, fs::read(&path)?);
        Ok(())
    }

    #[test]
    fn crash_after_intent_never_publishes_a_success_receipt_or_reimports() -> Result<()> {
        let temp = private_temp()?;
        let store = temp.path().join("accounts.json");
        let auth = temp.path().join("auth.json");
        let receipt = receipt();
        let lease = crate::activation::acquire_runtime_activation_lease(&store)?;
        let mut journal = Journal::acquire(
            &lease,
            &store,
            &auth,
            receipt.operation_id,
            &receipt.incoming_credential_set_fingerprint,
        )?;
        journal.prepare(&receipt)?;
        drop(journal);
        let result = status(&store, &auth, &receipt)?;
        assert_eq!(result.status, State::Pending);
        assert!(result.receipt.is_none());
        assert!(Journal::acquire(
            &lease,
            &store,
            &auth,
            receipt.operation_id,
            &receipt.incoming_credential_set_fingerprint
        )
        .is_err());
        assert!(Journal::acquire(
            &lease,
            &store,
            &auth,
            Uuid::new_v4(),
            &receipt.incoming_credential_set_fingerprint
        )
        .is_err());
        Ok(())
    }

    #[test]
    fn preparation_and_completion_require_exact_bindings() -> Result<()> {
        let temp = private_temp()?;
        let store = temp.path().join("accounts.json");
        let auth = temp.path().join("auth.json");
        let receipt = receipt();
        let lease = crate::activation::acquire_runtime_activation_lease(&store)?;
        let mut journal = Journal::acquire(
            &lease,
            &store,
            &auth,
            receipt.operation_id,
            &receipt.incoming_credential_set_fingerprint,
        )?;
        let mut wrong = receipt.clone();
        wrong.operation_id = Uuid::new_v4();
        assert!(journal.prepare(&wrong).is_err());
        journal.prepare(&receipt)?;
        wrong = receipt.clone();
        wrong.committed_credential_set_fingerprint = "7".repeat(64);
        assert!(journal.complete(&wrong).is_err());
        assert_eq!(status(&store, &auth, &receipt)?.status, State::Pending);
        Ok(())
    }

    #[test]
    fn capacity_refuses_new_operations_without_evicting_replay_history() -> Result<()> {
        let temp = private_temp()?;
        let store = temp.path().join("accounts.json");
        let auth = temp.path().join("auth.json");
        let scope = scope_fingerprint(&store, &auth)?;
        let ledger = Ledger {
            version: VERSION,
            records: (0..MAX_OPERATIONS)
                .map(|_| Record {
                    scope_fingerprint: scope.clone(),
                    state: State::Completed,
                    receipt: receipt(),
                })
                .collect(),
        };
        let path = ledger_path(&store)?;
        let lock = secure_file::lock(&path, false)?;
        let snapshot = lock.load(MAX_BYTES, true)?;
        let bytes = serde_json::to_vec(&ledger)?;
        lock.commit(snapshot.generation(), &bytes, MAX_BYTES)?;
        drop(lock);
        let lease = crate::activation::acquire_runtime_activation_lease(&store)?;
        assert!(Journal::acquire(&lease, &store, &auth, Uuid::new_v4(), &"2".repeat(64)).is_err());
        assert_eq!(fs::read(&path)?, bytes);
        assert_eq!(
            status(&store, &auth, &ledger.records[0].receipt)?.status,
            State::Completed
        );
        Ok(())
    }

    #[test]
    fn malformed_unknown_fields_and_symlinks_fail_closed() -> Result<()> {
        let temp = private_temp()?;
        let store = temp.path().join("accounts.json");
        let auth = temp.path().join("auth.json");
        let path = ledger_path(&store)?;
        let lock = secure_file::lock(&path, false)?;
        let snapshot = lock.load(MAX_BYTES, true)?;
        lock.commit(
            snapshot.generation(),
            br#"{"version":1,"records":[],"accessToken":"fixture-secret"}"#,
            MAX_BYTES,
        )?;
        drop(lock);
        let error = status(&store, &auth, &receipt()).unwrap_err();
        assert!(!format!("{error:#}").contains("fixture-secret"));
        fs::remove_file(&path)?;
        std::os::unix::fs::symlink(temp.path().join("missing"), &path)?;
        assert!(status(&store, &auth, &receipt()).is_err());
        Ok(())
    }
}
