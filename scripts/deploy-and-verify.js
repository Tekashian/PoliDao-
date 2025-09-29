/* eslint-disable no-console */
require("dotenv").config();
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const isLocal = (n) => n === "hardhat" || n === "localhost";
// NEW: detect polygon networks for better verify/confirm settings
const isPolygon = (n) =>
  ["polygon", "amoy", "mumbai", "matic", "maticmum", "polygonMumbai"].includes(n);
const waitMs = (ms) => new Promise((r) => setTimeout(r, ms));

// ENV toggles
const SKIP_VERIFY = process.env.SKIP_VERIFY === "1";
const FORCE_REDEPLOY = process.env.FORCE_REDEPLOY === "1";
const FORCE_REVERIFY = process.env.FORCE_REVERIFY === "1";
// CHANGED: default VERIFY_LIBS to true on non-local networks
const VERIFY_LIBS = process.env.VERIFY_LIBS
  ? process.env.VERIFY_LIBS === "1"
  : !isLocal(hre.network.name);
const VERIFY_RETRIES = Number(process.env.VERIFY_RETRIES || 3);
const VERIFY_DELAY_MS = Number(process.env.VERIFY_DELAY_MS || (isPolygon(hre.network.name) ? 60000 : 15000));
const MAX_PENDING_MS = Number(process.env.MAX_PENDING_MS || 5 * 60_000);
// NEW: comma-separated, case-insensitive list of names to force redeploy (e.g. "Storage,Core,Router")
const REDEPLOY_LIST = (process.env.REDEPLOY_LIST || "")
  .split(",")
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

// NEW: keep track of deployed libraries (name -> address)
const deployedLibs = {};

// NEW: tiny fs helpers
function ensureDirSync(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}
function writeJsonSync(fp, obj) {
  ensureDirSync(path.dirname(fp));
  fs.writeFileSync(fp, JSON.stringify(obj, null, 2));
}

// NEW: build sane fee overrides (EIP-1559) based on latest base fee + env floors
async function feeOverrides() {
  if (isLocal(hre.network.name)) return {};

  const net = hre.network.name;
  const isPoly = isPolygon(net);
  const isSep = net === "sepolia";

  // Network-aware floors, overridable by env
  const minTipGwei = Number(
    process.env.PRIORITY_FEE_GWEI ||
      process.env.MIN_TIP_GWEI ||
      (isSep ? 1.5 : isPoly ? 5 : 2)
  );
  const minMaxGwei = Number(
    process.env.MIN_MAX_FEE_GWEI || (isSep ? 5 : isPoly ? 60 : 30)
  );
  const multiplier = Number(process.env.FEE_MULTIPLIER || (isSep ? 2 : 2));

  const fee = await hre.ethers.provider.getFeeData();
  const latest = await hre.ethers.provider.getBlock("latest").catch(() => undefined);
  const base = latest?.baseFeePerGas ?? fee.lastBaseFeePerGas ?? fee.maxFeePerGas ?? 0n;

  const tipFloor = hre.ethers.parseUnits(String(minTipGwei), "gwei");
  let tip = fee.maxPriorityFeePerGas ?? tipFloor;
  if (tip < tipFloor) tip = tipFloor;

  const minMax = hre.ethers.parseUnits(String(minMaxGwei), "gwei");
  const suggestedMax = base > 0n ? base * BigInt(multiplier) + tip : tip * 10n;
  let maxFee = fee.maxFeePerGas ?? 0n;
  if (maxFee < suggestedMax) maxFee = suggestedMax;
  if (maxFee < minMax) maxFee = minMax;

  if (!feeOverrides._logged) {
    console.log(
      `Fee overrides -> net=${net}, base≈${base ? Number(base) / 1e9 : 0} gwei, tip=${Number(tip) / 1e9} gwei, maxFee=${Number(maxFee) / 1e9} gwei`
    );
    feeOverrides._logged = true;
  }
  return { maxFeePerGas: maxFee, maxPriorityFeePerGas: tip };
}

// NEW: get constructor inputs from ABI for a factory/contract name
async function getConstructorInputs(factoryName) {
  const artifact = await hre.artifacts.readArtifact(factoryName);
  const ctor = artifact.abi.find((x) => x.type === "constructor");
  return ctor?.inputs ?? [];
}

async function waitConf(tx) {
  if (!tx) return;
  // MORE confs on Polygon to stabilize verification/indexing
  const confs = isLocal(hre.network.name) ? 1 : isPolygon(hre.network.name) ? 5 : 2;
  await tx.wait(confs);
}

function explorerBase(network) {
  if (network === "sepolia") return "https://sepolia.etherscan.io";
  // NEW: polygon explorers
  if (network === "polygon" || network === "matic") return "https://polygonscan.com";
  if (network === "amoy") return "https://amoy.polygonscan.com";
  if (network === "mumbai" || network === "maticmum" || network === "polygonMumbai") return "https://mumbai.polygonscan.com";
  return "";
}

// NEW: safe wait for deployment with timeout + polling
async function waitForDeploymentSafe(name, contract, txHash) {
  const start = Date.now();
  const provider = hre.ethers.provider;
  while (true) {
    // if contract has been deployed, break
    try {
      await contract.getAddress(); // ensures deployment promise resolves
      const addr = contract.target;
      if (addr) {
        // double-check code exists
        const code = await provider.getCode(addr);
        if (code && code !== "0x") return;
      }
    } catch {}
    // poll receipt
    if (txHash) {
      const rc = await provider.getTransactionReceipt(txHash);
      if (rc && rc.blockNumber) return;
    }
    if (Date.now() - start > MAX_PENDING_MS) {
      console.warn(`${name}: deployment pending > ${Math.round(MAX_PENDING_MS / 1000)}s. Consider increasing fees via env: PRIORITY_FEE_GWEI, MIN_MAX_FEE_GWEI, FEE_MULTIPLIER.`);
      throw new Error(`${name} deployment timeout`);
    }
    await waitMs(5000);
  }
}

// NEW: load previous deployments file if present
function loadPrevious() {
  try {
    const outDir = path.join(__dirname, "..", "deployments");
    const outFile = path.join(outDir, `${hre.network.name}.json`);
    if (fs.existsSync(outFile)) {
      const data = JSON.parse(fs.readFileSync(outFile, "utf8"));
      if (data?.libraries && typeof data.libraries === "object") {
        Object.assign(deployedLibs, data.libraries);
      }
      return data;
    }
  } catch (e) {
    console.warn("Failed to load previous deployments:", e?.message || e);
  }
  return null;
}

// NEW: deploy a single library if not already deployed (reuses previous if available)
async function deployLibrary(libName) {
  if (deployedLibs[libName]) return deployedLibs[libName];
  const LF = await hre.ethers.getContractFactory(libName);
  const overrides = await feeOverrides();
  const lib = await LF.deploy(overrides);
  const tx = lib.deploymentTransaction?.();
  if (tx?.hash) console.log(`Library ${libName} tx: ${tx.hash}`);
  await waitForDeploymentSafe(`Library ${libName}`, lib, tx?.hash);
  const addr = await lib.getAddress();
  deployedLibs[libName] = addr;
  console.log(`Library ${libName}: ${addr}`);
  return addr;
}

// NEW: ensure a set of libraries are deployed and return mapping for linking
async function ensureLibraries(libNames = []) {
  const libs = {};
  for (const name of libNames) {
    libs[name] = await deployLibrary(name);
  }
  return libs;
}

// Hardened verify that can fall back to fully-qualified name on ambiguity
async function verify(address, args = [], libraries = undefined, contractName = undefined) {
  if (isLocal(hre.network.name) || SKIP_VERIFY) {
    console.log(`Skip verify on '${hre.network.name}' for ${address}`);
    return;
  }
  // NEW: ensure Etherscan API key on Sepolia
  if (hre.network.name === "sepolia" && !process.env.ETHERSCAN_API_KEY) {
    console.warn("ETHERSCAN_API_KEY is missing. Skipping verification on sepolia.");
    return;
  }

  const baseDelay = VERIFY_DELAY_MS;

  // CHANGED: precompute FQN when contractName provided and always pass it to verifier
  let fqn;
  if (contractName) {
    try {
      const art = await hre.artifacts.readArtifact(contractName);
      if (art?.sourceName) fqn = `${art.sourceName}:${art.contractName}`;
    } catch {}
  }

  for (let attempt = 1; attempt <= VERIFY_RETRIES; attempt++) {
    try {
      await waitMs(baseDelay * attempt);
      const params = { address, constructorArguments: args, libraries };
      // always include FQN when available (particularly important for libraries)
      if (fqn) params.contract = fqn;
      await hre.run("verify:verify", params);
      console.log("Verified:", address, fqn ? `(via ${fqn})` : "");
      return;
    } catch (e) {
      const msg = String(e?.message || e);
      if (msg.includes("Already Verified")) {
        console.log("Already verified:", address);
        return;
      }
      if (attempt === VERIFY_RETRIES) {
        console.warn(`Verify failed (final) for ${address}:`, msg);
      } else {
        console.warn(`Verify failed (attempt ${attempt}/${VERIFY_RETRIES}) for ${address}:`, msg);
      }
    }
  }
}

async function deploy(name, factoryName, args = [], options = {}) {
  // options.libraries can be provided, otherwise we auto-detect on failure
  let libraries = options.libraries;
  let F;
  try {
    F = await hre.ethers.getContractFactory(factoryName, libraries ? { libraries } : undefined);
  } catch (e) {
    const msg = String(e?.message || e);
    // NEW: auto-detect missing libraries and link them
    if (msg.includes("missing links")) {
      const missing = Array.from(
        msg.matchAll(/^\*\s+.*?:([A-Za-z0-9_]+)\s*$/gm)
      ).map((m) => m[1]);
      if (missing.length > 0) {
        console.log(`Auto-linking required libraries for ${factoryName}: ${missing.join(", ")}`);
        const ensured = await ensureLibraries(missing);
        libraries = { ...(libraries || {}), ...ensured };
        F = await hre.ethers.getContractFactory(factoryName, { libraries });
      } else {
        throw e;
      }
    } else {
      throw e;
    }
  }

  // NEW: determine required constructor arg count from ABI and adjust
  const ctorInputs = await getConstructorInputs(factoryName);
  const needed = ctorInputs.length;
  if (args.length < needed) {
    throw new Error(
      `${factoryName} constructor requires ${needed} arg(s) but got ${args.length}. ` +
      `Inputs: [${ctorInputs.map((i) => `${i.type} ${i.name || ""}`.trim()).join(", ")}]`
    );
  }
  let usedArgs = args;
  if (args.length > needed) {
    usedArgs = args.slice(0, needed);
    console.warn(
      `Warning: ${factoryName} expects ${needed} constructor arg(s); trimming provided args ` +
      `from ${args.length} to ${needed}: ${JSON.stringify(usedArgs)}`
    );
  }

  const overrides = await feeOverrides();
  const c = await F.deploy(...usedArgs, overrides);
  const tx = c.deploymentTransaction();
  if (tx?.hash) {
    console.log(`${name} tx: ${tx.hash}`);
    setTimeout(() => {
      console.warn(`${name}: tx ${tx.hash} still pending after 60s (maxFee/tip applied). Will mine when base fee allows.`);
    }, 60_000);
  }

  // NEW: safe wait with timeout
  await waitForDeploymentSafe(name, c, tx?.hash);

  // compute gas stats
  let costEth = "n/a", gasUsedStr = "n/a", gasPriceGwei = "n/a";
  try {
    if (tx?.hash) {
      const rc = await hre.ethers.provider.getTransactionReceipt(tx.hash);
      const gasUsed = rc?.gasUsed;
      const eff = rc?.effectiveGasPrice ?? rc?.gasPrice;
      if (gasUsed && eff) {
        const cost = gasUsed * eff;
        costEth = hre.ethers.formatEther(cost);
        gasUsedStr = gasUsed.toString();
        gasPriceGwei = (Number(eff) / 1e9).toFixed(2);
      }
    }
  } catch {}

  const addr = await c.getAddress();
  console.log(`${name}: ${addr} (ctor args: ${JSON.stringify(usedArgs)})`);
  console.log(`  ↳ gasUsed=${gasUsedStr}, gasPrice≈${gasPriceGwei} gwei, cost≈${costEth} ETH`);
  // NEW: return tx hash for persistence
  return { addr, c, args: usedArgs, libraries, fresh: true, txHash: tx?.hash };
}

// NEW: idempotent attach-or-deploy using previous deployments file (unless FORCE_REDEPLOY=1)
async function attachOrDeploy(name, factoryName, args = [], options = {}, prev = {}) {
  // map human name to field in json
  const keyMap = {
    Storage: "storage",
    Core: "core",
    Router: "router",
    Media: "media",
    Updates: "updates",
    Refunds: "refunds",
    Governance: "governance",
    Analytics: "analytics",
    Security: "security",
    Web3: "web3",
  };
  const field = keyMap[name] || name.toLowerCase();
  const prevAddr = prev?.[field];

  // NEW: force redeploy if listed in REDEPLOY_LIST
  const forceThisOne = FORCE_REDEPLOY || REDEPLOY_LIST.includes(name.toLowerCase()) || REDEPLOY_LIST.includes(field);

  if (!forceThisOne && prevAddr) {
    try {
      const code = await hre.ethers.provider.getCode(prevAddr);
      if (code && code !== "0x") {
        const c = await hre.ethers.getContractAt(factoryName, prevAddr);
        console.log(`${name}: reusing ${prevAddr} from deployments/${hre.network.name}.json`);
        return { addr: prevAddr, c, args, libraries: undefined, fresh: false };
      }
    } catch (e) {
      console.warn(`${name}: cannot reuse previous address ${prevAddr}:`, e?.message || e);
    }
  } else if (prevAddr && forceThisOne) {
    console.log(`${name}: forced redeploy requested, ignoring previous address ${prevAddr}`);
  }
  return await deploy(name, factoryName, args, options);
}

async function main() {
  console.log(`\n=== Deploy start | network: ${hre.network.name} ===`);
  if (isLocal(hre.network.name)) {
    // friendlier hint for any testnet, include Polygon Amoy example
    console.error("Run with --network <testnet>. Examples:");
    console.error("  npx hardhat run scripts/deploy-and-verify.js --network sepolia");
    console.error("  npx hardhat run scripts/deploy-and-verify.js --network amoy");
    process.exit(1);
  }

  // NEW: load previous deployments and preload library addresses
  const previous = loadPrevious();

  // NEW: block Amoy deploys unless explicitly allowed
  if (hre.network.name === "amoy" && process.env.ALLOW_AMOY !== "1") {
    console.error("Amoy deployment temporarily disabled (insufficient funds). Set ALLOW_AMOY=1 to enable.");
    process.exit(1);
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "ETH");
  if (balance === 0n) {
    console.warn("Warning: deployer balance is 0. Get test ETH from faucet.");
  }

  // NEW: show chainId and block for context
  try {
    const net = await hre.ethers.provider.getNetwork();
    const blk = await hre.ethers.provider.getBlockNumber();
    console.log(`ChainId: ${Number(net.chainId)} | Block: ${blk}`);
  } catch {}

  // NEW: support OWNER_ADDRESS override for constructors
  const owner =
    (process.env.OWNER_ADDRESS && hre.ethers.isAddress(process.env.OWNER_ADDRESS)
      ? process.env.OWNER_ADDRESS
      : deployer.address);
  if (owner !== deployer.address) {
    console.log("Owner (overridden):", owner);
  }

  // Kolejność i argumenty:
  const storage = await attachOrDeploy("Storage", "PoliDaoStorage", [], {}, previous);
  // Core(storage, owner)
  const core = await attachOrDeploy("Core", "PoliDaoCore", [storage.addr, owner], {}, previous);
  const router = await attachOrDeploy("Router", "PoliDaoRouter", [core.addr], {}, previous);
  const media = await attachOrDeploy("Media", "PoliDaoMedia", [core.addr], {}, previous);
  const updates = await attachOrDeploy("Updates", "PoliDaoUpdates", [core.addr, media.addr], {}, previous);
  // Refunds(core, owner)
  const refunds = await attachOrDeploy("Refunds", "PoliDaoRefunds", [core.addr, owner], {}, previous);
  const governance = await attachOrDeploy("Governance", "PoliDaoGovernance", [core.addr], {}, previous);
  const analytics = await attachOrDeploy("Analytics", "PoliDaoAnalytics", [core.addr], {}, previous);
  const security = await attachOrDeploy("Security", "PoliDaoSecurity", [core.addr], {}, previous);
  const web3 = await attachOrDeploy("Web3", "PoliDaoWeb3", [], {}, previous);

  // NEW: summarize whether anything was newly deployed
  const all = [storage, core, router, media, updates, refunds, governance, analytics, security, web3];
  const freshCount = all.filter((x) => x?.fresh).length;
  if (freshCount === 0) {
    console.log("No new deployments performed (reused previous addresses).");
    console.log("To deploy fresh contracts set FORCE_REDEPLOY=1 or specify REDEPLOY_LIST, e.g.:");
    console.log('  FORCE_REDEPLOY=1 npx hardhat run scripts/deploy-and-verify.js --network sepolia');
    console.log('  REDEPLOY_LIST=Router,Media npx hardhat run scripts/deploy-and-verify.js --network sepolia');
  }

  // Wire router <-> core/storage so Router is the single entry point
  const maybeCall = async (contract, fn, params = []) => {
    if (!contract || typeof contract[fn] !== "function") return;
    try {
      const tx = await contract[fn](...params);
      await waitConf(tx);
      console.log(`wired: ${fn}(${params.map(String).join(", ")}) on ${contract.target || "contract"}`);
    } catch (e) {
      console.warn(`wire failed: ${fn} on ${contract.target || "contract"} -> ${e?.message || e}`);
    }
  };

  await maybeCall(core.c, "setRouter", [router.addr]);
  await maybeCall(storage.c, "setRouter", [router.addr]);
  await maybeCall(router.c, "setCore", [core.addr]);
  await maybeCall(router.c, "setStorage", [storage.addr]);

  const modules = [media, updates, refunds, governance, analytics, security, web3].filter(Boolean);
  for (const m of modules) {
    await maybeCall(m.c, "setRouter", [router.addr]);
  }

  // NEW: optional readback checks if getters exist (best-effort)
  const tryRead = async (label, fn) => {
    try {
      const v = await fn();
      console.log(`check ${label}: ${v}`);
    } catch {}
  };
  await tryRead("router.core()", async () => (router.c.core ? router.c.core() : "n/a"));
  await tryRead("router.storage()", async () => (router.c.storage ? router.c.storage() : "n/a"));

  // Link do eksploratora
  const base = explorerBase(hre.network.name);
  if (base) {
    console.log("\nExplorer links:");
    console.log(`${base}/address/${storage.addr}`);
    console.log(`${base}/address/${core.addr}`);
    console.log(`${base}/address/${router.addr}`);
    console.log(`${base}/address/${media.addr}`);
    console.log(`${base}/address/${updates.addr}`);
    console.log(`${base}/address/${refunds.addr}`);
    console.log(`${base}/address/${governance.addr}`);
    console.log(`${base}/address/${analytics.addr}`);
    console.log(`${base}/address/${security.addr}`);
    console.log(`${base}/address/${web3.addr}`);
  }

  // Weryfikacja
  if (freshCount > 0) {
    console.log("\nVerifying (please wait)...");
  } else {
    console.log("\nNothing to verify (all contracts reused). Use FORCE_REVERIFY=1 to re-verify anyway.");
  }
  const shouldVerify = (x) => x && (x.fresh || FORCE_REVERIFY);
  // CHANGED: verify libs also when FORCE_REVERIFY is set (already present) and print a short summary
  if ((VERIFY_LIBS || FORCE_REVERIFY) && Object.keys(deployedLibs).length > 0) {
    console.log(`Verifying libraries: ${Object.keys(deployedLibs).join(", ")}`);
    for (const [lib, addr] of Object.entries(deployedLibs)) {
      await verify(addr, [], undefined, lib);
    }
  }
  if (shouldVerify(storage)) await verify(storage.addr, storage.args, storage.libraries, "PoliDaoStorage");
  if (shouldVerify(core)) await verify(core.addr, core.args, core.libraries, "PoliDaoCore");
  if (shouldVerify(router)) await verify(router.addr, router.args, router.libraries, "PoliDaoRouter");
  if (shouldVerify(media)) await verify(media.addr, media.args, media.libraries, "PoliDaoMedia");
  if (shouldVerify(updates)) await verify(updates.addr, updates.args, updates.libraries, "PoliDaoUpdates");
  if (shouldVerify(refunds)) await verify(refunds.addr, refunds.args, refunds.libraries, "PoliDaoRefunds");
  if (shouldVerify(governance)) await verify(governance.addr, governance.args, governance.libraries, "PoliDaoGovernance");
  if (shouldVerify(analytics)) await verify(analytics.addr, analytics.args, analytics.libraries, "PoliDaoAnalytics");
  if (shouldVerify(security)) await verify(security.addr, security.args, security.libraries, "PoliDaoSecurity");
  if (shouldVerify(web3)) await verify(web3.addr, web3.args, web3.libraries, "PoliDaoWeb3");

  // Zapis do deployments/<network>.json
  const out = {
    network: hre.network.name,
    deployer: deployer.address,
    owner,
    entrypoint: router.addr, // FE should use this
    storage: storage.addr,
    core: core.addr,
    router: router.addr,
    media: media.addr,
    updates: updates.addr,
    refunds: refunds.addr,
    governance: governance.addr,
    analytics: analytics.addr,
    security: security.addr,
    web3: web3.addr,
    // NEW: persist libraries used (if any)
    libraries: deployedLibs,
    // NEW: persist tx hashes for fresh deployments (if available)
    txs: {
      ...(storage.txHash ? { storage: storage.txHash } : {}),
      ...(core.txHash ? { core: core.txHash } : {}),
      ...(router.txHash ? { router: router.txHash } : {}),
      ...(media.txHash ? { media: media.txHash } : {}),
      ...(updates.txHash ? { updates: updates.txHash } : {}),
      ...(refunds.txHash ? { refunds: refunds.txHash } : {}),
      ...(governance.txHash ? { governance: governance.txHash } : {}),
      ...(analytics.txHash ? { analytics: analytics.txHash } : {}),
      ...(security.txHash ? { security: security.txHash } : {}),
      ...(web3.txHash ? { web3: web3.txHash } : {}),
    },
  };
  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${hre.network.name}.json`);
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2));
  console.log(`\nSaved: deployments/${hre.network.name}.json`);

  // NEW: export Router ABI and minimal addresses for FE (Router-only ABI per unified-storage design)
  try {
    const routerArtifact = await hre.artifacts.readArtifact("PoliDaoRouter");
    const feDir = path.join(__dirname, "..", "deployments", "fe");
    const abiFile = path.join(feDir, `router.abi.json`);
    const addrsFile = path.join(feDir, `addresses.${hre.network.name}.json`);
    writeJsonSync(abiFile, routerArtifact.abi);
    writeJsonSync(addrsFile, {
      network: hre.network.name,
      entrypoint: router.addr,
      router: router.addr,
      core: core.addr,
      storage: storage.addr,
    });
    console.log(`Exported FE artifacts: ${path.relative(path.join(__dirname, ".."), abiFile)} , ${path.relative(path.join(__dirname, ".."), addrsFile)}`);
  } catch (e) {
    console.warn("Failed to export FE artifacts:", e?.message || e);
  }

  console.log("=== Deploy end ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});