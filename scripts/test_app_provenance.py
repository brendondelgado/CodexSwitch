import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('provenance', Path(__file__).with_name('check-app-provenance.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvenanceTests(unittest.TestCase):
    def test_install_requires_known_ancestor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()
            git('init')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-m', 'first')
            first = git('rev-parse', 'HEAD')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-m', 'second')
            second = git('rev-parse', 'HEAD')
            app = root / 'App.app'
            module.check(root, app)
            (app / 'Contents').mkdir(parents=True)
            def installed(revision):
                with (app / 'Contents/Info.plist').open('wb') as output:
                    plistlib.dump({'CFBundleSourceRevision': revision}, output)
            for revision in [first, second, first[:12] + '-dirty.abc123']:
                installed(revision)
                module.check(root, app)
            git('checkout', '--detach', first)
            installed(second)
            with self.assertRaises(ValueError):
                module.check(root, app)
            for revision in ['unknown', 'f' * 40, '']:
                installed(revision)
                with self.assertRaises(ValueError):
                    module.check(root, app)

    def test_guard_runs_before_build_and_quit(self):
        script = Path(__file__).with_name('build-app.sh').read_text()
        guard = script.index('python3 "$PROJECT_DIR/scripts/check-app-provenance.py"')
        self.assertLess(guard, script.index('swift build -c'))
        self.assertLess(guard, script.index('tell application "CodexSwitch" to quit'))


if __name__ == '__main__':
    unittest.main()
