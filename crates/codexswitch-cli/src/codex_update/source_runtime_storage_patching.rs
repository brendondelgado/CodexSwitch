const RUNTIME_STORAGE_PATCH_VERSION: &str = "0.144.1";
const RUNTIME_STORAGE_PATCH_COMMIT: &str =
    "44918ea10c0f99151c6710411b4322c2f5c96bea";
const RUNTIME_STORAGE_PATCH_MARKER: &str = "codex-rs/.codexswitch-runtime-storage-patch-v1";
const RUNTIME_STORAGE_PATCH_MARKER_BYTES: &str = concat!(
    "codexswitch-runtime-storage-hardening-v1\n",
    "upstream=44918ea10c0f99151c6710411b4322c2f5c96bea\n",
    "feature_default=off\n",
    "activation_authority=none\n",
);
const RUNTIME_STORAGE_PATCH: &str = include_str!(
    "../../../../patches/codex/0.144.1-runtime-storage-hardening.patch"
);
// Filled from the formatted, tested pinned source tree before the immutable freeze.
// The patch and final manifests have the same complete path denominator. They
// differ only where a later deterministic CodexSwitch transformation changes a
// runtime-storage-patched file (currently Cargo.lock placeholder versions).
const RUNTIME_STORAGE_PATCH_POSTIMAGES: &[(&str, &str)] = &[
    ("codex-rs/.codexswitch-runtime-storage-patch-v1", "c26185c6853c321dd606a3df8db2662f2c7286d2ea26c66f3d58c3f87ce9666e"),
    ("codex-rs/Cargo.lock", "5d433ef605c3fb1bdfc21968a23424480d1722a22a55a97410e9c6f4f988b5be"),
    ("codex-rs/Cargo.toml", "48bb3ebfb66487e0be32593fd01adeafade4052f2ada8dcbc9aa74c5c88955b2"),
    ("codex-rs/core/src/personality_migration.rs", "4c20219eeb7b0e565b177f2d612db2fbe21b2ad172926a0bd1aef0589ad09eab"),
    ("codex-rs/core/src/thread_manager.rs", "bc56c9941e48391076e460cf7abace6125535913f8904aa779b473072a2e09eb"),
    ("codex-rs/rollout/Cargo.toml", "5be9451cefb9b8156b92f302f7bf1f3d41ed2af9403d588b428e6b9a370354df"),
    ("codex-rs/rollout/src/bundle_move.rs", "dd2fe722ad0079c841604195b6be7f4933e73e0c0a3e5bb1ba502c1805ab12dc"),
    ("codex-rs/rollout/src/bundle_move_tests.rs", "31542e14c65e393110d043664704ab134b225b0e88222702459f008dcc286937"),
    ("codex-rs/rollout/src/compression.rs", "62184ccb26362b6d91fab9ae1d36dd0b955bfce92c46bf0a4b8fee90e05e0aff"),
    ("codex-rs/rollout/src/compression_worker.rs", "5e52db1c2f5b6bb501fc5647763bfbfa3eb24e07385ac2dfe99891e7e2e2a215"),
    ("codex-rs/rollout/src/lease.rs", "9c4068b636ea257343a72b01882161fcb00a4cfe96ea3bf0893db2d30d646037"),
    ("codex-rs/rollout/src/lease_tests.rs", "ff9ee906e5ea6b8a30898d0bfe9e67184dd41a3dacc205eb717c3f110a78fe79"),
    ("codex-rs/rollout/src/lib.rs", "6bc710f91a320e74939d5fcc3ea2304008e8a0775b196dbc745691a48e2ff94d"),
    ("codex-rs/rollout/src/manifest.rs", "55304923b780aa08b94492a260bc09d7c63d9237dbb3530a7cb3bda727b1dd0e"),
    ("codex-rs/rollout/src/manifest_tests.rs", "1a88f13280053760ccea73398cc1443ecd146603b280dfa52d2ba96515b2c3ff"),
    ("codex-rs/rollout/src/recorder.rs", "741df355151c5a8cbcd8397ea12cb16b6fc30f77fc5a52b3a9e029667ed5303e"),
    ("codex-rs/rollout/src/runtime_storage_compression_tests.rs", "082c9ef8557bb67a339f97558807722e648e097221fa9b40199caf43470b1374"),
    ("codex-rs/state/Cargo.toml", "9d4e8caf703519052767da32a0746281b343fa1997b47722ddd78575692b7e1b"),
    ("codex-rs/state/logs_migrations/0003_logs_maintenance.sql", "71654676d6ec6564ecc2bd7ec29abc7ad98d4756bf6840a3150aa8ccea0102be"),
    ("codex-rs/state/migrations/0041_runtime_storage_catalog.sql", "6ed910aed1b16463463e856cf2ade6f9f45628a8999e42fe5e82e14a05ff6c34"),
    ("codex-rs/state/src/lib.rs", "48a35f9c7671a3e80e41ded9b3ab7bd0247d8bdfca88c4a4c0418e73211ef1d6"),
    ("codex-rs/state/src/runtime.rs", "2377fedc99c7c8575b4622391542707654b83f15f62515454b9e8c34d901085a"),
    ("codex-rs/state/src/runtime/logs.rs", "ffd25d01fe2a97bf7ff656ddacc4cd8d9d85efdcafdb56bce54b315fccc45fd0"),
    ("codex-rs/state/src/runtime/runtime_storage.rs", "d752e3af42684cd508d059bdccc44e07181dbfffa6d687e36ccf431a43d1609d"),
    ("codex-rs/state/src/runtime/runtime_storage_tests.rs", "661e619adc9aded5a2dce8f6915ed3b7dac55bd94d20507fea8bbf9780857430"),
    ("codex-rs/state/src/runtime/threads.rs", "5db82e1761ef8f51733aec510b330abf203ebe9af9334a763578d944f3bc94a2"),
    ("codex-rs/thread-store/src/local/archive_thread.rs", "a8d4525a30b53e115a62657b7e35c9c3bbab107265b3445470068b1b583dae14"),
    ("codex-rs/thread-store/src/local/delete_thread.rs", "3391117ec4cf5371bd808760887d27ccb11cbc07c8ccea7c038b92d64c107e86"),
    ("codex-rs/thread-store/src/local/mod.rs", "fe8eca22232b1914066cf9dcc67ab19b292132b56d37aa186e76bc8e9ad6facc"),
    ("codex-rs/thread-store/src/local/test_support.rs", "780bc95b6d139cb14ed6f9e991df185d8985cc75134f75c13b9281361db2188f"),
    ("codex-rs/thread-store/src/local/unarchive_thread.rs", "ee4ee7d8461154a7c9aeefbd7dc98bf146a11e6bad761a861b791f97cf9fd747"),
];
const RUNTIME_STORAGE_FINAL_POSTIMAGES: &[(&str, &str)] = &[
    ("codex-rs/.codexswitch-runtime-storage-patch-v1", "c26185c6853c321dd606a3df8db2662f2c7286d2ea26c66f3d58c3f87ce9666e"),
    ("codex-rs/Cargo.lock", "f6b69fcc6698a070800af01c0698d295088c434abeb4d8d1b4f24f21908744b7"),
    ("codex-rs/Cargo.toml", "48bb3ebfb66487e0be32593fd01adeafade4052f2ada8dcbc9aa74c5c88955b2"),
    ("codex-rs/core/src/personality_migration.rs", "4c20219eeb7b0e565b177f2d612db2fbe21b2ad172926a0bd1aef0589ad09eab"),
    ("codex-rs/core/src/thread_manager.rs", "bc56c9941e48391076e460cf7abace6125535913f8904aa779b473072a2e09eb"),
    ("codex-rs/rollout/Cargo.toml", "5be9451cefb9b8156b92f302f7bf1f3d41ed2af9403d588b428e6b9a370354df"),
    ("codex-rs/rollout/src/bundle_move.rs", "dd2fe722ad0079c841604195b6be7f4933e73e0c0a3e5bb1ba502c1805ab12dc"),
    ("codex-rs/rollout/src/bundle_move_tests.rs", "31542e14c65e393110d043664704ab134b225b0e88222702459f008dcc286937"),
    ("codex-rs/rollout/src/compression.rs", "62184ccb26362b6d91fab9ae1d36dd0b955bfce92c46bf0a4b8fee90e05e0aff"),
    ("codex-rs/rollout/src/compression_worker.rs", "5e52db1c2f5b6bb501fc5647763bfbfa3eb24e07385ac2dfe99891e7e2e2a215"),
    ("codex-rs/rollout/src/lease.rs", "9c4068b636ea257343a72b01882161fcb00a4cfe96ea3bf0893db2d30d646037"),
    ("codex-rs/rollout/src/lease_tests.rs", "ff9ee906e5ea6b8a30898d0bfe9e67184dd41a3dacc205eb717c3f110a78fe79"),
    ("codex-rs/rollout/src/lib.rs", "6bc710f91a320e74939d5fcc3ea2304008e8a0775b196dbc745691a48e2ff94d"),
    ("codex-rs/rollout/src/manifest.rs", "55304923b780aa08b94492a260bc09d7c63d9237dbb3530a7cb3bda727b1dd0e"),
    ("codex-rs/rollout/src/manifest_tests.rs", "1a88f13280053760ccea73398cc1443ecd146603b280dfa52d2ba96515b2c3ff"),
    ("codex-rs/rollout/src/recorder.rs", "741df355151c5a8cbcd8397ea12cb16b6fc30f77fc5a52b3a9e029667ed5303e"),
    ("codex-rs/rollout/src/runtime_storage_compression_tests.rs", "082c9ef8557bb67a339f97558807722e648e097221fa9b40199caf43470b1374"),
    ("codex-rs/state/Cargo.toml", "9d4e8caf703519052767da32a0746281b343fa1997b47722ddd78575692b7e1b"),
    ("codex-rs/state/logs_migrations/0003_logs_maintenance.sql", "71654676d6ec6564ecc2bd7ec29abc7ad98d4756bf6840a3150aa8ccea0102be"),
    ("codex-rs/state/migrations/0041_runtime_storage_catalog.sql", "6ed910aed1b16463463e856cf2ade6f9f45628a8999e42fe5e82e14a05ff6c34"),
    ("codex-rs/state/src/lib.rs", "48a35f9c7671a3e80e41ded9b3ab7bd0247d8bdfca88c4a4c0418e73211ef1d6"),
    ("codex-rs/state/src/runtime.rs", "2377fedc99c7c8575b4622391542707654b83f15f62515454b9e8c34d901085a"),
    ("codex-rs/state/src/runtime/logs.rs", "ffd25d01fe2a97bf7ff656ddacc4cd8d9d85efdcafdb56bce54b315fccc45fd0"),
    ("codex-rs/state/src/runtime/runtime_storage.rs", "d752e3af42684cd508d059bdccc44e07181dbfffa6d687e36ccf431a43d1609d"),
    ("codex-rs/state/src/runtime/runtime_storage_tests.rs", "661e619adc9aded5a2dce8f6915ed3b7dac55bd94d20507fea8bbf9780857430"),
    ("codex-rs/state/src/runtime/threads.rs", "5db82e1761ef8f51733aec510b330abf203ebe9af9334a763578d944f3bc94a2"),
    ("codex-rs/thread-store/src/local/archive_thread.rs", "a8d4525a30b53e115a62657b7e35c9c3bbab107265b3445470068b1b583dae14"),
    ("codex-rs/thread-store/src/local/delete_thread.rs", "3391117ec4cf5371bd808760887d27ccb11cbc07c8ccea7c038b92d64c107e86"),
    ("codex-rs/thread-store/src/local/mod.rs", "fe8eca22232b1914066cf9dcc67ab19b292132b56d37aa186e76bc8e9ad6facc"),
    ("codex-rs/thread-store/src/local/test_support.rs", "780bc95b6d139cb14ed6f9e991df185d8985cc75134f75c13b9281361db2188f"),
    ("codex-rs/thread-store/src/local/unarchive_thread.rs", "ee4ee7d8461154a7c9aeefbd7dc98bf146a11e6bad761a861b791f97cf9fd747"),
];

fn apply_runtime_storage_source_patch(version: &str, source_dir: &Path) -> Result<()> {
    apply_runtime_storage_source_patch_contract(
        version,
        source_dir,
        RUNTIME_STORAGE_PATCH_VERSION,
        RUNTIME_STORAGE_PATCH_COMMIT,
        RUNTIME_STORAGE_PATCH_MARKER,
        RUNTIME_STORAGE_PATCH_MARKER_BYTES,
        RUNTIME_STORAGE_PATCH,
        RUNTIME_STORAGE_PATCH_POSTIMAGES,
    )
}

fn verify_runtime_storage_source_patch(source_dir: &Path) -> Result<()> {
    verify_runtime_storage_postimages(source_dir, RUNTIME_STORAGE_FINAL_POSTIMAGES)?;
    verify_runtime_storage_lockfile(source_dir)
}

#[allow(clippy::too_many_arguments)]
fn apply_runtime_storage_source_patch_contract(
    version: &str,
    source_dir: &Path,
    expected_version: &str,
    expected_commit: &str,
    marker_relative: &str,
    marker_bytes: &str,
    patch: &str,
    postimages: &[(&str, &str)],
) -> Result<()> {
    if version != expected_version {
        bail!(
            "runtime-storage hardening is pinned to Codex {expected_version}; refusing {version}"
        );
    }
    let output = bounded_command::output(
        Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(source_dir),
        SOURCE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .with_context(|| format!("failed to identify Codex source at {}", source_dir.display()))?;
    if !output.status.success() {
        bail!(
            "failed to identify Codex source at {}: {}",
            source_dir.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let observed_commit = String::from_utf8(output.stdout)
        .context("Codex source commit is not UTF-8")?;
    if observed_commit.trim() != expected_commit {
        bail!(
            "runtime-storage source contract expected {expected_commit}, found {}",
            observed_commit.trim()
        );
    }

    let marker = source_dir.join(marker_relative);
    if marker.exists() {
        let observed = fs::read_to_string(&marker)
            .with_context(|| format!("failed to read runtime-storage marker {}", marker.display()))?;
        if observed == marker_bytes {
            verify_runtime_storage_postimages(source_dir, postimages)?;
            return Ok(());
        }
        bail!(
            "runtime-storage marker exists with unexpected content: {}",
            marker.display()
        );
    }

    let mut patch_file = tempfile::NamedTempFile::new()
        .context("failed to stage embedded runtime-storage patch")?;
    patch_file
        .write_all(patch.as_bytes())
        .context("failed to write embedded runtime-storage patch")?;
    patch_file
        .flush()
        .context("failed to flush embedded runtime-storage patch")?;
    patch_file
        .as_file()
        .sync_all()
        .context("failed to sync embedded runtime-storage patch")?;

    let check = bounded_command::output(
        Command::new("git")
            .args(["apply", "--check", "--whitespace=error-all"])
            .arg(patch_file.path())
            .current_dir(source_dir),
        SOURCE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .context("failed to validate embedded runtime-storage patch")?;
    if !check.status.success() {
        bail!(
            "runtime-storage patch does not apply exactly: {}",
            String::from_utf8_lossy(&check.stderr).trim()
        );
    }
    let apply = bounded_command::output(
        Command::new("git")
            .args(["apply", "--whitespace=error-all"])
            .arg(patch_file.path())
            .current_dir(source_dir),
        SOURCE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .context("failed to apply embedded runtime-storage patch")?;
    if !apply.status.success() {
        bail!(
            "runtime-storage patch application failed: {}",
            String::from_utf8_lossy(&apply.stderr).trim()
        );
    }
    let observed = fs::read_to_string(&marker).with_context(|| {
        format!(
            "runtime-storage patch did not install its marker {}",
            marker.display()
        )
    })?;
    if observed != marker_bytes {
        bail!("runtime-storage patch marker verification failed");
    }
    verify_runtime_storage_postimages(source_dir, postimages)?;
    Ok(())
}

fn verify_runtime_storage_postimages(
    source_dir: &Path,
    postimages: &[(&str, &str)],
) -> Result<()> {
    if postimages.is_empty() {
        bail!("runtime-storage postimage manifest is empty");
    }
    for (relative, expected_sha256) in postimages {
        let path = source_dir.join(relative);
        let bytes = fs::read(&path)
            .with_context(|| format!("runtime-storage postimage is missing: {}", path.display()))?;
        let observed = sha256_hex(bytes.as_slice());
        if observed != *expected_sha256 {
            bail!(
                "runtime-storage postimage mismatch for {relative}: expected {expected_sha256}, found {observed}"
            );
        }
    }
    Ok(())
}

fn verify_runtime_storage_lockfile(source_dir: &Path) -> Result<()> {
    let path = source_dir.join("codex-rs/Cargo.lock");
    let contents = fs::read_to_string(&path)
        .with_context(|| format!("failed to read runtime-storage lockfile {}", path.display()))?;
    let package = contents
        .split("[[package]]\n")
        .find(|block| block.starts_with("name = \"codex-rollout\"\n"))
        .context("codex-rollout package is missing from Cargo.lock")?;
    for dependency in ["fs2", "gethostname", "sha2 0.10.9"] {
        let needle = format!(" \"{dependency}\",");
        if !package.contains(&needle) {
            bail!("codex-rollout lockfile dependency is missing: {dependency}");
        }
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod runtime_storage_source_patch_tests {
    use super::*;

    fn git(directory: &Path, arguments: &[&str]) -> String {
        let output = std::process::Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .output()
            .expect("git command");
        assert!(
            output.status.success(),
            "git {:?}: {}",
            arguments,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("utf8")
            .trim()
            .to_string()
    }

    fn fixture() -> (tempfile::TempDir, String) {
        let directory = tempfile::tempdir().expect("temp repo");
        git(directory.path(), &["init", "--quiet"]);
        git(directory.path(), &["config", "user.email", "synthetic@example.invalid"]);
        git(directory.path(), &["config", "user.name", "Synthetic Fixture"]);
        fs::write(directory.path().join("fixture.txt"), "before\n").expect("fixture");
        git(directory.path(), &["add", "fixture.txt"]);
        git(directory.path(), &["commit", "--quiet", "-m", "synthetic"]);
        let commit = git(directory.path(), &["rev-parse", "HEAD"]);
        (directory, commit)
    }

    const PATCH: &str = concat!(
        "diff --git a/fixture.txt b/fixture.txt\n",
        "index 90be1f3..294186e 100644\n",
        "--- a/fixture.txt\n",
        "+++ b/fixture.txt\n",
        "@@ -1 +1 @@\n",
        "-before\n",
        "+after\n",
        "diff --git a/marker b/marker\n",
        "new file mode 100644\n",
        "index 0000000..f94d6ed\n",
        "--- /dev/null\n",
        "+++ b/marker\n",
        "@@ -0,0 +1 @@\n",
        "+installed\n",
    );

    #[test]
    fn embedded_patch_and_postimage_manifests_have_one_complete_denominator() {
        let patch_paths = RUNTIME_STORAGE_PATCH
            .lines()
            .filter_map(|line| line.strip_prefix("diff --git a/"))
            .map(|line| {
                line.split_once(" b/")
                    .expect("well-formed embedded patch path")
                    .0
            })
            .collect::<std::collections::BTreeSet<_>>();
        let patch_postimages = RUNTIME_STORAGE_PATCH_POSTIMAGES
            .iter()
            .map(|(path, digest)| {
                assert_eq!(digest.len(), 64, "SHA-256 length for {path}");
                assert!(
                    digest.bytes().all(|byte| byte.is_ascii_hexdigit()),
                    "SHA-256 encoding for {path}"
                );
                *path
            })
            .collect::<std::collections::BTreeSet<_>>();
        let final_postimages = RUNTIME_STORAGE_FINAL_POSTIMAGES
            .iter()
            .map(|(path, digest)| {
                assert_eq!(digest.len(), 64, "final SHA-256 length for {path}");
                assert!(
                    digest.bytes().all(|byte| byte.is_ascii_hexdigit()),
                    "final SHA-256 encoding for {path}"
                );
                *path
            })
            .collect::<std::collections::BTreeSet<_>>();

        assert!(!patch_paths.is_empty(), "embedded patch has no paths");
        assert_eq!(patch_postimages, patch_paths);
        assert_eq!(final_postimages, patch_paths);
        assert!(patch_paths.contains(RUNTIME_STORAGE_PATCH_MARKER));
    }

    #[test]
    fn patch_is_idempotent_and_refuses_wrong_version_or_source() {
        let (repo, commit) = fixture();
        let expected_hash = sha256_hex(b"after\n");
        let postimages = [("fixture.txt", expected_hash.as_str())];
        apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .expect("first apply");
        apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .expect("idempotent apply");
        assert_eq!(fs::read_to_string(repo.path().join("fixture.txt")).unwrap(), "after\n");

        assert!(apply_runtime_storage_source_patch_contract(
            "wrong-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .is_err());
        assert!(apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            "0000000000000000000000000000000000000000",
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .is_err());

        fs::write(repo.path().join("fixture.txt"), "before\n").unwrap();
        assert!(apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .is_err());
        fs::write(repo.path().join("fixture.txt"), "mutated\n").unwrap();
        assert!(apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &postimages,
        )
        .is_err());
    }

    #[test]
    fn final_verifier_catches_downstream_overlap_or_drift() {
        let (repo, commit) = fixture();
        let patch_hash = sha256_hex(b"after\n");
        let final_hash = sha256_hex(b"after downstream\n");
        let patch_postimages = [("fixture.txt", patch_hash.as_str())];
        let final_postimages = [("fixture.txt", final_hash.as_str())];
        apply_runtime_storage_source_patch_contract(
            "test-version",
            repo.path(),
            "test-version",
            &commit,
            "marker",
            "installed\n",
            PATCH,
            &patch_postimages,
        )
        .expect("first apply");

        assert!(verify_runtime_storage_postimages(repo.path(), &final_postimages).is_err());
        fs::write(repo.path().join("fixture.txt"), "after downstream\n").unwrap();
        verify_runtime_storage_postimages(repo.path(), &final_postimages)
            .expect("exact downstream postimage");
        fs::write(repo.path().join("fixture.txt"), "drifted after downstream\n").unwrap();
        assert!(verify_runtime_storage_postimages(repo.path(), &final_postimages).is_err());
    }
}
