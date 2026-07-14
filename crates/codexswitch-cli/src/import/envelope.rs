use super::bounds::{
    validate_length, BoundedText, BUNDLE_FORMAT, MAX_BUNDLE_FILE_BYTES,
    MAX_CIPHERTEXT_BASE64_BYTES, MAX_NONCE_BASE64_BYTES, MAX_ROUTING_STRING_BYTES,
    MAX_SALT_BASE64_BYTES, NONCE_BYTES, SALT_BYTES, V2_CIPHER, V2_ITERATIONS, V2_KDF,
    V2_SCHEMA_VERSION,
};
use super::crypto::{
    authenticate_and_decrypt, decode_ciphertext, decode_fixed_base64, derive_v2_key, SecretBytes,
};
use super::payload::decode_authenticated_payload;
use super::secure_input::{open_owned_regular, read_bounded, validate_passphrase};
use crate::account_store::{CodexAccount, LinuxBundleMetadata};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize)]
struct EnvelopeVersionProbe {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct V2Envelope {
    format: BoundedText<MAX_ROUTING_STRING_BYTES>,
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    kdf: BoundedText<MAX_ROUTING_STRING_BYTES>,
    iterations: u32,
    cipher: BoundedText<MAX_ROUTING_STRING_BYTES>,
    salt: BoundedText<MAX_SALT_BASE64_BYTES>,
    nonce: BoundedText<MAX_NONCE_BASE64_BYTES>,
    ciphertext: BoundedText<MAX_CIPHERTEXT_BASE64_BYTES>,
}

pub(super) fn read_csbundle<F>(
    path: &Path,
    passphrase_provider: F,
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)>
where
    F: FnOnce() -> Result<SecretBytes>,
{
    let file = open_owned_regular(path, MAX_BUNDLE_FILE_BYTES, None)?;
    let data = read_bounded(file, MAX_BUNDLE_FILE_BYTES, path)?;
    decrypt_csbundle_bytes(&data, passphrase_provider)
}

pub(super) fn probe_csbundle_schema_version(path: &Path) -> Result<u32> {
    let file = open_owned_regular(path, MAX_BUNDLE_FILE_BYTES, None)?;
    let data = read_bounded(file, MAX_BUNDLE_FILE_BYTES, path)?;
    let probe: EnvelopeVersionProbe =
        serde_json::from_slice(&data).context("failed to decode .csbundle version")?;
    Ok(probe.schema_version)
}

pub(super) fn decrypt_csbundle_bytes<F>(
    data: &[u8],
    passphrase_provider: F,
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)>
where
    F: FnOnce() -> Result<SecretBytes>,
{
    validate_length(data.len(), MAX_BUNDLE_FILE_BYTES, "credential bundle file")?;
    let probe: EnvelopeVersionProbe =
        serde_json::from_slice(data).context("failed to decode .csbundle version")?;
    match probe.schema_version {
        V2_SCHEMA_VERSION => {
            let envelope: V2Envelope =
                serde_json::from_slice(data).context("failed to decode v2 .csbundle envelope")?;
            decrypt_v2(envelope, passphrase_provider)
        }
        super::bounds::LEGACY_V1_SCHEMA_VERSION => bail!(
            "legacy version 1 .csbundle is compatibility-inspection only and cannot be imported"
        ),
        version => bail!("unsupported encrypted bundle schema version {version}"),
    }
}

fn decrypt_v2<F>(
    envelope: V2Envelope,
    passphrase_provider: F,
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)>
where
    F: FnOnce() -> Result<SecretBytes>,
{
    if envelope.format.as_str() != BUNDLE_FORMAT
        || envelope.schema_version != V2_SCHEMA_VERSION
        || envelope.kdf.as_str() != V2_KDF
        || envelope.iterations != V2_ITERATIONS
        || envelope.cipher.as_str() != V2_CIPHER
    {
        bail!("unsupported v2 encrypted bundle parameters");
    }

    let salt = decode_fixed_base64::<SALT_BYTES>(envelope.salt.as_str(), "salt")?;
    let nonce = decode_fixed_base64::<NONCE_BYTES>(envelope.nonce.as_str(), "nonce")?;
    let ciphertext = decode_ciphertext(envelope.ciphertext.as_str())?;
    let passphrase = passphrase_provider()?;
    validate_passphrase(passphrase.as_slice())?;
    let key = derive_v2_key(envelope.iterations, &salt, passphrase.as_slice())?;
    let plaintext = authenticate_and_decrypt(ciphertext, key.as_slice(), &nonce)?;
    decode_authenticated_payload(plaintext.as_slice(), V2_SCHEMA_VERSION)
}
