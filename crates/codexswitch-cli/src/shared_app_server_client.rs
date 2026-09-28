//! Shared Codex app-server client (`codexswitch-cli app-server-client`).
//!
//! A third-party frontend such as T3 Code normally spawns a private
//! `codex app-server` per thread. Codex allows only one writer per thread
//! across processes, so a private server cannot open a thread that the shared
//! desktop daemon already holds. This client accepts the exact argv the
//! frontend would give `codex` and, for plain stdio app-server invocations,
//! relays the JSON-RPC stream to the shared daemon's control socket instead.
//! Per-invocation `-c` overrides become per-thread `config` on
//! `thread/start`, `thread/resume`, and `thread/fork`. Every other invocation,
//! and every case where no verified shared daemon is reachable, replaces this
//! process with the real Codex runtime using the original argv.
//!
//! Contract: `docs/architecture/shared-app-server-client.md`.

use anyhow::{bail, Context, Result};
use serde_json::{Map, Value};
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, ErrorKind, Read, Write};
use std::mem::ManuallyDrop;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Message, WebSocket};

pub const SUBCOMMAND: &str = "app-server-client";

/// Explicit real Codex executable for fallback and starting the shared daemon.
const REAL_CODEX_ENV: &str = "CODEXSWITCH_REAL_CODEX";
/// Explicit control socket. When set, it is used on every platform and a
/// daemon is never started for it.
const SOCKET_ENV: &str = "CODEXSWITCH_APP_SERVER_SOCKET";

/// Upper bound for one JSON-RPC message in either direction. Resume and read
/// responses can carry long histories with inline images, so the bound matches
/// tungstenite's default message cap rather than a typical request size.
const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(30);
const DAEMON_READY_TIMEOUT: Duration = Duration::from_secs(15);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(5);
const STDIN_CHUNK_BYTES: usize = 64 * 1024;
const CONFIG_METHODS: [&str; 3] = ["thread/start", "thread/resume", "thread/fork"];

/// Overrides collected from the frontend's argv, expressed as the dotted-key
/// map accepted by the app-server `config` parameter.
#[derive(Debug, Default)]
struct SharedClientPlan {
    config: Map<String, Value>,
    /// Environment variables whose values became literal headers. They are
    /// removed from any daemon started on behalf of this client.
    secret_env: Vec<String>,
}

pub fn run(arguments: Vec<OsString>) -> ! {
    let Some(plan) = plan_shared_client(&arguments, &|name| std::env::var(name).ok()) else {
        exec_real_codex(&arguments);
    };
    let real_codex = resolve_real_codex();
    let websocket = match connect_shared_daemon(&plan, real_codex.as_ref().ok()) {
        Ok(Some(websocket)) => websocket,
        Ok(None) => exec_real_codex(&arguments),
        Err(error) => {
            eprintln!(
                "codexswitch app-server-client: shared app-server unavailable ({error:#}); starting a private app-server"
            );
            exec_real_codex(&arguments);
        }
    };
    match relay(websocket, &plan.config) {
        Ok(()) => std::process::exit(0),
        Err(error) => {
            eprintln!("codexswitch app-server-client: {error:#}");
            std::process::exit(1);
        }
    }
}

fn exec_real_codex(arguments: &[OsString]) -> ! {
    match resolve_real_codex() {
        Ok(codex) => {
            let error = Command::new(&codex).args(arguments).exec();
            eprintln!(
                "codexswitch app-server-client: failed to execute {}: {error}",
                codex.display()
            );
        }
        Err(error) => eprintln!("codexswitch app-server-client: {error:#}"),
    }
    std::process::exit(127);
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn resolve_real_codex() -> Result<PathBuf> {
    if let Some(path) = env_path(REAL_CODEX_ENV) {
        return Ok(path);
    }
    let launcher = crate::patched_codex::default_user_launcher()?;
    if is_executable_file(&launcher) {
        return Ok(launcher);
    }
    #[cfg(target_os = "linux")]
    {
        let home = env_path("HOME").context("HOME is not set")?;
        let managed = home.join(".local/share/codexswitch/current/patched-codex/codex");
        if is_executable_file(&managed) {
            return Ok(managed);
        }
    }
    bail!(
        "no Codex runtime found at {}; set {REAL_CODEX_ENV}",
        launcher.display()
    )
}

fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

// ---------------------------------------------------------------------------
// Argument planning
// ---------------------------------------------------------------------------

/// Returns the shared-client plan for a plain stdio `app-server` invocation,
/// or `None` when the invocation must run on the real Codex unchanged.
fn plan_shared_client(
    arguments: &[OsString],
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<SharedClientPlan> {
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_str())
        .collect::<Option<Vec<_>>>()?;
    let mut rest = arguments.into_iter();
    let mut overrides = Vec::new();
    let mut in_app_server = false;
    while let Some(argument) = rest.next() {
        if let Some(value) = flag_value(argument, "--config", Some("-c"), &mut rest) {
            overrides.push(parse_override(value?)?);
        } else if let Some(value) = flag_value(argument, "--enable", None, &mut rest) {
            overrides.push(feature_override(value?, true)?);
        } else if let Some(value) = flag_value(argument, "--disable", None, &mut rest) {
            overrides.push(feature_override(value?, false)?);
        } else if !in_app_server && argument == "app-server" {
            in_app_server = true;
        } else if in_app_server && argument == "--stdio" {
            continue;
        } else if let Some(value) = flag_value(argument, "--listen", None, &mut rest) {
            if !in_app_server || value? != "stdio://" {
                return None;
            }
        } else {
            // Unknown globals, other subcommands, app-server subcommands
            // (`proxy`, `daemon`, `generate-*`), help, and options the shared
            // daemon cannot honour per connection all run unchanged.
            return None;
        }
    }
    if !in_app_server {
        return None;
    }

    let mut plan = SharedClientPlan::default();
    for (key, value) in overrides {
        plan.config.insert(key, value);
    }
    convert_bearer_env_overrides(&mut plan, env);
    Some(plan)
}

/// Matches `long VALUE`, `long=VALUE`, `short VALUE`, `short=VALUE`, and
/// `shortVALUE`, mirroring clap. `Some(None)` means the flag matched but its
/// value is missing or looks like another flag.
fn flag_value<'a>(
    argument: &'a str,
    long: &str,
    short: Option<&str>,
    rest: &mut impl Iterator<Item = &'a str>,
) -> Option<Option<&'a str>> {
    if argument == long || short == Some(argument) {
        return Some(rest.next().filter(|value| !value.starts_with('-')));
    }
    if let Some(value) = argument
        .strip_prefix(long)
        .and_then(|value| value.strip_prefix('='))
    {
        return Some(Some(value));
    }
    let attached = argument.strip_prefix(short?)?;
    Some(Some(attached.strip_prefix('=').unwrap_or(attached)))
}

fn feature_override(name: &str, enabled: bool) -> Option<(String, Value)> {
    let name = name.trim();
    (!name.is_empty()).then(|| (format!("features.{name}"), Value::Bool(enabled)))
}

/// Mirrors Codex's `-c key=value` parsing: the value is TOML when it parses,
/// otherwise the raw string with surrounding quotes removed.
fn parse_override(raw: &str) -> Option<(String, Value)> {
    let (key, value) = raw.split_once('=')?;
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    let value = match toml::from_str::<toml::Table>(&format!("_x_ = {value}")) {
        Ok(mut table) => toml_to_json(table.remove("_x_")?)?,
        Err(_) => Value::String(
            value
                .trim()
                .trim_matches(|character| character == '"' || character == '\'')
                .to_string(),
        ),
    };
    Some((key.to_string(), value))
}

fn toml_to_json(value: toml::Value) -> Option<Value> {
    Some(match value {
        toml::Value::String(value) => Value::String(value),
        toml::Value::Integer(value) => Value::from(value),
        toml::Value::Float(value) => Value::Number(serde_json::Number::from_f64(value)?),
        toml::Value::Boolean(value) => Value::Bool(value),
        toml::Value::Datetime(value) => Value::String(value.to_string()),
        toml::Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(toml_to_json)
                .collect::<Option<Vec<_>>>()?,
        ),
        toml::Value::Table(table) => Value::Object(
            table
                .into_iter()
                .map(|(key, value)| Some((key, toml_to_json(value)?)))
                .collect::<Option<Map<_, _>>>()?,
        ),
    })
}

/// The shared daemon cannot read this client's environment, so an MCP
/// `bearer_token_env_var` whose variable is set here becomes a literal
/// `Authorization` header scoped to the thread's config.
fn convert_bearer_env_overrides(plan: &mut SharedClientPlan, env: &dyn Fn(&str) -> Option<String>) {
    let keys = plan.config.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        let segments = key.split('.').collect::<Vec<_>>();
        match segments.as_slice() {
            ["mcp_servers", name, "bearer_token_env_var"] => {
                let Some(Value::String(variable)) = plan.config.get(&key) else {
                    continue;
                };
                let variable = variable.clone();
                let Some(token) = env(&variable).filter(|token| !token.is_empty()) else {
                    continue;
                };
                plan.config.remove(&key);
                let headers = plan
                    .config
                    .entry(format!("mcp_servers.{name}.http_headers"))
                    .or_insert_with(|| Value::Object(Map::new()));
                set_authorization(headers, &token);
                plan.secret_env.push(variable);
            }
            ["mcp_servers", _] => {
                if let Some(server) = plan.config.get_mut(&key) {
                    convert_server_table(server, env, &mut plan.secret_env);
                }
            }
            ["mcp_servers"] => {
                if let Some(Value::Object(servers)) = plan.config.get_mut(&key) {
                    for server in servers.values_mut() {
                        convert_server_table(server, env, &mut plan.secret_env);
                    }
                }
            }
            _ => {}
        }
    }
}

fn convert_server_table(
    server: &mut Value,
    env: &dyn Fn(&str) -> Option<String>,
    secret_env: &mut Vec<String>,
) {
    let Some(server) = server.as_object_mut() else {
        return;
    };
    let Some(Value::String(variable)) = server.get("bearer_token_env_var") else {
        return;
    };
    let variable = variable.clone();
    let Some(token) = env(&variable).filter(|token| !token.is_empty()) else {
        return;
    };
    server.remove("bearer_token_env_var");
    let headers = server
        .entry("http_headers")
        .or_insert_with(|| Value::Object(Map::new()));
    set_authorization(headers, &token);
    secret_env.push(variable);
}

fn set_authorization(headers: &mut Value, token: &str) {
    if !headers.is_object() {
        *headers = Value::Object(Map::new());
    }
    if let Some(headers) = headers.as_object_mut() {
        headers.insert(
            "Authorization".to_string(),
            Value::String(format!("Bearer {token}")),
        );
    }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

/// Where the shared daemon is expected, and whether this client may start it.
struct SocketTarget {
    path: PathBuf,
    may_start_daemon: bool,
}

fn socket_target() -> Option<SocketTarget> {
    if let Some(path) = env_path(SOCKET_ENV) {
        return Some(SocketTarget {
            path,
            may_start_daemon: false,
        });
    }
    // The Mac desktop contract forbids a shared desktop bridge: the ChatGPT
    // desktop owns its stdio app-server child, so the Mac always runs a
    // private app-server unless a socket is named explicitly.
    if !cfg!(target_os = "linux") {
        return None;
    }
    let codex_home =
        env_path("CODEX_HOME").or_else(|| env_path("HOME").map(|home| home.join(".codex")))?;
    Some(SocketTarget {
        path: codex_home.join("app-server-control/app-server-control.sock"),
        may_start_daemon: true,
    })
}

fn connect_shared_daemon(
    plan: &SharedClientPlan,
    real_codex: Option<&PathBuf>,
) -> Result<Option<WebSocket<UnixStream>>> {
    let Some(target) = socket_target() else {
        return Ok(None);
    };
    let stream = match UnixStream::connect(&target.path) {
        Ok(stream) => stream,
        Err(error) if daemon_absent(&error) && target.may_start_daemon => {
            let codex = real_codex.context("no Codex runtime is available to start the daemon")?;
            start_daemon(codex, &plan.secret_env)?;
            wait_for_daemon(&target.path)?
        }
        Err(error) if daemon_absent(&error) => return Ok(None),
        Err(error) => {
            return Err(error).context("failed to connect to the app-server control socket")
        }
    };
    verify_socket_peer(&stream)?;
    handshake(stream).map(Some)
}

fn daemon_absent(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::NotFound | ErrorKind::ConnectionRefused
    )
}

/// Starts the shared daemon exactly the way ChatGPT's SSH remote does: a
/// `codex app-server proxy` through the managed launcher auto-starts the
/// daemon with the launcher's flags (for example `features.code_mode_host`),
/// then exits when its stdin closes. On Linux it runs inside its own transient
/// systemd user scope so the daemon never joins the calling frontend's service
/// cgroup; restarting T3 must not kill the daemon every other client shares.
fn start_daemon(codex: &Path, secret_env: &[String]) -> Result<()> {
    let systemd_run = Path::new("/usr/bin/systemd-run");
    let mut command = if cfg!(target_os = "linux") && is_executable_file(systemd_run) {
        let mut command = Command::new(systemd_run);
        command
            .args(["--user", "--scope", "--quiet", "--collect", "--"])
            .arg(codex);
        command
    } else {
        Command::new(codex)
    };
    command
        .args(["app-server", "proxy"])
        .env("CODEXSWITCH_SHARED_DAEMON_START", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    // The daemon outlives this client and serves every frontend; it must not
    // inherit this thread's credentials or pin the frontend's working tree.
    for variable in secret_env {
        command.env_remove(variable);
    }
    if let Some(home) = env_path("HOME") {
        command.current_dir(home);
    }
    let mut child = command
        .spawn()
        .context("failed to run `codex app-server proxy` to start the daemon")?;
    let deadline = Instant::now() + DAEMON_START_TIMEOUT;
    loop {
        // The proxy's own exit status is not the signal: it may exit non-zero
        // when stdin closes. Readiness is proven by the socket accepting.
        if child
            .try_wait()
            .context("failed to wait for `codex app-server proxy`")?
            .is_some()
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!(
                "`codex app-server proxy` did not start the daemon within {DAEMON_START_TIMEOUT:?}"
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_daemon(path: &Path) -> Result<UnixStream> {
    let deadline = Instant::now() + DAEMON_READY_TIMEOUT;
    loop {
        match UnixStream::connect(path) {
            Ok(stream) => return Ok(stream),
            Err(error) if daemon_absent(&error) && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(error) => {
                return Err(error)
                    .context("the started app-server daemon did not accept connections")
            }
        }
    }
}

/// Credentials travel over this socket, so its server must run as this user.
fn verify_socket_peer(stream: &UnixStream) -> Result<()> {
    let peer = socket_peer_uid(stream).context("failed to read the control socket peer")?;
    let euid = unsafe { libc::geteuid() };
    if peer != euid {
        bail!("the control socket is served by uid {peer}, not uid {euid}");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn socket_peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(io::Error::other("short SO_PEERCRED result"));
    }
    Ok(credentials.uid)
}

#[cfg(not(target_os = "linux"))]
fn socket_peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

fn handshake(stream: UnixStream) -> Result<WebSocket<UnixStream>> {
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    stream.set_write_timeout(Some(HANDSHAKE_TIMEOUT))?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES))
        .max_write_buffer_size(2 * MAX_MESSAGE_BYTES);
    let (websocket, _) =
        tungstenite::client::client_with_config("ws://localhost/", stream, Some(config))
            .map_err(|error| anyhow::anyhow!("WebSocket handshake failed: {error}"))?;
    let stream = websocket.get_ref();
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(None)?;
    stream.set_nonblocking(true)?;
    Ok(websocket)
}

// ---------------------------------------------------------------------------
// Relay
// ---------------------------------------------------------------------------

/// Relays newline-delimited JSON-RPC on stdio to WebSocket text frames until
/// the server closes the connection or stdin reaches EOF and the close
/// handshake completes. One thread, one poll loop: client lines are read only
/// when every earlier line has been handed to the socket, so a slow server
/// applies backpressure to the frontend instead of growing memory.
fn relay(mut websocket: WebSocket<UnixStream>, config: &Map<String, Value>) -> Result<()> {
    let socket_fd = websocket.get_ref().as_raw_fd();
    // Borrow fd 0 without buffering so poll readiness matches unread data.
    let mut stdin = ManuallyDrop::new(unsafe { File::from_raw_fd(libc::STDIN_FILENO) });
    let mut stdout = io::stdout().lock();
    let mut chunk = vec![0_u8; STDIN_CHUNK_BYTES];
    let mut partial = Vec::new();
    let mut outbound = std::collections::VecDeque::<String>::new();
    let mut stdin_open = true;
    let mut write_blocked = false;
    let mut close_deadline: Option<Instant> = None;

    loop {
        loop {
            match websocket.read() {
                Ok(Message::Text(text)) => write_line(&mut stdout, text.as_bytes())?,
                Ok(Message::Binary(bytes)) => write_line(&mut stdout, &bytes)?,
                Ok(_) => {}
                Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock => {
                    break
                }
                Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                    return Ok(())
                }
                // After the frontend closed stdin the daemon may drop the
                // socket without a closing handshake; the session is over.
                Err(tungstenite::Error::Protocol(
                    tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
                )) if !stdin_open => return Ok(()),
                Err(tungstenite::Error::Io(error))
                    if !stdin_open && error.kind() == ErrorKind::ConnectionReset =>
                {
                    return Ok(())
                }
                Err(error) => {
                    return Err(error).context("shared app-server connection failed");
                }
            }
        }

        if !websocket.can_write() {
            // The server started closing; nothing more can be delivered.
            outbound.clear();
            stdin_open = false;
        }
        while !write_blocked && close_deadline.is_none() {
            let Some(text) = outbound.pop_front() else {
                break;
            };
            match websocket.write(Message::text(text)) {
                Ok(()) => {}
                Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock => {
                    write_blocked = true;
                }
                Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                    return Ok(())
                }
                Err(error) => return Err(error).context("failed to send to the shared app-server"),
            }
        }

        if !stdin_open && outbound.is_empty() && close_deadline.is_none() {
            close_deadline = Some(Instant::now() + CLOSE_TIMEOUT);
            match websocket.close(None) {
                Ok(()) => {}
                Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock => {}
                Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                    return Ok(())
                }
                Err(error) => return Err(error).context("failed to close the shared app-server"),
            }
        }

        match websocket.flush() {
            Ok(()) => write_blocked = false,
            Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock => {
                write_blocked = true;
            }
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                return Ok(())
            }
            Err(error) => return Err(error).context("failed to send to the shared app-server"),
        }

        if !write_blocked && !outbound.is_empty() {
            // The socket drained; send the remaining queued lines first.
            continue;
        }
        let timeout_ms = match close_deadline {
            Some(deadline) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Ok(());
                }
                remaining.as_millis().min(i32::MAX as u128) as libc::c_int
            }
            None => -1,
        };
        let read_stdin = stdin_open && outbound.is_empty() && !write_blocked;
        let mut descriptors = [
            libc::pollfd {
                fd: socket_fd,
                events: libc::POLLIN | if write_blocked { libc::POLLOUT } else { 0 },
                revents: 0,
            },
            libc::pollfd {
                fd: if read_stdin { libc::STDIN_FILENO } else { -1 },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, timeout_ms) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == ErrorKind::Interrupted {
                continue;
            }
            return Err(error).context("failed to wait for relay input");
        }
        if read_stdin && descriptors[1].revents != 0 {
            let count = match stdin.read(&mut chunk) {
                Ok(count) => count,
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error).context("failed to read stdin"),
            };
            if count == 0 {
                stdin_open = false;
                let last = std::mem::take(&mut partial);
                queue_client_line(&last, config, &mut outbound)?;
                continue;
            }
            let mut data = &chunk[..count];
            while let Some(newline) = data.iter().position(|byte| *byte == b'\n') {
                if partial.is_empty() {
                    queue_client_line(&data[..newline], config, &mut outbound)?;
                } else {
                    partial.extend_from_slice(&data[..newline]);
                    let line = std::mem::take(&mut partial);
                    queue_client_line(&line, config, &mut outbound)?;
                }
                data = &data[newline + 1..];
            }
            partial.extend_from_slice(data);
            if partial.len() > MAX_MESSAGE_BYTES {
                bail!("a client message exceeded {MAX_MESSAGE_BYTES} bytes");
            }
        }
    }
}

fn write_line(stdout: &mut impl Write, bytes: &[u8]) -> Result<()> {
    stdout
        .write_all(bytes)
        .and_then(|()| stdout.write_all(b"\n"))
        .and_then(|()| stdout.flush())
        .context("failed to write to stdout")
}

fn queue_client_line(
    line: &[u8],
    config: &Map<String, Value>,
    outbound: &mut std::collections::VecDeque<String>,
) -> Result<()> {
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    if line.len() > MAX_MESSAGE_BYTES {
        bail!("a client message exceeded {MAX_MESSAGE_BYTES} bytes");
    }
    if line.iter().all(u8::is_ascii_whitespace) {
        return Ok(());
    }
    let text = std::str::from_utf8(line).context("a client message is not UTF-8")?;
    outbound.push_back(prepare_client_message(text, config));
    Ok(())
}

/// Adds the invocation's overrides to thread-opening requests. Everything
/// else, including unparsable input, is forwarded byte-for-byte.
fn prepare_client_message(text: &str, config: &Map<String, Value>) -> String {
    if config.is_empty() || !text.contains("thread/") {
        return text.to_owned();
    }
    let Ok(mut message) = serde_json::from_str::<Value>(text) else {
        return text.to_owned();
    };
    if !inject_thread_config(&mut message, config) {
        return text.to_owned();
    }
    serde_json::to_string(&message).unwrap_or_else(|_| text.to_owned())
}

fn inject_thread_config(message: &mut Value, config: &Map<String, Value>) -> bool {
    let Some(message) = message.as_object_mut() else {
        return false;
    };
    let is_thread_open = message
        .get("method")
        .and_then(Value::as_str)
        .is_some_and(|method| CONFIG_METHODS.contains(&method));
    if !is_thread_open || !message.contains_key("id") {
        return false;
    }
    let params = message
        .entry("params")
        .or_insert_with(|| Value::Object(Map::new()));
    if params.is_null() {
        *params = Value::Object(Map::new());
    }
    let Some(params) = params.as_object_mut() else {
        return false;
    };
    let existing = params.entry("config").or_insert(Value::Null);
    if existing.is_null() {
        *existing = Value::Object(Map::new());
    }
    let Some(existing) = existing.as_object_mut() else {
        return false;
    };
    for (key, value) in config {
        existing.entry(key.clone()).or_insert_with(|| value.clone());
    }
    true
}

pub fn is_subcommand(argument: Option<&OsStr>) -> bool {
    argument == Some(OsStr::new(SUBCOMMAND))
}
