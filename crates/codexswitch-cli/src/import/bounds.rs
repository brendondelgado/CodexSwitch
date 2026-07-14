use anyhow::{bail, Result};
use serde::de::{self, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::fmt;
use std::marker::PhantomData;

pub(super) const BUNDLE_FORMAT: &str = "codexswitch-linux-devbox-bundle";
pub(super) const V2_SCHEMA_VERSION: u32 = 2;
pub(super) const V2_KDF: &str = "pbkdf2-hmac-sha256-v2";
pub(super) const V2_ITERATIONS: u32 = 600_000;
pub(super) const V2_CIPHER: &str = "aes-256-gcm";
pub(super) const LEGACY_V1_SCHEMA_VERSION: u32 = 1;

pub(super) const SALT_BYTES: usize = 32;
pub(super) const NONCE_BYTES: usize = 12;
pub(super) const TAG_BYTES: usize = 16;
pub(super) const KEY_BYTES: usize = 32;
pub(super) const MAX_BUNDLE_FILE_BYTES: usize = 12 * 1024 * 1024;
pub(super) const MAX_PLAINTEXT_BYTES: usize = 8 * 1024 * 1024;
pub(super) const MAX_ACCOUNT_COUNT: usize = 128;
pub(super) const MAX_PASSPHRASE_BYTES: usize = 1_024;
pub(super) const MAX_PASSPHRASE_FILE_BYTES: usize = MAX_PASSPHRASE_BYTES + 2;
pub(super) const MAX_TOKEN_BYTES: usize = 256 * 1024;
pub(super) const MAX_EMAIL_BYTES: usize = 320;
pub(super) const MAX_INNER_STRING_BYTES: usize = 4 * 1024;
pub(super) const MAX_ROUTING_STRING_BYTES: usize = 64;
pub(super) const MAX_SALT_BASE64_BYTES: usize = 64;
pub(super) const MAX_NONCE_BASE64_BYTES: usize = 32;
pub(super) const MAX_CIPHERTEXT_BYTES: usize = MAX_PLAINTEXT_BYTES + TAG_BYTES;
pub(super) const MAX_CIPHERTEXT_BASE64_BYTES: usize = base64_encoded_length(MAX_CIPHERTEXT_BYTES);
pub(super) const MAX_QUOTA_WINDOWS_PER_ACCOUNT: usize = 32;
pub(super) const MAX_RESET_CREDITS_PER_ACCOUNT: usize = 128;
pub(super) const UNIX_TO_SWIFT_REFERENCE_SECONDS: f64 = 978_307_200.0;
pub(super) const PASSPHRASE_FILE_MODE: u32 = 0o600;

const fn base64_encoded_length(byte_count: usize) -> usize {
    ((byte_count + 2) / 3) * 4
}

pub(super) fn validate_length(length: usize, maximum: usize, label: &str) -> Result<()> {
    if length > maximum {
        bail!("{label} exceeds the {maximum} byte limit");
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct BoundedVec<T, const MAX_ITEMS: usize>(Vec<T>);

impl<T, const MAX_ITEMS: usize> BoundedVec<T, MAX_ITEMS> {
    pub(super) fn len(&self) -> usize {
        self.0.len()
    }

    pub(super) fn as_slice(&self) -> &[T] {
        &self.0
    }

    pub(super) fn into_values(self) -> Vec<T> {
        self.0
    }
}

impl<'de, T, const MAX_ITEMS: usize> Deserialize<'de> for BoundedVec<T, MAX_ITEMS>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct BoundedVecVisitor<T, const MAX_ITEMS: usize>(PhantomData<T>);

        impl<'de, T, const MAX_ITEMS: usize> Visitor<'de> for BoundedVecVisitor<T, MAX_ITEMS>
        where
            T: Deserialize<'de>,
        {
            type Value = BoundedVec<T, MAX_ITEMS>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "a sequence with at most {MAX_ITEMS} items")
            }

            fn visit_seq<A>(self, mut sequence: A) -> std::result::Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                if sequence.size_hint().is_some_and(|size| size > MAX_ITEMS) {
                    return Err(de::Error::invalid_length(
                        sequence.size_hint().unwrap_or(MAX_ITEMS + 1),
                        &self,
                    ));
                }
                let mut values =
                    Vec::with_capacity(sequence.size_hint().unwrap_or(0).min(MAX_ITEMS));
                while values.len() < MAX_ITEMS {
                    let Some(value) = sequence.next_element()? else {
                        return Ok(BoundedVec(values));
                    };
                    values.push(value);
                }
                if sequence.next_element::<de::IgnoredAny>()?.is_some() {
                    return Err(de::Error::invalid_length(MAX_ITEMS + 1, &self));
                }
                Ok(BoundedVec(values))
            }
        }

        deserializer.deserialize_seq(BoundedVecVisitor::<T, MAX_ITEMS>(PhantomData))
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct BoundedText<const MAX_BYTES: usize>(String);

impl<const MAX_BYTES: usize> BoundedText<MAX_BYTES> {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }

    pub(super) fn into_string(self) -> String {
        self.0
    }
}

impl<'de, const MAX_BYTES: usize> Deserialize<'de> for BoundedText<MAX_BYTES> {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct TextVisitor<const MAX_BYTES: usize>;

        impl<'de, const MAX_BYTES: usize> Visitor<'de> for TextVisitor<MAX_BYTES> {
            type Value = BoundedText<MAX_BYTES>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "a string no longer than {MAX_BYTES} bytes")
            }

            fn visit_str<E>(self, value: &str) -> std::result::Result<Self::Value, E>
            where
                E: de::Error,
            {
                if value.len() > MAX_BYTES {
                    return Err(E::invalid_length(value.len(), &self));
                }
                Ok(BoundedText(value.to_owned()))
            }

            fn visit_string<E>(self, value: String) -> std::result::Result<Self::Value, E>
            where
                E: de::Error,
            {
                if value.len() > MAX_BYTES {
                    return Err(E::invalid_length(value.len(), &self));
                }
                Ok(BoundedText(value))
            }
        }

        deserializer.deserialize_string(TextVisitor::<MAX_BYTES>)
    }
}
