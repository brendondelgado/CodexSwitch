#![allow(dead_code)]

use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

macro_rules! bail {
    ($($argument:tt)*) => {
        return Err(format!($($argument)*).into())
    };
}

trait Context<T> {
    fn context<C>(self, context: C) -> Result<T>
    where
        C: std::fmt::Display;

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: std::fmt::Display,
        F: FnOnce() -> C;
}

impl<T, E> Context<T> for std::result::Result<T, E>
where
    E: std::fmt::Display,
{
    fn context<C>(self, context: C) -> Result<T>
    where
        C: std::fmt::Display,
    {
        self.map_err(|error| format!("{context}: {error}").into())
    }

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: std::fmt::Display,
        F: FnOnce() -> C,
    {
        self.map_err(|error| format!("{}: {error}", context()).into())
    }
}

impl<T> Context<T> for Option<T> {
    fn context<C>(self, context: C) -> Result<T>
    where
        C: std::fmt::Display,
    {
        self.ok_or_else(|| context.to_string().into())
    }

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: std::fmt::Display,
        F: FnOnce() -> C,
    {
        self.ok_or_else(|| context().to_string().into())
    }
}

const CODEX_REPO_URL: &str = "https://github.com/openai/codex.git";
const SOURCE_COMMAND_TIMEOUT: Duration = Duration::from_secs(10 * 60);

fn stable_source_tag(version: &str) -> Result<String> {
    Ok(format!("rust-v{version}"))
}

mod bounded_command {
    use super::Result;
    use std::process::{Command, ExitStatus};
    use std::time::Duration;

    pub fn status_inherited(command: &mut Command, _timeout: Duration) -> Result<ExitStatus> {
        command.status().map_err(Into::into)
    }
}

include!(concat!(
    env!("CODEXSWITCH_REPOSITORY_ROOT"),
    "/crates/codexswitch-cli/src/codex_update/source_patching.rs"
));

fn only_argument() -> Result<OsString> {
    let mut arguments = std::env::args_os();
    let program = arguments
        .next()
        .unwrap_or_else(|| OsString::from("patch-codex-source"));
    let Some(source) = arguments.next() else {
        bail!(
            "usage: {} <codex-source-directory>",
            PathBuf::from(program).display()
        );
    };
    if arguments.next().is_some() {
        bail!("expected exactly one Codex source directory");
    }
    Ok(source)
}

fn run() -> Result<()> {
    let source_dir = PathBuf::from(only_argument()?);
    let metadata = fs::symlink_metadata(&source_dir)
        .with_context(|| format!("failed to inspect {}", source_dir.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!(
            "Codex source must be a non-symlink directory: {}",
            source_dir.display()
        );
    }
    patch_codex_source(&source_dir)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("patch-codex-source: {error}");
        std::process::exit(1);
    }
}
