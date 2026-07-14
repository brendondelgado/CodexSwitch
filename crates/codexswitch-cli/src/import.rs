mod bounds;
mod crypto;
mod envelope;
mod payload;
mod payload_details;
mod secure_input;

use self::bounds::{MAX_BUNDLE_FILE_BYTES, V2_SCHEMA_VERSION};
use crate::account_store::{validate_accounts, CodexAccount, LinuxBundleMetadata};
use anyhow::{bail, Result};
use chrono::{DateTime, Utc};
use std::path::Path;

pub fn prepare_import_bundle(bundle_path: &Path, ignore_expiry: bool) -> Result<Vec<CodexAccount>> {
    let compatibility = inspect_bundle_compatibility(bundle_path)?;
    if compatibility != BundleCompatibility::CurrentV2 {
        bail!(
            "{} is supported for compatibility inspection only and cannot be imported; create a version 2 .csbundle",
            compatibility.label()
        );
    }

    let (metadata, accounts) = read_bundle(bundle_path)?;
    validate_decrypted_import(metadata, accounts, ignore_expiry, Utc::now())
}

fn validate_decrypted_import(
    metadata: LinuxBundleMetadata,
    accounts: Vec<CodexAccount>,
    ignore_expiry: bool,
    now: DateTime<Utc>,
) -> Result<Vec<CodexAccount>> {
    if metadata.schema_version != V2_SCHEMA_VERSION {
        bail!(
            "unsupported bundle schema version {}",
            metadata.schema_version
        );
    }
    if !ignore_expiry && metadata.expires_at < now {
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
    validate_accounts(&accounts)?;
    Ok(accounts)
}

fn read_bundle(path: &Path) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
    {
        "csbundle" => envelope::read_csbundle(path, secure_input::read_passphrase),
        extension => bail!("unsupported credential bundle extension {extension:?}"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BundleCompatibility {
    CurrentV2,
    LegacyV1Encrypted,
    LegacyAge,
    LegacyTar,
}

impl BundleCompatibility {
    fn label(self) -> &'static str {
        match self {
            Self::CurrentV2 => "version 2 .csbundle",
            Self::LegacyV1Encrypted => "legacy version 1 .csbundle",
            Self::LegacyAge => "legacy .age bundle",
            Self::LegacyTar => "legacy .tar bundle",
        }
    }
}

fn inspect_bundle_compatibility(path: &Path) -> Result<BundleCompatibility> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
    {
        "csbundle" => match envelope::probe_csbundle_schema_version(path)? {
            V2_SCHEMA_VERSION => Ok(BundleCompatibility::CurrentV2),
            bounds::LEGACY_V1_SCHEMA_VERSION => Ok(BundleCompatibility::LegacyV1Encrypted),
            version => bail!("unsupported encrypted bundle schema version {version}"),
        },
        "age" => {
            secure_input::open_owned_regular(path, MAX_BUNDLE_FILE_BYTES, None)?;
            Ok(BundleCompatibility::LegacyAge)
        }
        "tar" => {
            secure_input::open_owned_regular(path, MAX_BUNDLE_FILE_BYTES, None)?;
            Ok(BundleCompatibility::LegacyTar)
        }
        extension => bail!("unsupported credential bundle extension {extension:?}"),
    }
}

#[cfg(test)]
mod tests;
