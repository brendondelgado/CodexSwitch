use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;
use std::os::unix::fs as unix_fs;

#[test]
fn files_doctor_reports_configured_roots_without_networking() {
    let temp = tempfile::tempdir().unwrap();
    let local_root = temp.path().join("securedrop");

    Command::cargo_bin("codexswitch-cli")
        .unwrap()
        .args([
            "files",
            "doctor",
            "--local-root",
            local_root.to_str().unwrap(),
            "--remote-root",
            "/home/signul/codexswitch-secure-files",
            "--host",
            "signul-vps",
            "--json",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"host\": \"signul-vps\""))
        .stdout(predicate::str::contains(
            "\"remoteRoot\": \"/home/signul/codexswitch-secure-files\"",
        ))
        .stdout(predicate::str::contains(
            "\"transport\": \"rsync-over-ssh\"",
        ));
}

#[test]
fn files_send_dry_run_builds_manifest_and_rsync_plan() {
    let temp = tempfile::tempdir().unwrap();
    let local_root = temp.path().join("securedrop");
    let payload = temp.path().join("battlecard.html");
    fs::write(&payload, "enterprise artifact\n").unwrap();

    Command::cargo_bin("codexswitch-cli")
        .unwrap()
        .args([
            "files",
            "send",
            payload.to_str().unwrap(),
            "--local-root",
            local_root.to_str().unwrap(),
            "--remote-root",
            "/home/signul/codexswitch-secure-files",
            "--host",
            "signul-vps",
            "--dry-run",
            "--json",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"dryRun\": true"))
        .stdout(predicate::str::contains("battlecard.html"))
        .stdout(predicate::str::contains(
            "signul-vps:/home/signul/codexswitch-secure-files/inbox/",
        ))
        .stdout(predicate::str::contains("\"sha256\":"));

    let manifest = local_root.join("manifests").join("battlecard.html.sha256");
    assert!(
        manifest.exists(),
        "expected {} to exist",
        manifest.display()
    );
}

#[test]
fn files_send_rejects_symlink_sources() {
    let temp = tempfile::tempdir().unwrap();
    let local_root = temp.path().join("securedrop");
    let target = temp.path().join("secret.txt");
    let link = temp.path().join("link.txt");
    fs::write(&target, "secret\n").unwrap();
    unix_fs::symlink(&target, &link).unwrap();

    Command::cargo_bin("codexswitch-cli")
        .unwrap()
        .args([
            "files",
            "send",
            link.to_str().unwrap(),
            "--local-root",
            local_root.to_str().unwrap(),
            "--remote-root",
            "/home/signul/codexswitch-secure-files",
            "--host",
            "signul-vps",
            "--dry-run",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("refusing symlink source"));
}
