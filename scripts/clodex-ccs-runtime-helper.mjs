#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const PINNED_CCS_VERSION = "8.8.1";
const DEFAULT_PACKAGE_ROOT = "/usr/lib/node_modules/@kaitranntt/ccs";
const DEFAULT_BASE_URL = "http://127.0.0.1:8317";
const AUTH_MODULE_RELATIVE =
  "dist/cliproxy/auth/auth-token-manager.js";
const HEALTH_TIMEOUT_MS = 3_000;

class RuntimeRefusal extends Error {}

function readOwnedRegular(filePath) {
  const flags =
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0);
  let descriptor;
  try {
    descriptor = fs.openSync(filePath, flags);
    const info = fs.fstatSync(descriptor);
    const allowedOwners = new Set([0, process.getuid?.()]);
    if (!info.isFile()) {
      throw new RuntimeRefusal(`not a regular file: ${filePath}`);
    }
    if (!allowedOwners.has(info.uid)) {
      throw new RuntimeRefusal(`unexpected file owner: ${filePath}`);
    }
    return fs.readFileSync(descriptor);
  } finally {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
  }
}

function resolvePackage() {
  const configured =
    process.env.CLODEX_CCS_PACKAGE_ROOT || DEFAULT_PACKAGE_ROOT;
  const rootInfo = fs.lstatSync(configured);
  if (rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) {
    throw new RuntimeRefusal("CCS package root is not a real directory");
  }
  const root = fs.realpathSync(configured);
  const packageJsonPath = path.join(root, "package.json");
  let metadata;
  try {
    metadata = JSON.parse(readOwnedRegular(packageJsonPath).toString("utf8"));
  } catch (error) {
    if (error instanceof RuntimeRefusal) {
      throw error;
    }
    throw new RuntimeRefusal("CCS package metadata is invalid");
  }
  if (metadata.name !== "@kaitranntt/ccs") {
    throw new RuntimeRefusal("unexpected CCS package name");
  }
  if (metadata.version !== PINNED_CCS_VERSION) {
    throw new RuntimeRefusal(
      `unsupported CCS version ${JSON.stringify(metadata.version)}; ` +
        `expected ${PINNED_CCS_VERSION}`,
    );
  }

  const modulePath = path.join(root, AUTH_MODULE_RELATIVE);
  const moduleReal = fs.realpathSync(modulePath);
  if (!moduleReal.startsWith(`${root}${path.sep}`)) {
    throw new RuntimeRefusal("CCS auth module escapes the package root");
  }
  readOwnedRegular(moduleReal);
  return { root, modulePath: moduleReal };
}

function resolveLoopbackOrigin() {
  const raw = process.env.CLODEX_CCS_BASE_URL || DEFAULT_BASE_URL;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new RuntimeRefusal("CCS base URL is invalid");
  }
  if (
    url.protocol !== "http:" ||
    url.hostname !== "127.0.0.1" ||
    url.username ||
    url.password ||
    (url.pathname !== "" && url.pathname !== "/") ||
    url.search ||
    url.hash
  ) {
    throw new RuntimeRefusal(
      "CCS base URL must be an uncredentialed loopback HTTP origin",
    );
  }
  return url.origin;
}

function resolveGatewayKey(modulePath) {
  const require = createRequire(import.meta.url);
  const authModule = require(modulePath);
  if (typeof authModule.getEffectiveApiKey !== "function") {
    throw new RuntimeRefusal("CCS auth module API is unsupported");
  }
  const token = authModule.getEffectiveApiKey();
  if (
    typeof token !== "string" ||
    token.length < 8 ||
    token.length > 4096 ||
    /[\s\0]/u.test(token)
  ) {
    throw new RuntimeRefusal("CCS gateway key is missing or malformed");
  }
  return token;
}

async function checkGateway(origin, token) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);
  timeout.unref?.();
  try {
    const response = await fetch(new URL("/v1/models", origin), {
      headers: { Authorization: `Bearer ${token}` },
      signal: controller.signal,
    });
    await response.body?.cancel();
    if (!response.ok) {
      throw new RuntimeRefusal(
        `CCS gateway health check returned HTTP ${response.status}`,
      );
    }
  } catch (error) {
    if (error instanceof RuntimeRefusal) {
      throw error;
    }
    throw new RuntimeRefusal("CCS gateway health check failed");
  } finally {
    clearTimeout(timeout);
  }
}

async function main() {
  const [action, ...extra] = process.argv.slice(2);
  if (!["--check", "--token"].includes(action) || extra.length > 0) {
    throw new RuntimeRefusal("usage: clodex-ccs-runtime-helper --check|--token");
  }
  const { modulePath } = resolvePackage();
  const origin = resolveLoopbackOrigin();
  const token = resolveGatewayKey(modulePath);
  await checkGateway(origin, token);

  if (action === "--token") {
    process.stdout.write(token);
    return;
  }
  process.stdout.write(
    `clodex-ccs-runtime: ready ccs=${PINNED_CCS_VERSION} origin=${origin}\n`,
  );
}

main().catch((error) => {
  const message =
    error instanceof RuntimeRefusal
      ? error.message
      : "unexpected runtime-helper failure";
  process.stderr.write(`clodex-ccs-runtime: refused: ${message}\n`);
  process.exitCode = 78;
});
