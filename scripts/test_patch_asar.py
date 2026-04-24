import importlib.util
import hashlib
import os
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path


def load_patch_module():
    script_path = Path(__file__).with_name("patch-asar.py")
    spec = importlib.util.spec_from_file_location("patch_asar", script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


patch_asar = load_patch_module()


class PatchAsarTests(unittest.TestCase):
    def test_collect_unpack_specs_preserves_exact_file_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            unpacked_root = Path(tmp)

            expected_files = [
                "node_modules/better-sqlite3/build/Release/better_sqlite3.node",
                "node_modules/better-sqlite3/lib/database.js",
                "node_modules/node-pty/build/Release/pty.node",
                "node_modules/node-pty/build/Release/spawn-helper",
                "node_modules/node-pty/lib/index.js",
            ]

            for relative_path in expected_files:
                file_path = unpacked_root / relative_path
                file_path.parent.mkdir(parents=True, exist_ok=True)
                file_path.write_text("x")

            unpack_dirs, unpack_files = patch_asar.collect_unpack_specs(unpacked_root)

            self.assertEqual(unpack_dirs, [])
            self.assertEqual(unpack_files, sorted(expected_files))

    def test_build_pack_command_uses_exact_unpack_file_flags(self):
        command = patch_asar.build_pack_command(
            Path("/tmp/src"),
            Path("/tmp/out.asar"),
            unpack_dirs=[],
            unpack_files=[
                "node_modules/better-sqlite3/lib/database.js",
                "node_modules/node-pty/build/Release/pty.node",
            ],
        )

        self.assertEqual(
            command,
            [
                *patch_asar.ASAR_CMD,
                "pack",
                "/tmp/src",
                "/tmp/out.asar",
                "--unpack",
                "node_modules/better-sqlite3/lib/database.js",
                "--unpack",
                "node_modules/node-pty/build/Release/pty.node",
            ],
        )

    def test_sha256_asar_header_json_hashes_header_not_whole_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            asar_path = Path(tmp) / "app.asar"
            header_json = b'{"files":{"index.js":{"size":1}}}'
            blob = bytearray(16 + len(header_json) + 32)
            struct.pack_into("<I", blob, 12, len(header_json))
            blob[16 : 16 + len(header_json)] = header_json
            blob[-32:] = b"x" * 32
            asar_path.write_bytes(blob)

            actual = patch_asar.sha256_asar_header_json(asar_path)

            self.assertEqual(actual, hashlib.sha256(header_json).hexdigest())
            self.assertNotEqual(actual, hashlib.sha256(blob).hexdigest())

    def test_update_info_plist_rewrites_electron_asar_integrity_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            plist_path = Path(tmp) / "Info.plist"
            plist_path.write_bytes(
                plistlib.dumps(
                    {
                        "ElectronAsarIntegrity": {
                            "Resources/app.asar": {
                                "algorithm": "SHA256",
                                "hash": "old-hash",
                            }
                        }
                    }
                )
            )

            patch_asar.update_info_plist_asar_hash(
                plist_path,
                asar_relative_path="Resources/app.asar",
                new_hash="new-hash",
            )

            updated = plistlib.loads(plist_path.read_bytes())
            self.assertEqual(
                updated["ElectronAsarIntegrity"]["Resources/app.asar"]["hash"],
                "new-hash",
            )

    def test_migrate_legacy_auth_patch_is_noop_when_auth_hook_is_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "invalidate-queries-and-broadcast-test.js"
            original = (
                'import{s as e}from"./chunk.js";'
                'import{t}from"./react.js";'
                'import{o as n,r}from"./logger.js";'
                'import{S as i,T as a,o,r as s}from"./vscode-api.js";'
                'var d=n();'
                'function f(){let e=(0,d.c)(2),t=i(),n;return '
                'e[0]===t?n=e[1]:(n=()=>{t.invalidateQueries({queryKey:s(`is-copilot-api-available`)})},'
                'e[0]=t,e[1]=n),n}'
                'var m=e(t(),1),_=2e3,v=new WeakMap;'
                'function b(e,t){let n=(0,d.c)(14),{onLogout:o}=t,[l,u]=(0,m.useState)(null),h,g;'
                'h=()=>{if(e==null)return;let t=!1,n=!1,s=null,l=()=>{'
                'C(e).then(e=>{n=!0,s!=null&&clearTimeout(s),!t&&u(T(e,{isCopilotApiAvailable:!1,useCopilotAuthIfAvailable:!1}))})'
                '.catch(()=>{n=!0,s!=null&&clearTimeout(s),t||u(S)})};'
                'a&&(s=setTimeout(()=>{t||n||(u(x))},_)),l();'
                'let d=e=>{u(t=>e.authMethod==null&&t?.authMethod!=null?(o?.(),w()):t==null?e.authMethod==null?t:{...w(),authMethod:e.authMethod}:{...t,authMethod:e.authMethod??null}),l()};'
                'return e.addAuthStatusCallback(d),()=>{t=!0,s!=null&&clearTimeout(s),e.removeAuthStatusCallback(d)}}'
                'function C(e){let t=v.get(e);if(t!=null)return t;let n=e.getAccount().finally(()=>{v.delete(e)});return v.set(e,n),n}'
                'function w(){return{openAIAuth:null,authMethod:null}}'
                'function x(e){return e??w()}'
                'function S(e){return e??w()}'
                'export{b as a,f as l};'
            )
            target.write_text(original)

            ok = patch_asar.migrate_legacy_auth_patch(target)

            self.assertTrue(ok)
            self.assertEqual(target.read_text(), original)

    def test_migrate_legacy_auth_patch_removes_auth_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "invalidate-queries-and-broadcast-legacy.js"
            legacy = (
                'import{s as e}from"./chunk.js";'
                'import{t}from"./react.js";'
                'import{o as n,r}from"./logger.js";'
                'import{S as i,T as a,o,r as s}from"./vscode-api.js";'
                'import{n as c}from"./use-window-type.js";'
                'import{i as l}from"./app-server-manager-hooks.js";'
                'import{t as u}from"./use-global-state.js";'
                'var _qcHook=i,_qkBuild=s,_qcRef=null;'
                'function _invalidateAccountQueries(){if(_qcRef){'
                '_qcRef.invalidateQueries({queryKey:[`accounts`,`check`]});'
                '_qcRef.invalidateQueries({queryKey:_qkBuild(`account-info`)})}}'
                'var d=n();'
                'function f(){let e=(0,d.c)(2),t=i(),n;_qcRef=t;return '
                'e[0]===t?n=e[1]:(n=()=>{t.invalidateQueries({queryKey:s(`is-copilot-api-available`)})},'
                'e[0]=t,e[1]=n),n}'
                'var m=e(t(),1),_=2e3,v=new WeakMap;'
                'function b(e,t){let n=(0,d.c)(14),{onLogout:o}=t,[l,u]=(0,m.useState)(null),h,g;'
                'h=()=>{if(e==null)return;let t=!1,n=!1,s=null,l=()=>{'
                'C(e).then(e=>{n=!0,s!=null&&clearTimeout(s),!t&&u(T(e,{isCopilotApiAvailable:!1,useCopilotAuthIfAvailable:!1}))})'
                '.catch(()=>{n=!0,s!=null&&clearTimeout(s),t||u(S)})};'
                'a&&(s=setTimeout(()=>{t||n||(u(x))},_)),l();'
                'let d=e=>{u(t=>e.authMethod==null&&t?.authMethod!=null?(o?.(),w()):t==null?e.authMethod==null?t:{...w(),authMethod:e.authMethod}:{...t,authMethod:e.authMethod??null}),_invalidateAccountQueries(),l()};'
                'return e.addAuthStatusCallback(d),()=>{t=!0,s!=null&&clearTimeout(s),e.removeAuthStatusCallback(d)}}'
                'function C(e){let t=v.get(e);if(t!=null)return t;let n=e.getAccount().finally(()=>{v.delete(e)});return v.set(e,n),n}'
                'function w(){return{openAIAuth:null,authMethod:null}}'
                'function x(e){return e??w()}'
                'function S(e){return e??w()}'
                'export{b as a,f as l};'
            )
            expected = (
                'import{s as e}from"./chunk.js";'
                'import{t}from"./react.js";'
                'import{o as n,r}from"./logger.js";'
                'import{S as i,T as a,o,r as s}from"./vscode-api.js";'
                'import{n as c}from"./use-window-type.js";'
                'import{i as l}from"./app-server-manager-hooks.js";'
                'import{t as u}from"./use-global-state.js";'
                'var d=n();'
                'function f(){let e=(0,d.c)(2),t=i(),n;return '
                'e[0]===t?n=e[1]:(n=()=>{t.invalidateQueries({queryKey:s(`is-copilot-api-available`)})},'
                'e[0]=t,e[1]=n),n}'
                'var m=e(t(),1),_=2e3,v=new WeakMap;'
                'function b(e,t){let n=(0,d.c)(14),{onLogout:o}=t,[l,u]=(0,m.useState)(null),h,g;'
                'h=()=>{if(e==null)return;let t=!1,n=!1,s=null,l=()=>{'
                'C(e).then(e=>{n=!0,s!=null&&clearTimeout(s),!t&&u(T(e,{isCopilotApiAvailable:!1,useCopilotAuthIfAvailable:!1}))})'
                '.catch(()=>{n=!0,s!=null&&clearTimeout(s),t||u(S)})};'
                'a&&(s=setTimeout(()=>{t||n||(u(x))},_)),l();'
                'let d=e=>{u(t=>e.authMethod==null&&t?.authMethod!=null?(o?.(),w()):t==null?e.authMethod==null?t:{...w(),authMethod:e.authMethod}:{...t,authMethod:e.authMethod??null}),l()};'
                'return e.addAuthStatusCallback(d),()=>{t=!0,s!=null&&clearTimeout(s),e.removeAuthStatusCallback(d)}}'
                'function C(e){let t=v.get(e);if(t!=null)return t;let n=e.getAccount().finally(()=>{v.delete(e)});return v.set(e,n),n}'
                'function w(){return{openAIAuth:null,authMethod:null}}'
                'function x(e){return e??w()}'
                'function S(e){return e??w()}'
                'export{b as a,f as l};'
            )
            target.write_text(legacy)

            ok = patch_asar.migrate_legacy_auth_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertNotIn("_invalidateAccountQueries", patched)
            self.assertNotIn("_qcRef=", patched)
            self.assertNotIn("_qcHook=", patched)
            self.assertNotIn("queryKey:[`accounts`,`check`]", patched)
            self.assertNotIn("queryKey:_qkBuild(`account-info`)", patched)
            self.assertIn("addAuthStatusCallback", patched)
            self.assertIn("),l()};return e.addAuthStatusCallback(d)", patched)
            self.assertEqual(patched, expected)

    def test_apply_desktop_request_patch_adds_login_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-server-manager-signals-test.js"
            target.write_text(
                "class R{"
                "writeSkillConfig(e){return this.sendRequest(`skills/config/write`,e)}"
                "async getAccount(){return this.sendRequest(`account/read`,{refreshToken:!1})}"
                "}"
            )

            ok = patch_asar.apply_desktop_request_patch(target)

            patched = target.read_text()
            self.assertTrue(ok)
            self.assertIn("codexSwitchReadHostFile", patched)
            self.assertIn("codexSwitchLoginWithChatGptAuthTokens", patched)
            self.assertIn("account/login/start", patched)

    def test_apply_desktop_auth_sync_patch_adds_auth_file_watcher(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "use-auth-test.js"
            target.write_text(
                "var p=e(t(),1),m=(0,p.createContext)(void 0),g=2e3,_=new WeakMap;"
                "function y(e,t){let n=(0,u.c)(14),h;"
                "h=()=>{if(e==null)return;let t=!1,n=!1,s=null,l=()=>{S(e)}};"
                "return h}"
            )

            ok = patch_asar.apply_desktop_auth_sync_patch(
                target,
                "/Users/test/.codex/auth.json",
            )

            patched = target.read_text()
            self.assertTrue(ok)
            self.assertIn("_codexSwitchEnsureDesktopAuthSync", patched)
            self.assertIn("_codexSwitchDesktopAuthPath", patched)
            self.assertIn("/Users/test/.codex/auth.json", patched)
            self.assertIn("if(e==null)return;_codexSwitchEnsureDesktopAuthSync(e);let", patched)

    def test_list_codesign_targets_orders_nested_code_before_containers(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            (
                app
                / "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
            ).mkdir(parents=True)
            sparkle_framework = app / "Contents/Frameworks/Sparkle.framework"
            electron_framework = app / "Contents/Frameworks/Electron Framework.framework"
            libraries_dir = electron_framework / "Versions/A/Libraries"
            resources_dir = app / "Contents/Resources"
            libraries_dir.mkdir(parents=True, exist_ok=True)
            resources_dir.mkdir(parents=True, exist_ok=True)

            sparkled = sparkle_framework / "Versions/B/Sparkle"
            sparkled.parent.mkdir(parents=True, exist_ok=True)
            sparkled.write_text("sparkle")
            os.chmod(sparkled, 0o755)
            ffmpeg = libraries_dir / "libffmpeg.dylib"
            ffmpeg.write_text("ffmpeg")
            node_binary = libraries_dir / "sparkle.node"
            node_binary.write_text("node")
            helper = resources_dir / "codex"
            helper.write_text("codex")
            os.chmod(helper, 0o755)

            targets = patch_asar.list_codesign_targets(app)

            self.assertEqual(targets[-1], app)
            self.assertIn(sparkled, targets)
            self.assertIn(ffmpeg, targets)
            self.assertIn(node_binary, targets)
            self.assertIn(helper, targets)
            self.assertIn(sparkle_framework.resolve(), targets)
            self.assertIn(electron_framework.resolve(), targets)
            self.assertLess(targets.index(sparkled), targets.index(sparkle_framework.resolve()))
            self.assertLess(targets.index(ffmpeg), targets.index(electron_framework.resolve()))


if __name__ == "__main__":
    unittest.main()
