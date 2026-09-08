import assert from 'node:assert/strict';
import test from 'node:test';
import { runtimeEnvironment, runtimePaths, verifyRuntime } from './computer-use-mcp.mjs';

test('runtime paths are confined to a top-level application', () => {
  for (const input of ['ChatGPT.app', '/tmp/ChatGPT.app', '/Applications/Nested/ChatGPT.app', '/Applications/ChatGPT']) {
    assert.throws(() => runtimePaths(input));
  }
  assert.equal(runtimePaths().repl, '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl');
});

test('both official executable identities must pass strict verification', () => {
  const paths = runtimePaths();
  const calls = [];
  verifyRuntime(paths, {
    execPath: paths.node,
    canonicalPath: value => value,
    run: (...args) => calls.push(args),
  });
  assert.equal(calls.length, 2);
  for (const [command, args, options] of calls) {
    assert.equal(command, '/usr/bin/codesign');
    assert.deepEqual(args.slice(0, 3), ['--verify', '--strict', '-R']);
    assert.match(args[3], /anchor apple generic/);
    assert.match(args[3], /2DC432GLL2/);
    assert.equal(options.timeout, 15000);
  }
  assert.equal(calls[1][1].at(-1), paths.repl);
  assert.throws(() => verifyRuntime(paths, {
    execPath: paths.node, canonicalPath: value => value,
    run: () => { throw new Error('invalid signature'); },
  }), /invalid signature/);
});

test('an unsigned or unrelated Node parent cannot launch the connector', () => {
  assert.throws(() => verifyRuntime(runtimePaths(), {
    execPath: '/opt/homebrew/bin/node', canonicalPath: value => value,
    run: () => assert.fail('must reject before verification'),
  }), /official Node/);
});

test('trusted sky service uses bundled code and retains sandbox CLI and metadata', () => {
  const paths = runtimePaths();
  const inherited = {
    CODEX_CLI_PATH: '/Users/test/.local/share/codexswitch/prepared-codex/codex',
    NODE_REPL_REQUEST_META: 'opaque-test-metadata',
    NODE_REPL_HOST_SERVICES_PIPE_PATH: '/tmp/host-services.sock',
    NODE_REPL_TRUSTED_SERVICES: '{"unexpected":"/tmp/untrusted.js"}',
    NODE_REPL_TRUSTED_CODE_PATHS: '/tmp',
  };
  const env = runtimeEnvironment(paths, inherited);
  assert.deepEqual(JSON.parse(env.NODE_REPL_TRUSTED_SERVICES), { sky: '@oai/sky/service' });
  assert.equal(env.NODE_REPL_TRUSTED_CODE_PATHS, paths.modules);
  assert.equal(env.CODEX_CLI_PATH, inherited.CODEX_CLI_PATH);
  assert.equal(env.NODE_REPL_REQUEST_META, inherited.NODE_REPL_REQUEST_META);
  assert.equal(env.NODE_REPL_HOST_SERVICES_PIPE_PATH, inherited.NODE_REPL_HOST_SERVICES_PIPE_PATH);
  assert.equal(runtimeEnvironment(paths, {}).CODEX_CLI_PATH, paths.stockCLI);
  assert.equal(inherited.NODE_REPL_TRUSTED_CODE_PATHS, '/tmp');
});

test('runtime injection settings fail closed', () => {
  for (const key of ['NODE_OPTIONS', 'NODE_PATH', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH']) {
    assert.throws(() => runtimeEnvironment(runtimePaths(), { [key]: 'injected' }), /refuses injected/);
  }
});
