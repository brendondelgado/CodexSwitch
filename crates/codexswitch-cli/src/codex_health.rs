use crate::bounded_command;
use anyhow::{anyhow, bail, Context, Result};
use std::process::Command;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexHealth {
    pub path: Option<String>,
    pub healthy: bool,
    pub version: Option<String>,
    pub problem: Option<String>,
}

pub fn check() -> CodexHealth {
    let path = command_output(
        "/bin/sh",
        &["-lc", "command -v codex"],
        Duration::from_secs(3),
    )
    .ok()
    .and_then(|output| {
        let trimmed = output.stdout.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    });

    let Some(path_value) = &path else {
        return CodexHealth {
            path,
            healthy: false,
            version: None,
            problem: Some("codex is not on PATH".to_string()),
        };
    };

    match command_output(path_value, &["--version"], Duration::from_secs(8)) {
        Ok(output) if output.status == 0 => CodexHealth {
            path,
            healthy: true,
            version: Some(output.stdout.trim().to_string()),
            problem: None,
        },
        Ok(output) => CodexHealth {
            path,
            healthy: false,
            version: None,
            problem: Some(classify_failure(
                output.status,
                output.stderr,
                output.timed_out,
            )),
        },
        Err(error) => CodexHealth {
            path,
            healthy: false,
            version: None,
            problem: Some(error.to_string()),
        },
    }
}

pub fn fix(yes: bool, version: &str) -> Result<CodexHealth> {
    let before = check();
    if before.healthy {
        return Ok(before);
    }
    if !yes {
        return Ok(before);
    }

    let npm_path = command_output(
        "/bin/sh",
        &["-lc", "command -v npm"],
        Duration::from_secs(3),
    )
    .ok()
    .and_then(|output| {
        let trimmed = output.stdout.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
    .context("npm is not installed; cannot reinstall @openai/codex automatically")?;

    let install_command = format!(
        "{} install -g @openai/codex@{} || sudo {} install -g @openai/codex@{}",
        shell_quote(&npm_path),
        shell_quote(version),
        shell_quote(&npm_path),
        shell_quote(version)
    );
    let output = command_output(
        "/bin/sh",
        &["-lc", &install_command],
        Duration::from_secs(180),
    )
    .context("failed to run npm reinstall")?;
    if output.status != 0 {
        bail!(
            "npm reinstall failed: {}",
            if output.stderr.trim().is_empty() {
                output.stdout
            } else {
                output.stderr
            }
        );
    }

    let after = check();
    if !after.healthy {
        return Err(anyhow!(
            "codex is still unhealthy after reinstall: {}",
            after
                .problem
                .clone()
                .unwrap_or_else(|| "unknown".to_string())
        ));
    }
    Ok(after)
}

#[derive(Debug)]
struct CommandOutput {
    status: i32,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

fn command_output(program: &str, args: &[&str], timeout: Duration) -> Result<CommandOutput> {
    match bounded_command::output(
        Command::new(program).args(args),
        timeout,
        bounded_command::SMALL_OUTPUT_LIMIT,
    ) {
        Ok(output) => Ok(CommandOutput {
            status: output
                .status
                .code()
                .unwrap_or_else(|| 128 + status_signal(&output.status)),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            timed_out: false,
        }),
        Err(error) if format!("{error:#}").contains("deadline") => Ok(CommandOutput {
            status: 124,
            stdout: String::new(),
            stderr: String::new(),
            timed_out: true,
        }),
        Err(error) => Err(error).with_context(|| format!("failed to run {program}")),
    }
}

#[cfg(unix)]
fn status_signal(status: &std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status.signal().unwrap_or(0)
}

#[cfg(not(unix))]
fn status_signal(_: &std::process::ExitStatus) -> i32 {
    0
}

fn classify_failure(status: i32, stderr: String, timed_out: bool) -> String {
    if timed_out {
        return "codex --version timed out".to_string();
    }
    if status == 137 || status == 9 {
        return "codex was killed at startup, likely a broken native binary".to_string();
    }
    let trimmed = stderr.trim();
    if trimmed.is_empty() {
        format!("codex --version exited with status {status}")
    } else {
        format!("codex --version exited with status {status}: {trimmed}")
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
