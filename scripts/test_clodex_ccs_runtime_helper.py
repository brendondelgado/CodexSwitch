#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "clodex-ccs-runtime-helper.mjs"
TOKEN = "synthetic-ccs-internal-token"


class _Handler(http.server.BaseHTTPRequestHandler):
    expected_token = TOKEN

    def do_GET(self):
        if (
            self.path == "/v1/models"
            and self.headers.get("Authorization") == f"Bearer {self.expected_token}"
        ):
            payload = json.dumps({"data": []}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(401)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


class ClodexCCSRuntimeHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.package = self.root / "ccs"
        module = (
            self.package
            / "dist"
            / "cliproxy"
            / "auth"
            / "auth-token-manager.js"
        )
        module.parent.mkdir(parents=True)
        (self.package / "package.json").write_text(
            json.dumps({"name": "@kaitranntt/ccs", "version": "8.8.1"})
        )
        module.write_text(
            f'"use strict"; exports.getEffectiveApiKey = () => {TOKEN!r};\n'
        )
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temp.cleanup()

    def run_helper(self, action: str, **overrides):
        env = {
            **os.environ,
            "CLODEX_CCS_PACKAGE_ROOT": str(self.package),
            "CLODEX_CCS_BASE_URL": (
                f"http://127.0.0.1:{self.server.server_port}"
            ),
            **overrides,
        }
        return subprocess.run(
            ["node", str(HELPER), action],
            text=True,
            capture_output=True,
            env=env,
        )

    def test_check_is_authenticated_and_redacts_gateway_key(self):
        result = self.run_helper("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ready ccs=8.8.1", result.stdout)
        self.assertNotIn(TOKEN, result.stdout)
        self.assertNotIn(TOKEN, result.stderr)

    def test_token_is_returned_only_by_explicit_token_action(self):
        result = self.run_helper("--token")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, TOKEN)
        self.assertEqual(result.stderr, "")

    def test_wrong_ccs_version_and_non_loopback_origin_refuse(self):
        (self.package / "package.json").write_text(
            json.dumps({"name": "@kaitranntt/ccs", "version": "9.9.9"})
        )
        wrong_version = self.run_helper("--check")
        self.assertEqual(wrong_version.returncode, 78)
        self.assertIn("unsupported CCS version", wrong_version.stderr)
        self.assertNotIn(TOKEN, wrong_version.stderr)

        (self.package / "package.json").write_text(
            json.dumps({"name": "@kaitranntt/ccs", "version": "8.8.1"})
        )
        non_loopback = self.run_helper(
            "--check",
            CLODEX_CCS_BASE_URL="https://example.com",
        )
        self.assertEqual(non_loopback.returncode, 78)
        self.assertIn("loopback", non_loopback.stderr)

    def test_bad_gateway_auth_refuses_without_disclosing_key(self):
        _Handler.expected_token = "different-token"
        try:
            result = self.run_helper("--token")
        finally:
            _Handler.expected_token = TOKEN
        self.assertEqual(result.returncode, 78)
        self.assertEqual(result.stdout, "")
        self.assertIn("health check", result.stderr)
        self.assertNotIn(TOKEN, result.stderr)


if __name__ == "__main__":
    unittest.main()
