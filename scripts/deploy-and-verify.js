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
// NEW: prefer verifying without recompile to avoid bytecode drift
const VERIFY_NO_COMPILE = process.env.VERIFY_NO_COMPILE ? process.env.VERIFY_NO_COMPILE === "1" : true;
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
  // BigInt-safe JSON stringify
  const replacer = (_k, v) => (typeof v === "bigint" ? v.toString() : v);
  fs.writeFileSync(fp, JSON.stringify(obj, replacer, 2));
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

async function waitConf(txOrHash, conf = (hre.network.config.confirmations || 2), timeoutMs = MAX_PENDING_MS) {
  // ethers v6: pozwól na oba przypadki
  if (typeof txOrHash === "string") {
    // czekaj po hashu
    return await hre.ethers.provider.waitForTransaction(txOrHash, conf, timeoutMs);
  }
  if (txOrHash && typeof txOrHash.wait === "function") {
    return await txOrHash.wait(conf);
  }
  throw new Error("waitConf: unsupported tx type");
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
  if (process.env.IGNORE_PREVIOUS === "1") return {}; // <<< IGNORE PREVIOUS
  try {
    const fp = path.join(__dirname, "..", "deployments", `${hre.network.name}.json`);
    const raw = fs.readFileSync(fp, "utf8");
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

// NEW: deploy a single library if not already deployed (reuses previous if available)
async function deployLibrary(libName) {
  const forceLibs = process.env.REDEPLOY_LIBS === "1";
  if (!forceLibs && deployedLibs[libName]) return deployedLibs[libName];

  const previous = loadPrevious();
  if (!forceLibs && previous.libraries && previous.libraries[libName]) {
    deployedLibs[libName] = previous.libraries[libName];
    return deployedLibs[libName];
  }

  const Factory = await hre.ethers.getContractFactory(`contracts/libraries/${libName}.sol:${libName}`);
  const fee = await feeOverrides();
  const c = await Factory.deploy({ ...fee });

  const txResp = c.deploymentTransaction(); // ethers v6 TransactionResponse
  console.log(`Library ${libName} tx: ${txResp.hash}`);
  await waitConf(txResp);                   // <<< przekazujemy TransactionResponse
  const addr = await c.getAddress();
  console.log(`Library ${libName}: ${addr}`);

  deployedLibs[libName] = addr;
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

// NEW: quick preflight check to compare creation bytecode with tx.input
async function preflightCreationMatches(contractRef, args = [], txHash, libraries = undefined) {
  try {
    if (!txHash) return true;
    const F = await hre.ethers.getContractFactory(contractRef, libraries ? { libraries } : undefined);
    const deployTx = await F.getDeployTransaction(...args);
    const onchainTx = await hre.ethers.provider.getTransaction(txHash);
    if (!deployTx?.data || !onchainTx?.data) return true;
    return String(deployTx.data).toLowerCase() === String(onchainTx.data).toLowerCase();
  } catch {
    // if we cannot preflight, don't block verification
    return true;
  }
}

// Hardened verify that can fall back to fully-qualified name on ambiguity
async function verify(address, args = [], libraries = undefined, contractName = undefined, txHash = undefined) {
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

  // CHANGED: precompute FQN when contractName provided; accept FQN directly
  let fqn;
  if (contractName) {
    if (contractName.includes(":")) {
      fqn = contractName;
    } else {
      try {
        const art = await hre.artifacts.readArtifact(contractName);
        if (art?.sourceName) fqn = `${art.sourceName}:${art.contractName}`;
      } catch {}
    }
  }

  // NEW: preflight creation bytecode check (diagnostic)
  const refForPreflight = fqn || contractName;
  if (refForPreflight && txHash) {
    const ok = await preflightCreationMatches(refForPreflight, args, txHash, libraries);
    if (!ok) {
      console.warn(`Preflight: creation bytecode mismatch for ${address}. Verification aborted to avoid misleading 'bytecode did not match'.`);
      console.warn(`Hints:`);
      console.warn(` - Użyj dokładnie tego samego builda, z którego był deploy (solc/optimizer/evmVersion/sources).`);
      console.warn(` - Albo wykonaj świeży deploy tego kontraktu (np. REDEPLOY_LIST=Router lub FORCE_REDEPLOY=1).`);
      console.warn(` - Jeśli weryfikujesz stary deploy, wróć do odpowiedniego commita i skompiluj przed verify.`);
      return;
    }
  }

  for (let attempt = 1; attempt <= VERIFY_RETRIES; attempt++) {
    try {
      await waitMs(baseDelay * attempt);
      const params = { address, constructorArguments: args, libraries, noCompile: VERIFY_NO_COMPILE };
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
  const { libraries } = options;
  const Factory = await hre.ethers.getContractFactory(factoryName, { libraries });
  const tx = await Factory.deploy(...args);
  const contract = await tx.waitForDeployment();
  const addr = await contract.getAddress();
  return { name, factoryName, addr, args, libraries, txHash: tx.deploymentTransaction().hash };
}

// [ADD] attachOrDeploy: użyj poprzednich adresów lub wykonaj świeży deploy
async function attachOrDeploy(name, factoryName, args = [], options = {}, previous = {}) {
  const key = String(name).toLowerCase();
  const force = FORCE_REDEPLOY || REDEPLOY_LIST.includes(key);
  const prevAddr = previous?.[key];

  // Reuse poprzedniego deployu (attach), jeśli nie wymuszono redeploy
  if (prevAddr && !force) {
    const c = await hre.ethers.getContractAt(factoryName, prevAddr);
    const prevArgs = previous?.args?.[key] || args;
    const prevTx = previous?.txs?.[key];
    return {
      name,
      factoryName,
      addr: prevAddr,
      args: prevArgs,
      libraries: options?.libraries,
      txHash: prevTx,
      fresh: false,
      c,
    };
  }

  // Świeży deploy
  const deployed = await deploy(name, factoryName, args, options);
  const c = await hre.ethers.getContractAt(factoryName, deployed.addr);
  return { ...deployed, fresh: true, c };
}

// [ADD] getBuildInfoSummary: metadane builda do zapisu w deployments JSON
async function getBuildInfoSummary(nameOrFqn) {
  try {
    let fqn = nameOrFqn;
    if (!fqn.includes(":")) {
      const art = await hre.artifacts.readArtifact(nameOrFqn);
      if (art?.sourceName) fqn = `${art.sourceName}:${art.contractName}`;
    }
    const bi = await hre.artifacts.getBuildInfo(fqn);
    if (!bi) return undefined;

    const settings = bi.input?.settings || {};
    const optimizer = settings.optimizer || {};
    return {
      solcVersion: bi.solcVersion || bi.solcLongVersion,
      evmVersion: settings.evmVersion,
      viaIR: settings.viaIR === true,
      optimizer: {
        enabled: optimizer.enabled === true,
        runs: optimizer.runs,
      },
      // opcjonalnie: lista plików źródłowych (bez treści)
      sources: Object.keys(bi.input?.sources || {}),
    };
  } catch {
    return undefined;
  }
}

// NEW: ensureLibrariesFor: wykryj z artefaktu, zdeployuj i zwróć mapę FQN->addr
async function ensureLibrariesFor(factoryName) {
  const artifact = await hre.artifacts.readArtifact(factoryName);
  const linkRefs = artifact.linkReferences || {};
  const fqnToAddr = {};

  // wczytaj poprzednie biblioteki (jeśli zapisane)
  const previous = loadPrevious();
  const prevLibs = (previous && previous.libraries) || {};

  for (const [source, libs] of Object.entries(linkRefs)) {
    for (const libName of Object.keys(libs)) {
      const fqn = `${source}:${libName}`;

      // spróbuj użyć adresu z pamięci/skrzynki
      let addr = deployedLibs[libName] || deployedLibs[fqn] || prevLibs[libName] || prevLibs[fqn];

      if (!addr) {
        // zdeployuj bibliotekę po nazwie (nasza deployLibrary używa FQN do fabryki)
        addr = await deployLibrary(libName);
      }

      // zapamiętaj pod kluczem prostym i FQN (na przyszłość)
      deployedLibs[libName] = addr;
      deployedLibs[fqn] = addr;

      // mapowanie wymagane przez ethers: FQN -> address
      fqnToAddr[fqn] = addr;
    }
  }
  return fqnToAddr;
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

  // Core – zapewnij biblioteki jeśli wymagane (np. DonationLogic/WithdrawLogic/FundraiserLogic)
  const coreLibs = await ensureLibrariesFor("PoliDaoCore");
  const storage = await attachOrDeploy("Storage", "PoliDaoStorage", [], {}, previous);
  const core = await attachOrDeploy("Core", "PoliDaoCore", [storage.addr, owner], { libraries: coreLibs }, previous);

  // Router
  const router = await attachOrDeploy("Router", "contracts/router/PoliDaoRouter.sol:PoliDaoRouter", [core.addr], {}, previous);

  // Extension – tu miałeś crash: podlinkuj ExtensionLogic i LocationLogic
  const extLibs = await ensureLibrariesFor("PoliDaoExtension");
  const extension = await attachOrDeploy("Extension", "PoliDaoExtension", [], { libraries: extLibs }, previous);

  // Pozostałe moduły (bezpiecznie próbujemy linkować; jeśli nie mają linków, mapka będzie pusta)
  const mediaLibs = await ensureLibrariesFor("PoliDaoMedia");
  const media = await attachOrDeploy("Media", "PoliDaoMedia", [core.addr], { libraries: mediaLibs }, previous);

  const updatesLibs = await ensureLibrariesFor("PoliDaoUpdates");
  const updates = await attachOrDeploy("Updates", "PoliDaoUpdates", [core.addr, media.addr], { libraries: updatesLibs }, previous);

  const governanceLibs = await ensureLibrariesFor("PoliDaoGovernance");
  const governance = await attachOrDeploy("Governance", "PoliDaoGovernance", [core.addr], { libraries: governanceLibs }, previous);

  const analyticsLibs = await ensureLibrariesFor("PoliDaoAnalytics");
  const analytics = await attachOrDeploy("Analytics", "PoliDaoAnalytics", [core.addr], { libraries: analyticsLibs }, previous);

  const securityLibs = await ensureLibrariesFor("PoliDaoSecurity");
  const security = await attachOrDeploy("Security", "PoliDaoSecurity", [core.addr], { libraries: securityLibs }, previous);

  const web3Libs = await ensureLibrariesFor("PoliDaoWeb3");
  const web3 = await attachOrDeploy("Web3", "PoliDaoWeb3", [], { libraries: web3Libs }, previous);

  // NEW: summarize whether anything was newly deployed
  const all = [storage, core, router, extension, media, updates, governance, analytics, security, web3];
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

  // [NEW] always bind Storage -> Core (required for onlyCore)
  await maybeCall(storage.c, "setCore", [core.addr]);

  // [UPDATED] set Router on Core and Storage and grant permissions
  await maybeCall(core.c, "setRouterContract", [router.addr]);
  await maybeCall(storage.c, "setAuthorizedRouter", [router.addr]);
  // grant Router permissions where supported
  await maybeCall(core.c, "authorizeContract", [router.addr]);
  await maybeCall(storage.c, "authorizeContract", [router.addr]);
  // try to deauthorize previous router if different (best-effort)
  if (previous?.router && previous.router !== router.addr) {
    await maybeCall(core.c, "deauthorizeContract", [previous.router]);
    await maybeCall(storage.c, "deauthorizeContract", [previous.router]);
  }

  // [ADDED] wire Security to Core and Router (best-effort)
  await maybeCall(security.c, "setCore", [core.addr]);
  await maybeCall(router.c, "setSecurity", [security.addr]);

  // [NEW] if only Storage is fresh and Core is reused, try to point each other (best-effort)
  const storageWasFresh = !!storage?.fresh;
  const coreWasFresh = !!core?.fresh;
  if (storageWasFresh && !coreWasFresh) {
    // Core -> Storage (try multiple setter names)
    await maybeCall(core.c, "setStorage", [storage.addr]);
    await maybeCall(core.c, "setStorageContract", [storage.addr]);
    await maybeCall(core.c, "setStorageAddress", [storage.addr]);
    // Storage -> Core (already wired above)
  }

  // Wire Extension
  await maybeCall(extension.c, "initialize", [storage.addr, core.addr]);       // onlyOwner, idempotent
  await maybeCall(storage.c, "authorizeContract", [extension.addr]);
  await maybeCall(core.c, "setExtensionsContract", [extension.addr]);
  // (opcjonalnie) alternatywne nazwy jeżeli Core ma inny setter
  await maybeCall(core.c, "setExtensionContract", [extension.addr]);
  await maybeCall(core.c, "setExtension", [extension.addr]);

  const modules = [media, updates, governance, analytics, security, web3].filter(Boolean);
  for (const m of modules) {
    await maybeCall(m.c, "setRouter", [router.addr]);
  }

  // [NEW] Whitelist USDC token (env override or provided address)
  try {
    const usdc = process.env.USDC_TOKEN || "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
    if (usdc && hre.ethers.isAddress(usdc)) {
      await maybeCall(storage.c, "addWhitelistedToken", [usdc]);
      console.log(`USDC whitelisted: ${usdc}`);
    }
  } catch (e) {
    console.warn("Whitelist USDC failed:", e?.message || e);
  }

  // Link do eksploratora
  const base = explorerBase(hre.network.name);
  if (base) {
    console.log("\nExplorer links:");
    console.log(`${base}/address/${storage.addr}`);
    console.log(`${base}/address/${core.addr}`);
    console.log(`${base}/address/${router.addr}`);
    console.log(`${base}/address/${extension.addr}`);
    console.log(`${base}/address/${media.addr}`);
    console.log(`${base}/address/${updates.addr}`);
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
  if (shouldVerify(storage)) await verify(storage.addr, storage.args, storage.libraries, "PoliDaoStorage", storage.txHash);
  if (shouldVerify(core)) await verify(core.addr, core.args, core.libraries, "contracts/core/PoliDaoCore.sol:PoliDaoCore", core.txHash);
  if (shouldVerify(router)) await verify(router.addr, router.args, router.libraries, "contracts/router/PoliDaoRouter.sol:PoliDaoRouter", router.txHash);
  if (shouldVerify(extension)) await verify(extension.addr, extension.args, extension.libraries, "PoliDaoExtension", extension.txHash);
  if (shouldVerify(media)) await verify(media.addr, media.args, media.libraries, "PoliDaoMedia", media.txHash);
  if (shouldVerify(updates)) await verify(updates.addr, updates.args, updates.libraries, "PoliDaoUpdates", updates.txHash);
  if (shouldVerify(governance)) await verify(governance.addr, governance.args, governance.libraries, "PoliDaoGovernance", governance.txHash);
  if (shouldVerify(analytics)) await verify(analytics.addr, analytics.args, analytics.libraries, "PoliDaoAnalytics", analytics.txHash);
  if (shouldVerify(security)) await verify(security.addr, security.args, security.libraries, "PoliDaoSecurity", security.txHash);
  if (shouldVerify(web3)) await verify(web3.addr, web3.args, web3.libraries, "PoliDaoWeb3", web3.txHash);

  // Zapis do deployments/<network>.json
  const out = {
    network: hre.network.name,
    deployer: deployer.address,
    owner,
    entrypoint: router.addr, // FE should use this
    storage: storage.addr,
    core: core.addr,
    router: router.addr,
    extension: extension.addr,
    media: media.addr,
    updates: updates.addr,
    governance: governance.addr,
    analytics: analytics.addr,
    security: security.addr,
    web3: web3.addr,
    // Persist constructor args for reproducible verify
    args: {
      storage: storage.args || [],
      core: core.args || [],
      router: router.args || [],
      extension: extension.args || [],
      media: media.args || [],
      updates: updates.args || [],
      governance: governance.args || [],
      analytics: analytics.args || [],
      security: security.args || [],
      web3: web3.args || [],
    },
    libraries: deployedLibs,
    // NEW: persist tx hashes for fresh deployments (if available)
    txs: {
      ...(storage.txHash ? { storage: storage.txHash } : {}),
      ...(core.txHash ? { core: core.txHash } : {}),
      ...(router.txHash ? { router: router.txHash } : {}),
      ...(extension.txHash ? { extension: extension.txHash } : {}),
      ...(media.txHash ? { media: media.txHash } : {}),
      ...(updates.txHash ? { updates: updates.txHash } : {}),
      ...(governance.txHash ? { governance: governance.txHash } : {}),
      ...(analytics.txHash ? { analytics: analytics.txHash } : {}),
      ...(security.txHash ? { security: security.txHash } : {}),
      ...(web3.txHash ? { web3: web3.txHash } : {}),
    },
    build: {},
  };

  // NEW: capture build metadata for diagnostics (only for fresh ones)
  for (const item of all) {
    if (!item?.fresh) continue;
    try {
      const meta = await getBuildInfoSummary(item.factoryName || "");
      if (meta) {
        out.build[item.name] = meta;
        console.log(`Captured build info for ${item.name}`);
      }
    } catch (e) {
      console.warn(`Failed to capture build info for ${item.name}: ${e?.message || e}`);
    }
  }

  // Zapisz do pliku
  const fp = path.join(__dirname, "..", "deployments", `${hre.network.name}.json`);
  writeJsonSync(fp, out);
  console.log(`\n=== Deploy done | network: ${hre.network.name} ===`);
}

// Uruchom skrypt
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });