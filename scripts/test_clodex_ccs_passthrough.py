#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCHER = ROOT / "scripts" / "patch-clodex-codexswitch.py"
PINNED_PACKAGE = pathlib.Path("/tmp/clodex-inspect/package")
TOKEN = "synthetic-ccs-gateway-token"


class _CCSHandler(http.server.BaseHTTPRequestHandler):
    observed = []

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size)
        self.__class__.observed.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "body": json.loads(body),
            }
        )
        payload = json.dumps(
            {
                "id": "msg_synthetic",
                "type": "message",
                "role": "assistant",
                "content": [{"type": "text", "text": "ccs-ok"}],
                "model": "claude-opus-5",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        return


def reserve_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class ClodexCCSPassthroughTests(unittest.TestCase):
    def test_native_model_passthrough_uses_configured_loopback_ccs_origin(self):
        if not PINNED_PACKAGE.exists():
            self.skipTest("pinned npm inspection fixture is absent")
        if not (PINNED_PACKAGE / "node_modules").exists():
            self.skipTest("pinned npm fixture dependencies are absent")
        if shutil.which("curl") is None:
            self.skipTest("curl is unavailable")

        with tempfile.TemporaryDirectory() as raw:
            temp = pathlib.Path(raw)
            package = temp / "package"
            package.mkdir()
            shutil.copy2(PINNED_PACKAGE / "package.json", package / "package.json")
            shutil.copytree(PINNED_PACKAGE / "dist", package / "dist")
            (package / "node_modules").symlink_to(
                PINNED_PACKAGE / "node_modules",
                target_is_directory=True,
            )
            patched = subprocess.run(
                [
                    sys.executable,
                    str(PATCHER),
                    "--apply",
                    "--package-root",
                    str(package),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(patched.returncode, 0, patched.stderr)

            _CCSHandler.observed = []
            upstream = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0),
                _CCSHandler,
            )
            thread = threading.Thread(target=upstream.serve_forever, daemon=True)
            thread.start()
            proxy_port = reserve_port()
            home = temp / "home"
            home.mkdir()
            process = subprocess.Popen(
                [
                    "node",
                    str(package / "dist" / "cli.js"),
                    "server",
                    "--proxy",
                    "--port",
                    str(proxy_port),
                    "--no-discovery",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "ANTHROPIC_AUTH_TOKEN": TOKEN,
                    "CLODEX_ANTHROPIC_PASSTHROUGH_BASE_URL": (
                        f"http://127.0.0.1:{upstream.server_port}"
                    ),
                },
            )
            startup_lines = []
            try:
                assert process.stdout is not None
                ca_path = None
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([process.stdout], [], [], 0.25)
                    if not ready:
                        if process.poll() is not None:
                            break
                        continue
                    line = re.sub(r"\x1b\[[0-9;]*m", "", process.stdout.readline())
                    startup_lines.append(line)
                    if "NODE_EXTRA_CA_CERTS=" in line:
                        ca_path = line.split("NODE_EXTRA_CA_CERTS=", 1)[1].strip()
                    if "Press Ctrl+C to stop." in line:
                        break
                self.assertIsNone(
                    process.poll(),
                    "Clodex proxy exited before readiness:\n"
                    + "".join(startup_lines),
                )
                self.assertIsNotNone(ca_path, "Clodex proxy did not report its CA")

                request = subprocess.run(
                    [
                        "curl",
                        "--silent",
                        "--show-error",
                        "--fail-with-body",
                        "--noproxy",
                        "",
                        "--proxy",
                        f"http://127.0.0.1:{proxy_port}",
                        "--cacert",
                        str(ca_path),
                        "--header",
                        f"Authorization: Bearer {TOKEN}",
                        "--header",
                        "Content-Type: application/json",
                        "--data",
                        json.dumps(
                            {
                                "model": "claude-opus-5",
                                "max_tokens": 1,
                                "messages": [{"role": "user", "content": "synthetic"}],
                            }
                        ),
                        "https://api.anthropic.com/v1/messages",
                    ],
                    text=True,
                    capture_output=True,
                    timeout=15,
                )
                self.assertEqual(request.returncode, 0, request.stderr)
                response = json.loads(request.stdout)
                self.assertEqual(response["content"][0]["text"], "ccs-ok")
                self.assertEqual(len(_CCSHandler.observed), 1)
                observed = _CCSHandler.observed[0]
                self.assertEqual(observed["path"], "/v1/messages")
                self.assertEqual(
                    observed["authorization"],
                    f"Bearer {TOKEN}",
                )
                self.assertEqual(observed["body"]["model"], "claude-opus-5")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                if process.stdout is not None:
                    process.stdout.close()
                upstream.shutdown()
                upstream.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
