import importlib.util
import os
from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("patch-asar.py")
SPEC = importlib.util.spec_from_file_location("patch_asar", SCRIPT_PATH)
patch_asar = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(patch_asar)


FAST_FILE_CONTENT = (
    'import{a as o}from"./statsig.js";'
    'import{n as D}from"./auth.js";'
    'var qe=`fast`;'
    'function G(e){return e.additionalSpeedTiers?.includes(qe)===!0}'
    'function Qe(){let t=Xe(),{data:n}=Ve(),r;return r=t&&(n?.modelsByType.models.some(G)??!1),r}'
    'export{Qe as H};'
)

APP_SERVER_LAUNCHER_CONTENT = (
    "var ae=new Set([`BREAKPAD_DUMP_LOCATION`,`CHROME_CRASHPAD_PIPE_NAME`,"
    "`CRASHPAD_HANDLER_PID`,`ELECTRON_CRASH_REPORTER_PROCESS_TYPE`]);"
    "function F(e){let t={...e};"
    "for(let e of Object.keys(t))ae.has(e.toUpperCase())&&delete t[e];"
    "return t}"
    "function Yu(e){let n={...process.env,LOG_FORMAT:`json`};return{env:F(n)}}"
    "class Gl{ensureStarted(){"
    "this.options.logger.info(`Starting local app-server sidecar`)"
    "}createEnvironment(){let e={...F(process.env)},"
    "t=this.getCodexCliBinDirectoryFromExecutablePath();"
    "return t!=null&&Ml(e,Kl(jl(e),t)),e}"
    "getCodexCliBinDirectoryFromExecutablePath(){return null}}"
    "function Xu(e){if(process.platform===`win32`&&e.hostConfig.kind===`local`)"
    "return Zu(e);let t=ed({hostConfig:e.hostConfig});"
    "if(!t)throw Error(`Unable to locate the Codex CLI binary. "
    "Set CODEX_CLI_PATH or ensure the Electron resources include bin/codex.`);"
    "return t}"
)

APP_SERVER_LAUNCHER_LEGACY_HEADROOM_CONTENT = (
    "var ae=new Set([`BREAKPAD_DUMP_LOCATION`,`CHROME_CRASHPAD_PIPE_NAME`,"
    "`CRASHPAD_HANDLER_PID`,`ELECTRON_CRASH_REPORTER_PROCESS_TYPE`]);"
    "function F(e){let t={...e};"
    "e&&e.CODEXSWITCH_HEADROOM_BASE_URL&&("
    "\"CODEXSWITCH_HEADROOM_GLOBAL_ENV_PATCH\","
    "t.OPENAI_BASE_URL=e.CODEXSWITCH_HEADROOM_BASE_URL);"
    "delete t.CODEX_CLI_PATH;"
    "for(let e of Object.keys(t))ae.has(e.toUpperCase())&&delete t[e];"
    "return t}"
    "class Gl{ensureStarted(){"
    "this.options.logger.info(`Starting local app-server sidecar`)"
    "}createEnvironment(){let e={...F(process.env)};"
    "process.env.CODEXSWITCH_HEADROOM_BASE_URL&&("
    "e.OPENAI_BASE_URL=process.env.CODEXSWITCH_HEADROOM_BASE_URL);"
    "let t=this.getCodexCliBinDirectoryFromExecutablePath();"
    "return t!=null&&Ml(e,Kl(jl(e),t)),e}"
    "getCodexCliBinDirectoryFromExecutablePath(){return null}}"
)

APP_SERVER_LAUNCHER_CURRENT_HEADROOM_CONTENT = (
    "var ae=new Set([`BREAKPAD_DUMP_LOCATION`,`CHROME_CRASHPAD_PIPE_NAME`,"
    "`CRASHPAD_HANDLER_PID`,`ELECTRON_CRASH_REPORTER_PROCESS_TYPE`]);"
    "function F(e){let t={...e};"
    "e&&e.CODEXSWITCH_HEADROOM_BASE_URL&&("
    "\"CODEXSWITCH_HEADROOM_GLOBAL_ENV_PATCH\","
    "t.CODEXSWITCH_HEADROOM_BASE_URL=e.CODEXSWITCH_HEADROOM_BASE_URL,"
    "delete t.OPENAI_BASE_URL);"
    "delete t.CODEX_CLI_PATH;"
    "for(let e of Object.keys(t))ae.has(e.toUpperCase())&&delete t[e];"
    "return t}"
    "class Gl{ensureStarted(){"
    "this.options.logger.info(`Starting local app-server sidecar`)"
    "}createEnvironment(){let e={...F(process.env)};"
    "process.env.CODEXSWITCH_HEADROOM_BASE_URL&&("
    "\"CODEXSWITCH_HEADROOM_TRANSPORT_PATCH\","
    "e.CODEXSWITCH_HEADROOM_BASE_URL=process.env.CODEXSWITCH_HEADROOM_BASE_URL,"
    "delete e.OPENAI_BASE_URL);"
    "let t=this.getCodexCliBinDirectoryFromExecutablePath();"
    "return t!=null&&Ml(e,Kl(jl(e),t)),e}"
    "getCodexCliBinDirectoryFromExecutablePath(){return null}}"
)

BUNDLED_PLUGIN_SYNC_CONTENT = (
    "var H=t.Or(`BundledPluginsMarketplace`);"
    "async function cr(e){await ur({appServerConnection:e.appServerConnection,"
    "forceInstallPluginNames:new Set(e.forceInstallPluginNames??[]),"
    "installWhenMissingPluginNames:new Set(e.installWhenMissingPluginNames??[]),"
    "installedBundledMarketplace:n,materializedMarketplace:o,platformFamily:a})}"
    "H.info(`bundled_plugins_marketplace_sync_started`,{safe:{},sensitive:{}});"
    "async function ur(e){let t;try{"
    "t=(await e.appServerConnection.addMarketplace({source:e.materializedMarketplace.marketplaceRoot})).marketplaceName"
    "}catch(t){return H.warning(`bundled_plugins_marketplace_add_failed`,"
    "{safe:{marketplaceName:e.materializedMarketplace.marketplace.name},"
    "sensitive:{error:t,marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}"
    "H.info(`bundled_plugins_marketplace_added`,"
    "{safe:{enabledPluginNames:e.materializedMarketplace.marketplace.plugins.map(e=>e.name),"
    "marketplaceName:t},sensitive:{marketplaceRoot:e.materializedMarketplace.marketplaceRoot}});"
    "try{await vr({appServerConnection:e.appServerConnection,"
    "forceInstallPluginNames:e.forceInstallPluginNames,"
    "installWhenMissingPluginNames:e.installWhenMissingPluginNames,"
    "installedBundledMarketplace:e.installedBundledMarketplace,"
    "marketplace:e.materializedMarketplace.marketplace,marketplaceName:t,"
    "marketplaceRoot:e.materializedMarketplace.marketplaceRoot,platformFamily:e.platformFamily})}"
    "catch(n){return H.warning(`bundled_plugins_marketplace_install_failed`,"
    "{safe:{marketplaceName:t},sensitive:{error:n,"
    "marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}"
    "return!0}"
    "async function vr(e){await e.appServerConnection.installPlugin({marketplacePath:i,pluginName:t.name})}"
)

PLUGIN_LIST_CLIENT_CONTENT = (
    "class AppServerConnection{"
    "async listPlugins(e){await this.ensureReady();"
    "let t=`plugins:${uuid()}`,n=await this.sendInternalRequest({id:t,method:`plugin/list`,params:e});"
    "if(n.error)throw Error(n.error.message??`Failed to fetch plugins from app server`);"
    "return n.result??{featuredPluginIds:[],marketplaceLoadErrors:[],marketplaces:[]}}"
    "}"
)

PLUGIN_LIST_RENDERER_CONTENT = (
    "function Im(e,t){return e.sendRequest(`plugin/list`,t)}"
    "function Lm(e,t){return e.sendRequest(`plugin/read`,t)}"
    "\"list-plugins\":i9((e,{hostId:t,...n})=>e.sendRequest(`plugin/list`,n))"
)

MODERN_USE_AUTH_CONTENT = (
    'import{s as e}from"./chunk-Bj-mKKzh.js";'
    'import{Ho as t}from"./app-server-manager-signals-BOGyjFm3.js";'
    'import{n}from"./jsx-runtime-CiQ1k8xo.js";'
    'import{lt as r}from"./vscode-api-sUstfl-x.js";'
    'import{i}from"./app-server-manager-hooks-BJ2CaNwA.js";'
    'import{t as a}from"./use-global-state-DeR7WgiQ.js";'
    'import{n as o}from"./use-is-copilot-api-available-4vxhZax2.js";'
    "var s=e(n(),1),c=(0,s.createContext)(void 0),u=r(),d=2e3,f=new WeakMap;"
    "function p(e,t){let n=(0,u.c)(14),"
    "{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i,"
    "shouldUseWindowsStartupAuthTimeout:a,onLogout:o}=t,"
    "[c,l]=(0,s.useState)(e!=null),[f,p]=(0,s.useState)(null),v,b;"
    "let x,S;x=()=>{if(e==null)return;let t=!1,n=!1,s=null,"
    "c=()=>{g(e).then(e=>{n=!0,p(y(e,{isCopilotApiAvailable:r,"
    "useCopilotAuthIfAvailable:i}))}).catch(()=>{n=!0,p(h)})};"
    "c();let u=e=>{p(t=>e.authMethod==null&&t?.authMethod!=null?"
    "(o?.(),_()):t==null?e.authMethod==null?t:{..._(),authMethod:e.authMethod}:"
    "{...t,authMethod:e.authMethod??null}),c()};"
    "return e.addAuthStatusCallback(u),()=>{t=!0,s!=null&&clearTimeout(s),"
    "e.removeAuthStatusCallback(u)}},S=[e,r,o,a,i],(0,s.useEffect)(x,S);"
    "return{isLoading:c,authState:f}}"
    "function g(e){let t=f.get(e);if(t!=null)return t;"
    "let n=e.getAccount().finally(()=>{f.delete(e)});return f.set(e,n),n}"
    "function _(){return{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null}}"
    "function y(e,t){return{authMethod:e.account?.type}}"
    "function h(e){return e??_()}"
    "export{p as u};"
)


class PatchAsarTests(unittest.TestCase):
    def test_cli_has_sighup_patch_requires_marker_and_reload_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp) / "codex"
            cli.write_bytes(b"sighup-verified-tui\0SIGHUP: auth reloaded from disk")
            self.assertTrue(patch_asar.cli_has_sighup_patch(cli))

            cli.write_bytes(b"sighup-verified-tui only")
            self.assertFalse(patch_asar.cli_has_sighup_patch(cli))

    def test_ensure_bundled_cli_hot_swap_copies_verified_source(self):
        old_bundled_cli = patch_asar.BUNDLED_CLI_PATH
        old_env = os.environ.get("CODEXSWITCH_SIGHUP_CLI")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / "patched-codex"
                bundled = root / "Codex.app/Contents/Resources/codex"
                bundled.parent.mkdir(parents=True)
                source.write_bytes(
                    b"patched binary\0sighup-verified-exec\0"
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5"
                )
                bundled.write_bytes(b"stock binary")
                os.chmod(source, 0o755)
                os.chmod(bundled, 0o755)

                patch_asar.BUNDLED_CLI_PATH = bundled
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = str(source)

                ok, changed = patch_asar.ensure_bundled_cli_hot_swap()

                self.assertTrue(ok)
                self.assertTrue(changed)
                self.assertEqual(bundled.read_bytes(), source.read_bytes())
                self.assertTrue(os.access(bundled, os.X_OK))
        finally:
            patch_asar.BUNDLED_CLI_PATH = old_bundled_cli
            if old_env is None:
                os.environ.pop("CODEXSWITCH_SIGHUP_CLI", None)
            else:
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = old_env

    def test_ensure_bundled_cli_hot_swap_refuses_gpt55_downgrade(self):
        old_bundled_cli = patch_asar.BUNDLED_CLI_PATH
        old_env = os.environ.get("CODEXSWITCH_SIGHUP_CLI")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / "old-patched-codex"
                bundled = root / "Codex.app/Contents/Resources/codex"
                bundled.parent.mkdir(parents=True)
                source.write_bytes(
                    b"patched but older\0sighup-verified-exec\0"
                    b"SIGHUP: auth reloaded from disk"
                )
                bundled.write_bytes(b"new stock binary\0gpt-5.5")
                os.chmod(source, 0o755)
                os.chmod(bundled, 0o755)

                patch_asar.BUNDLED_CLI_PATH = bundled
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = str(source)

                ok, changed = patch_asar.ensure_bundled_cli_hot_swap()

                self.assertFalse(ok)
                self.assertFalse(changed)
                self.assertEqual(bundled.read_bytes(), b"new stock binary\0gpt-5.5")
        finally:
            patch_asar.BUNDLED_CLI_PATH = old_bundled_cli
            if old_env is None:
                os.environ.pop("CODEXSWITCH_SIGHUP_CLI", None)
            else:
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = old_env

    def test_ensure_bundled_cli_hot_swap_is_idempotent(self):
        old_bundled_cli = patch_asar.BUNDLED_CLI_PATH
        old_env = os.environ.get("CODEXSWITCH_SIGHUP_CLI")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                bundled = Path(tmp) / "Codex.app/Contents/Resources/codex"
                bundled.parent.mkdir(parents=True)
                bundled.write_bytes(
                    b"already patched\0sighup-verified-tui\0"
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5"
                )

                patch_asar.BUNDLED_CLI_PATH = bundled
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = str(bundled)

                ok, changed = patch_asar.ensure_bundled_cli_hot_swap()

                self.assertTrue(ok)
                self.assertFalse(changed)
        finally:
            patch_asar.BUNDLED_CLI_PATH = old_bundled_cli
            if old_env is None:
                os.environ.pop("CODEXSWITCH_SIGHUP_CLI", None)
            else:
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = old_env

    def test_ensure_bundled_cli_preserves_openai_parent_for_computer_use(self):
        old_app_path = patch_asar.APP_PATH
        old_bundled_cli = patch_asar.BUNDLED_CLI_PATH
        old_env = os.environ.get("CODEXSWITCH_SIGHUP_CLI")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                app = Path(tmp) / "Codex.app"
                bundled = app / "Contents/Resources/codex"
                sky_client = app / patch_asar.SKY_COMPUTER_USE_CLIENT_APP_RELATIVE
                computer_use = app / patch_asar.COMPUTER_USE_PLUGIN_APP_RELATIVE
                source = Path(tmp) / "patched-codex"
                bundled.parent.mkdir(parents=True)
                sky_client.mkdir(parents=True)
                computer_use.mkdir(parents=True, exist_ok=True)
                bundled.write_bytes(b"locally signed patched cli")
                source.write_bytes(
                    b"patched binary\0sighup-verified-exec\0"
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5"
                )

                patch_asar.APP_PATH = app
                patch_asar.BUNDLED_CLI_PATH = bundled
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = str(source)

                with patch.object(
                    patch_asar,
                    "restore_official_bundled_cli",
                    return_value=(True, True),
                ) as restore:
                    ok, changed = patch_asar.ensure_bundled_cli_hot_swap()

                self.assertTrue(ok)
                self.assertTrue(changed)
                restore.assert_called_once_with(app)
                self.assertEqual(bundled.read_bytes(), b"locally signed patched cli")
        finally:
            patch_asar.APP_PATH = old_app_path
            patch_asar.BUNDLED_CLI_PATH = old_bundled_cli
            if old_env is None:
                os.environ.pop("CODEXSWITCH_SIGHUP_CLI", None)
            else:
                os.environ["CODEXSWITCH_SIGHUP_CLI"] = old_env

    def test_find_auth_file_prefers_react_query_auth_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            (assets / "send-app-server-request.js").write_text(
                "function fake(){return e.addAuthStatusCallback(d)}"
                "function also(){return e.getAccount()}"
                "var authMethod=`chatgpt`;"
            )
            expected = assets / "invalidate-queries-and-broadcast.js"
            expected.write_text(
                'import{S as i,T as a,o,r as s}from"./vscode.js";'
                "function f(){let t=i();return()=>{t.invalidateQueries({queryKey:s(`is-copilot-api-available`)})}}"
                "function real(){return e.addAuthStatusCallback(d)}"
                "function also(){return e.getAccount()}"
                "var authMethod=`chatgpt`;"
            )

            found = patch_asar.find_auth_file(assets)

            self.assertEqual(found, expected)

    def test_find_auth_file_prefers_modern_use_auth_bundle_without_query_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            manager = assets / "app-server-manager-signals-HASH.js"
            manager.write_text(
                "function fake(){return e.addAuthStatusCallback(d)}"
                "function also(){return e.getAccount()}"
                "var authMethod=`chatgpt`;"
                "function query(){let t=n();t.invalidateQueries({queryKey:r(`account-info`)})}"
            )
            expected = assets / "use-auth-HASH.js"
            expected.write_text(MODERN_USE_AUTH_CONTENT)

            found = patch_asar.find_auth_file(assets)

            self.assertEqual(found, expected)

    def test_apply_patch_supports_modern_use_auth_bundle_without_query_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "use-auth-HASH.js"
            target.write_text(MODERN_USE_AUTH_CONTENT)

            ok = patch_asar.apply_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.PATCH_MARKER, patched)
            self.assertIn("A as _csUseQueryClient", patched)
            self.assertIn("r as _csQueryKey", patched)
            self.assertIn("_qcRef=_csUseQueryClient();let n=(0,u.c)(14),", patched)
            self.assertIn(
                "}),_invalidateAccountQueries(),c()};return e.addAuthStatusCallback",
                patched,
            )
            self.assertIn("export{p as u};", patched)

    def test_find_fast_mode_file_matches_bundle_by_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            (assets / "font-settings-good.js").write_text(FAST_FILE_CONTENT)
            (assets / "other.js").write_text("function nope(){}")

            found = patch_asar.find_fast_mode_file(assets)

            self.assertEqual(found, assets / "font-settings-good.js")

    def test_find_app_server_launcher_file_matches_by_behavior(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "webview/assets").mkdir(parents=True)
            (root / "webview/assets/irrelevant.js").write_text("function nope(){}")
            expected = root / ".vite/build/workspace-root-drop-handler.js"
            expected.parent.mkdir(parents=True)
            expected.write_text(APP_SERVER_LAUNCHER_CONTENT)

            found = patch_asar.find_app_server_launcher_file(root)

            self.assertEqual(found, expected)

    def test_apply_fast_mode_fallback_patch_inserts_bundled_fast_model_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "font-settings.js"
            target.write_text(FAST_FILE_CONTENT)

            ok = patch_asar.apply_fast_mode_fallback_patch(target, {"gpt-5.4"})

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.FAST_FALLBACK_MARKER, patched)
            self.assertIn("new Set([`gpt-5.4`])", patched)
            self.assertIn(
                "e.additionalSpeedTiers?.includes(qe)===!0||"
                "_bundledFastModels.has(e.model)&&"
                "(!(e.additionalSpeedTiers?.length>0))",
                patched,
            )

    def test_apply_fast_mode_fallback_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "font-settings.js"
            target.write_text(FAST_FILE_CONTENT)

            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(target, {"gpt-5.4"})
            )
            first = target.read_text()

            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(target, {"gpt-5.4"})
            )
            second = target.read_text()

            self.assertEqual(first, second)

    def test_remove_headroom_env_patch_leaves_stock_launcher_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_env_patch(target))

            self.assertEqual(target.read_text(), APP_SERVER_LAUNCHER_CONTENT)

    def test_remove_headroom_env_patch_removes_current_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CURRENT_HEADROOM_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_env_patch(target))

            patched = target.read_text()
            self.assertNotIn(patch_asar.HEADROOM_TRANSPORT_PATCH_MARKER, patched)
            self.assertNotIn(
                "e.CODEXSWITCH_HEADROOM_BASE_URL=process.env.CODEXSWITCH_HEADROOM_BASE_URL",
                patched,
            )
            self.assertNotIn("delete e.OPENAI_BASE_URL", patched)
            self.assertIn("t=this.getCodexCliBinDirectoryFromExecutablePath()", patched)

    def test_remove_headroom_env_patch_removes_legacy_openai_base_url_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_LEGACY_HEADROOM_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_env_patch(target))

            patched = target.read_text()
            self.assertNotIn("e.OPENAI_BASE_URL=process.env.CODEXSWITCH_HEADROOM_BASE_URL", patched)
            self.assertFalse(patch_asar.has_headroom_env_bridge(patched))

    def test_remove_headroom_global_env_patch_leaves_stock_launcher_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_global_env_patch(target))

            self.assertEqual(target.read_text(), APP_SERVER_LAUNCHER_CONTENT)

    def test_remove_headroom_global_env_patch_removes_current_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CURRENT_HEADROOM_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_global_env_patch(target))

            patched = target.read_text()
            self.assertNotIn(patch_asar.HEADROOM_GLOBAL_ENV_MARKER, patched)
            self.assertNotIn("t.CODEXSWITCH_HEADROOM_BASE_URL=e.CODEXSWITCH_HEADROOM_BASE_URL", patched)
            self.assertNotIn("delete t.OPENAI_BASE_URL", patched)
            self.assertIn("delete t.CODEX_CLI_PATH", patched)

    def test_remove_headroom_global_env_patch_removes_legacy_openai_base_url_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_LEGACY_HEADROOM_CONTENT)

            self.assertTrue(patch_asar.remove_headroom_global_env_patch(target))

            patched = target.read_text()
            self.assertNotIn("t.OPENAI_BASE_URL=e.CODEXSWITCH_HEADROOM_BASE_URL", patched)
            self.assertFalse(patch_asar.has_headroom_global_env_bridge(patched))

    def test_iter_sighup_cli_candidates_includes_local_fork_release(self):
        candidates = [str(path) for path in patch_asar.iter_sighup_cli_candidates()]

        self.assertIn(
            str(Path.home() / "Developer/codex/codex-rs/target/release/codex"),
            candidates,
        )

    def test_codex_app_is_running_detects_desktop_bundle_process(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="123 /Applications/Codex.app/Contents/MacOS/Codex\n",
            stderr="",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertTrue(patch_asar.codex_app_is_running())

    def test_codex_app_is_running_ignores_pgrep_and_codexswitch(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "123 pgrep -fl /Applications/Codex.app/Contents\n"
                "456 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch\n"
            ),
            stderr="",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertFalse(patch_asar.codex_app_is_running())

    def test_codex_app_is_running_ignores_crashpad_and_computer_use(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "123 /Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler\n"
                "456 /Applications/Codex.app/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient mcp\n"
            ),
            stderr="",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertFalse(patch_asar.codex_app_is_running())

    def test_codex_app_is_running_detects_app_server(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="123 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled\n",
            stderr="",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertTrue(patch_asar.codex_app_is_running())

    def test_codesign_team_identifier_normalizes_not_set(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="Executable=/tmp/Codex\nTeamIdentifier=not set\n",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertIsNone(patch_asar.codesign_team_identifier(Path("/tmp/Codex")))

    def test_select_codesign_identity_prefers_apple_issued_over_self_signed_name(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                '  1) AAA "Apple Development: Brendon Delgado (856E75LLMU)"\n'
                '  2) BBB "iPhone Developer: bd7349@gmail.com (856E75LLMU)"\n'
                "     2 valid identities found\n"
            ),
            stderr="",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed), patch.object(
            patch_asar,
            "codesign_identity_is_apple_issued",
            side_effect=lambda identity: identity.startswith("iPhone Developer:"),
        ):
            self.assertEqual(
                patch_asar.select_codesign_identity(),
                "iPhone Developer: bd7349@gmail.com (856E75LLMU)",
            )

    def test_app_framework_executable_prefers_current_codex_framework_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Codex.app"
            framework_executable = (
                app
                / "Contents/Frameworks/Codex Framework.framework/Codex Framework"
            )
            framework_executable.parent.mkdir(parents=True)
            framework_executable.write_text("binary")

            found = patch_asar.app_framework_executable(app)

            self.assertEqual(found, framework_executable.resolve())

    def test_executable_and_framework_team_ids_match_accepts_local_dev_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Codex.app"
            main_executable = app / "Contents/MacOS/Codex"
            framework_executable = (
                app
                / "Contents/Frameworks/Codex Framework.framework/Codex Framework"
            )
            main_executable.parent.mkdir(parents=True)
            framework_executable.parent.mkdir(parents=True)
            main_executable.write_text("binary")
            framework_executable.write_text("binary")

            with patch.object(
                patch_asar,
                "codesign_team_identifier",
                side_effect=[None, None],
            ):
                self.assertTrue(patch_asar.executable_and_framework_team_ids_match(app))

    def test_apply_desktop_cli_path_guard_patch_deletes_global_override_before_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CONTENT)

            ok = patch_asar.apply_desktop_cli_path_guard_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.DESKTOP_CLI_PATH_GUARD_MARKER, patched)
            self.assertIn("delete process.env.CODEX_CLI_PATH", patched)
            self.assertIn("Unable to locate the Codex CLI binary", patched)

    def test_apply_desktop_cli_path_guard_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(APP_SERVER_LAUNCHER_CONTENT)

            self.assertTrue(patch_asar.apply_desktop_cli_path_guard_patch(target))
            first = target.read_text()

            self.assertTrue(patch_asar.apply_desktop_cli_path_guard_patch(target))
            second = target.read_text()

            self.assertEqual(first, second)

    def test_find_bundled_plugin_sync_file_matches_by_behavior(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".vite/build").mkdir(parents=True)
            (root / ".vite/build/irrelevant.js").write_text("function nope(){}")
            expected = root / ".vite/build/main.js"
            expected.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)

            found = patch_asar.find_bundled_plugin_sync_file(root)

            self.assertEqual(found, expected)

    def test_apply_bundled_plugin_sync_compat_patch_falls_back_when_marketplace_add_is_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "main.js"
            target.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)

            ok = patch_asar.apply_bundled_plugin_sync_compat_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.BUNDLED_PLUGIN_SYNC_COMPAT_MARKER, patched)
            self.assertIn("catch(n){let r=String(n?.message??n)", patched)
            self.assertNotIn("catch(t){let r=String(t?.message??t)", patched)
            self.assertIn("bundled_plugins_marketplace_add_compat_fallback", patched)
            self.assertIn("config/batchWrite", patched)
            self.assertIn("marketplaces.${t}.source", patched)
            self.assertIn("bundled_plugins_marketplace_added", patched)
            self.assertIn("await vr({appServerConnection:e.appServerConnection", patched)
            self.assertIn("bundled_plugin_direct_install_requested", patched)
            self.assertIn("await new Promise(e=>setTimeout(e,250))", patched)
            self.assertIn("for(let n of e.materializedMarketplace.marketplace.plugins)", patched)

    def test_apply_bundled_plugin_sync_compat_patch_upgrades_shadowed_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "main.js"
            target.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)
            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))
            broken = target.read_text().replace(
                "catch(n){let r=String(n?.message??n);if(r.includes(`marketplace/add`)){",
                "catch(t){let r=String(t?.message??t);if(r.includes(`marketplace/add`)){",
            )
            target.write_text(broken)

            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))

            patched = target.read_text()
            self.assertIn("catch(n){let r=String(n?.message??n)", patched)
            self.assertNotIn("catch(t){let r=String(t?.message??t)", patched)
            self.assertTrue(patch_asar.has_safe_bundled_plugin_sync_patch(patched))

    def test_shadowed_bundled_plugin_sync_fallback_is_not_safe_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "main.js"
            target.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)
            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))
            broken = target.read_text().replace(
                "catch(n){let r=String(n?.message??n);if(r.includes(`marketplace/add`)){",
                "catch(t){let r=String(t?.message??t);if(r.includes(`marketplace/add`)){",
            )

            self.assertTrue(
                patch_asar.has_shadowed_bundled_plugin_sync_fallback(broken)
            )
            self.assertFalse(patch_asar.has_safe_bundled_plugin_sync_patch(broken))

    def test_apply_bundled_plugin_sync_compat_patch_upgrades_missing_direct_install_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "main.js"
            target.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)
            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))
            intermediate = target.read_text()
            direct_start = intermediate.find(
                "catch(n){let r=String(n?.message??n);if(r.includes(`not been initialized`))"
            )
            direct_end = intermediate.find("return!0}", direct_start) + len("return!0}")
            intermediate = (
                intermediate[:direct_start]
                + "catch(n){return H.warning(`bundled_plugins_marketplace_install_failed`,"
                + "{safe:{marketplaceName:t},sensitive:{error:n,"
                + "marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}return!0}"
                + intermediate[direct_end:]
            )
            target.write_text(intermediate)

            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))

            patched = target.read_text()
            self.assertIn("bundled_plugin_direct_install_requested", patched)
            self.assertTrue(patch_asar.has_safe_bundled_plugin_sync_patch(patched))

    def test_apply_bundled_plugin_sync_compat_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "main.js"
            target.write_text(BUNDLED_PLUGIN_SYNC_CONTENT)

            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))
            first = target.read_text()

            self.assertTrue(patch_asar.apply_bundled_plugin_sync_compat_patch(target))
            second = target.read_text()

            self.assertEqual(first, second)

    def test_find_bundled_plugin_list_files_matches_runtime_plugin_list_callers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".vite/build").mkdir(parents=True)
            (root / "webview/assets").mkdir(parents=True)
            (root / ".vite/build/main.js").write_text("function nope(){}")
            client = root / ".vite/build/workspace-root-drop-handler.js"
            renderer = root / "webview/assets/app-server-manager-signals.js"
            client.write_text(PLUGIN_LIST_CLIENT_CONTENT)
            renderer.write_text(PLUGIN_LIST_RENDERER_CONTENT)

            found = patch_asar.find_bundled_plugin_list_files(root)

            self.assertEqual(found, [client, renderer])

    def test_apply_bundled_plugin_list_root_patch_adds_bundled_root_to_plugin_list_params(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(PLUGIN_LIST_CLIENT_CONTENT)

            ok = patch_asar.apply_bundled_plugin_list_root_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.BUNDLED_PLUGIN_LIST_ROOT_MARKER, patched)
            self.assertIn("method:`plugin/list`", patched)
            self.assertIn("plugins/openai-bundled", patched)
            self.assertIn("...(e?.cwds??[])", patched)

    def test_apply_bundled_plugin_list_root_patch_patches_renderer_plugin_list_wrappers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-server-manager-signals.js"
            target.write_text(PLUGIN_LIST_RENDERER_CONTENT)

            ok = patch_asar.apply_bundled_plugin_list_root_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.BUNDLED_PLUGIN_LIST_ROOT_MARKER, patched)
            self.assertIn("function Im(e,t)", patched)
            self.assertIn('"list-plugins":i9', patched)
            self.assertGreaterEqual(patched.count("plugins/openai-bundled"), 2)

    def test_apply_bundled_plugin_list_root_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "workspace-root-drop-handler.js"
            target.write_text(PLUGIN_LIST_CLIENT_CONTENT)

            self.assertTrue(patch_asar.apply_bundled_plugin_list_root_patch(target))
            first = target.read_text()

            self.assertTrue(patch_asar.apply_bundled_plugin_list_root_patch(target))
            second = target.read_text()

            self.assertEqual(first, second)

    def test_list_codesign_targets_orders_nested_code_before_containers(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            sparkle_xpc = (
                app
                / "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
            )
            sparkle_framework = app / "Contents/Frameworks/Sparkle.framework"
            electron_framework = app / "Contents/Frameworks/Electron Framework.framework"
            dylib = (
                electron_framework
                / "Versions/A/Libraries/libffmpeg.dylib"
            )
            main_executable = app / "Contents/MacOS/Codex"
            native_module = app / "Contents/Resources/native/sparkle.node"
            bundled_cli = app / "Contents/Resources/codex"

            for path in (
                sparkle_xpc,
                sparkle_framework,
                electron_framework,
                dylib.parent,
                main_executable.parent,
                native_module.parent,
                bundled_cli.parent,
            ):
                path.mkdir(parents=True, exist_ok=True)
            main_executable.write_text("#!/bin/sh\n")
            native_module.write_bytes(b"node")
            dylib.write_bytes(b"dylib")
            bundled_cli.write_text("#!/bin/sh\n")
            os.chmod(main_executable, 0o755)
            os.chmod(bundled_cli, 0o755)

            targets = patch_asar.list_codesign_targets(app)

            self.assertEqual(targets[-1], app)
            self.assertIn(main_executable, targets)
            self.assertIn(sparkle_xpc, targets)
            self.assertIn(sparkle_framework, targets)
            self.assertIn(electron_framework, targets)
            self.assertIn(dylib, targets)
            self.assertIn(native_module, targets)
            self.assertIn(bundled_cli, targets)
            self.assertLess(targets.index(sparkle_xpc), targets.index(sparkle_framework))
            self.assertLess(targets.index(dylib), targets.index(electron_framework))
            self.assertLess(targets.index(main_executable), targets.index(app))
            self.assertLess(targets.index(electron_framework), targets.index(app))
            self.assertLess(targets.index(native_module), targets.index(app))
            self.assertLess(targets.index(bundled_cli), targets.index(app))

    def test_executable_and_framework_team_ids_must_match_for_dyld(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            main_executable = app / "Contents/MacOS/Codex"
            electron_framework = (
                app
                / "Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
            )
            main_executable.parent.mkdir(parents=True)
            electron_framework.parent.mkdir(parents=True)
            main_executable.write_text("#!/bin/sh\n")
            electron_framework.write_text("framework")

            original = patch_asar.codesign_team_identifier
            try:
                patch_asar.codesign_team_identifier = lambda path: {
                    main_executable: None,
                    electron_framework: "2DC432GLL2",
                }.get(path)
                self.assertFalse(patch_asar.executable_and_framework_team_ids_match(app))

                patch_asar.codesign_team_identifier = lambda path: None
                self.assertTrue(patch_asar.executable_and_framework_team_ids_match(app))
            finally:
                patch_asar.codesign_team_identifier = original

    def test_list_codesign_targets_preserves_bundled_plugin_signatures(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            computer_use_app = (
                app
                / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
            )
            sky_client_app = (
                computer_use_app
                / "Contents/SharedSupport/SkyComputerUseClient.app"
            )
            sky_client_binary = sky_client_app / "Contents/MacOS/SkyComputerUseClient"
            plugin_helper_binary = computer_use_app / "Contents/MacOS/SkyComputerUseService"

            sky_client_binary.parent.mkdir(parents=True, exist_ok=True)
            plugin_helper_binary.parent.mkdir(parents=True, exist_ok=True)
            sky_client_binary.write_text("#!/bin/sh\n")
            plugin_helper_binary.write_text("#!/bin/sh\n")
            os.chmod(sky_client_binary, 0o755)
            os.chmod(plugin_helper_binary, 0o755)

            targets = patch_asar.list_codesign_targets(app)

            self.assertNotIn(computer_use_app, targets)
            self.assertNotIn(sky_client_app, targets)
            self.assertNotIn(sky_client_binary, targets)
            self.assertNotIn(plugin_helper_binary, targets)
            self.assertEqual(targets[-1], app)

    def test_list_codesign_targets_preserves_bundled_cli_when_computer_use_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            bundled_cli = app / "Contents/Resources/codex"
            computer_use_app = (
                app
                / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
            )
            sky_client_app = (
                computer_use_app
                / "Contents/SharedSupport/SkyComputerUseClient.app"
            )
            bundled_cli.parent.mkdir(parents=True)
            sky_client_app.mkdir(parents=True)
            bundled_cli.write_text("#!/bin/sh\n")
            os.chmod(bundled_cli, 0o755)

            targets = patch_asar.list_codesign_targets(app)

            self.assertNotIn(bundled_cli, targets)
            self.assertEqual(targets[-1], app)

    def test_computer_use_plugin_signing_targets_are_deliberate_and_ordered(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            computer_use_app = (
                app
                / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
            )
            sky_client_app = (
                computer_use_app
                / "Contents/SharedSupport/SkyComputerUseClient.app"
            )
            sky_client_app.mkdir(parents=True)

            self.assertEqual(
                patch_asar.computer_use_plugin_signing_targets(app),
                [sky_client_app, computer_use_app],
            )

    def test_computer_use_plugin_repair_not_needed_for_official_openai_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            bundled_cli = app / "Contents/Resources/codex"
            computer_use_app = (
                app
                / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
            )
            sky_client_app = (
                computer_use_app
                / "Contents/SharedSupport/SkyComputerUseClient.app"
            )
            bundled_cli.parent.mkdir(parents=True)
            sky_client_app.mkdir(parents=True)

            teams = {
                bundled_cli: "Y6LQRA2L45",
                sky_client_app: "2DC432GLL2",
                computer_use_app: "2DC432GLL2",
            }
            with patch.object(
                patch_asar,
                "codesign_team_identifier",
                side_effect=lambda path: teams[path],
            ), patch.object(
                patch_asar,
                "codesign_entitlements_text",
                return_value="<string>2DC432GLL2.com.openai.sky.CUAService</string>",
            ), patch.object(
                patch_asar,
                "spctl_accepts",
                return_value=True,
            ):
                self.assertFalse(
                    patch_asar.needs_computer_use_plugin_signature_repair(app)
                )

    def test_computer_use_plugin_repair_needed_for_local_signed_plugin(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = (Path(tmp) / "Codex.app").resolve()
            bundled_cli = app / "Contents/Resources/codex"
            computer_use_app = (
                app
                / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
            )
            sky_client_app = (
                computer_use_app
                / "Contents/SharedSupport/SkyComputerUseClient.app"
            )
            bundled_cli.parent.mkdir(parents=True)
            sky_client_app.mkdir(parents=True)

            teams = {
                bundled_cli: "Y6LQRA2L45",
                sky_client_app: "Y6LQRA2L45",
                computer_use_app: "Y6LQRA2L45",
            }
            entitlement_text = (
                "<key>com.apple.developer.team-identifier</key>"
                "<string>2DC432GLL2</string>"
            )
            with patch.object(
                patch_asar,
                "codesign_team_identifier",
                side_effect=lambda path: teams[path],
            ), patch.object(
                patch_asar,
                "codesign_entitlements_text",
                return_value=entitlement_text,
            ), patch.object(
                patch_asar,
                "spctl_accepts",
                return_value=False,
            ):
                self.assertTrue(
                    patch_asar.needs_computer_use_plugin_signature_repair(app)
                )

    def test_app_signature_repair_needed_when_deep_verify_fails(self):
        failed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="a sealed resource is missing or invalid",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=failed) as run:
            self.assertTrue(
                patch_asar.app_signature_repair_needed(Path("/Applications/Codex.app"))
            )

        args = run.call_args.args[0]
        self.assertEqual(args[:3], ["codesign", "--verify", "--strict"])

    def test_local_desktop_entitlements_strip_openai_only_claims(self):
        entitlement_path = patch_asar.write_local_desktop_app_entitlements()
        text = entitlement_path.read_text()

        self.assertIn("com.apple.security.cs.allow-jit", text)
        self.assertIn("com.apple.security.cs.disable-library-validation", text)
        self.assertNotIn("2DC432GLL2", text)
        self.assertNotIn("com.apple.application-identifier", text)
        self.assertNotIn("keychain-access-groups", text)

    def test_codesign_target_with_entitlements_does_not_preserve_old_entitlements(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="",
        )
        entitlements = Path("/tmp/codex.entitlements.plist")
        with patch.object(patch_asar.subprocess, "run", return_value=completed) as run:
            self.assertTrue(
                patch_asar.codesign_target(
                    Path("/Applications/Codex.app"),
                    "iPhone Developer: bd7349@gmail.com (856E75LLMU)",
                    entitlements=entitlements,
                )
            )

        args = run.call_args.args[0]
        self.assertIn("--entitlements", args)
        self.assertIn(str(entitlements), args)
        self.assertIn("--options", args)
        self.assertIn("runtime", args)
        self.assertIn("--preserve-metadata=identifier,flags", args)
        self.assertNotIn("--preserve-metadata=identifier,entitlements,flags", args)

    def test_restore_asar_from_workdir_restores_payload_and_unpacked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resources = root / "Codex.app/Contents/Resources"
            resources.mkdir(parents=True)
            current_asar = resources / "app.asar"
            current_unpacked = resources / "app.asar.unpacked"
            rollback_asar = root / "rollback.app.asar"
            rollback_unpacked = root / "rollback.app.asar.unpacked"

            current_asar.write_text("patched")
            current_unpacked.mkdir()
            (current_unpacked / "native.node").write_text("patched-native")
            rollback_asar.write_text("original")
            rollback_unpacked.mkdir()
            (rollback_unpacked / "native.node").write_text("original-native")

            old_asar_path = patch_asar.ASAR_PATH
            old_asar_unpacked = patch_asar.ASAR_UNPACKED
            try:
                patch_asar.ASAR_PATH = current_asar
                patch_asar.ASAR_UNPACKED = current_unpacked

                ok = patch_asar.restore_asar_from_workdir(
                    rollback_asar,
                    rollback_unpacked,
                )

                self.assertTrue(ok)
                self.assertEqual(current_asar.read_text(), "original")
                self.assertEqual(
                    (current_unpacked / "native.node").read_text(),
                    "original-native",
                )
            finally:
                patch_asar.ASAR_PATH = old_asar_path
                patch_asar.ASAR_UNPACKED = old_asar_unpacked


if __name__ == "__main__":
    unittest.main()
