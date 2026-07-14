fn patch_placeholder_workspace_lock_versions_if_present(
    workspace_manifest: &Path,
    lockfile: &Path,
) -> Result<()> {
    if !workspace_manifest.exists() || !lockfile.exists() {
        return Ok(());
    }

    let manifest = fs::read_to_string(workspace_manifest)
        .with_context(|| format!("failed to read {}", workspace_manifest.display()))?;
    let workspace_version = parse_workspace_package_version(&manifest).with_context(|| {
        format!(
            "failed to read [workspace.package] version from {}",
            workspace_manifest.display()
        )
    })?;
    if workspace_version == "0.0.0" {
        return Ok(());
    }

    let content = fs::read_to_string(lockfile)
        .with_context(|| format!("failed to read {}", lockfile.display()))?;
    let package_marker = "[[package]]\n";
    let placeholder = "\nversion = \"0.0.0\"\n";
    let replacement = format!("\nversion = \"{workspace_version}\"\n");
    let mut updated = String::with_capacity(content.len());
    let mut cursor = 0;

    while let Some(relative_start) = content[cursor..].find(package_marker) {
        let package_start = cursor + relative_start;
        updated.push_str(&content[cursor..package_start]);
        let package_end = content[package_start + package_marker.len()..]
            .find(package_marker)
            .map(|offset| package_start + package_marker.len() + offset)
            .unwrap_or(content.len());
        let package = &content[package_start..package_end];
        if !package.contains("\nsource = ") && package.contains(placeholder) {
            updated.push_str(&package.replacen(placeholder, &replacement, 1));
        } else {
            updated.push_str(package);
        }
        cursor = package_end;
    }
    updated.push_str(&content[cursor..]);

    if updated != content {
        fs::write(lockfile, updated)
            .with_context(|| format!("failed to write {}", lockfile.display()))?;
    }
    Ok(())
}

fn parse_workspace_package_version(manifest: &str) -> Result<String> {
    let mut in_workspace_package = false;
    for raw_line in manifest.lines() {
        let line = raw_line.trim();
        if line.starts_with('[') {
            in_workspace_package = line == "[workspace.package]";
            continue;
        }
        if !in_workspace_package {
            continue;
        }
        let Some(value) = line.strip_prefix("version = ") else {
            continue;
        };
        let value = value.split('#').next().unwrap_or_default().trim();
        let version = value
            .strip_prefix('"')
            .and_then(|value| value.strip_suffix('"'))
            .filter(|value| {
                !value.is_empty()
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b".+-".contains(&byte))
            })
            .with_context(|| "workspace package version is not a simple quoted version")?;
        return Ok(version.to_owned());
    }
    bail!("workspace package version is missing")
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
