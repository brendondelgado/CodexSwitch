//! Prepare sandboxed V8 inputs using the exact upstream source's checksum trust root.
//! Mirrors .github/actions/setup-rusty-v8 without executing downloaded code.
use crate::bounded_command;
use anyhow::{bail, Context, Result};
use ring::digest::{Context as DigestContext, SHA256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const MANIFEST_LIMIT: u64 = 64 * 1024;
const ARCHIVE_LIMIT: u64 = 256 * 1024 * 1024;
const BINDING_LIMIT: u64 = 4 * 1024 * 1024;

pub(super) struct VerifiedV8 {
    _directory: tempfile::TempDir,
    archive: PathBuf,
    binding: PathBuf,
}

impl VerifiedV8 {
    pub(super) fn configure(&self, command: &mut Command) {
        command
            .env("RUSTY_V8_ARCHIVE", &self.archive)
            .env("RUSTY_V8_SRC_BINDING_PATH", &self.binding)
            .env_remove("RUSTY_V8_MIRROR")
            .env_remove("V8_FROM_SOURCE");
    }
}

pub(super) fn prepare(workspace: &Path) -> Result<Option<VerifiedV8>> {
    let target = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", arch @ ("x86_64" | "aarch64")) => {
            let abi = if cfg!(target_env = "musl") {
                "musl"
            } else {
                "gnu"
            };
            format!("{arch}-unknown-linux-{abi}")
        }
        ("macos", arch @ ("x86_64" | "aarch64")) => format!("{arch}-apple-darwin"),
        _ => bail!("unsupported host for verified sandboxed V8 build"),
    };
    if std::env::var_os("CARGO_BUILD_TARGET").is_some_and(|value| value != target.as_str()) {
        bail!("verified sandboxed V8 build requires the native Cargo target {target}");
    }
    prepare_with(workspace, &target, |url, destination, limit| {
        let status = bounded_command::status(
            Command::new("curl")
                .args([
                    "--disable",
                    "--proto",
                    "=https",
                    "--proto-redir",
                    "=https",
                    "--tlsv1.2",
                    "--fail",
                    "--location",
                    "--silent",
                    "--show-error",
                    "--connect-timeout",
                    "10",
                    "--max-time",
                    "30",
                    "--max-filesize",
                ])
                .arg(limit.to_string())
                .arg("--output")
                .arg(destination)
                .arg(url),
            Duration::from_secs(35),
        )?;
        if !status.success() {
            bail!("verified sandboxed V8 download failed for {url}: {status}");
        }
        Ok(())
    })
}

fn prepare_with(
    workspace: &Path,
    target: &str,
    mut fetch: impl FnMut(&str, &Path, u64) -> Result<()>,
) -> Result<Option<VerifiedV8>> {
    let cargo: toml::Value =
        toml::from_str(&read_text(&workspace.join("Cargo.toml"), MANIFEST_LIMIT)?)?;
    let codex_version = cargo
        .get("workspace")
        .and_then(|v| v.get("package"))
        .and_then(|v| v.get("version"))
        .and_then(toml::Value::as_str)
        .context("Codex workspace version is missing")?;
    let lock: toml::Value =
        toml::from_str(&read_text(&workspace.join("Cargo.lock"), 16 * 1024 * 1024)?)?;
    let packages = lock
        .get("package")
        .and_then(toml::Value::as_array)
        .context("Codex lockfile package list is missing")?;
    let versions: Vec<_> = packages
        .iter()
        .filter(|p| p.get("name").and_then(toml::Value::as_str) == Some("v8"))
        .map(|p| p.get("version").and_then(toml::Value::as_str))
        .collect();
    let version = match versions.as_slice() {
        [Some(version)] if stable_version(version) => *version,
        _ => bail!("expected exactly one stable V8 version in Codex Cargo.lock"),
    };
    let root = workspace
        .parent()
        .context("Codex workspace has no source root")?;
    let pins_path = root.join("third_party/v8").join(format!(
        "rusty_v8_{}_release_manifests.sha256",
        version.replace('.', "_")
    ));
    match fs::symlink_metadata(&pins_path) {
        Err(error)
            if error.kind() == std::io::ErrorKind::NotFound && codex_version == "0.153.2" =>
        {
            // Preserve the previously supported recipe for this exact legacy revision only.
            return Ok(None);
        }
        Err(error) => {
            return Err(error).context("source-pinned V8 release manifests are unavailable")
        }
        Ok(_) => {}
    }
    let pins = parse_checksums(&read_text(&pins_path, MANIFEST_LIMIT)?)?;
    let profile = format!("ptrcomp_sandbox_release_{target}");
    let manifest_name = format!("rusty_v8_{profile}.sha256");
    let archive_name = format!("librusty_v8_{profile}.a.gz");
    let binding_name = format!("src_binding_{profile}.rs");
    let expected_manifest = pins
        .get(&manifest_name)
        .context("source does not pin a sandboxed V8 manifest for this target")?;

    // Private downloads stay inside the existing build target, away from live runtime routes.
    let target_root = workspace.join("target");
    fs::create_dir_all(&target_root)?;
    if !fs::symlink_metadata(&target_root)?.is_dir() {
        bail!("V8 build target directory must be a real directory");
    }
    let directory = tempfile::Builder::new()
        .prefix("codexswitch-v8-")
        .tempdir_in(&target_root)?;
    let base = format!("https://github.com/openai/codex/releases/download/rusty-v8-v{version}");
    let manifest = directory.path().join(&manifest_name);
    fetch(
        &format!("{base}/{manifest_name}"),
        &manifest,
        MANIFEST_LIMIT,
    )?;
    verify_digest(&manifest, expected_manifest, MANIFEST_LIMIT)?;
    let checksums = parse_checksums(&read_text(&manifest, MANIFEST_LIMIT)?)?;
    if checksums.len() != 2
        || !checksums.contains_key(&archive_name)
        || !checksums.contains_key(&binding_name)
    {
        bail!("sandboxed V8 manifest must name exactly the matching archive and bindings");
    }
    let archive = directory.path().join(&archive_name);
    let binding = directory.path().join(&binding_name);
    for (name, destination, limit) in [
        (&archive_name, &archive, ARCHIVE_LIMIT),
        (&binding_name, &binding, BINDING_LIMIT),
    ] {
        fetch(&format!("{base}/{name}"), destination, limit)?;
        verify_digest(destination, &checksums[name], limit)?;
    }
    Ok(Some(VerifiedV8 {
        _directory: directory,
        archive,
        binding,
    }))
}

fn stable_version(version: &str) -> bool {
    let parts: Vec<_> = version.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

fn open_bounded(path: &Path, limit: u64) -> Result<fs::File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > limit {
        bail!(
            "V8 input must be a nonempty bounded regular file: {}",
            path.display()
        );
    }
    Ok(file)
}

fn read_text(path: &Path, limit: u64) -> Result<String> {
    let mut value = String::new();
    open_bounded(path, limit)?
        .take(limit + 1)
        .read_to_string(&mut value)?;
    if value.len() as u64 > limit {
        bail!("V8 text input exceeds byte limit");
    }
    Ok(value)
}

fn verify_digest(path: &Path, expected: &str, limit: u64) -> Result<()> {
    let mut file = open_bounded(path, limit)?.take(limit + 1);
    let mut digest = DigestContext::new(&SHA256);
    let mut total = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > limit {
            bail!("V8 artifact exceeds byte limit");
        }
        digest.update(&buffer[..count]);
    }
    let actual: String = digest
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if actual != expected {
        bail!("sandboxed V8 SHA-256 mismatch: {}", path.display());
    }
    Ok(())
}

fn parse_checksums(text: &str) -> Result<BTreeMap<String, String>> {
    let mut entries = BTreeMap::new();
    for line in text.lines() {
        let (digest, name) = line.split_once("  ").context("invalid V8 checksum line")?;
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || name.is_empty()
            || name == "."
            || name == ".."
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            || entries.insert(name.to_owned(), digest.to_owned()).is_some()
        {
            bail!("invalid or duplicate V8 checksum entry");
        }
    }
    if entries.is_empty() {
        bail!("empty V8 checksum manifest");
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    const TARGET: &str = "x86_64-unknown-linux-gnu";
    const MANIFEST: &str = "rusty_v8_ptrcomp_sandbox_release_x86_64-unknown-linux-gnu.sha256";
    const ARCHIVE: &str = "librusty_v8_ptrcomp_sandbox_release_x86_64-unknown-linux-gnu.a.gz";
    const BINDING: &str = "src_binding_ptrcomp_sandbox_release_x86_64-unknown-linux-gnu.rs";

    fn digest(bytes: &[u8]) -> String {
        ring::digest::digest(&SHA256, bytes)
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    struct Fixture {
        root: tempfile::TempDir,
        files: BTreeMap<String, Vec<u8>>,
    }

    impl Fixture {
        fn new(version: &str) -> Self {
            let root = tempfile::tempdir().unwrap();
            fs::create_dir(root.path().join("codex-rs")).unwrap();
            fs::create_dir_all(root.path().join("third_party/v8")).unwrap();
            fs::write(
                root.path().join("codex-rs/Cargo.toml"),
                format!("[workspace.package]\nversion = {version:?}\n"),
            )
            .unwrap();
            fs::write(
                root.path().join("codex-rs/Cargo.lock"),
                "[[package]]\nname = \"v8\"\nversion = \"150.4.0\"\n",
            )
            .unwrap();
            let mut fixture = Self {
                root,
                files: BTreeMap::from([
                    (ARCHIVE.to_string(), b"fixture archive bytes".to_vec()),
                    (BINDING.to_string(), b"fixture binding bytes".to_vec()),
                ]),
            };
            let manifest = format!(
                "{}  {ARCHIVE}\r\n{}  {BINDING}\r\n",
                digest(&fixture.files[ARCHIVE]),
                digest(&fixture.files[BINDING])
            );
            fixture.set_manifest(manifest.into_bytes());
            fixture
        }

        fn workspace(&self) -> PathBuf {
            self.root.path().join("codex-rs")
        }
        fn pins(&self) -> PathBuf {
            self.root
                .path()
                .join("third_party/v8/rusty_v8_150_4_0_release_manifests.sha256")
        }
        fn set_manifest(&mut self, bytes: Vec<u8>) {
            fs::write(self.pins(), format!("{}  {MANIFEST}\n", digest(&bytes))).unwrap();
            self.files.insert(MANIFEST.to_string(), bytes);
        }
        fn fetch(&self, url: &str, path: &Path, limit: u64) -> Result<()> {
            assert!(url.starts_with(
                "https://github.com/openai/codex/releases/download/rusty-v8-v150.4.0/"
            ));
            let bytes = &self.files[url.rsplit('/').next().unwrap()];
            assert!(bytes.len() as u64 <= limit);
            fs::write(path, bytes)?;
            Ok(())
        }
    }

    #[test]
    fn verified_pair_uses_source_pin_and_sets_both_overrides() -> Result<()> {
        let fixture = Fixture::new("0.159.2");
        let mut requests = Vec::new();
        let prepared = prepare_with(&fixture.workspace(), TARGET, |url, path, limit| {
            requests.push(url.rsplit('/').next().unwrap().to_string());
            fixture.fetch(url, path, limit)
        })?
        .context("expected verified dependencies")?;
        assert_eq!(requests, [MANIFEST, ARCHIVE, BINDING]);
        assert_eq!(fs::read(&prepared.archive)?, fixture.files[ARCHIVE]);
        assert_eq!(fs::read(&prepared.binding)?, fixture.files[BINDING]);
        let mut command = Command::new("cargo");
        prepared.configure(&mut command);
        let env: BTreeMap<_, _> = command.get_envs().collect();
        assert_eq!(
            env[std::ffi::OsStr::new("RUSTY_V8_ARCHIVE")],
            Some(prepared.archive.as_os_str())
        );
        assert_eq!(
            env[std::ffi::OsStr::new("RUSTY_V8_SRC_BINDING_PATH")],
            Some(prepared.binding.as_os_str())
        );
        assert_eq!(env[std::ffi::OsStr::new("V8_FROM_SOURCE")], None);
        assert_eq!(env[std::ffi::OsStr::new("RUSTY_V8_MIRROR")], None);
        let archive = prepared.archive.clone();
        drop(prepared);
        assert!(!archive.exists());
        Ok(())
    }

    #[test]
    fn only_exact_legacy_version_may_omit_new_pins() -> Result<()> {
        for version in ["0.153.2", "0.159.2", "0.160.0"] {
            let fixture = Fixture::new(version);
            fs::remove_file(fixture.pins())?;
            let result = prepare_with(&fixture.workspace(), TARGET, |_, _, _| {
                panic!("must not fetch")
            });
            if version == "0.153.2" {
                assert!(result?.is_none());
            } else {
                assert!(result.is_err());
            }
        }
        Ok(())
    }

    #[test]
    fn tampered_release_manifest_is_rejected_before_artifact_download() {
        let fixture = Fixture::new("0.159.2");
        let mut calls = 0;
        let result = prepare_with(&fixture.workspace(), TARGET, |url, path, limit| {
            calls += 1;
            fixture.fetch(url, path, limit)?;
            fs::write(path, b"tampered manifest")?;
            Ok(())
        });
        assert!(result
            .err()
            .unwrap()
            .to_string()
            .contains("SHA-256 mismatch"));
        assert_eq!(calls, 1);
    }

    #[test]
    fn pinned_manifest_cannot_add_or_replace_an_artifact_name() {
        let mut fixture = Fixture::new("0.159.2");
        fixture.set_manifest(
            format!(
                "{}  {ARCHIVE}\n{}  other.rs\n",
                digest(&fixture.files[ARCHIVE]),
                digest(&fixture.files[BINDING])
            )
            .into_bytes(),
        );
        let mut calls = 0;
        let result = prepare_with(&fixture.workspace(), TARGET, |url, path, limit| {
            calls += 1;
            fixture.fetch(url, path, limit)
        });
        assert!(result
            .err()
            .unwrap()
            .to_string()
            .contains("exactly the matching"));
        assert_eq!(calls, 1);
    }

    #[test]
    fn mismatched_artifact_digest_refuses_and_cleans_private_downloads() {
        let fixture = Fixture::new("0.159.2");
        let result = prepare_with(&fixture.workspace(), TARGET, |url, path, limit| {
            fixture.fetch(url, path, limit)?;
            if url.ends_with(ARCHIVE) {
                fs::write(path, b"wrong archive")?;
            }
            Ok(())
        });
        assert!(result
            .err()
            .unwrap()
            .to_string()
            .contains("SHA-256 mismatch"));
        assert_eq!(
            fs::read_dir(fixture.workspace().join("target"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn ambiguous_v8_version_and_missing_target_pin_refuse_without_downloads() {
        let fixture = Fixture::new("0.159.2");
        assert!(prepare_with(
            &fixture.workspace(),
            "aarch64-unknown-linux-gnu",
            |_, _, _| panic!("must not fetch")
        )
        .is_err());
        fs::write(fixture.workspace().join("Cargo.lock"),
            "[[package]]\nname = \"v8\"\nversion = \"150.4.0\"\n[[package]]\nname = \"v8\"\nversion = \"150.5.0\"\n").unwrap();
        assert!(prepare_with(&fixture.workspace(), TARGET, |_, _, _| panic!(
            "must not fetch"
        ))
        .is_err());
    }

    #[test]
    fn checksum_parser_rejects_duplicates_traversal_and_invalid_hashes() {
        let hash = digest(b"fixture");
        for invalid in [
            format!("{hash}  file\n{hash}  file\n"),
            format!("{hash}  ../file\n"),
            format!("{hash}  /tmp/file\n"),
            "not-a-hash  file\n".to_string(),
            String::new(),
        ] {
            assert!(parse_checksums(&invalid).is_err());
        }
    }

    #[test]
    fn linked_and_oversized_inputs_are_rejected() -> Result<()> {
        let fixture = Fixture::new("0.159.2");
        let pins = fs::read(fixture.pins())?;
        fs::remove_file(fixture.pins())?;
        let real = fixture.root.path().join("real-pins");
        fs::write(&real, pins)?;
        symlink(&real, fixture.pins())?;
        assert!(prepare_with(&fixture.workspace(), TARGET, |_, _, _| panic!(
            "must not fetch"
        ))
        .is_err());
        assert!(read_text(&real, 4).is_err());
        let result = verify_digest(&real, &digest(b"wrong"), 4);
        assert!(result.is_err());
        let fifo = fixture.root.path().join("fifo");
        let fifo_name = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes())?;
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        assert!(read_text(&fifo, MANIFEST_LIMIT).is_err());
        Ok(())
    }
}
