fn checkout_stable_source(version: &str, source_dir: &Path) -> Result<()> {
    let tag = stable_source_tag(version)?;
    if source_dir.join(".git").exists() {
        let status = bounded_command::status_inherited(
            Command::new("git")
                .arg("fetch")
                .arg("--tags")
                .arg("--force")
                .current_dir(source_dir),
            SOURCE_COMMAND_TIMEOUT,
        )
        .with_context(|| format!("failed to fetch tags in {}", source_dir.display()))?;
        if !status.success() {
            bail!("git fetch failed with {status}");
        }
        let status = bounded_command::status_inherited(
            Command::new("git")
                .arg("checkout")
                .arg("--force")
                .arg(&tag)
                .current_dir(source_dir),
            SOURCE_COMMAND_TIMEOUT,
        )
        .with_context(|| format!("failed to checkout {tag} in {}", source_dir.display()))?;
        if !status.success() {
            bail!("git checkout {tag} failed with {status}");
        }
        return Ok(());
    }

    if let Some(parent) = source_dir.parent() {
        fs::create_dir_all(parent)?;
    }
    let status = bounded_command::status_inherited(
        Command::new("git")
            .arg("clone")
            .arg("--depth")
            .arg("1")
            .arg("--branch")
            .arg(&tag)
            .arg(CODEX_REPO_URL)
            .arg(source_dir),
        SOURCE_COMMAND_TIMEOUT,
    )
    .with_context(|| format!("failed to clone Codex source tag {tag}"))?;
    if !status.success() {
        bail!("git clone {tag} failed with {status}");
    }
    Ok(())
}
