//! End-to-end tests for `codexswitch-cli app-server-client`, the shared
//! app-server client used as T3 Code's Codex binary path.

use serde_json::{json, Value};
use std::fs;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use tungstenite::Message;

const TOKEN: &str = "t3-secret-token-value";
const MCP_URL: &str = "http://127.0.0.1:51870/mcp";

fn cli() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_codexswitch-cli"));
    command.arg("app-server-client");
    command
}

/// T3's argv shape: optional global flags, `app-server`, launch args, then the
/// per-thread MCP server whose bearer token arrives through the environment.
fn t3_arguments() -> Vec<String> {
    [
        "-c",
        "features.code_mode_host=true",
        "app-server",
        "--enable",
        "goals",
        "-c",
        &format!("mcp_servers.t3-code.url={MCP_URL}"),
        "-c",
        "mcp_servers.t3-code.bearer_token_env_var=\"T3_MCP_BEARER_TOKEN\"",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// A Codex stand-in that records how it was invoked, then echoes stdin, so a
/// test can prove the client exec'd it with the original argv and did not
/// consume any frontend input first.
fn write_fake_codex(dir: &Path) -> PathBuf {
    let path = dir.join("codex");
    fs::write(
        &path,
        r#"#!/bin/sh
if [ -n "$CODEXSWITCH_SHARED_DAEMON_START" ] && [ "$*" = "-c features.code_mode_host=true app-server --listen unix://" ]; then
  echo started > "$DAEMON_START_MARKER"
  exit 1
fi
printf 'argv:%s\n' "$@"
cat
"#,
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// The shipped launcher T3 is pointed at, routed to this build's CLI.
fn launcher() -> Command {
    let mut command =
        Command::new(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/codex-shared"));
    command.env("CODEXSWITCH_CLI", env!("CARGO_BIN_EXE_codexswitch-cli"));
    command
}

fn run_with_stdin(mut command: Command, stdin: &str) -> std::process::Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn expected_passthrough(arguments: &[String], stdin: &str) -> String {
    let mut expected = arguments
        .iter()
        .map(|argument| format!("argv:{argument}\n"))
        .collect::<String>();
    expected.push_str(stdin);
    expected
}

#[test]
fn relays_t3_session_through_shared_daemon_with_per_thread_mcp_config() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();

    // Fake shared daemon: WebSocket over the Unix socket, one JSON-RPC
    // message per text frame. It answers every request, emits a notification
    // before answering thread/start, and records what it received.
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut websocket = tungstenite::accept(stream).unwrap();
        let mut received = Vec::new();
        loop {
            match websocket.read() {
                Ok(Message::Text(text)) => {
                    let message: Value = serde_json::from_str(&text).unwrap();
                    received.push(text.to_string());
                    if message["method"] == "thread/start" {
                        websocket
                            .send(Message::text(
                                json!({
                                    "method": "mcpServer/startupStatus/updated",
                                    "params": {"threadId": "thread-new", "name": "t3-code"}
                                })
                                .to_string(),
                            ))
                            .unwrap();
                    }
                    if let Some(id) = message.get("id") {
                        websocket
                            .send(Message::text(
                                json!({"id": id, "result": {"method": message["method"]}})
                                    .to_string(),
                            ))
                            .unwrap();
                    }
                }
                Ok(Message::Close(_)) => {}
                Ok(_) => {}
                Err(tungstenite::Error::ConnectionClosed) => break,
                Err(error) => panic!("fake daemon failed: {error}"),
            }
        }
        received
    });

    let initialize =
        r#"{"id":1,  "method":"initialize","params":{"clientInfo":{"name":"t3code"}}}"#;
    let initialized = r#"{"method":"initialized"}"#;
    // Larger than one pipe read, so it must be reassembled intact.
    let large = format!(
        r#"{{"method":"note","params":{{"text":"{}"}}}}"#,
        "x".repeat(300_000)
    );
    let start = json!({
        "id": 2,
        "method": "thread/start",
        "params": {
            "cwd": "/work",
            "config": {"model": "gpt-client", "mcp_servers.t3-code.url": "http://client-wins/mcp"}
        }
    });
    let resume = json!({"id": 3, "method": "thread/resume", "params": {"threadId": "thread-old"}});
    let fork = json!({"id": 4, "method": "thread/fork", "params": {"threadId": "thread-old", "config": null}});
    let stdin = format!("{initialize}\n{initialized}\n{large}\n{start}\r\n\n{resume}\n{fork}");

    let fake_home = temp.path().join("home");
    let mut command = cli();
    command
        .args(t3_arguments())
        .env("CODEXSWITCH_APP_SERVER_SOCKET", &socket)
        .env("CODEXSWITCH_REAL_CODEX", temp.path().join("must-not-run"))
        .env("HOME", &fake_home)
        .env("CODEX_HOME", fake_home.join(".codex"))
        .env("T3_MCP_BEARER_TOKEN", TOKEN);
    let output = run_with_stdin(command, &stdin);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "client failed: {stderr}");
    assert!(!stderr.contains(TOKEN));

    let received = server.join().unwrap();
    assert_eq!(received.len(), 6);
    // Non-thread messages pass through byte-for-byte.
    assert_eq!(received[0], initialize);
    assert_eq!(received[1], initialized);
    assert_eq!(received[2], large);

    let bearer = json!({"Authorization": format!("Bearer {TOKEN}")});
    let start: Value = serde_json::from_str(&received[3]).unwrap();
    assert_eq!(start["params"]["cwd"], "/work");
    let config = start["params"]["config"].as_object().unwrap();
    assert_eq!(config["model"], "gpt-client");
    assert_eq!(config["mcp_servers.t3-code.url"], "http://client-wins/mcp");
    assert_eq!(config["mcp_servers.t3-code.http_headers"], bearer);
    assert_eq!(config["features.code_mode_host"], true);
    assert_eq!(config["features.goals"], true);
    assert!(!config.contains_key("mcp_servers.t3-code.bearer_token_env_var"));

    for index in [4, 5] {
        let message: Value = serde_json::from_str(&received[index]).unwrap();
        assert_eq!(message["params"]["threadId"], "thread-old");
        assert_eq!(
            message["params"]["config"],
            json!({
                "features.code_mode_host": true,
                "features.goals": true,
                "mcp_servers.t3-code.url": MCP_URL,
                "mcp_servers.t3-code.http_headers": bearer,
            })
        );
    }

    let stdout = String::from_utf8(output.stdout).unwrap();
    let lines = stdout
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(lines.len(), 5, "{stdout}");
    assert_eq!(lines[0]["id"], 1);
    assert_eq!(lines[1]["method"], "mcpServer/startupStatus/updated");
    assert_eq!(lines[2]["result"]["method"], "thread/start");
    assert_eq!(lines[3]["id"], 3);
    assert_eq!(lines[4]["id"], 4);
}

#[test]
fn non_shared_invocations_exec_the_real_codex_with_original_argv() {
    let temp = tempfile::tempdir().unwrap();
    let fake_codex = write_fake_codex(temp.path());
    let marker = temp.path().join("daemon-started");
    // A live listener proves pass-through never touches a reachable daemon.
    let socket = temp.path().join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();

    let invocations: Vec<Vec<&str>> = vec![
        vec!["--version"],
        vec!["exec", "--json", "hello"],
        vec!["-c", "model=\"o3\"", "login", "status"],
        vec!["app-server", "proxy"],
        vec!["app-server", "generate-json-schema", "--out", "/tmp/x"],
        vec!["app-server", "--analytics-default-enabled"],
        vec!["app-server", "--listen", "unix://"],
        vec!["app-server", "--strict-config"],
        vec!["-c", "missing-equals", "app-server"],
    ];
    for invocation in invocations {
        let arguments = invocation
            .iter()
            .map(|argument| argument.to_string())
            .collect::<Vec<_>>();
        let mut command = launcher();
        command
            .args(&arguments)
            .env("CODEXSWITCH_REAL_CODEX", &fake_codex)
            .env("CODEXSWITCH_APP_SERVER_SOCKET", &socket)
            .env("DAEMON_START_MARKER", &marker)
            .env("T3_MCP_BEARER_TOKEN", TOKEN);
        let output = run_with_stdin(command, "frontend input\n");
        assert!(output.status.success(), "{invocation:?}");
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            expected_passthrough(&arguments, "frontend input\n"),
            "{invocation:?}"
        );
    }
    listener.set_nonblocking(true).unwrap();
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        ErrorKind::WouldBlock,
        "a pass-through invocation connected to the shared daemon"
    );
    assert!(!marker.exists());
}

#[test]
fn missing_shared_daemon_falls_back_to_a_private_app_server() {
    let temp = tempfile::tempdir().unwrap();
    let fake_codex = write_fake_codex(temp.path());
    let marker = temp.path().join("daemon-started");
    let arguments = t3_arguments();
    let session = "{\"id\":1,\"method\":\"initialize\"}\n";

    // An explicitly named socket that does not exist never starts a daemon.
    let mut command = cli();
    command
        .args(&arguments)
        .env("CODEXSWITCH_REAL_CODEX", &fake_codex)
        .env(
            "CODEXSWITCH_APP_SERVER_SOCKET",
            temp.path().join("absent.sock"),
        )
        .env("DAEMON_START_MARKER", &marker)
        .env("T3_MCP_BEARER_TOKEN", TOKEN);
    let output = run_with_stdin(command, session);
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        expected_passthrough(&arguments, session)
    );
    assert!(!marker.exists());

    // Default discovery: Linux launches the shared `app-server --listen unix://` listener
    // (the fake fails it); macOS never starts a desktop daemon. Both then run
    // the private app-server with the untouched argv and stdin.
    let codex_home = temp.path().join("codex-home");
    let mut command = cli();
    command
        .args(&arguments)
        .env_remove("CODEXSWITCH_APP_SERVER_SOCKET")
        .env("CODEXSWITCH_REAL_CODEX", &fake_codex)
        .env("CODEX_HOME", &codex_home)
        .env("DAEMON_START_MARKER", &marker)
        .env("T3_MCP_BEARER_TOKEN", TOKEN);
    let output = run_with_stdin(command, session);
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        expected_passthrough(&arguments, session)
    );
    assert_eq!(marker.exists(), cfg!(target_os = "linux"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(TOKEN));
}
