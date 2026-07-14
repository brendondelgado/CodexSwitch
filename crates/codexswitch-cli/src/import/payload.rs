use super::bounds::{
    validate_length, BoundedText, BoundedVec, MAX_ACCOUNT_COUNT, MAX_EMAIL_BYTES,
    MAX_INNER_STRING_BYTES, MAX_PLAINTEXT_BYTES, MAX_TOKEN_BYTES,
};
use super::payload_details::{StrictDateScalar, StrictQuotaSnapshot, StrictRateLimitResetBank};
use crate::account_store::{CodexAccount, LinuxBundleMetadata};
use anyhow::{anyhow, bail, Context, Result};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use uuid::Uuid;

pub(super) fn decode_authenticated_payload(
    payload_bytes: &[u8],
    expected_version: u32,
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    decode_strict_payload(payload_bytes, expected_version)?.into_parts()
}

pub(super) fn decode_strict_payload(
    payload_bytes: &[u8],
    expected_version: u32,
) -> Result<StrictPayload> {
    validate_length(
        payload_bytes.len(),
        MAX_PLAINTEXT_BYTES,
        "decrypted bundle payload",
    )?;
    let payload: StrictPayload = serde_json::from_slice(payload_bytes)
        .context("failed to decode authenticated .csbundle payload")?;
    payload.metadata.validate_for_version(expected_version)?;
    if payload.metadata.account_count != payload.accounts.len() {
        bail!("bundle metadata account count does not match authenticated account count");
    }
    if expected_version == super::bounds::V2_SCHEMA_VERSION {
        payload.validate_authenticated_metadata()?;
    }
    Ok(payload)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StrictPayload {
    metadata: StrictMetadata,
    accounts: BoundedAccounts,
}

impl StrictPayload {
    pub(super) fn into_parts(self) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
        let accounts = self
            .accounts
            .into_values()
            .into_iter()
            .map(StrictCodexAccount::into_account)
            .collect::<Result<Vec<_>>>()?;
        Ok((self.metadata.into_metadata(), accounts))
    }

    fn validate_authenticated_metadata(&self) -> Result<()> {
        let accounts = self.accounts.as_slice();
        let metadata_emails = self.metadata.emails.as_slice();
        if metadata_emails.len() != accounts.len()
            || !metadata_emails
                .iter()
                .zip(accounts)
                .all(|(metadata_email, account)| metadata_email.as_str() == account.email.as_str())
        {
            bail!("authenticated metadata emails do not match account payload order");
        }

        let mut active_accounts = accounts.iter().filter(|account| account.is_active);
        let active = active_accounts
            .next()
            .context("authenticated account payload must contain exactly one active account")?;
        if active_accounts.next().is_some() {
            bail!("authenticated account payload must contain exactly one active account");
        }

        if self
            .metadata
            .active_account_id
            .as_ref()
            .map(|value| value.as_str())
            != Some(active.account_id.as_str())
        {
            bail!("authenticated metadata activeAccountId does not match the active account");
        }
        if self
            .metadata
            .active_email
            .as_ref()
            .map(|value| value.as_str())
            != Some(active.email.as_str())
        {
            bail!("authenticated metadata activeEmail does not match the active account");
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StrictMetadata {
    schema_version: u32,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    exported_by_host: BoundedText<MAX_INNER_STRING_BYTES>,
    account_count: usize,
    active_account_id: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    active_email: Option<BoundedText<MAX_EMAIL_BYTES>>,
    emails: BoundedEmails,
}

impl StrictMetadata {
    pub(super) fn validate_for_version(&self, expected_version: u32) -> Result<()> {
        if self.schema_version != expected_version {
            bail!("authenticated metadata schema version does not match its envelope");
        }
        if self.account_count > MAX_ACCOUNT_COUNT || self.emails.len() > MAX_ACCOUNT_COUNT {
            bail!("bundle metadata exceeds the account count limit");
        }
        Ok(())
    }

    fn into_metadata(self) -> LinuxBundleMetadata {
        LinuxBundleMetadata {
            schema_version: self.schema_version,
            created_at: self.created_at,
            expires_at: self.expires_at,
            exported_by_host: self.exported_by_host.into_string(),
            account_count: self.account_count,
            active_account_id: self.active_account_id.map(BoundedText::into_string),
            emails: self
                .emails
                .into_values()
                .into_iter()
                .map(BoundedText::into_string)
                .collect(),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StrictCodexAccount {
    id: BoundedText<64>,
    email: BoundedText<MAX_EMAIL_BYTES>,
    access_token: BoundedText<MAX_TOKEN_BYTES>,
    refresh_token: BoundedText<MAX_TOKEN_BYTES>,
    id_token: BoundedText<MAX_TOKEN_BYTES>,
    account_id: BoundedText<MAX_INNER_STRING_BYTES>,
    quota_snapshot: Option<StrictQuotaSnapshot>,
    plan_type: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    last_refreshed: Option<StrictDateScalar>,
    subscription_renews_at: Option<StrictDateScalar>,
    subscription_expires_at: Option<StrictDateScalar>,
    subscription_will_renew: Option<bool>,
    has_active_subscription: Option<bool>,
    five_hour_primed_at: Option<StrictDateScalar>,
    rate_limit_reset_bank: Option<StrictRateLimitResetBank>,
    runtime_unusable_until: Option<StrictDateScalar>,
    runtime_unusable_reason: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    is_active: bool,
}

impl StrictCodexAccount {
    fn into_account(self) -> Result<CodexAccount> {
        let id = Uuid::parse_str(self.id.as_str())
            .map_err(|_| anyhow!("account contains an invalid local identity"))?;
        let quota_snapshot = self
            .quota_snapshot
            .map(StrictQuotaSnapshot::into_snapshot)
            .transpose()?;
        let rate_limit_reset_bank = self
            .rate_limit_reset_bank
            .map(StrictRateLimitResetBank::into_bank)
            .transpose()?;
        let runtime_unusable_until = self
            .runtime_unusable_until
            .map(|value| value.into_datetime("runtimeUnusableUntil"))
            .transpose()?;
        Ok(CodexAccount {
            id,
            email: self.email.into_string(),
            access_token: self.access_token.into_string(),
            refresh_token: self.refresh_token.into_string(),
            id_token: self.id_token.into_string(),
            account_id: self.account_id.into_string(),
            quota_snapshot,
            plan_type: self.plan_type.map(BoundedText::into_string),
            last_refreshed: self.last_refreshed.map(StrictDateScalar::into_value),
            subscription_renews_at: self
                .subscription_renews_at
                .map(StrictDateScalar::into_value),
            subscription_expires_at: self
                .subscription_expires_at
                .map(StrictDateScalar::into_value),
            subscription_will_renew: self.subscription_will_renew,
            has_active_subscription: self.has_active_subscription,
            five_hour_primed_at: self.five_hour_primed_at.map(StrictDateScalar::into_value),
            runtime_unusable_until,
            runtime_unusable_reason: self.runtime_unusable_reason.map(BoundedText::into_string),
            rate_limit_reset_bank,
            is_active: self.is_active,
        })
    }
}

pub(super) type BoundedAccounts = BoundedVec<StrictCodexAccount, MAX_ACCOUNT_COUNT>;
type BoundedEmails = BoundedVec<BoundedText<MAX_EMAIL_BYTES>, MAX_ACCOUNT_COUNT>;
