use super::bounds::{
    validate_length, KEY_BYTES, MAX_CIPHERTEXT_BASE64_BYTES, MAX_CIPHERTEXT_BYTES,
    MAX_PLAINTEXT_BYTES, NONCE_BYTES, TAG_BYTES,
};
use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use ring::{aead, pbkdf2};
use std::num::NonZeroU32;

pub(super) fn derive_v2_key(
    iterations: u32,
    salt: &[u8],
    passphrase: &[u8],
) -> Result<SecretBytes> {
    let iterations =
        NonZeroU32::new(iterations).ok_or_else(|| anyhow!("invalid v2 PBKDF2 iteration count"))?;
    let mut key = SecretBytes::zeroed(KEY_BYTES);
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        iterations,
        salt,
        passphrase,
        key.as_mut_slice(),
    );
    Ok(key)
}

pub(super) fn authenticate_and_decrypt(
    mut ciphertext: SecretBytes,
    key_bytes: &[u8],
    nonce_bytes: &[u8; NONCE_BYTES],
) -> Result<DecryptedPayload> {
    let key = aead::UnboundKey::new(&aead::AES_256_GCM, key_bytes)
        .map_err(|_| anyhow!("failed to create AES key"))?;
    let key = aead::LessSafeKey::new(key);
    let nonce = aead::Nonce::try_assume_unique_for_key(nonce_bytes)
        .map_err(|_| anyhow!("invalid bundle nonce"))?;
    let plaintext_length = key
        .open_in_place(nonce, aead::Aad::empty(), ciphertext.as_mut_slice())
        .map_err(|_| anyhow!("bundle authentication failed; check the passphrase"))?
        .len();
    validate_length(
        plaintext_length,
        MAX_PLAINTEXT_BYTES,
        "decrypted bundle payload",
    )?;
    Ok(DecryptedPayload {
        storage: ciphertext,
        plaintext_length,
    })
}

pub(super) fn decode_fixed_base64<const N: usize>(value: &str, field: &str) -> Result<[u8; N]> {
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(value)
        .with_context(|| format!("failed to decode bundle {field}"))?;
    decoded
        .try_into()
        .map_err(|_| anyhow!("bundle {field} has an invalid decoded length"))
}

pub(super) fn decode_ciphertext(value: &str) -> Result<SecretBytes> {
    validate_length(
        value.len(),
        MAX_CIPHERTEXT_BASE64_BYTES,
        "bundle ciphertext base64 field",
    )?;
    let maximum_decoded = ((value.len() + 3) / 4) * 3;
    if maximum_decoded > MAX_CIPHERTEXT_BYTES + 2 {
        bail!("bundle ciphertext exceeds the decoded size limit");
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(value)
        .context("failed to decode bundle ciphertext")?;
    if decoded.len() < TAG_BYTES || decoded.len() > MAX_CIPHERTEXT_BYTES {
        bail!("bundle ciphertext has an invalid decoded length");
    }
    Ok(SecretBytes::new(decoded))
}

pub(super) struct DecryptedPayload {
    storage: SecretBytes,
    plaintext_length: usize,
}

impl DecryptedPayload {
    pub(super) fn as_slice(&self) -> &[u8] {
        &self.storage.as_slice()[..self.plaintext_length]
    }
}

pub(super) struct SecretBytes(Vec<u8>);

impl SecretBytes {
    pub(super) fn new(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    fn zeroed(length: usize) -> Self {
        Self(vec![0; length])
    }

    pub(super) fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub(super) fn as_mut_slice(&mut self) -> &mut [u8] {
        &mut self.0
    }

    pub(super) fn clear(&mut self) {
        self.0.fill(0);
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        self.clear();
    }
}
