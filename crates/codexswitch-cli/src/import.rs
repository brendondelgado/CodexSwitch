use crate::account_store::{
    lock_account_store, prefer_highest_usable_plan_active, save_accounts, CodexAccount,
    LinuxBundleMetadata,
};
use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use chrono::Utc;
use ring::aead;
use ring::digest;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use tar::Archive;

pub fn import_bundle(
    bundle_path: &Path,
    store_path: &Path,
    ignore_expiry: bool,
) -> Result<Vec<CodexAccount>> {
    let (metadata, mut accounts) = read_bundle(bundle_path)?;
    if metadata.schema_version != 1 {
        bail!(
            "unsupported bundle schema version {}",
            metadata.schema_version
        );
    }
    if !ignore_expiry && metadata.expires_at < Utc::now() {
        bail!(
            "bundle expired at {}; pass --ignore-expiry only if you intentionally trust this file",
            metadata.expires_at
        );
    }
    if metadata.account_count != accounts.len() {
        bail!(
            "bundle metadata account count {} does not match payload count {}",
            metadata.account_count,
            accounts.len()
        );
    }
    prefer_highest_usable_plan_active(&mut accounts);
    let _store_lock = lock_account_store(store_path)?;
    save_accounts(store_path, &accounts)?;
    Ok(accounts)
}

fn read_bundle(path: &Path) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    match extension {
        "age" => unpack_bundle(&decrypt_age_bundle(path)?),
        "csbundle" => unpack_csbundle_payload(&decrypt_csbundle(path)?),
        _ => {
            let bundle_bytes =
                fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
            unpack_bundle(&bundle_bytes)
        }
    }
}

#[derive(Debug, serde::Deserialize)]
struct EncryptedBundle {
    format: String,
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    kdf: String,
    cipher: String,
    salt: String,
    nonce: String,
    ciphertext: String,
}

fn decrypt_csbundle(path: &Path) -> Result<Vec<u8>> {
    let data = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let bundle: EncryptedBundle =
        serde_json::from_slice(&data).context("failed to decode .csbundle JSON")?;
    if bundle.format != "codexswitch-linux-devbox-bundle"
        || bundle.schema_version != 1
        || bundle.kdf != "sha256-passphrase-salt-v1"
        || bundle.cipher != "aes-256-gcm"
    {
        bail!("unsupported encrypted bundle format");
    }

    let passphrase = read_passphrase()?;
    let base64 = base64::engine::general_purpose::STANDARD;
    let salt = base64
        .decode(bundle.salt)
        .context("failed to decode bundle salt")?;
    let nonce_bytes = base64
        .decode(bundle.nonce)
        .context("failed to decode bundle nonce")?;
    let mut ciphertext = base64
        .decode(bundle.ciphertext)
        .context("failed to decode bundle ciphertext")?;

    let mut key_input = Vec::from(passphrase.as_bytes());
    key_input.extend_from_slice(&salt);
    let digest = digest::digest(&digest::SHA256, &key_input);
    let key = aead::UnboundKey::new(&aead::AES_256_GCM, digest.as_ref())
        .map_err(|_| anyhow!("failed to create AES key"))?;
    let key = aead::LessSafeKey::new(key);
    let nonce = aead::Nonce::try_assume_unique_for_key(&nonce_bytes)
        .map_err(|_| anyhow!("invalid bundle nonce"))?;
    let plaintext = key
        .open_in_place(nonce, aead::Aad::empty(), &mut ciphertext)
        .map_err(|_| anyhow!("failed to decrypt bundle; check passphrase"))?;
    Ok(plaintext.to_vec())
}

#[derive(Debug, serde::Deserialize)]
struct CsbundlePayload {
    metadata: LinuxBundleMetadata,
    accounts: Vec<CodexAccount>,
}

fn unpack_csbundle_payload(
    payload_bytes: &[u8],
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    let payload: CsbundlePayload = serde_json::from_slice(payload_bytes)
        .context("failed to decode decrypted .csbundle payload")?;
    Ok((payload.metadata, payload.accounts))
}

fn read_passphrase() -> Result<String> {
    if let Some(path) = std::env::var_os("CODEXSWITCH_IMPORT_PASSPHRASE_FILE") {
        let passphrase = fs::read_to_string(&path).with_context(|| {
            format!(
                "failed to read passphrase file {}",
                Path::new(&path).display()
            )
        })?;
        return Ok(passphrase.trim_end_matches(['\r', '\n']).to_string());
    }
    eprint!("Bundle passphrase: ");
    if let Ok(tty) = fs::File::open("/dev/tty") {
        let mut passphrase = String::new();
        BufReader::new(tty)
            .read_line(&mut passphrase)
            .context("failed to read passphrase from /dev/tty")?;
        return Ok(passphrase.trim_end_matches(['\r', '\n']).to_string());
    }
    let mut passphrase = String::new();
    std::io::stdin()
        .read_line(&mut passphrase)
        .context("failed to read passphrase")?;
    Ok(passphrase.trim_end_matches(['\r', '\n']).to_string())
}

fn decrypt_age_bundle(path: &Path) -> Result<Vec<u8>> {
    let mut child = Command::new("age")
        .arg("-d")
        .arg(path)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| {
            format!(
                "failed to run age; install age on the devbox or pass an unencrypted test bundle: {}",
                path.display()
            )
        })?;
    let mut stdout = child
        .stdout
        .take()
        .context("failed to capture age stdout")?;
    let mut decrypted = Vec::new();
    stdout
        .read_to_end(&mut decrypted)
        .context("failed to read decrypted bundle")?;
    let status = child.wait().context("failed to wait for age")?;
    if !status.success() {
        bail!("age failed to decrypt {}", path.display());
    }
    Ok(decrypted)
}

fn unpack_bundle(bundle_bytes: &[u8]) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    let mut archive = Archive::new(bundle_bytes);
    let mut metadata: Option<LinuxBundleMetadata> = None;
    let mut accounts: Option<Vec<CodexAccount>> = None;

    for entry in archive.entries().context("failed to read bundle tar")? {
        let mut entry = entry.context("failed to read tar entry")?;
        let path = entry
            .path()
            .context("failed to read tar entry path")?
            .to_string_lossy()
            .to_string();
        let mut contents = Vec::new();
        entry
            .read_to_end(&mut contents)
            .with_context(|| format!("failed to read tar entry {path}"))?;

        match path.as_str() {
            "metadata.json" => {
                metadata = Some(
                    serde_json::from_slice(&contents).context("failed to decode metadata.json")?,
                );
            }
            "accounts.json" => {
                accounts = Some(
                    serde_json::from_slice(&contents).context("failed to decode accounts.json")?,
                );
            }
            _ => {}
        }
    }

    Ok((
        metadata.ok_or_else(|| anyhow!("bundle missing metadata.json"))?,
        accounts.ok_or_else(|| anyhow!("bundle missing accounts.json"))?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use chrono::Duration;
    use ring::{aead, digest};
    use serde_json::json;
    use std::io::Write;
    use tar::{Builder, Header};
    use tempfile::tempdir;
    use uuid::Uuid;

    #[test]
    fn imports_tar_bundle_into_account_store() {
        let dir = tempdir().unwrap();
        let bundle_path = dir.path().join("bundle.tar");
        let store_path = dir.path().join("accounts.json");
        let account_id = Uuid::new_v4();
        let accounts = json!([
          {
            "id": account_id,
            "email": "dev@example.com",
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": "id-token",
            "accountId": "acct_1",
            "quotaSnapshot": null,
            "planType": "plus",
            "lastRefreshed": null,
            "subscriptionRenewsAt": null,
            "subscriptionExpiresAt": null,
            "subscriptionWillRenew": null,
            "hasActiveSubscription": true,
            "fiveHourPrimedAt": null,
            "isActive": true
          }
        ]);
        let metadata = json!({
          "schemaVersion": 1,
          "createdAt": Utc::now(),
          "expiresAt": Utc::now() + Duration::minutes(30),
          "exportedByHost": "test-host",
          "accountCount": 1,
          "activeAccountId": "acct_1",
          "emails": ["dev@example.com"]
        });

        let file = fs::File::create(&bundle_path).unwrap();
        let mut builder = Builder::new(file);
        append_json(&mut builder, "metadata.json", &metadata);
        append_json(&mut builder, "accounts.json", &accounts);
        builder.finish().unwrap();

        let imported = import_bundle(&bundle_path, &store_path, false).unwrap();
        assert_eq!(imported.len(), 1);
        assert_eq!(imported[0].email, "dev@example.com");
        assert!(store_path.exists());
    }

    #[test]
    fn imports_encrypted_csbundle_payload_into_account_store() {
        let dir = tempdir().unwrap();
        let bundle_path = dir.path().join("bundle.csbundle");
        let passphrase_path = dir.path().join("passphrase.txt");
        let store_path = dir.path().join("accounts.json");
        let account_id = Uuid::new_v4();
        let passphrase = "long-test-passphrase";
        fs::write(&passphrase_path, passphrase).unwrap();
        std::env::set_var("CODEXSWITCH_IMPORT_PASSPHRASE_FILE", &passphrase_path);

        let payload = json!({
          "metadata": {
            "schemaVersion": 1,
            "createdAt": Utc::now(),
            "expiresAt": Utc::now() + Duration::minutes(30),
            "exportedByHost": "test-host",
            "accountCount": 1,
            "activeAccountId": null,
            "activeEmail": "dev@example.com",
            "emails": ["dev@example.com"]
          },
          "accounts": [
            {
              "id": account_id,
              "email": "dev@example.com",
              "accessToken": "access-token",
              "refreshToken": "refresh-token",
              "idToken": "id-token",
              "accountId": "acct_1",
              "quotaSnapshot": null,
              "planType": "plus",
              "lastRefreshed": null,
              "subscriptionRenewsAt": null,
              "subscriptionExpiresAt": null,
              "subscriptionWillRenew": null,
              "hasActiveSubscription": true,
              "fiveHourPrimedAt": null,
              "isActive": true
            }
          ]
        });
        let encrypted =
            encrypt_csbundle_payload(passphrase, &serde_json::to_vec(&payload).unwrap());
        fs::write(&bundle_path, serde_json::to_vec(&encrypted).unwrap()).unwrap();

        let imported = import_bundle(&bundle_path, &store_path, false).unwrap();
        std::env::remove_var("CODEXSWITCH_IMPORT_PASSPHRASE_FILE");

        assert_eq!(imported.len(), 1);
        assert_eq!(imported[0].email, "dev@example.com");
        assert_eq!(imported[0].access_token, "access-token");
        assert!(store_path.exists());
    }

    fn encrypt_csbundle_payload(passphrase: &str, payload: &[u8]) -> serde_json::Value {
        let salt = b"01234567890123456789012345678901";
        let nonce_bytes = b"unique nonce";
        let mut key_input = Vec::from(passphrase.as_bytes());
        key_input.extend_from_slice(salt);
        let digest = digest::digest(&digest::SHA256, &key_input);
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, digest.as_ref()).unwrap();
        let key = aead::LessSafeKey::new(key);
        let nonce = aead::Nonce::try_assume_unique_for_key(nonce_bytes).unwrap();
        let mut ciphertext = payload.to_vec();
        key.seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut ciphertext)
            .unwrap();
        let base64 = base64::engine::general_purpose::STANDARD;
        json!({
          "format": "codexswitch-linux-devbox-bundle",
          "schemaVersion": 1,
          "kdf": "sha256-passphrase-salt-v1",
          "cipher": "aes-256-gcm",
          "metadata": {
            "schemaVersion": 1,
            "createdAt": Utc::now(),
            "expiresAt": Utc::now() + Duration::minutes(30),
            "exportedByHost": "test-host",
            "accountCount": 1,
            "activeAccountId": null,
            "activeEmail": "dev@example.com",
            "emails": ["dev@example.com"]
          },
          "salt": base64.encode(salt),
          "nonce": base64.encode(nonce_bytes),
          "ciphertext": base64.encode(ciphertext)
        })
    }

    fn append_json(builder: &mut Builder<fs::File>, path: &str, value: &serde_json::Value) {
        let data = serde_json::to_vec(value).unwrap();
        let mut header = Header::new_gnu();
        header.set_size(data.len() as u64);
        header.set_mode(0o600);
        header.set_cksum();
        builder.append_data(&mut header, path, &data[..]).unwrap();
        builder.get_mut().flush().unwrap();
    }
}
