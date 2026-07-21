#!/usr/bin/env python3
"""Structural regression tests for the macOS bundle installer."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts" / "build-app.sh").read_text()


class BuildAppInstallerTests(unittest.TestCase):
    def test_stages_and_verifies_before_stopping_installed_app(self) -> None:
        stage = SCRIPT.index('ditto --noextattr --noqtn "$APP_BUNDLE" "$STAGED_PATH"')
        verify = SCRIPT.index('verify_bundle "$STAGED_PATH"')
        stop = SCRIPT.index('tell application "CodexSwitch" to quit')
        self.assertLess(stage, verify)
        self.assertLess(verify, stop)

    def test_never_deletes_installed_bundle_before_activation(self) -> None:
        self.assertNotIn('rm -rf "$INSTALL_PATH"', SCRIPT)
        self.assertIn('RENAME_SWAP = 0x00000002', SCRIPT)
        self.assertIn('atomic_swap_paths "$STAGED_PATH" "$INSTALL_PATH"', SCRIPT)
        self.assertIn('atomic_swap_paths "$INSTALL_PATH" "$STAGED_PATH"', SCRIPT)
        self.assertIn('preserving recovery bundle at $STAGED_PATH', SCRIPT)

    def test_installed_copy_is_verified_and_launch_failure_rolls_back(self) -> None:
        installed_verify = SCRIPT.index('verify_bundle "$INSTALL_PATH"')
        launch = SCRIPT.index('/usr/bin/open "$INSTALL_PATH"')
        running = SCRIPT.index('pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME"')
        activated = SCRIPT.index('ACTIVATED=1')
        self.assertLess(installed_verify, launch)
        self.assertLess(launch, running)
        self.assertLess(running, activated)
        self.assertIn('replacement app did not launch; previous app was restored', SCRIPT)
        self.assertIn('replacement app exited during launch; previous app was restored', SCRIPT)

    def test_dirty_build_provenance_is_rooted_in_project_source(self) -> None:
        self.assertIn('git -C "$PROJECT_DIR" rev-parse', SCRIPT)
        self.assertIn('git -C "$PROJECT_DIR" status --porcelain', SCRIPT)
        self.assertIn('source_tree_fingerprint', SCRIPT)
        self.assertIn('dirty.%s', SCRIPT)

    def test_release_bundle_requires_prepared_pinned_asar_tool(self) -> None:
        self.assertIn('CODEXSWITCH_ASAR_TOOL_DIR', SCRIPT)
        self.assertIn('CODEXSWITCH_REQUIRE_BUNDLED_ASAR_TOOL', SCRIPT)
        self.assertIn('Contents/Resources/asar-tool', SCRIPT)
        self.assertIn('node_modules/@electron/asar', SCRIPT)
        self.assertIn('find "$ASAR_TOOL_DESTINATION" -type l', SCRIPT)


if __name__ == "__main__":
    unittest.main()
