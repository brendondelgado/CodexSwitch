#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { normalize, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const TESTING = process.env.CLODEX_CODEXSWITCH_TESTING === '1';
const PINNED_VERSION = '2.1.3';
const PATCHED_CLI_SHA256 = TESTING
  ? process.env.CLODEX_CODEXSWITCH_TEST_CLI_SHA256
  : 'd5c13c2321edd14aec557e79d31a75a1f9efc4b80d43de4f5223403e2b2bf81f';
const PROVIDER_ID = 'openai-oauth';
const ACCOUNT_BASE = `oauth:provider:${PROVIDER_ID}`;
const MANAGED_OWNER = 'codexswitch';
const BRIDGE_VERSION = 1;
const MAX_FAVORITES = 20;

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseArgs(argv) {
  const action = argv.shift();
  if (!['--configure', '--check', '--unconfigure'].includes(action)) {
    fail(
      'usage: configure-clodex-codexswitch.mjs '
      + '--configure|--check|--unconfigure --package-root PATH --helper PATH',
    );
  }
  const values = new Map();
  while (argv.length > 0) {
    const key = argv.shift();
    const value = argv.shift();
    if (!['--package-root', '--helper'].includes(key) || !value) {
      fail('invalid configurator argument');
    }
    values.set(key, value);
  }
  const packageRoot = values.get('--package-root');
  const helper = values.get('--helper');
  if (!packageRoot || !helper) fail('package root and helper are required');
  return { action, packageRoot: resolve(packageRoot), helper: resolve(helper) };
}

function verifyPrivateExecutable(path) {
  const info = statSync(path);
  if (!info.isFile()) fail('credential helper is not a regular file');
  if (typeof process.getuid === 'function' && info.uid !== process.getuid()) {
    fail('credential helper is not owned by the current user');
  }
  if ((info.mode & 0o777) !== 0o700) {
    fail('credential helper mode must be 0700');
  }
}

function verifyPackage(packageRoot) {
  const metadata = JSON.parse(readFileSync(`${packageRoot}/package.json`, 'utf8'));
  if (metadata.name !== '@bman654/clodex' || metadata.version !== PINNED_VERSION) {
    fail('Clodex package name or version does not match the pinned integration');
  }
  const cli = readFileSync(`${packageRoot}/dist/cli.js`);
  if (sha256(cli) !== PATCHED_CLI_SHA256) {
    fail('Clodex CodexSwitch runtime postimage is not exact');
  }
}

function managedAuthRef(helper) {
  const helperId = createHash('sha256')
    .update('clodex-credential-helper\0')
    .update(normalize(helper))
    .digest('hex');
  const appHome = resolve(process.env.CLODEX_HOME?.trim() || `${homedir()}/.clodex`);
  const scope = createHash('sha256')
    .update('clodex-credential-account\0')
    .update(normalize(appHome))
    .digest('hex')
    .slice(0, 32);
  return `helper:v1:${helperId}:${ACCOUNT_BASE}::credential::v1:${scope}`;
}

function helperAccount(authRef) {
  const parts = authRef.split(':');
  if (
    parts.length < 6
    || parts[0] !== 'helper'
    || parts[1] !== 'v1'
    || !/^[0-9a-f]{64}$/.test(parts[2])
  ) {
    fail('managed helper reference is malformed');
  }
  return parts.slice(3).join(':');
}

function verifyManagedRead(helper, authRef) {
  const result = spawnSync(
    helper,
    ['get', 'clodex', helperAccount(authRef)],
    {
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      shell: false,
      env: process.env,
    },
  );
  if (result.status !== 0) {
    fail(`CodexSwitch managed credential read failed with exit ${result.status ?? 'signal'}`);
  }
  let credential;
  try {
    credential = JSON.parse(result.stdout);
  } catch {
    fail('CodexSwitch managed credential helper returned invalid JSON');
  }
  if (
    credential?.type !== 'oauth'
    || typeof credential.access !== 'string'
    || !credential.access
    || typeof credential.refresh !== 'string'
    || !credential.refresh
    || typeof credential.expires !== 'number'
    || credential.expires <= Date.now()
    || credential.providerData?.credentialOwner !== MANAGED_OWNER
    || credential.providerData?.bridgeVersion !== BRIDGE_VERSION
  ) {
    fail('CodexSwitch managed credential helper returned an incomplete contract');
  }
}

function providerIsManaged(provider, authRef) {
  return (
    provider?.id === PROVIDER_ID
    && provider.templateId === 'openai'
    && provider.authType === 'oauth'
    && provider.authRef === authRef
  );
}

function managedAliasName(modelId, used) {
  const stem = `cs-${modelId.toLowerCase().replace(/[^a-z0-9._-]+/g, '-')}`
    .replace(/-+/g, '-')
    .slice(0, 56)
    .replace(/[-._]+$/g, '');
  let candidate = stem || 'cs-model';
  let suffix = 2;
  while (used.has(candidate)) {
    candidate = `${stem.slice(0, 58)}-${suffix}`;
    suffix += 1;
  }
  used.add(candidate);
  return candidate;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  verifyPrivateExecutable(args.helper);
  verifyPackage(args.packageRoot);
  const authRef = managedAuthRef(args.helper);
  if (args.action !== '--unconfigure') {
    verifyManagedRead(args.helper, authRef);
  }

  const runtime = await import(
    pathToFileURL(`${args.packageRoot}/dist/chunk-OVO6OUZG.js`).href
  );
  const {
    loadPreferences,
    loadRegistryStrict,
    savePreferences,
    saveRegistry,
    withRegistryWriteLock,
  } = runtime;
  if (
    typeof loadPreferences !== 'function'
    || typeof loadRegistryStrict !== 'function'
    || typeof savePreferences !== 'function'
    || typeof saveRegistry !== 'function'
    || typeof withRegistryWriteLock !== 'function'
  ) {
    fail('Clodex registry API does not match the pinned integration');
  }

  if (args.action === '--check') {
    const registry = loadRegistryStrict();
    const provider = registry.providers.find(candidate => candidate.id === PROVIDER_ID);
    if (!providerIsManaged(provider, authRef)) {
      fail('Clodex OpenAI OAuth provider is not bound to CodexSwitch');
    }
    const modelIds = new Set(
      (provider.modelsCache?.models ?? [])
        .map(model => model?.id)
        .filter(id => typeof id === 'string' && id),
    );
    const favoriteCount = (loadPreferences().favoriteModels ?? []).filter(
      favorite => (
        favorite?.providerId === PROVIDER_ID
        && modelIds.has(favorite.modelId)
      ),
    ).length;
    const aliasCount = (loadPreferences().modelAliases ?? []).filter(
      alias => (
        alias?.providerId === PROVIDER_ID
        && modelIds.has(alias.modelId)
        && typeof alias.name === 'string'
        && alias.name.startsWith('cs-')
      ),
    ).length;
    if (modelIds.size === 0 || favoriteCount === 0 || aliasCount !== favoriteCount) {
      fail('Clodex managed provider has no selectable favorite models');
    }
    process.stdout.write(
      `clodex-codexswitch: ready provider=${PROVIDER_ID} `
      + `models=${modelIds.size} favorites=${favoriteCount} aliases=${aliasCount}\n`,
    );
    return;
  }

  await withRegistryWriteLock(() => {
    const registry = loadRegistryStrict();
    const index = registry.providers.findIndex(candidate => candidate.id === PROVIDER_ID);
    const current = index >= 0 ? registry.providers[index] : undefined;
    if (args.action === '--unconfigure') {
      if (!current) return;
      if (!providerIsManaged(current, authRef)) {
        fail('refusing to remove a non-CodexSwitch OpenAI OAuth provider');
      }
      registry.providers.splice(index, 1);
      saveRegistry(registry);
      return;
    }
    if (current && !providerIsManaged(current, authRef)) {
      fail('refusing to replace an existing OpenAI OAuth provider');
    }
    if (!current) {
      registry.providers.push({
        id: PROVIDER_ID,
        templateId: 'openai',
        name: 'OpenAI (CodexSwitch pool)',
        enabled: true,
        authRef,
        authType: 'oauth',
        api: {
          npm: '@ai-sdk/openai',
          url: 'https://api.openai.com/v1',
        },
        addedAt: new Date().toISOString(),
      });
      saveRegistry(registry);
    }
  });
  const preferences = loadPreferences();
  const unrelatedFavorites = (preferences.favoriteModels ?? []).filter(
    favorite => favorite?.providerId !== PROVIDER_ID,
  );
  const unrelatedAliases = (preferences.modelAliases ?? []).filter(
    alias => alias?.providerId !== PROVIDER_ID,
  );
  if (args.action === '--unconfigure') {
    savePreferences({
      favoriteModels: unrelatedFavorites,
      modelAliases: unrelatedAliases,
      claudeBridgeMode: 'proxy',
    });
  } else {
    const registry = loadRegistryStrict();
    const provider = registry.providers.find(candidate => candidate.id === PROVIDER_ID);
    const availableSlots = Math.max(0, MAX_FAVORITES - unrelatedFavorites.length);
    const managedFavorites = (provider?.modelsCache?.models ?? [])
      .map(model => model?.id)
      .filter(id => typeof id === 'string' && id)
      .slice(0, availableSlots)
      .map(modelId => ({ providerId: PROVIDER_ID, modelId }));
    const usedAliases = new Set(
      unrelatedAliases.map(alias => alias?.name).filter(name => typeof name === 'string'),
    );
    const managedAliases = managedFavorites.map(favorite => ({
      name: managedAliasName(favorite.modelId, usedAliases),
      providerId: PROVIDER_ID,
      modelId: favorite.modelId,
    }));
    savePreferences({
      favoriteModels: [...unrelatedFavorites, ...managedFavorites],
      modelAliases: [...unrelatedAliases, ...managedAliases],
      claudeBridgeMode: 'proxy',
    });
  }
  process.stdout.write(
    `clodex-codexswitch: ${args.action === '--configure' ? 'configured' : 'removed'} `
    + `provider=${PROVIDER_ID}\n`,
  );
}

main().catch(error => {
  process.stderr.write(
    `clodex-codexswitch: refused: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exitCode = 78;
});
