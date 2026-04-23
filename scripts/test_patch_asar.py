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

    def test_apply_fast_mode_fallback_patch_adds_bundled_fast_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "font-settings-test.js"
            target.write_text(
                'import{a}from"./dep.js";'
                'function G(e){return e.additionalSpeedTiers?.includes(qe)===!0}'
                "function Qe(){return G({model:`gpt-5.4`})}"
            )

            ok = patch_asar.apply_fast_mode_fallback_patch(
                target,
                {"gpt-5.4", "gpt-5-mini"}
            )

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn("var _bundledFastModels=new Set([`gpt-5-mini`,`gpt-5.4`]);", patched)
            self.assertIn(
                'function G(e){return e.additionalSpeedTiers?.includes(qe)===!0||_bundledFastModels.has(e.model)&&(!(e.additionalSpeedTiers?.length>0))}',
                patched,
            )
            self.assertIn("function Qe(){return G({model:`gpt-5.4`})}", patched)

    def test_apply_desktop_request_patch_adds_auth_sync_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "send-app-server-request-test.js"
            target.write_text(
                "class X{"
                'writeSkillConfig(e){return this.sendRequest(`skills/config/write`,e)}'
                'async getAccount(){return this.sendRequest(`account/read`,{refreshToken:!1})}'
                'getGitDiffToRemote(e){return this.sendRequest(`gitDiffToRemote`,{cwd:e})}'
                "}"
            )

            ok = patch_asar.apply_desktop_request_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(
                'codexSwitchReadHostFile(e){return this.sendRequest(`fs/readFile`,{path:e})}',
                patched,
            )
            self.assertIn(
                'async codexSwitchLoginWithChatGptAuthTokens(e,t,n=null){return this.sendRequest(`account/login/start`,{type:`chatgptAuthTokens`,accessToken:e,chatgptAccountId:t,chatgptPlanType:n})}',
                patched,
            )
            self.assertIn('async getAccount(){return this.sendRequest(`account/read`,{refreshToken:!1})}', patched)

    def test_apply_desktop_auth_sync_patch_adds_safe_auth_watcher(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "invalidate-queries-and-broadcast-test.js"
            target.write_text(
                'import{s as e}from"./chunk.js";'
                'import{t}from"./react.js";'
                'import{o as n,r}from"./logger.js";'
                'import{S as i,T as a,o,r as s}from"./vscode-api.js";'
                'import{n as c}from"./use-window-type.js";'
                'import{i as l}from"./app-server-manager-hooks.js";'
                'import{t as u}from"./use-global-state.js";'
                'var d=n();function f(){let e=(0,d.c)(2),t=i(),n;return '
                'e[0]===t?n=e[1]:(n=()=>{t.invalidateQueries({queryKey:s(`is-copilot-api-available`)})},e[0]=t,e[1]=n),n}'
                'var m=e(t(),1),h=(0,m.createContext)(void 0),g=(0,m.createContext)(null),_=2e3,v=new WeakMap;'
                'function y(e){return e==null?null:e.type===`chatgpt`?`chatgpt`:`apikey`}function b(e,t){'
                'let n=(0,d.c)(14),{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i,shouldUseWindowsStartupAuthTimeout:a,onLogout:o}=t,[s,c]=(0,m.useState)(e!=null),[l,u]=(0,m.useState)(null),f,p;'
                'n[0]===e?(f=n[1],p=n[2]):(f=()=>{if(e==null){u(null),c(!1);return}u(null),c(!0)},p=[e],n[0]=e,n[1]=f,n[2]=p),'
                'n[3]!==r||n[4]!==e||n[5]!==o||n[6]!==a||n[7]!==i?(f=()=>{if(e==null)return;let t=!1,n=!1,s=null,l=()=>{'
                'C(e).then(e=>{n=!0,s!=null&&clearTimeout(s),!t&&(c(!1),u(T(e,{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i})))})'
                '.catch(()=>{n=!0,s!=null&&clearTimeout(s),t||(c(!1),u(S))})};a&&(s=setTimeout(()=>{t||n||(c(!1),u(x))},_)),l();'
                'let d=e=>{u(t=>e.authMethod==null&&t?.authMethod!=null?(o?.(),w()):t==null?e.authMethod==null?t:{...w(),authMethod:e.authMethod}:{...t,authMethod:e.authMethod??null}),l()};'
                'return e.addAuthStatusCallback(d),()=>{t=!0,s!=null&&clearTimeout(s),e.removeAuthStatusCallback(d)}},'
                'p=[e,r,o,a,i],n[3]=r,n[4]=e,n[5]=o,n[6]=a,n[7]=i,n[8]=f,n[9]=p):(f=n[8],p=n[9]),(0,m.useEffect)(f,p);'
                'let E;return n[10]===Symbol.for(`react.memo_cache_sentinel`)?(E=e=>{u(t=>({...t??w(),authMethod:e}))},n[10]=E):E=n[10];'
                'let D;return n[11]!==l||n[12]!==s?(D={isLoading:s,authState:l,setAuthMethod:E},n[11]=l,n[12]=s,n[13]=D):D=n[13],D}'
                'function x(e){return e??w()}function S(e){return e??w()}function C(e){let t=v.get(e);if(t!=null)return t;let n=e.getAccount().finally(()=>{v.delete(e)});return v.set(e,n),n}'
                'function w(){return{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null,planAtLogin:null}}'
            )

            ok = patch_asar.apply_desktop_auth_sync_patch(
                target,
                "/Users/test/.codex/auth.json"
            )

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn("_codexSwitchEnsureDesktopAuthSync", patched)
            self.assertIn("_codexSwitchDesktopAuthPrimed", patched)
            self.assertIn("/Users/test/.codex/auth.json", patched)
            self.assertIn("codexSwitchReadHostFile", patched)
            self.assertIn("codexSwitchLoginWithChatGptAuthTokens", patched)
            self.assertIn("_codexSwitchEnsureDesktopAuthSync(e),l();let d=", patched)

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
