fn patch_auth_manager_source(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    patch_file_after(
        path,
        "use serde::Serialize;",
        r#"
use sha2::Digest;
use sha2::Sha256;"#,
        "use sha2::Sha256;",
    )?;
    patch_file_after(
        path,
        "use std::sync::RwLock;",
        r#"
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;"#,
        "use std::sync::atomic::AtomicU64;",
    )?;
    patch_file_after(
        path,
        "    external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,",
        r#"
    /// Monotonically increasing counter incremented on every auth change.
    /// WebSocket sessions compare this to avoid reusing credentials after SIGHUP.
    auth_generation: AtomicU64,"#,
        "auth_generation: AtomicU64",
    )?;
    patch_auth_generation_none_initializers(path)?;
    patch_all(
        path,
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n        })",
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n            auth_generation: AtomicU64::new(0),\n        })",
    )?;
    patch_all(
        path,
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n            auth_route_config: None,\n        })",
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n            auth_generation: AtomicU64::new(0),\n            auth_route_config: None,\n        })",
    )?;
    patch_file_before(
        path,
        "    /// Current cached auth (clone) without attempting a refresh.",
        r#"    /// Current auth generation counter. Incremented whenever cached auth changes.
    pub fn auth_generation(&self) -> u64 {
        self.auth_generation.load(Ordering::Acquire)
    }

"#,
        "pub fn auth_generation(&self) -> u64",
    )?;
    patch_file_before(
        path,
        "    /// Returns the precise kind of credentials backing this authentication.",
        r#"    /// Hashes the complete token set used by the live runtime without exposing it.
    pub fn codexswitch_auth_fingerprint(&self) -> Option<String> {
        self.get_current_auth_json()
            .as_ref()
            .and_then(AuthDotJson::codexswitch_fingerprint)
    }

"#,
        "pub fn codexswitch_auth_fingerprint(&self)",
    )?;
    patch_file_before(
        path,
        "    /// Returns the precise kind of credentials backing this authentication.",
        r#"    /// Returns the stable, non-secret provider account identifier represented
    /// by the complete cached token set.
    pub fn codexswitch_provider_account_id(&self) -> Option<String> {
        self.get_current_auth_json()
            .as_ref()
            .and_then(AuthDotJson::codexswitch_provider_account_id)
    }

"#,
        "pub fn codexswitch_provider_account_id(&self)",
    )?;
    patch_file_before(
        path,
        "    /// Reloads auth from the active source. Returns whether the auth value changed.",
        r#"    fn codexswitch_read_auth_json_bounded(
        auth_path: &std::path::Path,
    ) -> std::io::Result<(AuthDotJson, String)> {
        const AUTH_MAX_BYTES: u64 = 1024 * 1024;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(auth_path)?;
        let metadata = file.metadata()?;
        if !metadata.file_type().is_file() || metadata.len() > AUTH_MAX_BYTES {
            return Err(std::io::Error::other("auth.json is not a bounded regular file"));
        }
        let mut data = Vec::with_capacity(metadata.len() as usize);
        let mut limited = std::io::Read::take(&mut file, AUTH_MAX_BYTES + 1);
        std::io::Read::read_to_end(&mut limited, &mut data)?;
        if data.len() as u64 > AUTH_MAX_BYTES {
            return Err(std::io::Error::other("auth.json exceeds the byte limit"));
        }
        let auth = serde_json::from_slice::<AuthDotJson>(&data)
            .map_err(std::io::Error::other)?;
        let fingerprint = auth
            .codexswitch_fingerprint()
            .ok_or_else(|| std::io::Error::other("auth.json has no complete ChatGPT token set"))?;
        Ok((auth, fingerprint))
    }

    pub fn codexswitch_auth_file_fingerprint(
        &self,
        auth_path: &std::path::Path,
    ) -> std::io::Result<String> {
        Self::codexswitch_read_auth_json_bounded(auth_path)
            .map(|(_, fingerprint)| fingerprint)
    }

"#,
        "pub fn codexswitch_auth_file_fingerprint",
    )?;
    patch_file_before(
        path,
        "    /// Reloads auth from the active source. Returns whether the auth value changed.",
        r#"    pub fn codexswitch_auth_file_identity(
        &self,
        auth_path: &std::path::Path,
    ) -> std::io::Result<(String, String)> {
        let (auth, fingerprint) = Self::codexswitch_read_auth_json_bounded(auth_path)?;
        let account_id = auth
            .codexswitch_provider_account_id()
            .ok_or_else(|| std::io::Error::other(
                "auth.json has no stable provider account identifier"
            ))?;
        Ok((fingerprint, account_id))
    }

"#,
        "pub fn codexswitch_auth_file_identity",
    )?;
    patch_file_before(
        path,
        "    /// Reloads auth from the active source. Returns whether the auth value changed.",
        r#"    /// Reloads auth.json transactionally for a CodexSwitch signal. Any read,
    /// parse, construction, lock, concurrent-change, or fingerprint failure leaves
    /// the previously cached auth intact.
    pub async fn codexswitch_reload_auth_json_verified(
        &self,
        auth_path: &std::path::Path,
    ) -> std::io::Result<(bool, String, String)> {
        let (initial_auth, loaded_auth_hash) =
            Self::codexswitch_read_auth_json_bounded(auth_path)?;
        let new_auth = CodexAuth::from_auth_dot_json(
            &self.codex_home,
            initial_auth,
            self.auth_credentials_store_mode,
            self.chatgpt_base_url.as_deref(),
            self.keyring_backend_kind,
            self.agent_identity_authapi_base_url.as_deref(),
            self.auth_route_config.as_ref(),
        )
        .await?;
        let active_auth_hash = new_auth
            .codexswitch_auth_fingerprint()
            .ok_or_else(|| std::io::Error::other("constructed auth has no complete token set"))?;
        let (_, verified_hash) = Self::codexswitch_read_auth_json_bounded(auth_path)?;
        if loaded_auth_hash != verified_hash || loaded_auth_hash != active_auth_hash {
            return Err(std::io::Error::other(
                "auth.json changed while CodexSwitch was reloading it",
            ));
        }

        let mut external_auth = self
            .external_auth
            .write()
            .map_err(|_| std::io::Error::other("failed to lock external auth"))?;
        let mut cached = self
            .inner
            .write()
            .map_err(|_| std::io::Error::other("failed to lock cached auth"))?;
        let changed = !Self::auths_equal(cached.auth.as_ref(), Some(&new_auth));
        let changed_for_refresh =
            !Self::auths_equal_for_refresh(cached.auth.as_ref(), Some(&new_auth));
        if changed_for_refresh {
            cached.permanent_refresh_failure = None;
        }
        cached.auth = Some(new_auth);
        *external_auth = None;
        if changed_for_refresh {
            self.auth_generation.fetch_add(1, Ordering::AcqRel);
            self.auth_change_tx.send_modify(|revision| *revision += 1);
        }
        drop(cached);
        drop(external_auth);

        let committed_hash = self
            .auth_cached()
            .and_then(|auth| auth.codexswitch_auth_fingerprint())
            .ok_or_else(|| std::io::Error::other("committed auth fingerprint is unavailable"))?;
        if committed_hash != active_auth_hash {
            return Err(std::io::Error::other("committed auth fingerprint mismatch"));
        }
        Ok((changed, loaded_auth_hash, active_auth_hash))
    }

"#,
        "pub async fn codexswitch_reload_auth_json_verified",
    )?;
    patch_file_after(
        path,
        "impl AuthDotJson {",
        r#"
    /// Hashes all ChatGPT token material with length prefixes so disk and live
    /// auth can be compared without logging credentials.
    pub fn codexswitch_fingerprint(&self) -> Option<String> {
        let tokens = self.tokens.as_ref()?;
        let parts = [
            tokens.id_token.raw_jwt.as_str(),
            tokens.access_token.as_str(),
            tokens.refresh_token.as_str(),
            tokens.account_id.as_deref()?,
        ];
        if parts.iter().any(|part| part.is_empty()) {
            return None;
        }
        let mut hasher = Sha256::new();
        for part in parts {
            hasher.update((part.len() as u64).to_be_bytes());
            hasher.update(part.as_bytes());
        }
        Some(format!("{:x}", hasher.finalize()))
    }

"#,
        "pub fn codexswitch_fingerprint(&self)",
    )?;
    patch_file_after(
        path,
        "impl AuthDotJson {",
        r#"
    pub fn codexswitch_provider_account_id(&self) -> Option<String> {
        let account_id = self.tokens.as_ref()?.account_id.as_deref()?;
        (!account_id.is_empty()
            && account_id.len() <= 1024
            && account_id.bytes().all(|byte| (0x21..=0x7e).contains(&byte)))
            .then(|| account_id.to_string())
    }
"#,
        "pub fn codexswitch_provider_account_id(&self)",
    )?;
    patch_file_after(
        path,
        "            tracing::info!(\"Reloaded auth, changed: {changed}\");\n            guard.auth = new_auth;",
        r#"
            if auth_changed_for_refresh {
                self.auth_generation.fetch_add(1, Ordering::AcqRel);
            }"#,
        "self.auth_generation.fetch_add",
    )?;
    Ok(())
}

fn patch_workspace_dependency_if_present(path: &Path, dependency: &str) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let declaration = format!("{dependency} = {{ workspace = true }}");
    patch_file_after(
        path,
        "[dependencies]",
        &format!("\n{declaration}"),
        &declaration,
    )
}

fn patch_lockfile_dependency_if_present(
    path: &Path,
    package: &str,
    dependency: &str,
) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let package_marker = format!("[[package]]\nname = \"{package}\"\n");
    let package_start = content.find(&package_marker).with_context(|| {
        format!(
            "package {package} is missing from lockfile {}",
            path.display()
        )
    })?;
    let package_end = content[package_start + package_marker.len()..]
        .find("\n[[package]]")
        .map(|offset| package_start + package_marker.len() + offset)
        .unwrap_or(content.len());
    let dependencies_marker = "dependencies = [\n";
    let dependencies_start = content[package_start..package_end]
        .find(dependencies_marker)
        .map(|offset| package_start + offset + dependencies_marker.len())
        .with_context(|| {
            format!(
                "package {package} has no dependency list in lockfile {}",
                path.display()
            )
        })?;
    let dependencies_end = content[dependencies_start..package_end]
        .find("]\n")
        .map(|offset| dependencies_start + offset)
        .with_context(|| {
            format!(
                "package {package} has an unterminated dependency list in lockfile {}",
                path.display()
            )
        })?;
    let mut dependencies = content[dependencies_start..dependencies_end]
        .lines()
        .map(|line| {
            line.trim()
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix("\","))
                .map(str::to_owned)
                .with_context(|| {
                    format!(
                        "package {package} has a malformed dependency in lockfile {}",
                        path.display()
                    )
                })
        })
        .collect::<Result<Vec<_>>>()?;
    if dependencies.iter().any(|value| value == dependency) {
        return Ok(());
    }
    dependencies.push(dependency.to_owned());
    dependencies.sort();
    dependencies.dedup();
    let rendered = dependencies
        .iter()
        .map(|value| format!(" \"{value}\",\n"))
        .collect::<String>();
    let updated = format!(
        "{}{}{}",
        &content[..dependencies_start],
        rendered,
        &content[dependencies_end..]
    );
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_auth_generation_none_initializers(path: &Path) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let mut updated = String::with_capacity(content.len() + 512);
    let lines = content.lines().collect::<Vec<_>>();
    let mut index = 0;
    let mut initializer_has_generation = false;
    while index < lines.len() {
        let line = lines[index];
        if line.contains("Self {") {
            initializer_has_generation = false;
        }
        if line.contains("auth_generation: AtomicU64::new(0),") {
            initializer_has_generation = true;
        }
        if line.contains("auth_route_config: None,") && !initializer_has_generation {
            updated.push_str("            auth_generation: AtomicU64::new(0),\n");
            initializer_has_generation = true;
        }

        updated.push_str(line);
        updated.push('\n');

        if line.contains("external_auth: RwLock::new(None),") {
            let lookahead_end = (index + 8).min(lines.len());
            let has_generation = lines[index + 1..lookahead_end]
                .iter()
                .any(|next| next.contains("auth_generation: AtomicU64::new(0),"));
            if !has_generation && !initializer_has_generation {
                updated.push_str("            auth_generation: AtomicU64::new(0),\n");
                initializer_has_generation = true;
            }
        }

        index += 1;
    }
    if updated != content {
        fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    }
    Ok(())
}
