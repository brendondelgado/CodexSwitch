fn patch_file_after(path: &Path, needle: &str, insertion: &str, marker: &str) -> Result<()> {
    patch_file_after_any(path, &[needle], insertion, marker)
}

fn patch_file_after_any(
    path: &Path,
    needles: &[&str],
    insertion: &str,
    marker: &str,
) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(marker) {
        return Ok(());
    }
    let Some((index, needle)) = needles
        .iter()
        .find_map(|needle| content.find(needle).map(|index| (index, *needle)))
    else {
        bail!("patch anchor not found in {}", path.display());
    };
    let insert_at = index + needle.len();
    let updated = format!(
        "{}{}{}",
        &content[..insert_at],
        insertion,
        &content[insert_at..]
    );
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_all(path: &Path, needle: &str, replacement: &str) -> Result<bool> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if !content.contains(needle) {
        return Ok(false);
    }
    let updated = content.replace(needle, replacement);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(true)
}

fn patch_file_before(path: &Path, needle: &str, insertion: &str, marker: &str) -> Result<()> {
    patch_file_before_any(path, &[needle], insertion, marker)
}

fn patch_file_before_any(
    path: &Path,
    needles: &[&str],
    insertion: &str,
    marker: &str,
) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(marker) {
        return Ok(());
    }
    let Some(index) = needles.iter().find_map(|needle| content.find(needle)) else {
        bail!("patch anchor not found in {}", path.display());
    };
    let updated = format!("{}{}{}", &content[..index], insertion, &content[index..]);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}
