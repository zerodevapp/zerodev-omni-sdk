#!/usr/bin/env node
/**
 * Test harness: starts Anvil (forked from Base) + Alto bundler.
 *
 * Usage:
 *   node harness.mjs start   — Start anvil + alto, keep running
 *   node harness.mjs test    — Start, run zig e2e tests, stop
 */
import { spawn, execSync } from "child_process";
import { createPublicClient, http, formatEther } from "viem";
import { base } from "viem/chains";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, "../..");

// ---- Configuration ----

const FORK_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const FORK_BLOCK = Number(process.env.FORK_BLOCK || 30_000_000);
const ANVIL_PORT = Number(process.env.ANVIL_PORT || 8545);
const ALTO_PORT = Number(process.env.ALTO_PORT || 4337);

// Anvil pre-funded account (10,000 ETH)
const EXECUTOR_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const ENTRY_POINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const META_FACTORY = "0xd703aaE79538628d27099B8c4f621bE4CCd142d5";

const ALTO_BIN = path.join(__dirname, "node_modules/.bin/alto");

// ---- Process management ----

let anvilProc = null;
let altoProc = null;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForRpc(url, maxRetries = 30) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          method: "eth_chainId",
          params: [],
          id: 1,
        }),
      });
      const json = await res.json();
      if (json.result) return true;
    } catch {}
    await sleep(500);
  }
  return false;
}

async function startAnvil() {
  console.log(`Starting Anvil (fork Base @ block ${FORK_BLOCK})...`);
  anvilProc = spawn(
    "anvil",
    [
      "--fork-url",
      FORK_URL,
      "--fork-block-number",
      String(FORK_BLOCK),
      "--port",
      String(ANVIL_PORT),
      "--chain-id",
      "8453",
      "--silent",
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );

  anvilProc.stderr.on("data", (d) => {
    const msg = d.toString().trim();
    if (msg) console.error(`  [anvil stderr] ${msg}`);
  });

  const ready = await waitForRpc(`http://127.0.0.1:${ANVIL_PORT}`);
  if (!ready) throw new Error("Anvil failed to start");
  console.log(`  Anvil ready on :${ANVIL_PORT}`);
}

async function verifyContracts() {
  const client = createPublicClient({
    chain: { ...base, id: 8453 },
    transport: http(`http://127.0.0.1:${ANVIL_PORT}`),
  });

  const epCode = await client.getCode({ address: ENTRY_POINT_V07 });
  if (!epCode || epCode === "0x") {
    throw new Error(
      `EntryPoint v0.7 not at ${ENTRY_POINT_V07} on block ${FORK_BLOCK}`
    );
  }
  console.log(`  EntryPoint v0.7: ${epCode.length} chars of bytecode`);

  const mfCode = await client.getCode({ address: META_FACTORY });
  if (!mfCode || mfCode === "0x") {
    throw new Error(`MetaFactory not at ${META_FACTORY} on block ${FORK_BLOCK}`);
  }
  console.log(`  MetaFactory: ${mfCode.length} chars of bytecode`);

  const balance = await client.getBalance({
    address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  });
  console.log(`  Executor balance: ${formatEther(balance)} ETH`);
}

async function startAlto() {
  console.log("Starting Alto bundler...");
  altoProc = spawn(
    ALTO_BIN,
    [
      "--entrypoints",
      ENTRY_POINT_V07,
      "--executor-private-keys",
      EXECUTOR_KEY,
      "--utility-private-key",
      EXECUTOR_KEY,
      "--rpc-url",
      `http://127.0.0.1:${ANVIL_PORT}`,
      "--port",
      String(ALTO_PORT),
      "--network-name",
      "local",
      "--safe-mode",
      "false",
      "--enable-debug-endpoints",
      "--min-entity-stake",
      "1",
      "--min-entity-unstake-delay",
      "1",
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );

  altoProc.stdout.on("data", (d) => {
    const msg = d.toString().trim();
    if (msg && process.env.VERBOSE) console.log(`  [alto] ${msg}`);
  });
  altoProc.stderr.on("data", (d) => {
    const msg = d.toString().trim();
    if (msg && process.env.VERBOSE) console.error(`  [alto err] ${msg}`);
  });

  // Wait for alto to be ready
  const ready = await waitForRpc(
    `http://127.0.0.1:${ALTO_PORT}`,
    40
  );
  if (!ready) {
    console.warn("  Warning: Alto may not be fully ready, continuing...");
  } else {
    console.log(`  Alto ready on :${ALTO_PORT}`);
  }

  // Verify bundler responds
  try {
    const res = await fetch(`http://127.0.0.1:${ALTO_PORT}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "eth_supportedEntryPoints",
        params: [],
        id: 1,
      }),
    });
    const json = await res.json();
    console.log(`  Bundler entrypoints: ${JSON.stringify(json.result)}`);
  } catch (e) {
    console.warn(`  Bundler health check failed: ${e.message}`);
  }
}

function stopAll() {
  if (altoProc) {
    altoProc.kill("SIGTERM");
    altoProc = null;
    console.log("  Alto stopped");
  }
  if (anvilProc) {
    anvilProc.kill("SIGTERM");
    anvilProc = null;
    console.log("  Anvil stopped");
  }
}

// ---- Commands ----

async function cmdStart() {
  await startAnvil();
  await verifyContracts();
  await startAlto();

  console.log("\nTest infrastructure ready!");
  console.log(`  RPC:     http://127.0.0.1:${ANVIL_PORT}`);
  console.log(`  Bundler: http://127.0.0.1:${ALTO_PORT}`);
  console.log("\nPress Ctrl+C to stop...");

  process.on("SIGINT", () => {
    stopAll();
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    stopAll();
    process.exit(0);
  });
}

async function cmdTest() {
  await startAnvil();
  await verifyContracts();
  await startAlto();

  console.log("\nRunning Zig E2E tests...\n");
  try {
    execSync("zig build test-e2e 2>&1", {
      cwd: ROOT_DIR,
      stdio: "inherit",
      env: {
        ...process.env,
        E2E_RPC_URL: `http://127.0.0.1:${ANVIL_PORT}`,
        E2E_BUNDLER_URL: `http://127.0.0.1:${ALTO_PORT}`,
        E2E_CHAIN_ID: "8453",
        E2E_PRIVATE_KEY:
          "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
      },
    });
    console.log("\nAll E2E tests passed!");
  } catch {
    console.error("\nE2E tests failed!");
    process.exitCode = 1;
  } finally {
    stopAll();
  }
}

// ---- CLI ----

const cmd = process.argv[2] || "test";

switch (cmd) {
  case "start":
    await cmdStart();
    break;
  case "test":
    await cmdTest();
    break;
  default:
    console.error(`Usage: node harness.mjs [start|test]`);
    process.exit(1);
}
