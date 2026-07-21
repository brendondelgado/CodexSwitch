use anyhow::{bail, Context, Result};
use ring::digest::{digest, SHA256};
use serde::{Deserialize, Serialize};
use std::ffi::{CString, OsStr, OsString};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const DIRECTORY_MODE: u32 = 0o700;
const FILE_MODE: u32 = 0o600;
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecureFileGeneration(String);

impl SecureFileGeneration {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone)]
pub struct SecureFileSnapshot {
    bytes: Option<Vec<u8>>,
    generation: SecureFileGeneration,
    path: PathBuf,
    device: Option<u64>,
    inode: Option<u64>,
    modified_unix: Option<(i64, u32)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecureFileOversized {
    length: u64,
    generation: SecureFileGeneration,
}

impl SecureFileOversized {
    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn generation(&self) -> &SecureFileGeneration {
        &self.generation
    }
}

impl SecureFileSnapshot {
    pub fn bytes(&self) -> Option<&[u8]> {
        self.bytes.as_deref()
    }

    pub fn generation(&self) -> &SecureFileGeneration {
        &self.generation
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn file_identity(&self) -> Option<(u64, u64)> {
        self.device.zip(self.inode)
    }

    pub fn modified_unix(&self) -> Option<(i64, u32)> {
        self.modified_unix
    }
}

pub struct SecureFileLock {
    lock_file: fs::File,
    directory: SecureDirectory,
    path: PathBuf,
    name: OsString,
}

/// Reads a secure file without creating a lock file or repairing filesystem
/// metadata. Observational commands use this path so diagnostics cannot mutate
/// the state they are trying to explain.
pub fn observe(path: &Path, max_bytes: usize, allow_missing: bool) -> Result<SecureFileSnapshot> {
    let path = normalize_path(path)?;
    let directory = open_parent_directory(&path, false)?;
    let name = file_name(&path)?.to_os_string();
    let mut file = match open_file_at(
        &directory.file,
        &name,
        libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        0,
    ) {
        Ok(file) => file,
        Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(missing_snapshot(&path));
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to open {}", path.display()));
        }
    };
    validate_owned_regular(&file, &path)?;
    let before = stable_file_identity(&file, &path)?;
    let length =
        usize::try_from(before.length).context("secure file length does not fit in memory")?;
    validate_length(length, max_bytes, &path)?;

    let mut bytes = Vec::with_capacity(length);
    std::io::Read::by_ref(&mut file)
        .take(max_bytes as u64 + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("failed to read {}", path.display()))?;
    validate_length(bytes.len(), max_bytes, &path)?;
    if stable_file_identity(&file, &path)? != before {
        bail!("secure file {} changed during observation", path.display());
    }

    let reopened = open_file_at(
        &directory.file,
        &name,
        libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        0,
    )
    .with_context(|| format!("failed to reopen {}", path.display()))?;
    validate_owned_regular(&reopened, &path)?;
    if stable_file_identity(&reopened, &path)? != before {
        bail!(
            "secure file {} was replaced during observation",
            path.display()
        );
    }

    Ok(SecureFileSnapshot {
        generation: generation_for_bytes(&bytes),
        bytes: Some(bytes),
        path,
        device: Some(before.device),
        inode: Some(before.inode),
        modified_unix: stable_modified_unix(before),
    })
}

struct SecureDirectory {
    file: fs::File,
    path: PathBuf,
}

pub fn lock(path: &Path, create_parent: bool) -> Result<SecureFileLock> {
    try_lock_inner(path, create_parent, false)?
        .context("blocking secure-file lock unexpectedly returned unavailable")
}

pub fn try_lock(path: &Path, create_parent: bool) -> Result<Option<SecureFileLock>> {
    try_lock_inner(path, create_parent, true)
}

fn try_lock_inner(
    path: &Path,
    create_parent: bool,
    nonblocking: bool,
) -> Result<Option<SecureFileLock>> {
    let path = normalize_path(path)?;
    let directory = open_parent_directory(&path, create_parent)?;
    let name = file_name(&path)?.to_os_string();
    let mut lock_name = name.clone();
    lock_name.push(".lock");
    let lock_path = directory.path.join(&lock_name);
    let lock_file = open_file_at(
        &directory.file,
        &lock_name,
        libc::O_CREAT | libc::O_RDWR | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        FILE_MODE,
    )
    .with_context(|| format!("failed to open secure-file lock {}", lock_path.display()))?;
    validate_owned_regular_identity(&lock_file, &lock_path)?;
    set_mode(&lock_file, &lock_path, FILE_MODE)?;
    validate_owned_regular(&lock_file, &lock_path)?;
    let acquired = if nonblocking {
        try_flock_exclusive(lock_file.as_raw_fd())?
    } else {
        flock(lock_file.as_raw_fd(), LOCK_EX)
            .with_context(|| format!("failed to lock {}", lock_path.display()))?;
        true
    };
    if !acquired {
        return Ok(None);
    }
    Ok(Some(SecureFileLock {
        lock_file,
        directory,
        path,
        name,
    }))
}

impl SecureFileLock {
    pub fn load(&self, max_bytes: usize, allow_missing: bool) -> Result<SecureFileSnapshot> {
        let mut file = match open_file_at(
            &self.directory.file,
            &self.name,
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0,
        ) {
            Ok(file) => file,
            Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(missing_snapshot(&self.path));
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to open {}", self.path.display()));
            }
        };
        validate_owned_regular_identity(&file, &self.path)?;
        set_mode(&file, &self.path, FILE_MODE)?;
        validate_owned_regular(&file, &self.path)?;
        let identity = stable_file_identity(&file, &self.path)?;
        let length = usize::try_from(identity.length)
            .context("secure file length does not fit in memory")?;
        validate_length(length, max_bytes, &self.path)?;
        let mut bytes = Vec::with_capacity(length);
        std::io::Read::by_ref(&mut file)
            .take(max_bytes as u64 + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("failed to read {}", self.path.display()))?;
        validate_length(bytes.len(), max_bytes, &self.path)?;
        Ok(SecureFileSnapshot {
            generation: generation_for_bytes(&bytes),
            bytes: Some(bytes),
            path: self.path.clone(),
            device: Some(identity.device),
            inode: Some(identity.inode),
            modified_unix: stable_modified_unix(identity),
        })
    }

    pub fn commit(
        &self,
        expected: &SecureFileGeneration,
        data: &[u8],
        max_bytes: usize,
    ) -> Result<SecureFileSnapshot> {
        self.commit_with_hook(expected, data, max_bytes, || Ok(()))
    }

    pub fn inspect_oversized(&self, max_bytes: usize) -> Result<Option<SecureFileOversized>> {
        let file = match open_file_at(
            &self.directory.file,
            &self.name,
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0,
        ) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to inspect {}", self.path.display()));
            }
        };
        validate_owned_regular_identity(&file, &self.path)?;
        set_mode(&file, &self.path, FILE_MODE)?;
        validate_owned_regular(&file, &self.path)?;
        let metadata = file
            .metadata()
            .with_context(|| format!("failed to fstat {}", self.path.display()))?;
        if metadata.len() <= max_bytes as u64 {
            return Ok(None);
        }
        Ok(Some(SecureFileOversized {
            length: metadata.len(),
            generation: oversized_generation(&metadata),
        }))
    }

    pub fn replace_oversized(
        &self,
        expected: &SecureFileOversized,
        data: &[u8],
        max_bytes: usize,
    ) -> Result<SecureFileSnapshot> {
        self.promote_with_hook(
            data,
            max_bytes,
            || Ok(()),
            || {
                let current = self
                    .inspect_oversized(max_bytes)?
                    .context("secure file is no longer oversized")?;
                ensure_generation(expected.generation(), current.generation(), &self.path)
            },
        )
    }

    #[cfg(test)]
    pub fn replace_oversized_with_test_hook<F>(
        &self,
        expected: &SecureFileOversized,
        data: &[u8],
        max_bytes: usize,
        before_final_compare: F,
    ) -> Result<SecureFileSnapshot>
    where
        F: FnOnce() -> Result<()>,
    {
        self.promote_with_hook(data, max_bytes, before_final_compare, || {
            let current = self
                .inspect_oversized(max_bytes)?
                .context("secure file is no longer oversized")?;
            ensure_generation(expected.generation(), current.generation(), &self.path)
        })
    }

    pub fn replace(
        &self,
        expected: &SecureFileGeneration,
        data: Option<&[u8]>,
        max_bytes: usize,
    ) -> Result<SecureFileSnapshot> {
        match data {
            Some(data) => self.commit(expected, data, max_bytes),
            None => self.remove(expected, max_bytes),
        }
    }

    fn remove(
        &self,
        expected: &SecureFileGeneration,
        max_bytes: usize,
    ) -> Result<SecureFileSnapshot> {
        let current = self.load(max_bytes, true)?;
        ensure_generation(expected, current.generation(), &self.path)?;
        match unlink_file_at(&self.directory.file, &self.name) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if expected != missing_generation() {
                    return Err(error).context("secure file disappeared during CAS removal");
                }
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to remove {}", self.path.display()));
            }
        }
        self.directory
            .file
            .sync_all()
            .with_context(|| format!("failed to sync {}", self.directory.path.display()))?;
        let readback = self.load(max_bytes, true)?;
        if readback.bytes().is_some() {
            bail!("secure file removal readback was not missing");
        }
        Ok(readback)
    }

    fn commit_with_hook<F>(
        &self,
        expected: &SecureFileGeneration,
        data: &[u8],
        max_bytes: usize,
        before_final_compare: F,
    ) -> Result<SecureFileSnapshot>
    where
        F: FnOnce() -> Result<()>,
    {
        self.promote_with_hook(data, max_bytes, before_final_compare, || {
            let current = self.load(max_bytes, true)?;
            ensure_generation(expected, current.generation(), &self.path)
        })
    }

    fn promote_with_hook<F, V>(
        &self,
        data: &[u8],
        max_bytes: usize,
        before_final_compare: F,
        validate_current: V,
    ) -> Result<SecureFileSnapshot>
    where
        F: FnOnce() -> Result<()>,
        V: FnOnce() -> Result<()>,
    {
        validate_length(data.len(), max_bytes, &self.path)?;
        let mut temporary_name = OsString::from(".");
        temporary_name.push(&self.name);
        temporary_name.push(format!(".tmp-{}-{}", std::process::id(), Uuid::new_v4()));
        let temporary_path = self.directory.path.join(&temporary_name);
        let result = (|| -> Result<SecureFileSnapshot> {
            let mut temporary = open_file_at(
                &self.directory.file,
                &temporary_name,
                libc::O_CREAT
                    | libc::O_EXCL
                    | libc::O_WRONLY
                    | libc::O_CLOEXEC
                    | libc::O_NOFOLLOW
                    | libc::O_NONBLOCK,
                FILE_MODE,
            )
            .with_context(|| format!("failed to create {}", temporary_path.display()))?;
            validate_owned_regular_identity(&temporary, &temporary_path)?;
            set_mode(&temporary, &temporary_path, FILE_MODE)?;
            validate_owned_regular(&temporary, &temporary_path)?;
            let created_identity = descriptor_identity(&temporary, &temporary_path)?;
            temporary
                .write_all(data)
                .with_context(|| format!("failed to write {}", temporary_path.display()))?;
            temporary
                .sync_all()
                .with_context(|| format!("failed to sync {}", temporary_path.display()))?;

            before_final_compare()?;
            validate_current()?;
            rename_file_at(&self.directory.file, &temporary_name, &self.name)
                .with_context(|| format!("failed to promote {}", self.path.display()))?;
            let reopened = open_file_at(
                &self.directory.file,
                &self.name,
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
                0,
            )
            .with_context(|| format!("failed to reopen {}", self.path.display()))?;
            validate_owned_regular(&reopened, &self.path)?;
            if descriptor_identity(&reopened, &self.path)? != created_identity {
                bail!("secure-file inode changed during atomic promotion");
            }
            self.directory
                .file
                .sync_all()
                .with_context(|| format!("failed to sync {}", self.directory.path.display()))?;
            let readback = self.load(max_bytes, false)?;
            if readback.bytes() != Some(data) {
                bail!("secure-file exact-byte readback mismatch");
            }
            Ok(readback)
        })();
        if result.is_err() {
            let _ = unlink_file_at(&self.directory.file, &temporary_name);
        }
        result
    }

    #[cfg(test)]
    pub fn commit_with_test_hook<F>(
        &self,
        expected: &SecureFileGeneration,
        data: &[u8],
        max_bytes: usize,
        before_final_compare: F,
    ) -> Result<SecureFileSnapshot>
    where
        F: FnOnce() -> Result<()>,
    {
        self.commit_with_hook(expected, data, max_bytes, before_final_compare)
    }
}

impl Drop for SecureFileLock {
    fn drop(&mut self) {
        let _ = flock(self.lock_file.as_raw_fd(), LOCK_UN);
    }
}

fn open_parent_directory(path: &Path, create: bool) -> Result<SecureDirectory> {
    let parent = path.parent().context("secure file must have a parent")?;
    if !parent.is_absolute() || parent == Path::new("/") {
        bail!("secure-file parent must be an absolute non-root directory");
    }
    let mut directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/")
        .context("failed to open filesystem root for secure traversal")?;
    let mut traversed = PathBuf::from("/");
    let components = parent
        .components()
        .filter_map(|component| match component {
            std::path::Component::RootDir | std::path::Component::CurDir => None,
            std::path::Component::Normal(component) => Some(Ok(component)),
            std::path::Component::ParentDir => Some(Err(anyhow::anyhow!(
                "secure path contains parent traversal"
            ))),
            std::path::Component::Prefix(_) => Some(Err(anyhow::anyhow!(
                "secure path contains an invalid prefix"
            ))),
        })
        .collect::<Result<Vec<_>>>()?;
    for (index, component) in components.iter().enumerate() {
        let next = match open_directory_at(&directory, component) {
            Ok(next) => next,
            Err(error) if create && error.kind() == std::io::ErrorKind::NotFound => {
                match create_directory_at(&directory, component, DIRECTORY_MODE) {
                    Ok(()) => directory.sync_all().with_context(|| {
                        format!("failed to sync parent directory {}", traversed.display())
                    })?,
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error).context("failed to create secure directory"),
                }
                open_directory_at(&directory, component).with_context(|| {
                    format!(
                        "failed to open newly created secure directory {}/{}",
                        traversed.display(),
                        component.to_string_lossy()
                    )
                })?
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "failed to open secure directory {}/{} without following symlinks",
                        traversed.display(),
                        component.to_string_lossy()
                    )
                });
            }
        };
        traversed.push(component);
        validate_directory(&next, &traversed, index + 1 == components.len())?;
        directory = next;
    }
    if create {
        set_mode(&directory, parent, DIRECTORY_MODE)?;
    }
    let mode = directory.metadata()?.mode() & 0o777;
    if mode != DIRECTORY_MODE {
        bail!(
            "secure-file parent {} has mode {:03o}, expected {:03o}",
            parent.display(),
            mode,
            DIRECTORY_MODE
        );
    }
    Ok(SecureDirectory {
        file: directory,
        path: parent.to_path_buf(),
    })
}

fn validate_directory(file: &fs::File, path: &Path, final_component: bool) -> Result<()> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    if !metadata.file_type().is_dir() {
        bail!("secure parent {} is not a directory", path.display());
    }
    let uid = current_uid();
    if metadata.uid() != uid && metadata.uid() != 0 {
        bail!("secure parent {} has an untrusted owner", path.display());
    }
    let mode = metadata.mode();
    let root_sticky = metadata.uid() == 0 && mode & libc::S_ISVTX as u32 != 0;
    if mode & 0o022 != 0 && !root_sticky {
        bail!(
            "secure parent {} is writable by another user",
            path.display()
        );
    }
    if final_component && metadata.uid() != uid {
        bail!("secure-file final parent is not owned by the current uid");
    }
    Ok(())
}

fn validate_owned_regular_identity(file: &fs::File, path: &Path) -> Result<()> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.uid() != current_uid() {
        bail!("secure file {} has an unsafe type or owner", path.display());
    }
    Ok(())
}

fn validate_owned_regular(file: &fs::File, path: &Path) -> Result<()> {
    validate_owned_regular_identity(file, path)?;
    let mode = file.metadata()?.mode() & 0o777;
    if mode != FILE_MODE {
        bail!(
            "secure file {} has mode {:03o}, expected {:03o}",
            path.display(),
            mode,
            FILE_MODE
        );
    }
    Ok(())
}

fn validate_length(length: usize, max_bytes: usize, path: &Path) -> Result<()> {
    if max_bytes == 0 || length > max_bytes {
        bail!(
            "secure file {} exceeds the {} byte limit",
            path.display(),
            max_bytes
        );
    }
    Ok(())
}

fn ensure_generation(
    expected: &SecureFileGeneration,
    observed: &SecureFileGeneration,
    path: &Path,
) -> Result<()> {
    if expected != observed {
        bail!(
            "secure-file generation changed for {}: expected {}, found {}",
            path.display(),
            expected.as_str(),
            observed.as_str()
        );
    }
    Ok(())
}

fn generation_for_bytes(bytes: &[u8]) -> SecureFileGeneration {
    SecureFileGeneration(
        digest(&SHA256, bytes)
            .as_ref()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

fn oversized_generation(metadata: &fs::Metadata) -> SecureFileGeneration {
    SecureFileGeneration(format!(
        "oversized:{}:{}:{}:{}:{}:{}:{}",
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    ))
}

fn missing_snapshot(path: &Path) -> SecureFileSnapshot {
    SecureFileSnapshot {
        bytes: None,
        generation: missing_generation().clone(),
        path: path.to_path_buf(),
        device: None,
        inode: None,
        modified_unix: None,
    }
}

fn missing_generation() -> &'static SecureFileGeneration {
    static MISSING: std::sync::OnceLock<SecureFileGeneration> = std::sync::OnceLock::new();
    MISSING.get_or_init(|| SecureFileGeneration("missing".to_string()))
}

fn normalize_path(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        bail!("secure-file path must be absolute");
    }
    if path
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        bail!("secure-file path cannot contain parent traversal");
    }
    #[cfg(target_os = "macos")]
    for (alias, canonical) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
        if let Ok(remainder) = path.strip_prefix(alias) {
            return Ok(Path::new(canonical).join(remainder));
        }
    }
    Ok(path.to_path_buf())
}

fn file_name(path: &Path) -> Result<&OsStr> {
    path.file_name()
        .filter(|name| !name.is_empty())
        .context("secure-file path must contain a file name")
}

fn set_mode(file: &fs::File, path: &Path, mode: u32) -> Result<()> {
    if file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?
        .mode()
        & 0o777
        == mode
    {
        return Ok(());
    }
    if unsafe { libc::fchmod(file.as_raw_fd(), mode as libc::mode_t) } != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("failed to fchmod {}", path.display()));
    }
    Ok(())
}

fn descriptor_identity(file: &fs::File, path: &Path) -> Result<(u64, u64)> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    Ok((metadata.dev(), metadata.ino()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StableFileIdentity {
    device: u64,
    inode: u64,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

fn stable_file_identity(file: &fs::File, path: &Path) -> Result<StableFileIdentity> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    Ok(StableFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        length: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
    })
}

fn stable_modified_unix(identity: StableFileIdentity) -> Option<(i64, u32)> {
    u32::try_from(identity.modified_nanoseconds)
        .ok()
        .filter(|nanoseconds| *nanoseconds < 1_000_000_000)
        .map(|nanoseconds| (identity.modified_seconds, nanoseconds))
}

fn open_directory_at(directory: &fs::File, name: &OsStr) -> std::io::Result<fs::File> {
    open_file_at(
        directory,
        name,
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0,
    )
}

fn create_directory_at(directory: &fs::File, name: &OsStr, mode: u32) -> std::io::Result<()> {
    let name = c_component(name)?;
    let status =
        unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), mode as libc::mode_t) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn open_file_at(
    directory: &fs::File,
    name: &OsStr,
    flags: i32,
    mode: u32,
) -> std::io::Result<fs::File> {
    let name = c_component(name)?;
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags,
            mode as libc::c_uint,
        )
    };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { fs::File::from_raw_fd(descriptor) })
}

fn rename_file_at(directory: &fs::File, from: &OsStr, to: &OsStr) -> std::io::Result<()> {
    let from = c_component(from)?;
    let to = c_component(to)?;
    let status = unsafe {
        libc::renameat(
            directory.as_raw_fd(),
            from.as_ptr(),
            directory.as_raw_fd(),
            to.as_ptr(),
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn unlink_file_at(directory: &fs::File, name: &OsStr) -> std::io::Result<()> {
    let name = c_component(name)?;
    let status = unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn c_component(name: &OsStr) -> std::io::Result<CString> {
    if name.as_bytes().contains(&b'/') {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path component contains a separator",
        ));
    }
    CString::new(name.as_bytes()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path component contains a null byte",
        )
    })
}

fn flock(fd: i32, operation: i32) -> Result<()> {
    unsafe extern "C" {
        #[link_name = "flock"]
        fn c_flock(fd: i32, operation: i32) -> i32;
    }
    if unsafe { c_flock(fd, operation) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error()).context("flock failed")
    }
}

fn try_flock_exclusive(fd: i32) -> Result<bool> {
    unsafe extern "C" {
        #[link_name = "flock"]
        fn c_flock(fd: i32, operation: i32) -> i32;
    }
    loop {
        if unsafe { c_flock(fd, LOCK_EX | LOCK_NB) } == 0 {
            return Ok(true);
        }
        let error = std::io::Error::last_os_error();
        match error.raw_os_error() {
            Some(code) if code == libc::EINTR => continue,
            Some(code) if code == libc::EWOULDBLOCK || code == libc::EAGAIN => return Ok(false),
            _ => return Err(error).context("nonblocking flock failed"),
        }
    }
}

fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn outside_replace(path: &Path, bytes: &[u8]) -> Result<()> {
        let parent = path.parent().unwrap();
        let temporary = parent.join("outside-writer.tmp");
        fs::write(&temporary, bytes)?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(FILE_MODE))?;
        fs::rename(temporary, path)?;
        Ok(())
    }

    #[test]
    fn nonblocking_lock_reports_contention_without_releasing_the_owner() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("provider-io");
        let owner = try_lock(&path, true)?.context("first nonblocking lock was unavailable")?;

        assert!(try_lock(&path, true)?.is_none());
        drop(owner);
        assert!(try_lock(&path, true)?.is_some());
        Ok(())
    }

    #[test]
    fn generation_cas_rejects_replacement_before_final_compare() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("state.json");
        let transaction = lock(&path, true)?;
        let missing = transaction.load(1024, true)?;
        let first = transaction.commit(missing.generation(), b"first", 1024)?;

        let error = transaction
            .commit_with_test_hook(first.generation(), b"rollback", 1024, || {
                outside_replace(&path, b"concurrent")
            })
            .unwrap_err();

        assert!(format!("{error:#}").contains("generation changed"));
        assert_eq!(fs::read(&path)?, b"concurrent");
        Ok(())
    }

    #[test]
    fn descriptor_transaction_rejects_symlinked_parent_and_target() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let real = temp.path().join("real");
        fs::create_dir(&real)?;
        fs::set_permissions(&real, fs::Permissions::from_mode(DIRECTORY_MODE))?;
        let linked = temp.path().join("linked");
        symlink(&real, &linked)?;
        assert!(lock(&linked.join("state.json"), true).is_err());

        let path = real.join("state.json");
        let outside = temp.path().join("outside");
        fs::write(&outside, b"outside")?;
        symlink(&outside, &path)?;
        let transaction = lock(&path, true)?;
        assert!(transaction.load(1024, false).is_err());
        assert_eq!(fs::read(&outside)?, b"outside");
        Ok(())
    }

    #[test]
    fn commit_proves_exact_bytes_and_reopened_inode() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("state.json");
        let transaction = lock(&path, true)?;
        let missing = transaction.load(1024, true)?;
        let committed = transaction.commit(missing.generation(), b"exact", 1024)?;

        assert_eq!(committed.bytes(), Some(b"exact".as_slice()));
        assert_eq!(
            transaction.load(1024, false)?.generation(),
            committed.generation()
        );
        Ok(())
    }

    #[test]
    fn observe_reads_without_creating_a_lock_file() -> Result<()> {
        let temp = tempfile::tempdir()?;
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(DIRECTORY_MODE))?;
        let path = temp.path().join("state.json");
        fs::write(&path, b"observed")?;
        fs::set_permissions(&path, fs::Permissions::from_mode(FILE_MODE))?;

        let snapshot = observe(&path, 1024, false)?;

        assert_eq!(snapshot.bytes(), Some(b"observed".as_slice()));
        assert!(!temp.path().join("state.json.lock").exists());
        Ok(())
    }

    #[test]
    fn observe_rejects_wrong_mode_without_repairing_it() -> Result<()> {
        let temp = tempfile::tempdir()?;
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(DIRECTORY_MODE))?;
        let path = temp.path().join("state.json");
        fs::write(&path, b"observed")?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))?;

        let error = observe(&path, 1024, false).unwrap_err();

        assert!(format!("{error:#}").contains("expected 600"));
        assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o644);
        assert!(!temp.path().join("state.json.lock").exists());
        Ok(())
    }

    #[test]
    fn oversized_replacement_is_descriptor_cas_and_bounded() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("state.json");
        fs::write(&path, vec![b'x'; 1_025])?;
        fs::set_permissions(&path, fs::Permissions::from_mode(FILE_MODE))?;
        let transaction = lock(&path, true)?;
        let oversized = transaction.inspect_oversized(1_024)?.unwrap();

        assert_eq!(oversized.length(), 1_025);
        let committed = transaction.replace_oversized(&oversized, b"manual-review", 1_024)?;
        assert_eq!(committed.bytes(), Some(b"manual-review".as_slice()));
        assert!(transaction.inspect_oversized(1_024)?.is_none());
        Ok(())
    }

    #[test]
    fn oversized_replacement_preserves_concurrent_inode_change() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("state.json");
        fs::write(&path, vec![b'x'; 1_025])?;
        fs::set_permissions(&path, fs::Permissions::from_mode(FILE_MODE))?;
        let transaction = lock(&path, true)?;
        let oversized = transaction.inspect_oversized(1_024)?.unwrap();
        let concurrent = vec![b'y'; 1_026];

        let error = transaction
            .replace_oversized_with_test_hook(&oversized, b"manual-review", 1_024, || {
                outside_replace(&path, &concurrent)
            })
            .unwrap_err();

        assert!(format!("{error:#}").contains("generation changed"));
        assert_eq!(fs::read(&path)?, concurrent);
        Ok(())
    }
}
