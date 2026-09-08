import { execFileSync, spawn } from 'node:child_process';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const team = '2DC432GLL2';

export function runtimePaths(appPath = '/Applications/ChatGPT.app') {
  if (!path.isAbsolute(appPath) || path.dirname(appPath) !== '/Applications'
      || !appPath.endsWith('.app')) {
    throw new Error('Computer Use requires a top-level /Applications app bundle');
  }
  const root = path.join(appPath, 'Contents/Resources/cua_node');
  return {
    node: path.join(root, 'bin/node'),
    repl: path.join(root, 'bin/node_repl'),
    modules: path.join(root, 'lib/node_modules'),
    stockCLI: path.join(appPath, 'Contents/Resources/codex'),
  };
}

export function verifyRuntime(paths, {
  execPath = process.execPath,
  canonicalPath = realpathSync,
  run = execFileSync,
} = {}) {
  if (canonicalPath(execPath) !== canonicalPath(paths.node)) {
    throw new Error('Launch this connector with ChatGPT\'s official Node runtime');
  }
  for (const [binary, identifier] of [[paths.node, 'node'], [paths.repl, 'node_repl']]) {
    run('/usr/bin/codesign', [
      '--verify', '--strict', '-R',
      `=anchor apple generic and certificate leaf[subject.OU] = "${team}" and identifier "${identifier}"`,
      binary,
    ], { timeout: 15000, stdio: ['ignore', 'ignore', 'pipe'] });
  }
}

export function runtimeEnvironment(paths, inherited = process.env) {
  for (const key of ['NODE_OPTIONS', 'NODE_PATH', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH']) {
    if (inherited[key]) throw new Error(`Computer Use refuses injected runtime setting ${key}`);
  }
  return {
    ...inherited,
    NODE_REPL_NODE_PATH: paths.node,
    NODE_REPL_NODE_MODULE_DIRS: paths.modules,
    NODE_REPL_TRUSTED_CODE_PATHS: paths.modules,
    NODE_REPL_TRUSTED_SERVICES: JSON.stringify({ sky: '@oai/sky/service' }),
    NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE:
      'Control local Mac apps through Computer Use using @oai/sky in this node_repl runtime.',
    CODEX_CLI_PATH: inherited.CODEX_CLI_PATH || paths.stockCLI,
  };
}

export function start() {
  if (process.platform !== 'darwin') throw new Error('Computer Use is available only on macOS');
  if (process.argv.length !== 2) throw new Error('This connector accepts no command arguments');
  const paths = runtimePaths(process.env.CODEXSWITCH_CHATGPT_APP_PATH);
  verifyRuntime(paths);
  const env = runtimeEnvironment(paths);

  // Keep the verified official Node process as the MCP runtime's parent.
  // Inherited stdio preserves the complete MCP approval and metadata protocol.
  const child = spawn(paths.repl, [], { env, stdio: 'inherit' });
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => child.kill(signal));
  }
  child.once('error', error => {
    console.error(`Computer Use runtime could not start: ${error.message}`);
    process.exitCode = 1;
  });
  child.once('exit', (code, signal) => {
    process.exitCode = code ?? (signal === 'SIGTERM' ? 0 : 1);
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    start();
  } catch (error) {
    console.error(`Computer Use startup refused: ${error.message}`);
    process.exitCode = 1;
  }
}
