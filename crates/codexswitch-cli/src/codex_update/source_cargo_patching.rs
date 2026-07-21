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
    let dependency_reference =
        canonical_lockfile_dependency_reference(&content, package, dependency, path)?;
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
    dependencies.retain(|value| lockfile_dependency_name(value) != dependency);
    dependencies.push(dependency_reference);
    dependencies.sort();
    dependencies.dedup();
    let rendered = dependencies
        .iter()
        .map(|value| format!(" \"{value}\",\n"))
        .collect::<String>();
    if rendered == content[dependencies_start..dependencies_end] {
        return Ok(());
    }
    let updated = format!(
        "{}{}{}",
        &content[..dependencies_start],
        rendered,
        &content[dependencies_end..]
    );
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn canonical_lockfile_dependency_reference(
    content: &str,
    target_package: &str,
    dependency: &str,
    path: &Path,
) -> Result<String> {
    let mut dependency_versions = Vec::new();
    let mut workspace_references = Vec::new();

    for package_block in content.split("[[package]]\n").skip(1) {
        let package_name = lockfile_string_field(package_block, "name")
            .with_context(|| format!("lockfile package has no name in {}", path.display()))?;
        if package_name == dependency {
            let version = lockfile_string_field(package_block, "version").with_context(|| {
                format!(
                    "dependency {dependency} has no version in lockfile {}",
                    path.display()
                )
            })?;
            dependency_versions.push(version.to_owned());
        }

        let is_workspace_package = !package_block
            .lines()
            .any(|line| line.starts_with("source = "));
        if !is_workspace_package || package_name == target_package {
            continue;
        }
        for reference in lockfile_dependency_references(package_block, package_name, path)? {
            if lockfile_dependency_name(&reference) == dependency {
                workspace_references.push(reference);
            }
        }
    }

    dependency_versions.sort();
    match dependency_versions.len() {
        0 => bail!(
            "dependency {dependency} is missing from lockfile {}",
            path.display()
        ),
        1 => return Ok(dependency.to_owned()),
        _ => {}
    }

    workspace_references.retain(|reference| {
        let mut components = reference.split_whitespace();
        components.next() == Some(dependency)
            && components
                .next()
                .is_some_and(|version| dependency_versions.iter().any(|item| item == version))
    });
    workspace_references.sort();
    workspace_references.dedup();
    match workspace_references.as_slice() {
        [reference] => Ok(reference.clone()),
        [] => bail!(
            "dependency {dependency} has multiple locked versions but no canonical workspace reference in {}",
            path.display()
        ),
        references => bail!(
            "dependency {dependency} has conflicting workspace lock references in {}: {}",
            path.display(),
            references.join(", ")
        ),
    }
}

fn lockfile_string_field<'a>(package_block: &'a str, field: &str) -> Option<&'a str> {
    let prefix = format!("{field} = \"");
    package_block
        .lines()
        .find_map(|line| line.strip_prefix(&prefix)?.strip_suffix('"'))
}

fn lockfile_dependency_references(
    package_block: &str,
    package: &str,
    path: &Path,
) -> Result<Vec<String>> {
    let marker = "dependencies = [\n";
    let Some(start) = package_block
        .find(marker)
        .map(|offset| offset + marker.len())
    else {
        return Ok(Vec::new());
    };
    let end = package_block[start..]
        .find("]\n")
        .map(|offset| start + offset)
        .with_context(|| {
            format!(
                "package {package} has an unterminated dependency list in lockfile {}",
                path.display()
            )
        })?;
    package_block[start..end]
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
        .collect()
}

fn lockfile_dependency_name(reference: &str) -> &str {
    reference.split_whitespace().next().unwrap_or(reference)
}
