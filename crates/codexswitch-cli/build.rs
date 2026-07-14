use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let repository = manifest.join("../..");
    let git_sha =
        git_output(&repository, &["rev-parse", "HEAD"]).unwrap_or_else(|| "unknown".to_string());
    let dirty = Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=normal"])
        .current_dir(&repository)
        .output()
        .map(|output| !output.status.success() || !output.stdout.is_empty())
        .unwrap_or(true);
    let build_epoch = env::var("SOURCE_DATE_EPOCH").ok().unwrap_or_else(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    });
    let package_version = env::var("CARGO_PKG_VERSION").expect("package version");
    let dirty_suffix = if dirty { "-dirty" } else { "" };
    let version = format!("{package_version} (git {git_sha}{dirty_suffix}, built {build_epoch})");

    println!("cargo:rustc-env=CODEXSWITCH_BUILD_VERSION={version}");
    println!("cargo:rerun-if-env-changed=SOURCE_DATE_EPOCH");
    emit_git_dependency(&repository, "HEAD");
    if let Some(head_ref) = git_output(&repository, &["symbolic-ref", "-q", "HEAD"]) {
        emit_git_dependency(&repository, &head_ref);
    }
    emit_git_dependency(&repository, "packed-refs");
}

fn emit_git_dependency(repository: &Path, name: &str) {
    let Some(path) = git_output(repository, &["rev-parse", "--git-path", name]) else {
        return;
    };
    let path = PathBuf::from(path);
    let path = if path.is_absolute() {
        path
    } else {
        repository.join(path)
    };
    println!("cargo:rerun-if-changed={}", path.display());
}

fn git_output(repository: &Path, arguments: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(arguments)
        .current_dir(repository)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}
