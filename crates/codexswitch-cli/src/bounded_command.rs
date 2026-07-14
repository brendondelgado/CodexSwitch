use anyhow::{bail, Context, Result};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub const SMALL_OUTPUT_LIMIT: usize = 256 * 1024;

#[derive(Debug)]
pub struct BoundedOutput {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub fn output(
    command: &mut Command,
    timeout: Duration,
    max_stream_bytes: usize,
) -> Result<BoundedOutput> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = command
        .spawn()
        .context("failed to spawn bounded subprocess")?;
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            terminate_and_reap(&mut child);
            bail!("failed to capture stdout");
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            terminate_and_reap(&mut child);
            bail!("failed to capture stderr");
        }
    };
    let stdout_reader = thread::spawn(move || read_bounded_and_drain(stdout, max_stream_bytes));
    let stderr_reader = thread::spawn(move || read_bounded_and_drain(stderr, max_stream_bytes));

    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                terminate_and_reap(&mut child);
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(error).context("failed to poll bounded subprocess");
            }
        }
        if started.elapsed() >= timeout {
            // The Child handle owns this exact spawned process. Poll immediately
            // before termination so an already-exited child is reaped instead.
            match child.try_wait() {
                Ok(Some(_)) => {}
                Ok(None) => terminate_and_reap(&mut child),
                Err(_) => terminate_and_reap(&mut child),
            }
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            bail!("subprocess exceeded its {:?} deadline", timeout);
        }
        thread::sleep(Duration::from_millis(20));
    };

    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| anyhow::anyhow!("stdout reader thread panicked"))??;
    let (stderr, stderr_exceeded) = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("stderr reader thread panicked"))??;
    if stdout_exceeded || stderr_exceeded {
        bail!(
            "subprocess output exceeded the {} byte per-stream limit",
            max_stream_bytes
        );
    }
    Ok(BoundedOutput {
        status,
        stdout,
        stderr,
    })
}

pub fn status(command: &mut Command, timeout: Duration) -> Result<ExitStatus> {
    output(command, timeout, SMALL_OUTPUT_LIMIT).map(|output| output.status)
}

pub fn status_inherited(command: &mut Command, timeout: Duration) -> Result<ExitStatus> {
    command
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .process_group(0);
    let mut child = command
        .spawn()
        .context("failed to spawn bounded subprocess")?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {}
            Err(error) => {
                terminate_and_reap(&mut child);
                return Err(error).context("failed to poll bounded subprocess");
            }
        }
        if started.elapsed() >= timeout {
            match child.try_wait() {
                Ok(Some(_)) => {}
                Ok(None) => terminate_and_reap(&mut child),
                Err(_) => terminate_and_reap(&mut child),
            }
            bail!("subprocess exceeded its {:?} deadline", timeout);
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn terminate_and_reap(child: &mut std::process::Child) {
    // Every bounded child is its own process-group leader. Kill the group first
    // so compiler or package-manager descendants cannot outlive the deadline.
    let _ = unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
    let _ = child.kill();
    let _ = child.wait();
}

fn read_bounded_and_drain<R: Read>(
    mut reader: R,
    max_bytes: usize,
) -> std::io::Result<(Vec<u8>, bool)> {
    let mut captured = Vec::with_capacity(max_bytes.min(16 * 1024));
    let mut exceeded = false;
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let count = reader.read(&mut chunk)?;
        if count == 0 {
            break;
        }
        let remaining = max_bytes.saturating_sub(captured.len());
        let keep = remaining.min(count);
        captured.extend_from_slice(&chunk[..keep]);
        exceeded |= keep < count;
    }
    Ok((captured, exceeded))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_command_times_out_without_waiting_for_full_child_duration() {
        let started = Instant::now();
        let error = output(
            Command::new("/bin/sh").args(["-c", "sleep 5"]),
            Duration::from_millis(80),
            1024,
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("deadline"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn bounded_command_rejects_output_over_limit_after_draining_child() {
        let error = output(
            Command::new("/bin/sh").args(["-c", "printf '0123456789'"]),
            Duration::from_secs(1),
            4,
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("per-stream limit"));
    }

    #[test]
    fn bounded_command_timeout_prevents_descendant_writes() {
        let temp = tempfile::tempdir().unwrap();
        let marker = temp.path().join("late-write");
        let error = output(
            Command::new("/bin/sh")
                .args([
                    "-c",
                    "(sleep 0.25; printf leaked > \"$1\") & wait",
                    "bounded-descendant",
                ])
                .arg(&marker),
            Duration::from_millis(50),
            1024,
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("deadline"));
        thread::sleep(Duration::from_millis(350));
        assert!(!marker.exists(), "timed-out descendant wrote after cleanup");
    }
}
