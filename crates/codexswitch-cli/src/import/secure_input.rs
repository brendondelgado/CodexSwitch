use super::bounds::{
    validate_length, MAX_PASSPHRASE_BYTES, MAX_PASSPHRASE_FILE_BYTES, PASSPHRASE_FILE_MODE,
};
use super::crypto::SecretBytes;
use anyhow::{bail, Context, Result};
use std::ffi::{CString, OsStr, OsString};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub(super) fn read_passphrase() -> Result<SecretBytes> {
    if let Some(path) = std::env::var_os("CODEXSWITCH_IMPORT_PASSPHRASE_FILE") {
        return read_passphrase_file(Path::new(&path));
    }
    let mut stderr = std::io::stderr().lock();
    write!(stderr, "Bundle passphrase: ").context("failed to write passphrase prompt")?;
    stderr
        .flush()
        .context("failed to flush passphrase prompt")?;
    drop(stderr);
    if let Ok(tty) = fs::File::open("/dev/tty") {
        let descriptor = tty.as_raw_fd();
        return read_terminal_secret(BufReader::new(tty), descriptor)
            .context("failed to read passphrase from /dev/tty");
    }
    let stdin = std::io::stdin();
    let descriptor = stdin.as_raw_fd();
    if unsafe { libc::isatty(descriptor) } == 1 {
        read_terminal_secret(stdin.lock(), descriptor).context("failed to read passphrase")
    } else {
        read_secret_line(stdin.lock()).context("failed to read passphrase")
    }
}

pub(super) fn read_passphrase_file(path: &Path) -> Result<SecretBytes> {
    let file = open_owned_regular(path, MAX_PASSPHRASE_FILE_BYTES, Some(PASSPHRASE_FILE_MODE))?;
    normalize_passphrase(read_bounded(file, MAX_PASSPHRASE_FILE_BYTES, path)?)
}

pub(super) fn validate_passphrase(passphrase: &[u8]) -> Result<()> {
    if passphrase.is_empty() || passphrase.len() > MAX_PASSPHRASE_BYTES {
        bail!("passphrase is empty or exceeds the byte limit");
    }
    Ok(())
}

fn read_secret_line<R: BufRead>(reader: R) -> Result<SecretBytes> {
    let mut bytes = Vec::with_capacity(128);
    let mut limited = reader.take((MAX_PASSPHRASE_FILE_BYTES + 1) as u64);
    if let Err(error) = limited.read_until(b'\n', &mut bytes) {
        bytes.fill(0);
        return Err(error).context("failed to read bounded passphrase");
    }
    if bytes.len() > MAX_PASSPHRASE_FILE_BYTES {
        bytes.fill(0);
        bail!("passphrase exceeds the byte limit");
    }
    normalize_passphrase(bytes)
}

fn read_terminal_secret<R: BufRead>(reader: R, descriptor: RawFd) -> Result<SecretBytes> {
    let result = with_terminal_echo_disabled(descriptor, LibcTerminalAttributes, || {
        read_secret_line(reader)
    });
    eprintln!();
    result
}

pub(super) trait TerminalAttributes {
    fn read(&self, descriptor: RawFd) -> std::io::Result<libc::termios>;
    fn write(&self, descriptor: RawFd, attributes: &libc::termios) -> std::io::Result<()>;
}

#[derive(Debug, Clone, Copy)]
struct LibcTerminalAttributes;

impl TerminalAttributes for LibcTerminalAttributes {
    fn read(&self, descriptor: RawFd) -> std::io::Result<libc::termios> {
        let mut attributes = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(descriptor, &mut attributes) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(attributes)
    }

    fn write(&self, descriptor: RawFd, attributes: &libc::termios) -> std::io::Result<()> {
        if unsafe { libc::tcsetattr(descriptor, libc::TCSAFLUSH, attributes) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

struct TerminalEchoGuard<O: TerminalAttributes> {
    descriptor: RawFd,
    original: libc::termios,
    operations: O,
    restored: bool,
}

impl<O: TerminalAttributes> TerminalEchoGuard<O> {
    fn disable(descriptor: RawFd, operations: O) -> Result<Self> {
        let original = operations
            .read(descriptor)
            .context("failed to read terminal attributes")?;
        let mut hidden = original;
        hidden.c_lflag &= !(libc::ECHO as libc::tcflag_t);
        operations
            .write(descriptor, &hidden)
            .context("failed to disable terminal echo")?;
        Ok(Self {
            descriptor,
            original,
            operations,
            restored: false,
        })
    }

    fn restore(&mut self) -> Result<()> {
        if self.restored {
            return Ok(());
        }
        self.operations
            .write(self.descriptor, &self.original)
            .context("failed to restore terminal echo")?;
        self.restored = true;
        Ok(())
    }
}

impl<O: TerminalAttributes> Drop for TerminalEchoGuard<O> {
    fn drop(&mut self) {
        if !self.restored {
            let _ = self.operations.write(self.descriptor, &self.original);
        }
    }
}

pub(super) fn with_terminal_echo_disabled<O, T, F>(
    descriptor: RawFd,
    operations: O,
    action: F,
) -> Result<T>
where
    O: TerminalAttributes,
    F: FnOnce() -> Result<T>,
{
    let mut guard = TerminalEchoGuard::disable(descriptor, operations)?;
    let action_result = action();
    let restore_result = guard.restore();
    match (action_result, restore_result) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(restore_error)) => Err(error.context(format!(
            "terminal echo restoration also failed: {restore_error:#}"
        ))),
    }
}

fn normalize_passphrase(mut bytes: Vec<u8>) -> Result<SecretBytes> {
    while bytes
        .last()
        .is_some_and(|byte| matches!(byte, b'\r' | b'\n'))
    {
        bytes.pop();
    }
    if bytes.is_empty() || bytes.len() > MAX_PASSPHRASE_BYTES {
        bytes.fill(0);
        bail!("passphrase is empty or exceeds the byte limit");
    }
    Ok(SecretBytes::new(bytes))
}

pub(super) struct SecureInputFile {
    file: fs::File,
    _parent: fs::File,
    path: PathBuf,
    identity: DescriptorIdentity,
}

impl SecureInputFile {
    pub(super) fn verify_unchanged(&self) -> Result<()> {
        let observed = descriptor_identity(&self.file, &self.path)?;
        if observed != self.identity {
            bail!("credential input changed during secure read");
        }
        Ok(())
    }
}

pub(super) fn open_owned_regular(
    path: &Path,
    max_bytes: usize,
    required_mode: Option<u32>,
) -> Result<SecureInputFile> {
    let path = absolute_without_traversal(path)?;
    let components = raw_components(&path)?;
    let (file_name, parent_components) = components
        .split_last()
        .context("credential input path must contain a file name")?;

    let mut parent = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open("/")
        .context("failed to open filesystem root for credential traversal")?;
    let mut traversed = PathBuf::from("/");
    for component in parent_components {
        let next = open_at(
            &parent,
            component,
            libc::O_RDONLY
                | libc::O_DIRECTORY
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK,
        )
        .with_context(|| {
            format!(
                "failed to open credential parent {}/{} without following symlinks",
                traversed.display(),
                component.to_string_lossy()
            )
        })?;
        traversed.push(component);
        if !next
            .metadata()
            .with_context(|| format!("failed to inspect {}", traversed.display()))?
            .file_type()
            .is_dir()
        {
            bail!(
                "credential parent {} is not a directory",
                traversed.display()
            );
        }
        parent = next;
    }

    let file = open_at(
        &parent,
        file_name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
    )
    .with_context(|| {
        format!(
            "failed to open {} without following symlinks",
            path.display()
        )
    })?;
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    validate_file_security(
        metadata.file_type().is_file(),
        metadata.uid(),
        metadata.mode() & 0o7777,
        unsafe { libc::geteuid() },
        required_mode,
    )
    .with_context(|| format!("unsafe credential file {}", path.display()))?;
    let length =
        usize::try_from(metadata.len()).context("credential file length is unsupported")?;
    validate_length(length, max_bytes, "credential file")?;
    let identity = DescriptorIdentity::from_metadata(&metadata);

    Ok(SecureInputFile {
        file,
        _parent: parent,
        path,
        identity,
    })
}

fn absolute_without_traversal(path: &Path) -> Result<PathBuf> {
    if path.as_os_str().is_empty() {
        bail!("credential input path is empty");
    }
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()
            .context("failed to resolve current directory for credential input")?
            .join(path))
    }
}

fn raw_components(path: &Path) -> Result<Vec<OsString>> {
    if !path.is_absolute() {
        bail!("credential input path must resolve from the filesystem root");
    }
    let mut components = Vec::new();
    for component in path.as_os_str().as_bytes().split(|byte| *byte == b'/') {
        if component.is_empty() || component == b"." {
            continue;
        }
        if component == b".." {
            bail!("credential input path contains parent traversal");
        }
        components.push(OsStr::from_bytes(component).to_os_string());
    }
    if components.is_empty() {
        bail!("credential input path must identify a file");
    }
    Ok(components)
}

fn open_at(directory: &fs::File, name: &OsStr, flags: i32) -> std::io::Result<fs::File> {
    let name = c_component(name)?;
    let descriptor = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { fs::File::from_raw_fd(descriptor) })
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

pub(super) fn validate_file_security(
    is_regular: bool,
    owner_uid: u32,
    mode: u32,
    current_uid: u32,
    required_mode: Option<u32>,
) -> Result<()> {
    if !is_regular {
        bail!("credential input is not a regular file");
    }
    if owner_uid != current_uid {
        bail!("credential input is not owned by the current user");
    }
    if let Some(required_mode) = required_mode {
        if mode != required_mode {
            bail!("passphrase file mode must be 0600");
        }
    }
    Ok(())
}

pub(super) fn read_bounded(
    file: SecureInputFile,
    max_bytes: usize,
    _path: &Path,
) -> Result<Vec<u8>> {
    read_bounded_with_hook(file, max_bytes, || Ok(()))
}

fn read_bounded_with_hook<F>(
    mut input: SecureInputFile,
    max_bytes: usize,
    before_final_fstat: F,
) -> Result<Vec<u8>>
where
    F: FnOnce() -> Result<()>,
{
    let capacity = usize::try_from(input.identity.length)
        .unwrap_or(max_bytes)
        .min(max_bytes);
    let mut bytes = Vec::with_capacity(capacity);
    if let Err(error) = Read::by_ref(&mut input.file)
        .take(max_bytes as u64 + 1)
        .read_to_end(&mut bytes)
    {
        bytes.fill(0);
        return Err(error).with_context(|| format!("failed to read {}", input.path.display()));
    }
    if let Err(error) = validate_length(bytes.len(), max_bytes, "credential file") {
        bytes.fill(0);
        return Err(error);
    }
    if let Err(error) = before_final_fstat() {
        bytes.fill(0);
        return Err(error);
    }
    if let Err(error) = input.verify_unchanged() {
        bytes.fill(0);
        return Err(error);
    }
    Ok(bytes)
}

#[cfg(test)]
pub(super) fn read_bounded_with_test_hook<F>(
    input: SecureInputFile,
    max_bytes: usize,
    before_final_fstat: F,
) -> Result<Vec<u8>>
where
    F: FnOnce() -> Result<()>,
{
    read_bounded_with_hook(input, max_bytes, before_final_fstat)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DescriptorIdentity {
    device: u64,
    inode: u64,
    owner_uid: u32,
    mode: u32,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

impl DescriptorIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            owner_uid: metadata.uid(),
            mode: metadata.mode(),
            length: metadata.len(),
            modified_seconds: metadata.mtime(),
            modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
        }
    }
}

fn descriptor_identity(file: &fs::File, path: &Path) -> Result<DescriptorIdentity> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to re-inspect {}", path.display()))?;
    Ok(DescriptorIdentity::from_metadata(&metadata))
}
