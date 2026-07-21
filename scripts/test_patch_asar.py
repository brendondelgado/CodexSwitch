import importlib.util
import inspect
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

CHATGPT_2670751957_FAST_CONTENT = (
    'import{a as o}from"./runtime.js";'
    'import{b as r}from"./models.js";'
    'function XJt(e){let a=e.authMethod===`chatgpt`,u=e.isLoading,c=e.accountInfo,'
    'd=a&&!u&&c!=null&&c?.requirements?.featureRequirements?.fast_mode!==!1;'
    'return{isServiceTierAllowed:d,isLoading:u}}'
    'function QJt(e){return e?.requirements?.featureRequirements?.fast_mode!==!1}'
    'function AD(e,t){let n=t?.trim().toLowerCase();'
    'return e===`priority`||e===`fast`||n===`fast`?`fast`:null}'
    'function TBt(e){return e.name}function EBt(e){return e.description}'
    'var MD={standardDescription:`Default speed`,standardLabel:`Standard`};'
    'function OBt(e){return[{description:MD.standardDescription,iconKind:null,'
    'label:MD.standardLabel,tier:null,value:null},...(e?.serviceTiers??[]).map('
    'e=>({description:EBt(e),iconKind:AD(e.id,e.name),label:TBt(e),tier:e,value:e.id}))]}'
    'function XOa(e){let{isServiceTierAllowed:b}=XJt(e),'
    'v={availableOptions:OBt(e.model)},'
    'K=v.availableOptions.find(e=>e.iconKind===`fast`)?.value,'
    'se=b&&v.availableOptions.length>1;'
    'return{fast:K,serviceTierOptions:se?v.availableOptions:[],'
    'onSelectServiceTier:se?e=>e:void 0}}export{XOa as X};'
)

CHATGPT_2670762119_SPLIT_FAST_CONTENT = (
    'import{a as o}from"./runtime.js";'
    'import{b as r}from"./models.js";'
    'var vz={standardDescription:`Default speed`,standardLabel:`Standard`};'
    'function Cdt(e){return e.name}function wdt(e){return e.description}'
    'function gz(e,t){return e===`priority`||t===`Fast`?`fast`:null}'
    'function Edt(e){return[{description:vz.standardDescription,iconKind:null,'
    'label:vz.standardLabel,tier:null,value:null},...(e?.serviceTiers??[]).map('
    'e=>({description:wdt(e),iconKind:gz(e.id,e.name),label:Cdt(e),tier:e,value:e.id}))]}'
    'function Tdt(e,t){return e?.serviceTiers?.find(e=>e.id===t)??null}'
    'export{Edt as E,Tdt as T};'
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

NATIVE_UPDATER_BOOTSTRAP_CONTENT = (
    "sparkleManager:new aH({enableUpdater:r.a.shouldIncludeUpdater("
    "o,process.platform,process.env),buildFlavor:o,isPackaged:a.app.isPackaged})"
)

NATIVE_UPDATER_MAIN_CONTENT = (
    "m=i.a.shouldIncludeSparkle(o,process.platform,process.env),"
    "h=i.a.shouldIncludeUpdater(o,process.platform,process.env),"
    "g=i.a.allowDevtools(o)"
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

REMOTE_RECENTS_CONTENT = (
    "import{x as x}from\"./vscode-api.js\";"
    "function N(e){return()=>{for(let t of e)t()}}"
    "function P(e){return()=>{}}"
    "function R(e){}"
    "function I(e){return[]}"
    "function z(e){return new Set(JSON.parse(e))}"
    "function X(e){let t=(0,k.c)(23),n=i(o),s=V(),"
    "{enabledRemoteHostIdSet:c}=T(),l;t[0]===c?l=t[1]:(l=B(c),t[0]=c,t[1]=l);"
    "let u=l,d=r(w,`2413345355`),f=a(E),p=d?D:f,m=x(),h;"
    "let g=(0,A.useRef)(h),_,v;"
    "t[3]!==s||t[4]!==u||t[5]!==m||t[6]!==e||t[7]!==n||t[8]!==p?"
    "(_=()=>{let t=()=>{let t=z(u);"
    "m.setQueryData([e,p,u],I({appServerRegistry:s,enabledRemoteHostIds:t,sortKey:p})),"
    "R({scope:n,appServerRegistry:s,sortKey:p,refreshesInFlightHostIds:g.current})};"
    "return t(),P({appServerRegistry:s,onStoreChange:t,subscribeToManager:(t,n)=>{"
    "switch(e){case`recent-conversations`:return t.addAnyConversationCallback(n);"
    "case`recent-conversations-meta`:return t.addAnyConversationMetaCallback(n)}}})},"
    "v=[s,u,m,e,n,p],t[3]=s,t[4]=u,t[5]=m,t[6]=e,t[7]=n,t[8]=p,t[9]=_,t[10]=v):"
    "(_=t[9],v=t[10]),(0,A.useEffect)(_,v);"
    "let O={queryKey:[e,p,u],staleTime:C.INFINITE,queryFn:async()=>[]};return b(O)}"
    "function visible(){return `recent-conversations refresh-recent-conversations-for-host "
    "hasFetchedRecentConversations addAnyConversationCallback`}"
)

CODEX_4753_REMOTE_RECENTS_CONTENT = (
    "function W7(e){return()=>{for(let t of e)t()}}"
    "function G7(e){return()=>{}}"
    "function Rde(e){}"
    "function Aie(e){return[]}"
    "function J7(e){return new Set(JSON.parse(e))}"
    "function Q7(e){let t=(0,$7.c)(23),n=Qt(L),r=Y7(),"
    "{enabledRemoteHostIdSet:i}=c7(),a;t[0]===i?a=t[1]:(a=zde(i),t[0]=i,t[1]=a);"
    "let o=a,s=yt(Ns,`12346831`),c=zt(O7),l=s?$A:c,u=rt(),d;"
    "t[2]===Symbol.for(`react.memo_cache_sentinel`)?(d=new Set,t[2]=d):d=t[2];"
    "let f=(0,e9.useRef)(d),p,m;"
    "t[3]!==r||t[4]!==o||t[5]!==u||t[6]!==e||t[7]!==n||t[8]!==l?"
    "(p=()=>{let t=()=>{let t=J7(o);"
    "u.setQueryData([e,l,o],Aie({appServerRegistry:r,enabledRemoteHostIds:t,sortKey:l})),"
    "Rde({scope:n,appServerRegistry:r,sortKey:l,refreshesInFlightHostIds:f.current})};"
    "return t(),G7({appServerRegistry:r,onStoreChange:t,subscribeToManager:(t,n)=>{"
    "switch(e){case`recent-conversations`:return t.addAnyConversationCallback(n);"
    "case`recent-conversations-meta`:return t.addAnyConversationMetaCallback(n)}}})},"
    "m=[r,o,u,e,n,l],t[3]=r,t[4]=o,t[5]=u,t[6]=e,t[7]=n,t[8]=l,t[9]=p,t[10]=m):"
    "(p=t[9],m=t[10]),(0,e9.useEffect)(p,m);"
    "return b({queryKey:[e,l,o],staleTime:C.INFINITE,queryFn:async()=>[]})}"
    "function visible(){return `recent-conversations refresh-recent-conversations-for-host "
    "hasFetchedRecentConversations addAnyConversationCallback`}"
)

CODEX_5018_REMOTE_RECENTS_SIGNAL_CONTENT = (
    "function qmt(e,t,n,r){}"
    "P5=qn(X,e=>[],{onMount:(e,t)=>{let{key:n}=t,r=[],"
    "i=t.watch(({get:i})=>{let a=i(O5,n),o=i=>{e(i),qmt(t,n,r,i),r=i};"
    "if(o(a?.getRecentConversations().map(({id:e})=>e)??[]),a!=null)"
    "return a.addAnyConversationMetaCallback(e=>{o(e.map(({id:e})=>e))})});"
    "return()=>{i(),qmt(t,n,r,[])}}});"
    "class Host{refreshRecentConversations(e={}){return dH(`refresh-recent-conversations-for-host`,"
    "{hostId:this.hostId,...e})}addAnyConversationCallback(e){return()=>{}}"
    "get hasFetchedRecentConversations(){return true}}"
    "function visible(){return `recent-conversations hasFetchedRecentConversations "
    "addAnyConversationCallback`}"
)

CHATGPT_5440_RECENT_THREADS_CONTENT = (
    "class RequestClient{"
    "async listRecentThreads({limit:e}){return(await this.sendRequest(`thread/list`,"
    "{archived:!1,cursor:null,limit:e,modelProviders:null,sortKey:`updated_at`},"
    "{priority:`background`,source:`thread_list`})).data}"
    "async searchThreads({limit:e,query:t}){return[]}"
    "}"
    "class RecentThreadManager{"
    "async listRecentThreads({cursor:e,limit:t,useStateDbOnly:n=!1,background:r=!1}){"
    "let i={limit:t,cursor:e,sortKey:this.params.requestClient."
    "getCompatibleThreadSortKey(this.recentConversationSortKey),modelProviders:null,"
    "archived:!1,sourceKinds:wb,useStateDbOnly:n},a=await this.params.requestClient."
    "sendRequest(`thread/list`,i,r?{priority:`background`,source:`recent_threads`}:"
    "{source:`recent_threads`});return{...a,data:a.data.filter(e=>e.ephemeral!==!0)}}"
    "async hydrateThreads(e,{includeTurns:t=!1}){return e}"
    "}"
)

CHATGPT_5440_STATSIG_CONTENT = (
    "async function Bootstrap(e){throw Error(`Timed out while fetching post-login "
    "Statsig bootstrap`)}"
    "function AsyncFallback(e){StableIDs.StableID.get(e.statsigClientKey);"
    "return `CodexStatsigProvider.async.identity`}"
    "function ReadyProvider({appVersion:e,authMethod:t,client:n,deviceId:r,"
    "hostBuildFlavor:i,children:a}){return a}"
    "function PostLogin(e){let{appSessionId:n,appVersion:r,auth:i,browserLocale:a,"
    "hostBuildFlavor:o,stableId:s,statsigClientKey:c,systemName:l,systemVersion:u,"
    "children:d}=e,f={mutationFn:async e=>{let t=await Bootstrap(e);try{let e=new "
    "StatsigSDK.StatsigClient(c,t.user,networkConfig);return e.initializeSync(),e}"
    "catch(e){throw e}},retry:retryBootstrap,onError:reportBootstrapError};"
    "let{data:p,error:m,mutate:h,status:g}=useMutation(f);"
    "if(g===`error`){let e=diagnostic,s;return s=(0,jsxRuntime.jsxs)(AsyncFallback,"
    "{appSessionId:n,appVersion:r,auth:i,browserLocale:a,hostBuildFlavor:o,"
    "statsigClientKey:c,systemName:l,systemVersion:u,children:[e,d]})}"
    "if(p==null)return loading;return (0,jsxRuntime.jsx)(ReadyProvider,"
    "{appVersion:r,authMethod:i.authMethod,client:p,deviceId:s,hostBuildFlavor:o,"
    "children:d})}"
    "function visible(){return `Statsig: error while bootstrapping post-login client "
    "CodexStatsigProvider.async`}"
)

CODEX_5042_MODEL_PICKER_CONTENT = (
    "function DM(e){if(!e.trimStart().toLowerCase().startsWith(`gpt`))return e;"
    "return e}"
    "function A8n(e){return e?.flatMap(({displayName:e,model:t,"
    "supportedReasoningEfforts:n})=>{let r=e==null?`Custom`:"
    "DM(e).replace(/^GPT-/iu,``),i=n.flatMap(({reasoningEffort:e})=>[e]);"
    "return i.map(e=>({id:`${t}:${e}`,model:t,modelLabel:r,"
    "reasoningEffort:e}))})??[]}"
    "var N8n=[{id:`gpt-5.6-sol:medium`,model:`gpt-5.6-sol`,"
    "modelLabel:`5.6 Sol`,reasoningEffort:`medium`}];"
)

CODEX_5059_MODEL_AVAILABILITY_CONTENT = (
    "function Jv({authMethod:e,availableModels:t,defaultModel:n,"
    "enabledReasoningEfforts:r,includeUltraReasoningEffort:i,models:a,"
    "useHiddenModels:o}){let s=[],c=null,l=o&&e!==`amazonBedrock`;"
    "return a.forEach(n=>{if(l?t.has(n.model):!n.hidden){let a={...n};"
    "s.push(a),n.isDefault&&(c=a)}}),{models:s,defaultModel:c}}"
)

CODEX_5059_MAX_EFFORT_CONTENT = (
    "function Jv({authMethod:e,availableModels:t,defaultModel:n,"
    "enabledReasoningEfforts:r,includeUltraReasoningEffort:i,models:a,"
    "useHiddenModels:o}){let s=[],c=null,l=o&&e!==`amazonBedrock`,"
    "u=a.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`max`)),"
    "d=i&&a.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`ultra`));"
    "return a.forEach(n=>{if(l?t.has(n.model):!n.hidden){let t=i?"
    "n.supportedReasoningEfforts:n.supportedReasoningEfforts.filter("
    "({reasoningEffort:e})=>e!==`ultra`),a=t.filter(({reasoningEffort:e})=>"
    "vg(e)&&r.has(e)),o={...n,supportedReasoningEfforts:a};s.push(o)}}),"
    "{models:s,defaultModel:c,hasModelSupportingMaxReasoningEffort:u,"
    "hasModelSupportingUltraReasoningEffort:d}}"
    "function PRe(e,t){return e.flatMap((e,n)=>t?.some(t=>t.model===e.model&&"
    "t.supportedReasoningEfforts.some(({reasoningEffort:t})=>"
    "t===e.reasoningEffort))?[{...e,powerSettingIndex:n}]:[])}"
    "var FRe=[{id:`gpt-5.6-sol:xhigh`,model:`gpt-5.6-sol`,"
    "modelLabel:`5.6 Sol`,reasoningEffort:`xhigh`},"
    "{id:`gpt-5.6-sol:ultra`,model:`gpt-5.6-sol`,"
    "modelLabel:`5.6 Sol`,reasoningEffort:`ultra`}];"
)

CODEX_5211_MODEL_FILTER_CONTENT = (
    "function Ki(e){return e===`medium`||e===`xhigh`||e===`max`||e===`ultra`}"
    "function Zi({authMethod:e,availableModels:t,defaultModel:n,"
    "enabledReasoningEfforts:r,includeUltraReasoningEffort:i,models:a,"
    "useHiddenModels:o}){let s=[],c=null,l=o&&e!==`amazonBedrock`,"
    "u=a.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`max`));"
    "return a.forEach(n=>{if(l?t.has(n.model):!n.hidden){let t="
    "n.supportedReasoningEfforts.filter(({reasoningEffort:e})=>Ki(e)&&r.has(e)),"
    "o={...n,supportedReasoningEfforts:t};s.push(o)}}),"
    "{models:s,defaultModel:c,hasModelSupportingMaxReasoningEffort:u}}"
)

CODEX_5211_POWER_PRESET_CONTENT = (
    'import{a as o}from"./models.js";'
    "var Is=[{id:`gpt-5.6-sol:xhigh`,model:`gpt-5.6-sol`,"
    "modelLabel:`5.6 Sol`,reasoningEffort:`xhigh`}],"
    "Ls={id:`gpt-5.6-sol:ultra`,model:`gpt-5.6-sol`,"
    "modelLabel:`5.6 Sol`,reasoningEffort:`ultra`};"
)

CODEX_5059_SELECTED_MODEL_LABEL_CONTENT = (
    "function zE(e){return e}"
    "function o6(e){let t=cache(),{model:n,displayName:r,labelClassName:i,"
    "serviceTierIconKind:a,stripGptPrefix:o}=e,s=a===void 0?null:a,"
    "c=o===void 0?!1:o,l;if(r!=null){let e;if(t[0]!==r||t[1]!==c){"
    "let n=zE(r);e=c?n.replace(/^GPT-/iu,``):n,t[0]=r,t[1]=c,t[2]=e}"
    "else e=t[2];l=e}else if(n){let e;t[3]===Symbol.for(`react.memo_cache_sentinel`)"
    "?(e=jsx(q,{id:`composer.mode.local.model.custom`,defaultMessage:`Custom`,"
    "description:`Custom model from config`}),t[3]=e):e=t[3],l=e}else l=n;"
    "return l}"
)

CODEX_5059_REMOTE_MODEL_RECONNECT_CONTENT = (
    "function xhe(){let e=scope(),t=queryClient(),n=registry(),r=false,i=null,"
    "a=null,o=null,s={current:new Map},c={current:new Set};"
    "async function d(r){let a=s.current.get(r);if(a!=null&&await a,!c.current.has(r)){"
    "c.current.add(r);try{await Promise.all(["
    "t.invalidateQueries({queryKey:[`user-saved-config`]}),"
    "t.invalidateQueries({queryKey:ES(r)}),"
    "t.invalidateQueries({queryKey:bC(r)})]);"
    "let a=n.getForHostIdOrThrow(r);log(`app_server_restart_recovery_done`,a)}"
    "finally{c.current.delete(r)}}}"
    "return jt(`codex-app-server-initialized`,e=>{r||d(e.hostId)},"
    "[r,i,a,o?.roots,n,t,e]),null}"
    "function listModels(e){return call(`list-models-for-host`,e)}"
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

WEAKMAP_USE_AUTH_CONTENT = (
    'import{s as e}from"./chunk-Cq_f4orQ.js";'
    'import{n as t}from"./jsx-runtime-DXKlqYIQ.js";'
    'import{R as n}from"./app-scope-DbsKKT7R.js";'
    'import{ds as r}from"./app-server-manager-signals-DoSKsUgQ.js";'
    'import{i}from"./app-server-manager-hooks-D3kQaoB-.js";'
    'import{n as a}from"./use-is-copilot-api-available-BvFkK8hA.js";'
    'import{t as o}from"./use-global-state-BKadSfwQ.js";'
    "var s=e(t(),1),c=(0,s.createContext)(void 0),l=(0,s.createContext)(null),"
    "u=n(),d=2e3,f=new WeakMap;"
    "function p(e,t){let n=(0,u.c)(14),"
    "{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i,"
    "shouldUseWindowsStartupAuthTimeout:a,onLogout:o}=t,"
    "[c,l]=(0,s.useState)(e!=null),[f,p]=(0,s.useState)(null),v,b;"
    "let x,S;x=()=>{if(e==null)return;let t=!1,n=!1,s=null,"
    "c=()=>{g(e).then(e=>{n=!0,s!=null&&clearTimeout(s),"
    "!t&&(l(!1),p(y(e,{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i})))})"
    ".catch(()=>{n=!0,s!=null&&clearTimeout(s),t||(l(!1),p(h))})};"
    "a&&(s=setTimeout(()=>{t||n||(l(!1),p(m))},d)),c();"
    "let u=e=>{p(t=>e.authMethod==null&&t?.authMethod!=null?(o?.(),_()):"
    "t==null?e.authMethod==null?t:{..._(),authMethod:e.authMethod}:"
    "{...t,authMethod:e.authMethod??null}),c()};"
    "return e.addAuthStatusCallback(u),()=>{t=!0,s!=null&&clearTimeout(s),"
    "e.removeAuthStatusCallback(u)}},S=[e,r,o,a,i],(0,s.useEffect)(x,S);"
    "return{isLoading:c,authState:f}}"
    "function g(e){let t=f.get(e);if(t!=null)return t;"
    "let n=e.getAccount().finally(()=>{f.delete(e)});return f.set(e,n),n}"
    "function _(){return{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null}}"
    "function y(e,t){return{authMethod:e.account?.type}}"
    "function h(e){return e??_()}"
    "function m(e){return e??_()}"
    "export{l as a,p as i,c as o};"
)

CODEX_4753_WEAKMAP_AUTH_CONTENT = (
    "function query(){let t=n();t.invalidateQueries({queryKey:r(`account-info`)})}"
    "var hd,gd=e((()=>{sd(),hd=new WeakMap}));"
    "function f9(e,t){let n=(0,m9.c)(14),"
    "{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i,"
    "shouldUseWindowsStartupAuthTimeout:a,onLogout:o}=t,"
    "[s,c]=(0,h9.useState)(e!=null),[l,u]=(0,h9.useState)(null),d,f;"
    "p=()=>{if(e==null)return;let t=!1,n=!1,s=null,"
    "l=()=>{Zde(e).then(e=>{n=!0,u($de(e,{isCopilotApiAvailable:r,"
    "useCopilotAuthIfAvailable:i}))}).catch(()=>{n=!0,u(Xde)})};"
    "l();let d=e=>{u(t=>e.authMethod==null&&t?.authMethod!=null?"
    "(o?.(),p9()):t==null?e.authMethod==null?t:{...p9(),authMethod:e.authMethod}:"
    "{...t,authMethod:e.authMethod??null}),l()};"
    "return e.addAuthStatusCallback(d),()=>{t=!0,s!=null&&clearTimeout(s),"
    "e.removeAuthStatusCallback(d)}}}"
    "function Zde(e){let t=_9.get(e);if(t!=null)return t;"
    "let n=e.getAccount().finally(()=>{_9.delete(e)});return _9.set(e,n),n}"
    "function p9(){return{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null}}"
    "function $de(e,t){return{authMethod:e.account?.type}}"
    "function Xde(e){return e??p9()}"
    "var m9,h9,g9,_9,v9=e((()=>{m9=Fe(),h9=n(S(),1),g9=2e3,_9=new WeakMap}));"
    "export{f9 as i};"
)


class PatchAsarTests(unittest.TestCase):
    def test_resolve_asar_cmd_accepts_explicit_cached_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            asar_js = Path(tmp) / "asar.js"
            asar_js.write_text("// fixture")
            with patch.dict(
                os.environ,
                {"CODEXSWITCH_ASAR_JS": str(asar_js)},
            ), patch.object(
                patch_asar,
                "resolve_node_path",
                return_value="/usr/local/bin/node",
            ):
                self.assertEqual(
                    patch_asar.resolve_asar_cmd(),
                    ["/usr/local/bin/node", str(asar_js)],
                )

    def test_resolve_asar_cmd_prefers_owned_modern_esm_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool_root = Path(tmp)
            asar_cli = tool_root / "node_modules/@electron/asar/bin/asar.mjs"
            asar_cli.parent.mkdir(parents=True)
            asar_cli.write_text("// fixture")
            with patch.dict(
                os.environ,
                {"CODEXSWITCH_ASAR_JS": ""},
            ), patch.object(
                patch_asar,
                "ASAR_TOOL_ROOT",
                tool_root,
            ), patch.object(
                patch_asar,
                "resolve_node_path",
                return_value="/usr/local/bin/node",
            ):
                self.assertEqual(
                    patch_asar.resolve_asar_cmd(),
                    ["/usr/local/bin/node", str(asar_cli)],
                )

    def test_resolve_asar_cmd_prefers_bundled_tool_over_owned_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundled_root = root / "bundled"
            owned_root = root / "owned"
            bundled_cli = bundled_root / "node_modules/@electron/asar/bin/asar.mjs"
            owned_cli = owned_root / "node_modules/@electron/asar/bin/asar.mjs"
            for cli in (bundled_cli, owned_cli):
                cli.parent.mkdir(parents=True)
                cli.write_text("// fixture")
            with patch.dict(
                os.environ,
                {"CODEXSWITCH_ASAR_JS": ""},
            ), patch.object(
                patch_asar,
                "BUNDLED_ASAR_TOOL_ROOT",
                bundled_root,
            ), patch.object(
                patch_asar,
                "ASAR_TOOL_ROOT",
                owned_root,
            ), patch.object(
                patch_asar,
                "resolve_node_path",
                return_value="/usr/local/bin/node",
            ):
                self.assertEqual(
                    patch_asar.resolve_asar_cmd(),
                    ["/usr/local/bin/node", str(bundled_cli)],
                )

    def test_node_candidates_prefer_target_app_runtime_then_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp)
            bundled_node = resources / "cua_node/bin/node"
            bundled_node.parent.mkdir(parents=True)
            bundled_node.write_text("#!/bin/sh\n")
            bundled_node.chmod(0o755)
            with patch.object(
                patch_asar,
                "APP_RESOURCES",
                resources,
            ), patch.object(
                patch_asar.shutil,
                "which",
                return_value="/usr/local/bin/node",
            ):
                self.assertEqual(
                    patch_asar.node_candidates(),
                    [str(bundled_node), "/usr/local/bin/node"],
                )

            bundled_node.chmod(0o644)
            with patch.object(
                patch_asar,
                "APP_RESOURCES",
                resources,
            ), patch.object(
                patch_asar.shutil,
                "which",
                return_value="/usr/local/bin/node",
            ):
                self.assertEqual(patch_asar.node_candidates(), ["/usr/local/bin/node"])

    def test_modern_asar_uses_compatible_path_node_when_bundled_node_is_old(self):
        modern_cli = Path("/tool/node_modules/@electron/asar/bin/asar.mjs")
        versions = {
            "/app/cua_node/bin/node": (20, 18, 0),
            "/opt/homebrew/bin/node": (22, 12, 0),
        }
        with patch.object(
            patch_asar,
            "asar_cli_candidates",
            return_value=[modern_cli],
        ), patch.object(
            patch_asar,
            "node_candidates",
            return_value=list(versions),
        ), patch.object(
            patch_asar,
            "node_version",
            side_effect=versions.get,
        ), patch.dict(
            os.environ,
            {"CODEXSWITCH_ASAR_JS": ""},
        ):
            self.assertEqual(
                patch_asar.resolve_asar_cmd(),
                ["/opt/homebrew/bin/node", str(modern_cli)],
            )

    def test_node_version_requires_successful_semantic_version_output(self):
        cases = (
            (0, "v22.12.0\n", (22, 12, 0)),
            (0, "not-a-version\n", None),
            (1, "v24.0.0\n", None),
        )
        for returncode, stdout, expected in cases:
            with self.subTest(returncode=returncode, stdout=stdout), patch.object(
                patch_asar.subprocess,
                "run",
                return_value=patch_asar.subprocess.CompletedProcess(
                    ["node", "--version"],
                    returncode,
                    stdout,
                    "",
                ),
            ):
                self.assertEqual(patch_asar.node_version("node"), expected)

    def test_resolve_asar_cmd_never_falls_back_to_npx(self):
        with patch.object(
            patch_asar,
            "asar_cli_candidates",
            return_value=[],
        ), patch.dict(
            os.environ,
            {"CODEXSWITCH_ASAR_JS": ""},
        ):
            self.assertEqual(patch_asar.resolve_asar_cmd(), [])

    def test_run_asar_does_not_spawn_without_compatible_offline_tool(self):
        with patch.object(
            patch_asar,
            "ASAR_CMD",
            [],
        ), patch.object(
            patch_asar.subprocess,
            "run",
        ) as run:
            self.assertIsNone(patch_asar.run_asar("list", "app.asar", timeout=30))
            run.assert_not_called()

    def test_asar_module_path_supports_commonjs_and_esm_cli_layouts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for package_name, cli_name in (("asar", "asar.js"), ("@electron/asar", "asar.mjs")):
                with self.subTest(package_name=package_name):
                    package = root / package_name.replace("/", "-")
                    cli = package / "bin" / cli_name
                    module = package / "lib" / "asar.js"
                    cli.parent.mkdir(parents=True)
                    module.parent.mkdir(parents=True)
                    cli.write_text("// cli")
                    module.write_text("// module")

                    self.assertEqual(
                        patch_asar.asar_module_path_for_cli(cli),
                        module,
                    )

    def test_compute_asar_header_hash_imports_commonjs_and_esm_modules(self):
        node = patch_asar.shutil.which("node")
        if node is None:
            self.skipTest("node is required for the ASAR integrity fixture")

        expected = patch_asar.hashlib.sha256(b"fixture-header").hexdigest()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "app.asar"
            archive.write_bytes(b"fixture archive")
            fixtures = {
                "commonjs": "module.exports={getRawHeader(){return {headerString:`fixture-header`}}};",
                "esm": "export function getRawHeader(){return {headerString:`fixture-header`}}",
            }
            for module_kind, source in fixtures.items():
                with self.subTest(module_kind=module_kind):
                    package = root / module_kind
                    module = package / "lib" / "asar.js"
                    module.parent.mkdir(parents=True)
                    module.write_text(source)
                    if module_kind == "esm":
                        (package / "package.json").write_text('{"type":"module"}')

                    with patch.object(
                        patch_asar,
                        "resolve_asar_module_path",
                        return_value=module,
                    ), patch.object(
                        patch_asar,
                        "ASAR_CMD",
                        [node, str(package / "bin" / "asar.mjs")],
                    ):
                        self.assertEqual(
                            patch_asar.compute_electron_asar_header_hash(archive),
                            expected,
                        )

    def test_resolve_default_app_path_prefers_unified_chatgpt_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            legacy = root / "Codex.app"
            unified = root / "ChatGPT.app"
            legacy.mkdir()
            unified.mkdir()

            resolved = patch_asar.resolve_default_app_path([unified, legacy])

            self.assertEqual(resolved, unified)

    def test_cli_has_sighup_patch_requires_complete_runtime_contract(self):
        required_markers = (
            b"sighup-verified-tui",
            b"SIGHUP: auth reloaded",
            b"hotswap-ack",
            b"CodexSwitch rotated accounts after a usage limit",
            b"CodexSwitch rotated accounts after an auth failure",
            b"Auth changed, opening new WebSocket with fresh credentials",
            b"codexswitch-runtime-convergence-v3",
            b"codexswitch-runtime-rotation-handoff-v1",
            b"CodexSwitch account/updated frontend write acknowledged after auth reload",
            b"codexswitch-hotswap-contract-v3",
            b"codexswitch-hotswap-headless-idle-v1",
            b"codexswitch-hotswap-cli-contract-v3",
            b"Usage: /goal <objective>",
        )
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp) / "codex"
            complete_contract = b"\0".join(required_markers)
            cli.write_bytes(complete_contract)
            self.assertTrue(patch_asar.cli_has_sighup_patch(cli))

            for missing_marker in required_markers:
                with self.subTest(missing_marker=missing_marker):
                    cli.write_bytes(
                        b"\0".join(
                            marker for marker in required_markers if marker != missing_marker
                        )
                    )
                    self.assertFalse(patch_asar.cli_has_sighup_patch(cli))

            cli.write_bytes(
                complete_contract.replace(
                    b"CodexSwitch account/updated frontend write acknowledged after auth reload",
                    b"CodexSwitch account/updated broadcast after auth reload",
                )
            )
            self.assertFalse(patch_asar.cli_has_sighup_patch(cli))

            cli.write_bytes(
                complete_contract.replace(
                    b"Usage: /goal <objective>",
                    b"Pursuing goal\0thread/goal/set",
                )
            )
            self.assertTrue(patch_asar.cli_has_sighup_patch(cli))

    def test_cli_marker_scan_is_streaming_boundary_safe_and_reused(self):
        markers = (
            patch_asar.SIGHUP_CLI_MARKERS[0],
            patch_asar.SIGHUP_RELOAD_MARKER,
            *patch_asar.SIGHUP_REQUIRED_MARKERS,
            patch_asar.GOAL_USAGE_MARKER,
            patch_asar.GPT55_MODEL_MARKER,
        )
        chunk_size = 1024 * 1024
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp) / "codex"
            with cli.open("wb") as handle:
                handle.truncate((len(markers) + 2) * chunk_size)
                for index, marker in enumerate(markers, start=1):
                    handle.seek(index * chunk_size - max(1, len(marker) // 2))
                    handle.write(marker)

            patch_asar._CLI_MARKER_SCAN_CACHE.clear()
            original_open = Path.open
            open_count = 0

            def counting_open(path, *args, **kwargs):
                nonlocal open_count
                if path == cli:
                    open_count += 1
                return original_open(path, *args, **kwargs)

            with patch.object(Path, "open", counting_open), patch.object(
                Path,
                "read_bytes",
                side_effect=AssertionError("whole-file reads are forbidden"),
            ):
                scan = patch_asar.scan_cli_markers(cli, chunk_size=chunk_size)
                self.assertIsNotNone(scan)
                self.assertTrue(scan.has_sighup_contract)
                self.assertTrue(scan.supports_gpt55)
                self.assertTrue(patch_asar.cli_has_sighup_patch(cli))
                self.assertTrue(patch_asar.cli_supports_gpt55(cli))

            self.assertEqual(open_count, 1)

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
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5\0"
                    + b"\0".join(patch_asar.SIGHUP_REQUIRED_MARKERS)
                    + b"\0Usage: /goal <objective>"
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
                    b"SIGHUP: auth reloaded from disk\0"
                    + b"\0".join(patch_asar.SIGHUP_REQUIRED_MARKERS)
                    + b"\0Usage: /goal <objective>"
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
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5\0"
                    + b"\0".join(patch_asar.SIGHUP_REQUIRED_MARKERS)
                    + b"\0Usage: /goal <objective>"
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
                    b"SIGHUP: auth reloaded from disk\0gpt-5.5\0"
                    + b"\0".join(patch_asar.SIGHUP_REQUIRED_MARKERS)
                    + b"\0Usage: /goal <objective>"
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

    def test_find_auth_file_prefers_patchable_auth_hook_over_lifecycle_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            lifecycle = assets / "zzz-lifecycle-HASH.js"
            lifecycle.write_text(
                'import{S as i}from"./vscode-api-HASH.js";'
                "class Host{addAuthStatusCallback(e){this.authStatusCallbacks.add(e)}"
                "async getAccount(){return this.sendRequest(`account/read`)}"
                "notifyAuthStatusCallbacks(e){for(let t of this.authStatusCallbacks)t({authMethod:e})}}"
                "function refresh(){let t=i();t.invalidateQueries({queryKey:[`accounts`,`check`]})}"
            )
            expected = assets / "aaa-auth-hook-HASH.js"
            expected.write_text(CODEX_4753_WEAKMAP_AUTH_CONTENT)

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
            self.assertIn(patch_asar.AUTH_CACHE_PATCH_MARKER, patched)
            self.assertIn("A as _csUseQueryClient", patched)
            self.assertIn("r as _csQueryKey", patched)
            self.assertIn("_qcRef=_csUseQueryClient();let n=(0,u.c)(14),", patched)
            self.assertIn(
                "}),_invalidateAccountQueries(),e.authMethod==null?(",
                patched,
            )
            self.assertIn(patch_asar.AUTH_TRANSITION_PATCH_MARKER, patched)
            self.assertIn(
                "p(t=>_codexSwitchResolveAuthState(t,y(e,{isCopilotApiAvailable:r,"
                "useCopilotAuthIfAvailable:i}),o,_csReadEpoch===_csAuthEpoch,"
                "_csConfirmLogout))",
                patched,
            )
            self.assertIn("_csLogoutTimer=setTimeout", patched)
            self.assertIn("c(_csEventEpoch,!0)", patched)
            self.assertIn(
                "e.authMethod==null&&t?.authMethod!=null?t:",
                patched,
            )
            self.assertNotIn(
                "e.authMethod==null&&t?.authMethod!=null?(o?.(),_()):",
                patched,
            )
            self.assertIn("export{p as u};", patched)

    def test_apply_patch_supports_weakmap_use_auth_bundle_without_vscode_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "use-auth-HASH.js"
            target.write_text(WEAKMAP_USE_AUTH_CONTENT)

            ok = patch_asar.apply_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.PATCH_MARKER, patched)
            self.assertIn(patch_asar.AUTH_CACHE_PATCH_MARKER, patched)
            self.assertIn(
                'var _csAuthInvalidationPending=!1;function _invalidateAccountQueries(){'
                '"CODEXSWITCH_AUTH_CACHE_INVALIDATION_V3";'
                'if(_csAuthInvalidationPending)return;',
                patched,
            )
            self.assertIn('try{typeof f!="undefined"&&(f=new WeakMap)}catch{}}', patched)
            self.assertEqual(patched.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertIn(
                "p(t=>_codexSwitchResolveAuthState(t,y(e,{isCopilotApiAvailable:r,"
                "useCopilotAuthIfAvailable:i}),o,_csReadEpoch===_csAuthEpoch,"
                "_csConfirmLogout))",
                patched,
            )
            self.assertIn("e.authMethod==null&&t?.authMethod!=null?t:", patched)
            self.assertIn("f=new WeakMap;", patched)
            self.assertIn(
                "}),_invalidateAccountQueries(),e.authMethod==null?(",
                patched,
            )
            self.assertIn("export{l as a,p as i,c as o};", patched)

    def test_apply_patch_supports_codex_4753_weakmap_bundle_with_unrelated_query_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_4753_WEAKMAP_AUTH_CONTENT)

            ok = patch_asar.apply_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertEqual(patched.count(patch_asar.AUTH_CACHE_PATCH_MARKER), 1)
            self.assertIn(
                'var _csAuthInvalidationPending=!1;function _invalidateAccountQueries(){'
                '"CODEXSWITCH_AUTH_CACHE_INVALIDATION_V3";'
                'if(_csAuthInvalidationPending)return;',
                patched,
            )
            self.assertIn('try{typeof _9!="undefined"&&(_9=new WeakMap)}catch{}}', patched)
            self.assertEqual(patched.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertIn(
                "u(t=>_codexSwitchResolveAuthState(t,$de(e,{isCopilotApiAvailable:r,"
                "useCopilotAuthIfAvailable:i}),o,_csReadEpoch===_csAuthEpoch,"
                "_csConfirmLogout))",
                patched,
            )
            self.assertIn("e.authMethod==null&&t?.authMethod!=null?t:", patched)
            self.assertLess(
                patched.index("function _invalidateAccountQueries"),
                patched.index("var m9,h9,g9,_9,v9="),
            )
            self.assertIn("_9=new WeakMap}));", patched)
            self.assertIn("hd=new WeakMap", patched)
            self.assertNotIn("hd=new WeakMap;function _invalidateAccountQueries", patched)
            self.assertIn(
                "}),_invalidateAccountQueries(),e.authMethod==null?(",
                patched,
            )
            self.assertIn("export{f9 as i};", patched)

    def test_apply_patch_repairs_nested_weakmap_v1_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            broken = CODEX_4753_WEAKMAP_AUTH_CONTENT.replace(
                "_9=new WeakMap}));",
                "_9=new WeakMap;function _invalidateAccountQueries(){_9=new WeakMap}}));",
                1,
            ).replace(
                "}),l()};return e.addAuthStatusCallback",
                "}),_invalidateAccountQueries(),l()};return e.addAuthStatusCallback",
                1,
            )
            target.write_text(broken)

            self.assertTrue(patch_asar.apply_patch(target))

            repaired = target.read_text()
            self.assertNotIn(
                "_9=new WeakMap;function _invalidateAccountQueries(){_9=new WeakMap}",
                repaired,
            )
            self.assertEqual(repaired.count(patch_asar.AUTH_CACHE_PATCH_MARKER), 1)
            self.assertEqual(repaired.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertEqual(repaired.count("function _invalidateAccountQueries"), 1)
            self.assertEqual(
                repaired.count("_invalidateAccountQueries(),e.authMethod==null?"),
                1,
            )
            self.assertLess(
                repaired.index("function _invalidateAccountQueries"),
                repaired.index("var m9,h9,g9,_9,v9="),
            )

            self.assertTrue(patch_asar.apply_patch(target))
            self.assertEqual(target.read_text(), repaired)

    def test_apply_patch_upgrades_module_scope_query_client_v1(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "use-auth-HASH.js"
            target.write_text(
                "var _qcRef=null;"
                "function _invalidateAccountQueries(){if(_qcRef){"
                "_qcRef.invalidateQueries({queryKey:[`accounts`,`check`]});"
                "_qcRef.invalidateQueries({queryKey:_csQueryKey(`account-info`)})}}"
                + WEAKMAP_USE_AUTH_CONTENT.replace(
                    "}),c()};return e.addAuthStatusCallback",
                    "}),_invalidateAccountQueries(),c()};return e.addAuthStatusCallback",
                    1,
                )
            )

            self.assertTrue(patch_asar.apply_patch(target))

            upgraded = target.read_text()
            self.assertEqual(upgraded.count(patch_asar.AUTH_CACHE_PATCH_MARKER), 1)
            self.assertEqual(upgraded.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertIn("Promise.allSettled", upgraded)
            self.assertIn("_codexSwitchResolveAuthState", upgraded)
            self.assertNotIn(
                "function _invalidateAccountQueries(){if(_qcRef)",
                upgraded,
            )

            self.assertTrue(patch_asar.apply_patch(target))
            self.assertEqual(target.read_text(), upgraded)

    def test_apply_patch_upgrades_v2_auth_transition_without_layering_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "use-auth-HASH.js"
            last_import = 'import{t as o}from"./use-global-state-BKadSfwQ.js";'
            legacy_helper = (
                'function _invalidateAccountQueries(){'
                '"CODEXSWITCH_AUTH_CACHE_INVALIDATION_V2";'
                'try{typeof f!="undefined"&&(f=new WeakMap)}catch{}}'
            )
            legacy = WEAKMAP_USE_AUTH_CONTENT.replace(
                last_import,
                last_import + legacy_helper,
                1,
            ).replace(
                "}),c()};return e.addAuthStatusCallback",
                "}),_invalidateAccountQueries(),c()};return e.addAuthStatusCallback",
                1,
            )
            target.write_text(legacy)

            self.assertTrue(patch_asar.apply_patch(target))

            upgraded = target.read_text()
            self.assertNotIn(patch_asar.LEGACY_AUTH_CACHE_PATCH_MARKER, upgraded)
            self.assertEqual(upgraded.count(patch_asar.AUTH_CACHE_PATCH_MARKER), 1)
            self.assertEqual(upgraded.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertEqual(upgraded.count("function _invalidateAccountQueries"), 1)
            self.assertEqual(upgraded.count("function _codexSwitchResolveAuthState"), 1)
            self.assertIn("e.authMethod==null&&t?.authMethod!=null?t:", upgraded)
            self.assertNotIn(
                "e.authMethod==null&&t?.authMethod!=null?(o?.(),_()):",
                upgraded,
            )

            self.assertTrue(patch_asar.apply_patch(target))
            self.assertEqual(target.read_text(), upgraded)

    def test_apply_patch_upgrades_v1_transition_to_latest_generation_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            legacy = (
                'function _invalidateAccountQueries(){'
                '"CODEXSWITCH_AUTH_CACHE_INVALIDATION_V3";'
                'try{typeof _9!="undefined"&&(_9=new WeakMap)}catch{}}'
                + patch_asar.legacy_auth_transition_module_patch()
                + CODEX_4753_WEAKMAP_AUTH_CONTENT
            ).replace(
                "u($de(e,{isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i}))",
                "u(t=>_codexSwitchResolveAuthState(t,$de(e,{"
                "isCopilotApiAvailable:r,useCopilotAuthIfAvailable:i}),o))",
                1,
            ).replace(
                "e.authMethod==null&&t?.authMethod!=null?(o?.(),p9()):",
                "e.authMethod==null&&t?.authMethod!=null?t:",
                1,
            ).replace(
                "}),l()};return e.addAuthStatusCallback",
                "}),_invalidateAccountQueries(),l()};return e.addAuthStatusCallback",
                1,
            )
            target.write_text(legacy)

            self.assertTrue(patch_asar.apply_patch(target))

            upgraded = target.read_text()
            self.assertNotIn(
                patch_asar.LEGACY_AUTH_TRANSITION_PATCH_MARKER,
                upgraded,
            )
            self.assertEqual(upgraded.count(patch_asar.AUTH_TRANSITION_PATCH_MARKER), 1)
            self.assertEqual(upgraded.count("function _codexSwitchResolveAuthState"), 1)
            self.assertIn("_csReadEpoch===_csAuthEpoch", upgraded)
            self.assertIn("_csLogoutTimer=setTimeout", upgraded)
            self.assertIn("l(_csEventEpoch,!0)", upgraded)

            self.assertTrue(patch_asar.apply_patch(target))
            self.assertEqual(target.read_text(), upgraded)

    def test_auth_transition_helper_ignores_stale_null_reads(self):
        node = patch_asar.shutil.which("node")
        if node is None:
            self.skipTest("node is required for the renderer transition fixture")

        script = patch_asar.auth_transition_module_patch() + """
let state={authMethod:`chatgpt`,email:`old@example.com`};
let logoutCount=0;
const loggedOut=()=>{logoutCount++};
const empty={authMethod:null,email:null};
const replacement={authMethod:`chatgpt`,email:`new@example.com`};
state=_codexSwitchResolveAuthState(state,replacement,loggedOut,true,false);
state=_codexSwitchResolveAuthState(state,empty,loggedOut,false,true);
if(state.email!==`new@example.com`||logoutCount!==0)process.exit(1);
state=_codexSwitchResolveAuthState(state,empty,loggedOut,true,false);
if(state.email!==`new@example.com`||logoutCount!==0)process.exit(2);
state=_codexSwitchResolveAuthState(state,empty,loggedOut,true,true);
if(state.authMethod!==null||logoutCount!==1)process.exit(3);
state=_codexSwitchResolveAuthState(state,replacement,loggedOut,false,false);
if(state.authMethod!==null||logoutCount!==1)process.exit(4);
"""
        completed = patch_asar.subprocess.run(
            [node, "--eval", script],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_auth_invalidator_coalesces_subscriber_fanout(self):
        node = patch_asar.shutil.which("node")
        if node is None:
            self.skipTest("node is required for the renderer invalidation fixture")

        script = (
            "let timers=[];globalThis.setTimeout=e=>{timers.push(e);return timers.length};"
            "let cache=new WeakMap;"
            + patch_asar.auth_invalidation_guard_patch()
            + patch_asar.weakmap_auth_invalidator_patch("cache")
            + "let original=cache;_invalidateAccountQueries();let first=cache;"
            "_invalidateAccountQueries();"
            "if(first===original||cache!==first||timers.length!==1)process.exit(1);"
            "timers.shift()();_invalidateAccountQueries();"
            "if(cache===first||timers.length!==1)process.exit(2);"
        )
        completed = patch_asar.subprocess.run(
            [node, "--eval", script],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_find_fast_mode_file_matches_bundle_by_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            (assets / "font-settings-good.js").write_text(FAST_FILE_CONTENT)
            (assets / "other.js").write_text("function nope(){}")

            found = patch_asar.find_fast_mode_file(assets)

            self.assertEqual(found, assets / "font-settings-good.js")

    def test_find_fast_mode_file_matches_2670751957_service_tier_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            target = assets / "app-initial-2670751957.js"
            target.write_text(CHATGPT_2670751957_FAST_CONTENT)
            (assets / "other.js").write_text("function nope(){}")

            found = patch_asar.find_fast_mode_file(assets)

            self.assertEqual(found, target)

    def test_find_fast_mode_file_matches_2670762119_split_service_tier_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            entitlement = assets / "onboarding.js"
            entitlement.write_text(
                "function allowed(e){return "
                "e?.requirements?.featureRequirements?.fast_mode!==!1}"
            )
            target = assets / "conversation.js"
            target.write_text(CHATGPT_2670762119_SPLIT_FAST_CONTENT)

            found = patch_asar.find_fast_mode_file(assets)

            self.assertEqual(found, target)

    def test_find_fast_mode_file_accepts_existing_split_patch_for_upgrade(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            target = assets / "conversation.js"
            target.write_text(CHATGPT_2670762119_SPLIT_FAST_CONTENT)
            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(
                    target,
                    {"gpt-5.6-sol"},
                )
            )

            self.assertEqual(patch_asar.find_fast_mode_file(assets), target)

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

    def test_find_remote_recents_file_matches_sidebar_recent_conversations_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            (assets / "irrelevant.js").write_text("recent-conversations only")
            expected = assets / "app-server-manager-hooks-HASH.js"
            expected.write_text(REMOTE_RECENTS_CONTENT)

            found = patch_asar.find_remote_recents_file(assets)

            self.assertEqual(found, expected)

    def test_apply_remote_recents_refresh_patch_adds_timer_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-server-manager-hooks-HASH.js"
            target.write_text(REMOTE_RECENTS_CONTENT)

            ok = patch_asar.apply_remote_recents_refresh_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.REMOTE_RECENTS_REFRESH_MARKER, patched)
            self.assertIn("window.setInterval(t,60000)", patched)
            self.assertEqual(patched.count("window.setInterval(t,60000)"), 1)
            self.assertIn("window.clearInterval(_csRemoteRecentRefreshTimer)", patched)
            self.assertIn("return t(),N([P({appServerRegistry:s", patched)

    def test_apply_remote_recents_refresh_patch_supports_codex_4753_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_4753_REMOTE_RECENTS_CONTENT)

            ok = patch_asar.apply_remote_recents_refresh_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.REMOTE_RECENTS_REFRESH_MARKER, patched)
            self.assertIn("window.setInterval(t,60000)", patched)
            self.assertIn("window.clearInterval(_csRemoteRecentRefreshTimer)", patched)
            self.assertIn("return t(),W7([G7({appServerRegistry:r", patched)

    def test_apply_remote_recents_refresh_patch_supports_codex_5018_signal_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5018_REMOTE_RECENTS_SIGNAL_CONTENT)

            ok = patch_asar.apply_remote_recents_refresh_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.REMOTE_RECENTS_REFRESH_MARKER, patched)
            self.assertIn("window.setInterval(_csRemoteRecentRefresh,60000)", patched)
            self.assertNotIn(
                "window.setInterval(_csRemoteRecentRefresh,60000),"
                "_csRemoteRecentRefresh()",
                patched,
            )
            self.assertIn("window.clearInterval(_csRemoteRecentRefreshTimer)", patched)
            self.assertIn("let e=t.get(O5,n)", patched)
            self.assertIn("e.refreshRecentConversations({})", patched)

    def test_apply_remote_recents_refresh_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-server-manager-hooks-HASH.js"
            target.write_text(REMOTE_RECENTS_CONTENT)

            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))
            first = target.read_text()
            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))
            second = target.read_text()

            self.assertEqual(first, second)

    def test_apply_remote_recents_refresh_patch_upgrades_v1_timer(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-server-manager-hooks-HASH.js"
            target.write_text(REMOTE_RECENTS_CONTENT)
            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))
            legacy = target.read_text().replace(
                patch_asar.REMOTE_RECENTS_REFRESH_MARKER,
                patch_asar.LEGACY_REMOTE_RECENTS_REFRESH_MARKER,
                1,
            ).replace("window.setInterval(t,60000)", "window.setInterval(t,15000)", 1)
            target.write_text(legacy)

            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))

            upgraded = target.read_text()
            self.assertIn('"CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2";', upgraded)
            self.assertNotIn('"CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH";', upgraded)
            self.assertIn("window.setInterval(t,60000)", upgraded)
            self.assertIn("return t(),N([P({appServerRegistry:s", upgraded)

    def test_apply_remote_recents_refresh_patch_removes_v1_signal_mount_refresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5018_REMOTE_RECENTS_SIGNAL_CONTENT)
            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))
            legacy = target.read_text().replace(
                patch_asar.REMOTE_RECENTS_REFRESH_MARKER,
                patch_asar.LEGACY_REMOTE_RECENTS_REFRESH_MARKER,
                1,
            ).replace(
                "window.setInterval(_csRemoteRecentRefresh,60000));",
                "window.setInterval(_csRemoteRecentRefresh,15000),"
                "_csRemoteRecentRefresh());",
                1,
            )
            target.write_text(legacy)

            self.assertTrue(patch_asar.apply_remote_recents_refresh_patch(target))

            upgraded = target.read_text()
            self.assertIn("window.setInterval(_csRemoteRecentRefresh,60000)", upgraded)
            self.assertNotIn(
                "window.setInterval(_csRemoteRecentRefresh,60000),"
                "_csRemoteRecentRefresh()",
                upgraded,
            )
            self.assertEqual(upgraded.count(patch_asar.REMOTE_RECENTS_REFRESH_MARKER), 1)

    def test_find_recent_threads_state_db_file_matches_unique_manager(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            (assets / "unrelated.js").write_text("async listRecentThreads({limit:e}){}")
            expected = assets / "app-main-current.js"
            expected.write_text(CHATGPT_5440_RECENT_THREADS_CONTENT)

            self.assertEqual(
                patch_asar.find_recent_threads_state_db_file(assets),
                expected,
            )

    def test_apply_recent_threads_state_db_patch_forces_only_sidebar_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-main-current.js"
            target.write_text(CHATGPT_5440_RECENT_THREADS_CONTENT)

            self.assertTrue(patch_asar.apply_recent_threads_state_db_patch(target))
            patched = target.read_text()

            self.assertTrue(patch_asar.has_recent_threads_state_db_patch(patched))
            self.assertEqual(
                patched.count(patch_asar.RECENT_THREADS_STATE_DB_MARKER),
                1,
            )
            self.assertIn("sourceKinds:wb,useStateDbOnly:!0", patched)
            self.assertIn(
                "{archived:!1,cursor:null,limit:e,modelProviders:null,sortKey:`updated_at`}",
                patched,
            )

    def test_apply_recent_threads_state_db_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-main-current.js"
            target.write_text(CHATGPT_5440_RECENT_THREADS_CONTENT)

            self.assertTrue(patch_asar.apply_recent_threads_state_db_patch(target))
            once = target.read_text()
            self.assertTrue(patch_asar.apply_recent_threads_state_db_patch(target))

            self.assertEqual(target.read_text(), once)

    def test_recent_threads_state_db_patch_rejects_ambiguous_manager(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "ambiguous.js"
            manager = CHATGPT_5440_RECENT_THREADS_CONTENT.split(
                "class RecentThreadManager{",
                1,
            )[1]
            target.write_text(
                CHATGPT_5440_RECENT_THREADS_CONTENT
                + "class DuplicateRecentThreadManager{"
                + manager
            )

            self.assertFalse(patch_asar.apply_recent_threads_state_db_patch(target))
            self.assertNotIn(
                patch_asar.RECENT_THREADS_STATE_DB_MARKER,
                target.read_text(),
            )

    def test_find_statsig_bootstrap_file_matches_unique_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            expected = assets / "app-main-current.js"
            expected.write_text(CHATGPT_5440_STATSIG_CONTENT)
            (assets / "unrelated.js").write_text("const statsig = null;")

            self.assertEqual(patch_asar.find_statsig_bootstrap_file(assets), expected)

    def test_apply_statsig_fail_open_patch_replaces_unbounded_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-main-current.js"
            target.write_text(CHATGPT_5440_STATSIG_CONTENT)

            self.assertTrue(patch_asar.apply_statsig_fail_open_patch(target))
            patched = target.read_text()

            self.assertTrue(patch_asar.has_statsig_fail_open_patch(patched))
            self.assertEqual(patched.count(patch_asar.STATSIG_FAIL_OPEN_MARKER), 1)
            self.assertIn("new StatsigSDK.StatsigClient", patched)
            self.assertIn("r=StableIDs.StableID.get(e.statsigClientKey)", patched)
            self.assertIn("{userID:r}", patched)
            self.assertIn("deviceId:r", patched)
            self.assertIn("n.initializeSync()", patched)
            self.assertIn("catch(t){return e.children}", patched)
            self.assertIn(
                "(0,jsxRuntime.jsxs)(_codexSwitchStatsigFailOpen,{appSessionId:",
                patched,
            )
            self.assertNotIn(
                "(0,jsxRuntime.jsxs)(AsyncFallback,{appSessionId:",
                patched,
            )

    def test_apply_statsig_fail_open_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-main-current.js"
            target.write_text(CHATGPT_5440_STATSIG_CONTENT)

            self.assertTrue(patch_asar.apply_statsig_fail_open_patch(target))
            once = target.read_text()
            self.assertTrue(patch_asar.apply_statsig_fail_open_patch(target))

            self.assertEqual(target.read_text(), once)

    def test_apply_model_label_fallback_patch_labels_gpt56_sol(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5042_MODEL_PICKER_CONTENT)

            ok = patch_asar.apply_model_label_fallback_patch(target)

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(patch_asar.MODEL_LABEL_FALLBACK_MARKER, patched)
            self.assertNotIn("e==null?`Custom`", patched)
            self.assertIn("DM(t).replace(/^GPT-/iu,``).replaceAll(`-`,` `)", patched)

    def test_apply_model_label_fallback_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5042_MODEL_PICKER_CONTENT)

            self.assertTrue(patch_asar.apply_model_label_fallback_patch(target))
            first = target.read_text()
            self.assertTrue(patch_asar.apply_model_label_fallback_patch(target))

            self.assertEqual(target.read_text(), first)

    def test_find_model_label_file_accepts_existing_label_patch_for_upgrade(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            target = assets / "app-initial-HASH.js"
            target.write_text(CODEX_5042_MODEL_PICKER_CONTENT)
            self.assertTrue(patch_asar.apply_model_label_fallback_patch(target))

            self.assertEqual(patch_asar.find_model_label_file(assets), target)

    def test_find_model_filter_file_supports_split_5211_chunk(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp)
            target = assets / "thread-app-shell.js"
            target.write_text(CODEX_5211_MODEL_FILTER_CONTENT)
            (assets / "model-picker.js").write_text(CODEX_5211_POWER_PRESET_CONTENT)

            self.assertEqual(patch_asar.find_model_filter_file(assets), target)

    def test_apply_model_availability_fallback_keeps_server_advertised_gpt56(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5059_MODEL_AVAILABILITY_CONTENT)

            self.assertTrue(patch_asar.apply_model_availability_fallback_patch(target))
            first = target.read_text()
            self.assertIn(patch_asar.MODEL_AVAILABILITY_FALLBACK_MARKER, first)
            self.assertIn(
                "t.has(n.model)||n.model.startsWith(`gpt-5.6-`)",
                first,
            )
            self.assertTrue(patch_asar.apply_model_availability_fallback_patch(target))
            self.assertEqual(target.read_text(), first)

    def test_gpt56_max_effort_patch_preserves_server_advertised_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5059_MAX_EFFORT_CONTENT)

            self.assertTrue(patch_asar.apply_gpt56_max_effort_patch(target))
            first = target.read_text()

            self.assertIn(patch_asar.GPT56_MAX_EFFORT_FALLBACK_MARKER, first)
            self.assertIn(
                "vg(e)&&(r.has(e)||(n.model.startsWith(`gpt-5.6-`)&&e===`max`))",
                first,
            )
            self.assertTrue(patch_asar.apply_gpt56_max_effort_patch(target))
            self.assertEqual(target.read_text(), first)

    def test_gpt56_max_effort_patch_supports_split_5211_chunks(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_filter = Path(tmp) / "thread-app-shell.js"
            model_filter.write_text(CODEX_5211_MODEL_FILTER_CONTENT)
            power_presets = Path(tmp) / "model-picker.js"
            power_presets.write_text(CODEX_5211_POWER_PRESET_CONTENT)

            self.assertTrue(
                patch_asar.apply_gpt56_max_effort_filter_patch(model_filter)
            )
            self.assertTrue(
                patch_asar.apply_gpt56_max_effort_preset_patch(power_presets)
            )

            self.assertTrue(
                patch_asar.has_gpt56_max_effort_filter_patch(
                    model_filter.read_text()
                )
            )
            self.assertTrue(
                patch_asar.has_gpt56_max_effort_preset_patch(
                    power_presets.read_text()
                )
            )

    def test_gpt56_max_effort_patch_orders_sol_max_before_ultra(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5059_MAX_EFFORT_CONTENT)

            self.assertTrue(patch_asar.apply_gpt56_max_effort_patch(target))
            patched = target.read_text()

            xhigh = patched.index("id:`gpt-5.6-sol:xhigh`")
            maximum = patched.index("id:`gpt-5.6-sol:max`")
            ultra = patched.index("id:`gpt-5.6-sol:ultra`")
            self.assertLess(xhigh, maximum)
            self.assertLess(maximum, ultra)
            self.assertIn(
                "t.supportedReasoningEfforts.some(({reasoningEffort:t})=>"
                "t===e.reasoningEffort)",
                patched,
            )

    def test_gpt56_max_effort_patch_supports_separate_ultra_preset(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            content = CODEX_5059_MAX_EFFORT_CONTENT
            preset_start = content.index("var FRe=[")
            ultra_start = content.index(",{", preset_start)
            array_end = content.index("];", ultra_start)
            split_layout = (
                content[:ultra_start]
                + "],URe="
                + content[ultra_start + 1 : array_end]
                + ";"
                + content[array_end + 2 :]
            )
            target.write_text(split_layout)

            self.assertTrue(patch_asar.apply_gpt56_max_effort_patch(target))
            patched = target.read_text()

            quote = chr(96)
            xhigh = patched.index(f"reasoningEffort:{quote}xhigh{quote}")
            maximum = patched.index(f"reasoningEffort:{quote}max{quote}")
            ultra = patched.index(f"reasoningEffort:{quote}ultra{quote}")
            self.assertLess(xhigh, maximum)
            self.assertLess(maximum, ultra)
            self.assertIn("],URe={", patched)
            self.assertTrue(patch_asar.apply_gpt56_max_effort_patch(target))
            self.assertEqual(target.read_text(), patched)

    def test_apply_selected_model_label_fallback_labels_active_gpt56_sol(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-HASH.js"
            target.write_text(CODEX_5059_SELECTED_MODEL_LABEL_CONTENT)

            self.assertTrue(patch_asar.apply_selected_model_label_fallback_patch(target))
            first = target.read_text()

            self.assertIn(patch_asar.SELECTED_MODEL_LABEL_FALLBACK_MARKER, first)
            self.assertIn("n.startsWith(`gpt-5.6-`)", first)
            self.assertIn("zE(n).replace(/^GPT-/iu,``).replaceAll(`-`,` `)", first)
            self.assertTrue(patch_asar.apply_selected_model_label_fallback_patch(target))
            self.assertEqual(target.read_text(), first)

    def test_remote_model_refresh_invalidates_same_host_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-main-HASH.js"
            target.write_text(CODEX_5059_REMOTE_MODEL_RECONNECT_CONTENT)

            self.assertTrue(patch_asar.apply_remote_model_refresh_patch(target))
            first = target.read_text()

            self.assertIn(patch_asar.REMOTE_MODEL_REFRESH_MARKER, first)
            self.assertIn(
                "t.invalidateQueries({queryKey:[`models`,`list`,r]})",
                first,
            )
            self.assertTrue(patch_asar.apply_remote_model_refresh_patch(target))
            self.assertEqual(target.read_text(), first)

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

    def test_apply_fast_mode_fallback_patch_repairs_2670751957_service_tiers(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-2670751957.js"
            target.write_text(CHATGPT_2670751957_FAST_CONTENT)

            ok = patch_asar.apply_fast_mode_fallback_patch(
                target,
                {"gpt-5.6-sol", "gpt-5.4"},
            )

            self.assertTrue(ok)
            patched = target.read_text()
            self.assertIn(
                "var _bundledFastModels=new Set([`gpt-5.4`,`gpt-5.6-sol`]);",
                patched,
            )
            self.assertEqual(patched.count("var _bundledFastModels="), 1)
            self.assertIn(
                "e?.serviceTiers?.length?e.serviceTiers:"
                "_bundledFastModels.has(e?.model)?"
                "[{id:`priority`,name:`Fast`,description:"
                "`1.5x speed, increased usage`}]:[]",
                patched,
            )
            self.assertNotIn("(e?.serviceTiers??[]).map", patched)
            self.assertEqual(patched.count("id:`priority`"), 1)

    def test_service_tier_fast_patch_preserves_entitlement_and_server_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-2670751957.js"
            target.write_text(CHATGPT_2670751957_FAST_CONTENT)

            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(
                    target,
                    {"gpt-5.6-sol"},
                )
            )
            patched = target.read_text()

            self.assertEqual(
                patched.count("featureRequirements?.fast_mode!==!1"),
                CHATGPT_2670751957_FAST_CONTENT.count(
                    "featureRequirements?.fast_mode!==!1"
                ),
            )
            self.assertIn(
                "e?.serviceTiers?.length?e.serviceTiers:",
                patched,
            )
            self.assertIn(
                "_bundledFastModels.has(e?.model)?",
                patched,
            )

    def test_service_tier_fast_patch_supports_split_entitlement_chunk(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "conversation.js"
            target.write_text(CHATGPT_2670762119_SPLIT_FAST_CONTENT)

            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(
                    target,
                    {"gpt-5.6-sol"},
                )
            )
            patched = target.read_text()

            self.assertIn(
                "e?.serviceTiers?.length?e.serviceTiers:",
                patched,
            )
            self.assertIn("_bundledFastModels.has(e?.model)?", patched)
            self.assertNotIn("featureRequirements?.fast_mode", patched)
            self.assertTrue(
                patch_asar.apply_fast_mode_fallback_patch(
                    target,
                    {"gpt-5.6-sol"},
                )
            )
            self.assertEqual(target.read_text(), patched)

    def test_bundled_fast_models_accept_service_tier_catalog_metadata(self):
        payload = {
            "models": [
                {
                    "slug": "gpt-5.6-sol",
                    "additional_speed_tiers": [],
                    "service_tiers": [{"id": "priority", "name": "Fast"}],
                },
                {
                    "slug": "gpt-5.4",
                    "additional_speed_tiers": ["fast"],
                    "service_tiers": [],
                },
                {
                    "slug": "gpt-5.4-mini",
                    "additional_speed_tiers": [],
                    "service_tiers": [{"id": "default", "name": "Standard"}],
                },
            ]
        }
        with patch.object(patch_asar.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = patch_asar.json.dumps(payload)
            run.return_value.stderr = ""

            models = patch_asar.get_bundled_fast_model_slugs(Path("/tmp/codex"))

        self.assertEqual(models, {"gpt-5.6-sol", "gpt-5.4"})

    def test_required_fast_patch_uses_bundled_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "app-initial-2670751957.js"
            target.write_text(CHATGPT_2670751957_FAST_CONTENT)
            with patch.object(
                patch_asar,
                "get_bundled_fast_model_slugs",
                return_value={"gpt-5.6-sol"},
            ):
                self.assertTrue(patch_asar.apply_required_fast_mode_patch(target))

            self.assertIn(patch_asar.FAST_FALLBACK_MARKER, target.read_text())

    def test_required_desktop_patch_contract_includes_fast_and_native_updater(self):
        states = {
            "auth": True,
            "remote_recents": True,
            "recent_threads_state_db": True,
            "statsig_fail_open": True,
            "fast": True,
            "model_label": True,
            "model_availability": True,
            "selected_model_label": True,
            "gpt56_max_effort": True,
            "remote_model_refresh": True,
            "native_updater": True,
        }
        self.assertTrue(patch_asar.required_desktop_patches_present(**states))

        states["fast"] = False

        self.assertFalse(patch_asar.required_desktop_patches_present(**states))

        states["fast"] = True
        states["statsig_fail_open"] = False

        self.assertFalse(patch_asar.required_desktop_patches_present(**states))

        states["statsig_fail_open"] = True
        states["native_updater"] = False

        self.assertFalse(patch_asar.required_desktop_patches_present(**states))

    def test_native_updater_patch_covers_bootstrap_and_main_bundles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build = root / ".vite" / "build"
            build.mkdir(parents=True)
            bootstrap = build / "bootstrap-current.js"
            main = build / "main-current.js"
            unrelated = build / "preload.js"
            bootstrap.write_text(NATIVE_UPDATER_BOOTSTRAP_CONTENT)
            main.write_text(NATIVE_UPDATER_MAIN_CONTENT)
            unrelated.write_text("const updater = null;")

            files = patch_asar.find_native_updater_files(root)

            self.assertEqual(files, [bootstrap, main])
            self.assertFalse(patch_asar.native_updater_patch_present(files))
            self.assertTrue(patch_asar.apply_native_updater_disable_patch(files))
            self.assertTrue(patch_asar.native_updater_patch_present(files))
            for target in files:
                patched = target.read_text()
                self.assertIn(patch_asar.NATIVE_UPDATER_DISABLED_MARKER, patched)
                self.assertIn("&&", patched)
                self.assertIn(",!1)", patched)

            first = [path.read_text() for path in files]
            self.assertTrue(patch_asar.apply_native_updater_disable_patch(files))
            self.assertEqual(first, [path.read_text() for path in files])

    def test_native_updater_cache_cleanup_is_exact_and_symlink_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            root = patch_asar.native_updater_persistent_downloads_path(home)
            first = root / "first"
            second = root / "second"
            first.mkdir(parents=True)
            second.mkdir()
            (first / "update.zip").write_bytes(b"a" * 32)
            (second / "update.zip").write_bytes(b"b" * 64)
            unrelated = home / "Library" / "Caches" / "unrelated"
            unrelated.mkdir(parents=True)
            sentinel = unrelated / "keep"
            sentinel.write_text("keep")

            removed_entries, removed_bytes = (
                patch_asar.cleanup_native_updater_persistent_downloads(root)
            )

            self.assertEqual(removed_entries, 2)
            self.assertEqual(removed_bytes, 96)
            self.assertEqual(list(root.iterdir()), [])
            self.assertEqual(sentinel.read_text(), "keep")

            linked_root = Path(tmp) / "linked-root"
            linked_root.symlink_to(unrelated, target_is_directory=True)
            self.assertEqual(
                patch_asar.cleanup_native_updater_persistent_downloads(linked_root),
                (0, 0),
            )
            self.assertEqual(sentinel.read_text(), "keep")

    def test_main_requires_and_applies_fast_patch(self):
        source = inspect.getsource(patch_asar.main)

        self.assertIn("fast=fast_already_patched", source)
        self.assertIn("apply_required_fast_mode_patch(fast_mode_file)", source)
        self.assertNotIn("Skipping optional fast-mode fallback", source)

    def test_main_requires_and_applies_native_updater_patch(self):
        source = inspect.getsource(patch_asar.main)

        self.assertIn("native_updater=native_updater_already_patched", source)
        self.assertIn("apply_native_updater_disable_patch(native_updater_files)", source)

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

    def test_codex_app_is_running_detects_unified_chatgpt_process(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="123 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n",
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

    def test_list_codesign_targets_skips_asar_unpacked_native_prebuilds(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Codex.app"
            foreign = (
                app
                / "Contents/Resources/app.asar.unpacked/node_modules/pkg/prebuilds/android-arm/node.napi.armv7.node"
            )
            darwin = (
                app
                / "Contents/Resources/app.asar.unpacked/node_modules/pkg/prebuilds/darwin-arm64/node.napi.armv8.node"
            )
            foreign.parent.mkdir(parents=True)
            darwin.parent.mkdir(parents=True)
            foreign.write_bytes(b"\x7fELFforeign")
            darwin.write_bytes(b"\xcf\xfa\xed\xfe" + b"macho")

            targets = patch_asar.list_codesign_targets(app)

            self.assertNotIn(foreign.resolve(), targets)
            self.assertNotIn(darwin.resolve(), targets)

    def test_codesign_team_identifier_normalizes_not_set(self):
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="Executable=/tmp/Codex\nTeamIdentifier=not set\n",
        )
        with patch.object(patch_asar.subprocess, "run", return_value=completed):
            self.assertIsNone(patch_asar.codesign_team_identifier(Path("/tmp/Codex")))

    def test_app_main_executable_uses_unified_bundle_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "ChatGPT.app"
            executable = app / "Contents/MacOS/ChatGPT"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"binary")
            info_plist = app / "Contents/Info.plist"
            with info_plist.open("wb") as handle:
                patch_asar.plistlib.dump({"CFBundleExecutable": "ChatGPT"}, handle)

            self.assertEqual(
                patch_asar.app_main_executable(app),
                executable.resolve(),
            )

    def test_select_codesign_identity_accepts_apple_issued_iphone_developer_fallback(self):
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

    def test_select_or_repair_codesign_identity_imports_cached_identity(self):
        with patch.object(
            patch_asar,
            "select_codesign_identity",
            side_effect=["-", "iPhone Developer: bd7349@gmail.com (856E75LLMU)"],
        ), patch.object(
            patch_asar,
            "import_cached_iphone_developer_identity",
            return_value=True,
        ) as importer:
            self.assertEqual(
                patch_asar.select_or_repair_codesign_identity(),
                "iPhone Developer: bd7349@gmail.com (856E75LLMU)",
            )

        importer.assert_called_once_with()

    def test_print_codesign_identity_is_read_only(self):
        with patch.object(
            patch_asar,
            "select_codesign_identity",
            return_value="Developer ID Application: Example",
        ) as inspector, patch.object(
            patch_asar,
            "select_or_repair_codesign_identity",
            return_value="unexpected repair",
        ) as repairer:
            self.assertEqual(
                patch_asar.requested_codesign_identity(
                    ["patch-asar.py", "--print-codesign-identity"]
                ),
                "Developer ID Application: Example",
            )

        inspector.assert_called_once_with()
        repairer.assert_not_called()

    def test_repair_codesign_identity_is_explicit(self):
        with patch.object(
            patch_asar,
            "select_or_repair_codesign_identity",
            return_value="iPhone Developer: Example",
        ) as repairer:
            self.assertEqual(
                patch_asar.requested_codesign_identity(
                    ["patch-asar.py", "--repair-codesign-identity"]
                ),
                "iPhone Developer: Example",
            )

        repairer.assert_called_once_with()

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
            macho = b"\xcf\xfa\xed\xfe" + b"binary"
            main_executable.write_bytes(macho)
            native_module.write_bytes(macho)
            dylib.write_bytes(macho)
            bundled_cli.write_bytes(macho)
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
                "codesign_strictly_valid",
                return_value=True,
            ), patch.object(
                patch_asar,
                "spctl_assessment",
                return_value="accepted",
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
                "codesign_strictly_valid",
                return_value=True,
            ), patch.object(
                patch_asar,
                "spctl_assessment",
                return_value="rejected",
            ):
                self.assertTrue(
                    patch_asar.needs_computer_use_plugin_signature_repair(app)
                )

    def test_computer_use_plugin_accepts_known_spctl_internal_error_after_strict_verify(self):
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

            with patch.object(
                patch_asar,
                "codesign_team_identifier",
                return_value="2DC432GLL2",
            ), patch.object(
                patch_asar,
                "codesign_entitlements_text",
                return_value="<string>2DC432GLL2.com.openai.sky.CUAService</string>",
            ), patch.object(
                patch_asar,
                "codesign_strictly_valid",
                return_value=True,
            ), patch.object(
                patch_asar,
                "spctl_assessment",
                return_value="unavailable",
            ):
                self.assertFalse(
                    patch_asar.needs_computer_use_plugin_signature_repair(app)
                )

    def test_spctl_assessment_distinguishes_internal_error_from_rejection(self):
        unavailable = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="internal error in Code Signing subsystem",
        )
        rejected = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="rejected",
            stderr="",
        )
        with patch.object(
            patch_asar.subprocess,
            "run",
            side_effect=[unavailable, rejected],
        ):
            self.assertEqual(
                patch_asar.spctl_assessment(Path("/tmp/one.app")),
                "unavailable",
            )
            self.assertEqual(
                patch_asar.spctl_assessment(Path("/tmp/two.app")),
                "rejected",
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

    def test_codesign_app_fails_when_gatekeeper_rejects_signed_bundle(self):
        app = Path("/Applications/Codex.app")
        nested = app / "Contents/Frameworks/Sparkle.framework"
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="",
        )
        with patch.object(patch_asar, "APP_PATH", app), patch.object(
            patch_asar,
            "select_or_repair_codesign_identity",
            return_value="Developer ID Application: Example (TEAMID1234)",
        ), patch.object(
            patch_asar,
            "list_codesign_targets",
            return_value=[nested, app],
        ), patch.object(
            patch_asar,
            "codesign_target",
            return_value=True,
        ), patch.object(
            patch_asar,
            "ensure_computer_use_plugin_signature_compatible",
            return_value=True,
        ), patch.object(
            patch_asar,
            "write_local_desktop_app_entitlements",
            return_value=Path("/tmp/codex.entitlements.plist"),
        ), patch.object(
            patch_asar.subprocess,
            "run",
            return_value=completed,
        ), patch.object(
            patch_asar,
            "executable_and_framework_team_ids_match",
            return_value=True,
        ), patch.object(
            patch_asar,
            "spctl_accepts",
            return_value=False,
        ) as spctl:
            self.assertFalse(patch_asar.codesign_app())

        spctl.assert_called_once_with(app)

    def test_codesign_app_allows_iphone_developer_local_gatekeeper_fallback(self):
        app = Path("/Applications/Codex.app")
        nested = app / "Contents/Frameworks/Sparkle.framework"
        completed = patch_asar.subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="",
        )
        with patch.object(patch_asar, "APP_PATH", app), patch.object(
            patch_asar,
            "select_or_repair_codesign_identity",
            return_value="iPhone Developer: bd7349@gmail.com (856E75LLMU)",
        ), patch.object(
            patch_asar,
            "list_codesign_targets",
            return_value=[nested, app],
        ), patch.object(
            patch_asar,
            "codesign_target",
            return_value=True,
        ), patch.object(
            patch_asar,
            "ensure_computer_use_plugin_signature_compatible",
            return_value=True,
        ), patch.object(
            patch_asar,
            "write_local_desktop_app_entitlements",
            return_value=Path("/tmp/codex.entitlements.plist"),
        ), patch.object(
            patch_asar.subprocess,
            "run",
            return_value=completed,
        ), patch.object(
            patch_asar,
            "executable_and_framework_team_ids_match",
            return_value=True,
        ), patch.object(
            patch_asar,
            "spctl_accepts",
            return_value=False,
        ) as spctl, patch.object(
            patch_asar,
            "codesign_identity_is_apple_issued",
            return_value=True,
        ):
            self.assertTrue(patch_asar.codesign_app())

        spctl.assert_called_once_with(app)

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
