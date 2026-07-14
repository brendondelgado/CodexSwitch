use super::bounds::*;
use super::crypto::{decode_ciphertext, SecretBytes};
use super::envelope::{decrypt_csbundle_bytes, read_csbundle};
use super::payload::{decode_strict_payload, BoundedAccounts};
use super::secure_input::{
    open_owned_regular, read_bounded_with_test_hook, read_passphrase_file, validate_file_security,
    validate_passphrase, with_terminal_echo_disabled, TerminalAttributes,
};
use super::*;
use crate::account_store::{CodexAccount, LinuxBundleMetadata};
use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use chrono::Utc;
use ring::{aead, pbkdf2};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::num::NonZeroU32;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::sync::{Arc, Mutex};
use tempfile::{tempdir_in, TempDir};
use uuid::Uuid;

#[test]
fn imports_deterministic_v2_fixture_with_exact_algorithms() -> Result<()> {
    let fixture = fixture_spec()?;
    let dir = secure_tempdir()?;
    let bundle_path = dir.path().join("fixture.csbundle");
    let passphrase_path = dir.path().join("fixture.passphrase");
    fs::write(&bundle_path, v2_fixture_bytes())?;
    fs::write(&passphrase_path, fixture.passphrase.as_bytes())?;
    fs::set_permissions(
        &passphrase_path,
        fs::Permissions::from_mode(PASSPHRASE_FILE_MODE),
    )?;

    let (metadata, accounts) =
        read_csbundle(&bundle_path, || read_passphrase_file(&passphrase_path))?;
    assert_eq!(metadata.schema_version, V2_SCHEMA_VERSION);
    assert_eq!(metadata.exported_by_host, fixture.host_name);
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].id, fixture.account.id);
    assert_eq!(accounts[0].email, fixture.account.email);
    assert_eq!(accounts[0].access_token, fixture.account.access_token);

    let outer: Value = serde_json::from_slice(v2_fixture_bytes())?;
    let keys = outer
        .as_object()
        .context("fixture envelope must be an object")?
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    assert_eq!(
        keys,
        BTreeSet::from([
            "cipher",
            "ciphertext",
            "format",
            "iterations",
            "kdf",
            "nonce",
            "salt",
            "schemaVersion",
        ])
    );
    let outer_text = String::from_utf8_lossy(v2_fixture_bytes());
    assert!(!outer_text.contains(&fixture.account.email));
    assert!(!outer_text.contains(&fixture.account.account_id));
    assert_eq!(outer["format"], BUNDLE_FORMAT);
    assert_eq!(outer["schemaVersion"], V2_SCHEMA_VERSION);
    assert_eq!(outer["kdf"], V2_KDF);
    assert_eq!(outer["iterations"], V2_ITERATIONS);
    assert_eq!(outer["cipher"], V2_CIPHER);
    Ok(())
}

#[test]
fn compatibility_inspects_bounded_legacy_v1_fixture_without_mutating_handoff() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle_path = dir.path().join("legacy.csbundle");
    fs::write(&bundle_path, v1_fixture_bytes())?;
    assert_eq!(
        inspect_bundle_compatibility(&bundle_path)?,
        BundleCompatibility::LegacyV1Encrypted
    );
    let error = prepare_import_bundle(&bundle_path, false).unwrap_err();
    assert!(format!("{error:#}").contains("compatibility inspection only"));
    Ok(())
}

#[test]
fn wrong_passphrase_fails_authentication_before_payload_parsing() {
    let error = decrypt_csbundle_bytes(v2_fixture_bytes(), || {
        Ok(SecretBytes::new(b"definitely-wrong-passphrase".to_vec()))
    })
    .unwrap_err();

    assert!(format!("{error:#}").contains("authentication failed"));
}

#[test]
fn rejects_unknown_duplicate_or_noncanonical_envelope_fields() -> Result<()> {
    let fixture = fixture_spec()?;
    let mut unknown: Value = serde_json::from_slice(v2_fixture_bytes())?;
    unknown["metadata"] = json!({"email": fixture.account.email});
    assert!(decrypt_with_fixture_passphrase(&serde_json::to_vec(&unknown)?, &fixture).is_err());

    let original = String::from_utf8(v2_fixture_bytes().to_vec())?;
    let duplicate = format!("{{\"format\":\"{BUNDLE_FORMAT}\",{}", &original[1..]);
    assert!(decrypt_with_fixture_passphrase(duplicate.as_bytes(), &fixture).is_err());

    for (field, value) in [
        ("schemaVersion", json!(99)),
        ("kdf", json!("unknown-kdf")),
        ("iterations", json!(V2_ITERATIONS - 1)),
        ("cipher", json!("unknown-cipher")),
    ] {
        let mut envelope: Value = serde_json::from_slice(v2_fixture_bytes())?;
        envelope[field] = value;
        assert!(
            decrypt_with_fixture_passphrase(&serde_json::to_vec(&envelope)?, &fixture).is_err(),
            "field {field} must fail closed"
        );
    }

    Ok(())
}

#[test]
fn authenticated_v2_metadata_must_exactly_match_account_payload() -> Result<()> {
    let fixture = fixture_spec()?;
    let mut cases = Vec::new();

    let mut wrong_count = fixture_payload(V2_SCHEMA_VERSION);
    wrong_count["metadata"]["accountCount"] = json!(2);
    cases.push((wrong_count, "account count"));

    let mut wrong_emails = fixture_payload(V2_SCHEMA_VERSION);
    wrong_emails["metadata"]["emails"] = json!(["other@example.com"]);
    cases.push((wrong_emails, "metadata emails"));

    let mut wrong_active_id = fixture_payload(V2_SCHEMA_VERSION);
    wrong_active_id["metadata"]["activeAccountId"] = json!("other-account-id");
    cases.push((wrong_active_id, "activeAccountId"));

    let mut wrong_active_email = fixture_payload(V2_SCHEMA_VERSION);
    wrong_active_email["metadata"]["activeEmail"] = json!("other@example.com");
    cases.push((wrong_active_email, "activeEmail"));

    let mut no_active = fixture_payload(V2_SCHEMA_VERSION);
    no_active["accounts"][0]["isActive"] = json!(false);
    no_active["metadata"]["activeAccountId"] = Value::Null;
    no_active["metadata"]["activeEmail"] = Value::Null;
    cases.push((no_active, "exactly one active account"));

    for (payload, expected_error) in cases {
        let encrypted = encrypt_v2_test_payload(&serde_json::to_vec(&payload)?)?;
        let error = decrypt_with_fixture_passphrase(&encrypted, &fixture).unwrap_err();
        assert!(
            format!("{error:#}").contains(expected_error),
            "expected {expected_error:?}, got {error:#}"
        );
    }
    Ok(())
}

#[test]
fn validated_import_preserves_authenticated_active_identity() -> Result<()> {
    let fixture = fixture_spec()?;
    let mut payload = fixture_payload(V2_SCHEMA_VERSION);
    let mut preferred_by_policy = fixture_account();
    preferred_by_policy["id"] = json!("66666666-7777-8888-9999-aaaaaaaaaaaa");
    preferred_by_policy["email"] = json!("pro@example.com");
    preferred_by_policy["accessToken"] = json!("pro-access-token");
    preferred_by_policy["refreshToken"] = json!("pro-refresh-token");
    preferred_by_policy["idToken"] = json!("pro-id-token");
    preferred_by_policy["accountId"] = json!("pro-account-id");
    preferred_by_policy["planType"] = json!("pro");
    preferred_by_policy["isActive"] = json!(false);
    payload["accounts"] = json!([fixture_account(), preferred_by_policy]);
    payload["metadata"]["accountCount"] = json!(2);
    payload["metadata"]["emails"] = json!(["fixture@example.com", "pro@example.com"]);

    let encrypted = encrypt_v2_test_payload(&serde_json::to_vec(&payload)?)?;
    let (metadata, accounts) = decrypt_with_fixture_passphrase(&encrypted, &fixture)?;
    let imported = validate_decrypted_import(metadata, accounts, false, Utc::now())?;

    assert_eq!(imported.len(), 2);
    assert!(imported[0].is_active);
    assert_eq!(imported[0].account_id, "fixture-account-id");
    assert!(!imported[1].is_active);
    assert_eq!(imported[1].account_id, "pro-account-id");
    Ok(())
}

#[test]
fn strict_payload_rejects_unknown_and_duplicate_fields() -> Result<()> {
    let mut unknown_payload = fixture_payload(V2_SCHEMA_VERSION);
    unknown_payload["unexpected"] = json!(true);
    assert!(decode_strict_payload(&serde_json::to_vec(&unknown_payload)?, 2).is_err());
    let authenticated_unknown = encrypt_v2_test_payload(&serde_json::to_vec(&unknown_payload)?)?;
    let fixture = fixture_spec()?;
    let error = decrypt_with_fixture_passphrase(&authenticated_unknown, &fixture).unwrap_err();
    assert!(format!("{error:#}").contains("authenticated .csbundle payload"));

    let mut unknown_account = fixture_payload(V2_SCHEMA_VERSION);
    unknown_account["accounts"][0]["unexpected"] = json!(true);
    assert!(decode_strict_payload(&serde_json::to_vec(&unknown_account)?, 2).is_err());

    let mut unknown_metadata = fixture_payload(V2_SCHEMA_VERSION);
    unknown_metadata["metadata"]["unexpected"] = json!(true);
    assert!(decode_strict_payload(&serde_json::to_vec(&unknown_metadata)?, 2).is_err());

    let mut unknown_quota = fixture_payload(V2_SCHEMA_VERSION);
    unknown_quota["accounts"][0]["quotaSnapshot"] = json!({
        "fetchedAt": 799_048_365.0,
        "unexpected": true,
    });
    assert!(decode_strict_payload(&serde_json::to_vec(&unknown_quota)?, 2).is_err());

    let metadata = serde_json::to_string(&fixture_metadata(V2_SCHEMA_VERSION))?;
    let accounts = serde_json::to_string(&json!([fixture_account()]))?;
    let duplicate =
        format!("{{\"accounts\":{accounts},\"metadata\":{metadata},\"metadata\":{metadata}}}");
    assert!(decode_strict_payload(duplicate.as_bytes(), 2).is_err());

    let account = serde_json::to_string(&fixture_account())?;
    let duplicate_account = account.replacen(
        "\"accessToken\":\"fixture-access-token\"",
        "\"accessToken\":\"fixture-access-token\",\"accessToken\":\"duplicate\"",
        1,
    );
    assert_ne!(account, duplicate_account);
    let duplicate_account_payload =
        format!("{{\"accounts\":[{duplicate_account}],\"metadata\":{metadata}}}");
    assert!(decode_strict_payload(duplicate_account_payload.as_bytes(), 2).is_err());
    Ok(())
}

#[test]
fn malformed_and_oversized_base64_fail_before_decryption() -> Result<()> {
    let fixture = fixture_spec()?;
    let mut malformed: Value = serde_json::from_slice(v2_fixture_bytes())?;
    malformed["salt"] = json!("%%%not-base64%%%");
    assert!(decrypt_with_fixture_passphrase(&serde_json::to_vec(&malformed)?, &fixture).is_err());

    assert!(decode_ciphertext("***").is_err());
    assert!(
        decode_ciphertext(&base64::engine::general_purpose::STANDARD.encode([0_u8; 15])).is_err()
    );
    assert!(decode_ciphertext(&"A".repeat(MAX_CIPHERTEXT_BASE64_BYTES + 1)).is_err());
    Ok(())
}

#[test]
fn payload_account_token_and_passphrase_bounds_fail_closed() -> Result<()> {
    assert!(validate_length(MAX_PLAINTEXT_BYTES + 1, MAX_PLAINTEXT_BYTES, "payload").is_err());
    assert!(validate_passphrase(&vec![b'x'; MAX_PASSPHRASE_BYTES + 1]).is_err());

    let accounts = vec![fixture_account(); MAX_ACCOUNT_COUNT + 1];
    assert!(serde_json::from_slice::<BoundedAccounts>(&serde_json::to_vec(&accounts)?).is_err());

    let mut oversized_token = fixture_payload(V2_SCHEMA_VERSION);
    oversized_token["accounts"][0]["accessToken"] = json!("x".repeat(MAX_TOKEN_BYTES + 1));
    assert!(decode_strict_payload(&serde_json::to_vec(&oversized_token)?, 2).is_err());

    let quota_window = json!({
        "kind": "fiveHour",
        "durationSeconds": 18_000,
        "usedPercent": 10.0,
        "resetsAt": 799_048_365.0,
        "source": {
            "rateLimit": "main",
            "slot": "primary",
            "limitName": null,
            "meteredFeature": null,
        },
        "hardLimitReached": false,
    });
    let mut oversized_windows = fixture_payload(V2_SCHEMA_VERSION);
    oversized_windows["accounts"][0]["quotaSnapshot"] = json!({
        "version": 2,
        "allowed": true,
        "limitReached": false,
        "fetchedAt": 799_048_365.0,
        "windows": vec![quota_window; MAX_QUOTA_WINDOWS_PER_ACCOUNT + 1],
    });
    assert!(decode_strict_payload(&serde_json::to_vec(&oversized_windows)?, 2).is_err());
    Ok(())
}

#[test]
fn file_open_rejects_symlinks_wrong_owner_mode_and_oversize() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle = dir.path().join("bundle.csbundle");
    let linked_bundle = dir.path().join("linked.csbundle");
    fs::write(&bundle, v2_fixture_bytes())?;
    symlink(&bundle, &linked_bundle)?;
    assert!(open_owned_regular(&linked_bundle, MAX_BUNDLE_FILE_BYTES, None).is_err());

    let passphrase = dir.path().join("passphrase");
    fs::write(&passphrase, b"fixture-passphrase-2026")?;
    fs::set_permissions(&passphrase, fs::Permissions::from_mode(0o644))?;
    assert!(read_passphrase_file(&passphrase).is_err());
    fs::set_permissions(
        &passphrase,
        fs::Permissions::from_mode(PASSPHRASE_FILE_MODE),
    )?;
    assert_eq!(
        read_passphrase_file(&passphrase)?.as_slice(),
        b"fixture-passphrase-2026"
    );
    let linked_passphrase = dir.path().join("linked-passphrase");
    symlink(&passphrase, &linked_passphrase)?;
    assert!(read_passphrase_file(&linked_passphrase).is_err());

    let oversized_passphrase = dir.path().join("oversized-passphrase");
    let oversized_passphrase_file = fs::File::create(&oversized_passphrase)?;
    oversized_passphrase_file.set_len((MAX_PASSPHRASE_FILE_BYTES + 1) as u64)?;
    fs::set_permissions(
        &oversized_passphrase,
        fs::Permissions::from_mode(PASSPHRASE_FILE_MODE),
    )?;
    assert!(read_passphrase_file(&oversized_passphrase).is_err());

    assert!(validate_file_security(true, 501, 0o600, 502, Some(0o600)).is_err());
    assert!(validate_file_security(false, 501, 0o600, 501, Some(0o600)).is_err());
    assert!(validate_file_security(true, 501, 0o600, 501, Some(0o600)).is_ok());

    let oversized = dir.path().join("oversized.csbundle");
    let oversized_file = fs::File::create(&oversized)?;
    oversized_file.set_len((MAX_BUNDLE_FILE_BYTES + 1) as u64)?;
    assert!(open_owned_regular(&oversized, MAX_BUNDLE_FILE_BYTES, None).is_err());
    Ok(())
}

#[test]
fn file_open_rejects_parent_symlinks_and_lexical_traversal() -> Result<()> {
    let dir = secure_tempdir()?;
    let real_parent = dir.path().join("real-parent");
    let linked_parent = dir.path().join("linked-parent");
    fs::create_dir(&real_parent)?;
    let bundle = real_parent.join("bundle.csbundle");
    fs::write(&bundle, v2_fixture_bytes())?;
    symlink(&real_parent, &linked_parent)?;

    let passphrase = real_parent.join("passphrase");
    fs::write(&passphrase, b"fixture-passphrase-2026")?;
    fs::set_permissions(
        &passphrase,
        fs::Permissions::from_mode(PASSPHRASE_FILE_MODE),
    )?;

    assert!(open_owned_regular(
        &linked_parent.join("bundle.csbundle"),
        MAX_BUNDLE_FILE_BYTES,
        None,
    )
    .is_err());
    assert!(read_passphrase_file(&linked_parent.join("passphrase")).is_err());

    let traversing_path = real_parent
        .join("..")
        .join("real-parent")
        .join("bundle.csbundle");
    assert!(open_owned_regular(&traversing_path, MAX_BUNDLE_FILE_BYTES, None).is_err());
    Ok(())
}

#[test]
fn terminal_echo_is_restored_after_read_failure() {
    let operations = FakeTerminalAttributes::new();
    let observed = operations.observed_echo_states.clone();

    let error = with_terminal_echo_disabled(42, operations, || -> Result<()> {
        bail!("fixture read failure")
    })
    .unwrap_err();

    assert!(format!("{error:#}").contains("fixture read failure"));
    assert_eq!(*observed.lock().unwrap(), vec![false, true]);
}

#[test]
fn terminal_echo_guard_restores_during_unwind() {
    let operations = FakeTerminalAttributes::new();
    let observed = operations.observed_echo_states.clone();

    let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = with_terminal_echo_disabled(42, operations, || -> Result<()> {
            panic!("fixture panic")
        });
    }));

    assert!(unwind.is_err());
    assert_eq!(*observed.lock().unwrap(), vec![false, true]);
}

#[test]
fn bounded_read_rejects_descriptor_identity_changes() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle = dir.path().join("bundle.csbundle");
    fs::write(&bundle, b"before")?;
    let input = open_owned_regular(&bundle, MAX_BUNDLE_FILE_BYTES, None)?;

    let error = read_bounded_with_test_hook(input, MAX_BUNDLE_FILE_BYTES, || {
        fs::write(&bundle, b"changed-after-read")?;
        Ok(())
    })
    .unwrap_err();

    assert!(format!("{error:#}").contains("changed during secure read"));
    Ok(())
}

#[test]
fn legacy_tar_is_inspection_only_and_never_reaches_mutating_handoff() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle_path = dir.path().join("bundle.tar");
    let store_path = dir.path().join("accounts.json");
    fs::write(&bundle_path, b"legacy tar content is never decoded")?;

    assert_eq!(
        inspect_bundle_compatibility(&bundle_path)?,
        BundleCompatibility::LegacyTar
    );
    let error = prepare_import_bundle(&bundle_path, false).unwrap_err();
    assert!(format!("{error:#}").contains("compatibility inspection only"));
    assert!(!store_path.exists());
    Ok(())
}

#[test]
fn legacy_age_is_inspection_only_and_never_reaches_mutating_handoff() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle_path = dir.path().join("bundle.age");
    fs::write(&bundle_path, b"age-encryption.org/v1\n")?;

    assert_eq!(
        inspect_bundle_compatibility(&bundle_path)?,
        BundleCompatibility::LegacyAge
    );
    let error = prepare_import_bundle(&bundle_path, false).unwrap_err();
    assert!(format!("{error:#}").contains("compatibility inspection only"));
    Ok(())
}

#[test]
fn rejects_unknown_bundle_extensions_without_legacy_fallback() -> Result<()> {
    let dir = secure_tempdir()?;
    let bundle_path = dir.path().join("bundle.bin");
    fs::write(&bundle_path, b"not-a-credential-bundle")?;

    assert!(prepare_import_bundle(&bundle_path, false).is_err());
    Ok(())
}

fn decrypt_with_fixture_passphrase(
    bundle: &[u8],
    fixture: &FixtureSpec,
) -> Result<(LinuxBundleMetadata, Vec<CodexAccount>)> {
    decrypt_csbundle_bytes(bundle, || {
        Ok(SecretBytes::new(fixture.passphrase.as_bytes().to_vec()))
    })
}

fn encrypt_v2_test_payload(payload: &[u8]) -> Result<Vec<u8>> {
    let fixture = fixture_spec()?;
    let salt = base64::engine::general_purpose::STANDARD.decode(fixture.salt_base64)?;
    let nonce_bytes = base64::engine::general_purpose::STANDARD.decode(fixture.nonce_base64)?;
    let mut key_bytes = vec![0_u8; KEY_BYTES];
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        NonZeroU32::new(V2_ITERATIONS).context("iterations must be nonzero")?,
        &salt,
        fixture.passphrase.as_bytes(),
        &mut key_bytes,
    );
    let key = aead::UnboundKey::new(&aead::AES_256_GCM, &key_bytes)
        .map_err(|_| anyhow!("test key failed"))?;
    let key = aead::LessSafeKey::new(key);
    let nonce = aead::Nonce::try_assume_unique_for_key(&nonce_bytes)
        .map_err(|_| anyhow!("test nonce failed"))?;
    let mut ciphertext = payload.to_vec();
    key.seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut ciphertext)
        .map_err(|_| anyhow!("test encryption failed"))?;
    key_bytes.fill(0);
    let base64 = base64::engine::general_purpose::STANDARD;
    Ok(serde_json::to_vec(&json!({
        "format": BUNDLE_FORMAT,
        "schemaVersion": V2_SCHEMA_VERSION,
        "kdf": V2_KDF,
        "iterations": V2_ITERATIONS,
        "cipher": V2_CIPHER,
        "salt": base64.encode(salt),
        "nonce": base64.encode(nonce_bytes),
        "ciphertext": base64.encode(ciphertext),
    }))?)
}

fn fixture_payload(schema_version: u32) -> Value {
    json!({
        "accounts": [fixture_account()],
        "metadata": fixture_metadata(schema_version),
    })
}

fn fixture_metadata(schema_version: u32) -> Value {
    json!({
        "schemaVersion": schema_version,
        "createdAt": "2099-01-01T00:00:00Z",
        "expiresAt": "2099-01-01T00:30:00Z",
        "exportedByHost": "fixture-mac",
        "accountCount": 1,
        "activeAccountId": "fixture-account-id",
        "activeEmail": "fixture@example.com",
        "emails": ["fixture@example.com"],
    })
}

fn fixture_account() -> Value {
    json!({
        "id": "11111111-2222-3333-4444-555555555555",
        "email": "fixture@example.com",
        "accessToken": "fixture-access-token",
        "refreshToken": "fixture-refresh-token",
        "idToken": "fixture-id-token",
        "accountId": "fixture-account-id",
        "quotaSnapshot": null,
        "planType": "plus",
        "lastRefreshed": null,
        "subscriptionRenewsAt": null,
        "subscriptionExpiresAt": null,
        "subscriptionWillRenew": null,
        "hasActiveSubscription": null,
        "fiveHourPrimedAt": null,
        "rateLimitResetBank": null,
        "runtimeUnusableUntil": null,
        "runtimeUnusableReason": null,
        "isActive": true,
    })
}

fn fixture_spec() -> Result<FixtureSpec> {
    Ok(serde_json::from_slice(include_bytes!(
        "../../../../Tests/Fixtures/CredentialBundle/fixture.json"
    ))?)
}

fn v2_fixture_bytes() -> &'static [u8] {
    include_bytes!("../../../../Tests/Fixtures/CredentialBundle/v2.csbundle")
}

fn v1_fixture_bytes() -> &'static [u8] {
    include_bytes!("../../../../Tests/Fixtures/CredentialBundle/legacy-v1.csbundle")
}

fn secure_tempdir() -> Result<TempDir> {
    let physical_temp = fs::canonicalize(std::env::temp_dir())?;
    Ok(tempdir_in(physical_temp)?)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureSpec {
    passphrase: String,
    salt_base64: String,
    nonce_base64: String,
    host_name: String,
    account: FixtureAccount,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureAccount {
    id: Uuid,
    email: String,
    access_token: String,
    account_id: String,
}

#[derive(Clone)]
struct FakeTerminalAttributes {
    original: libc::termios,
    observed_echo_states: Arc<Mutex<Vec<bool>>>,
}

impl FakeTerminalAttributes {
    fn new() -> Self {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        original.c_lflag |= libc::ECHO as libc::tcflag_t;
        Self {
            original,
            observed_echo_states: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl TerminalAttributes for FakeTerminalAttributes {
    fn read(&self, _descriptor: std::os::fd::RawFd) -> std::io::Result<libc::termios> {
        Ok(self.original)
    }

    fn write(
        &self,
        _descriptor: std::os::fd::RawFd,
        attributes: &libc::termios,
    ) -> std::io::Result<()> {
        self.observed_echo_states
            .lock()
            .unwrap()
            .push(attributes.c_lflag & libc::ECHO as libc::tcflag_t != 0);
        Ok(())
    }
}
