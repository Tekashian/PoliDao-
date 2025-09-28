/* eslint-disable no-console */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const isLocal = (n) => n === "hardhat" || n === "localhost";
// NEW: detect polygon networks for better verify/confirm settings
const isPolygon = (n) =>
  ["polygon", "amoy", "mumbai", "matic", "maticmum", "polygonMumbai"].includes(n);
const waitMs = (ms) => new Promise((r) => setTimeout(r, ms));

// NEW: keep track of deployed libraries (name -> address)
const deployedLibs = {};

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

// NEW: deploy a single library if not already deployed
async function deployLibrary(libName) {
  if (deployedLibs[libName]) return deployedLibs[libName];
  const LF = await hre.ethers.getContractFactory(libName);
  const lib = await LF.deploy();
  await lib.waitForDeployment();
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

async function verify(address, args = [], libraries = undefined) {
  if (isLocal(hre.network.name)) {
    console.log(`Skip verify on '${hre.network.name}' for ${address}`);
    return;
  }
  try {
    // krótka pauza, żeby indeksery nadążyły
    // LONGER pause on Polygon testnets
    await waitMs(isPolygon(hre.network.name) ? 60000 : 20000);
    await hre.run("verify:verify", { address, constructorArguments: args, libraries });
    console.log("Verified:", address);
  } catch (e) {
    const msg = String(e?.message || e);
    if (msg.includes("Already Verified")) {
      console.log("Already verified:", address);
      return;
    }
    console.warn("Verify failed:", address, msg);
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

  const c = await F.deploy(...usedArgs);
  await c.waitForDeployment();
  const tx = c.deploymentTransaction();
  let costEth = "n/a", gasUsedStr = "n/a", gasPriceGwei = "n/a";
  if (tx) {
    const rc = await tx.wait(isLocal(hre.network.name) ? 1 : 2);
    const gasUsed = rc.gasUsed;
    const eff = rc.effectiveGasPrice ?? rc.gasPrice;
    if (gasUsed && eff) {
      const cost = gasUsed * eff;
      costEth = hre.ethers.formatEther(cost);
      gasUsedStr = gasUsed.toString();
      gasPriceGwei = (Number(eff) / 1e9).toFixed(2);
    }
  }
  const addr = await c.getAddress();
  console.log(`${name}: ${addr} (ctor args: ${JSON.stringify(usedArgs)})`);
  console.log(`  ↳ gasUsed=${gasUsedStr}, gasPrice≈${gasPriceGwei} gwei, cost≈${costEth} ETH`);
  // return usedArgs for verification
  return { addr, c, args: usedArgs, libraries };
}

async function main() {
  console.log(`\n=== Deploy start | network: ${hre.network.name} ===`);
  if (isLocal(hre.network.name)) {
    // friendlier hint for any testnet, include Polygon Amoy example
    console.error("Run with --network <testnet>. Examples:");
    console.error("  npx hardhat run scripts/deploy-and-verify.js --network amoy");
    console.error("  npx hardhat run scripts/deploy-and-verify.js --network sepolia");
    process.exit(1);
  }

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

  // Kolejność i argumenty na podstawie Twoich udanych lokalnych logów:
  // Storage(): []
  const storage = await deploy("Storage", "PoliDaoStorage", []);

  // Core(storage, owner): [storageAddr, deployer.address]
  // NEW: auto-linking will deploy DonationLogic, RefundLogic, WithdrawLogic if missing
  const core = await deploy("Core", "PoliDaoCore", [storage.addr, deployer.address]);

  // Router expects only core in its constructor; storage is set via setStorage() below.
  const router = await deploy("Router", "PoliDaoRouter", [core.addr]);

  // Media(core): [coreAddr]
  const media = await deploy("Media", "PoliDaoMedia", [core.addr]);

  // Updates(core, media): [coreAddr, mediaAddr]
  const updates = await deploy("Updates", "PoliDaoUpdates", [core.addr, media.addr]);

  // Refunds(core, owner): [coreAddr, deployer.address]
  const refunds = await deploy("Refunds", "PoliDaoRefunds", [core.addr, deployer.address]);

  // Governance(core): [coreAddr]
  const governance = await deploy("Governance", "PoliDaoGovernance", [core.addr]);

  // Analytics(core): [coreAddr]
  const analytics = await deploy("Analytics", "PoliDaoAnalytics", [core.addr]);

  // Security(core): [coreAddr]
  const security = await deploy("Security", "PoliDaoSecurity", [core.addr]);

  // Web3(): []
  const web3 = await deploy("Web3", "PoliDaoWeb3", []);

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

  // Optionally point modules to Router if they support it
  const modules = [media, updates, refunds, governance, analytics, security, web3].filter(Boolean);
  for (const m of modules) {
    await maybeCall(m.c, "setRouter", [router.addr]);
  }

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
  console.log("\nVerifying (please wait)...");
  await verify(storage.addr, storage.args, storage.libraries);
  await verify(core.addr, core.args, core.libraries);
  await verify(router.addr, router.args, router.libraries);
  await verify(media.addr, media.args, media.libraries);
  await verify(updates.addr, updates.args, updates.libraries);
  await verify(refunds.addr, refunds.args, refunds.libraries);
  await verify(governance.addr, governance.args, governance.libraries);
  await verify(analytics.addr, analytics.args, analytics.libraries);
  await verify(security.addr, security.args, security.libraries);
  await verify(web3.addr, web3.args, web3.libraries);

  // Zapis do deployments/<network>.json
  const out = {
    network: hre.network.name,
    deployer: deployer.address,
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
  };
  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${hre.network.name}.json`);
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2));
  console.log(`\nSaved: deployments/${hre.network.name}.json`);
  console.log("=== Deploy end ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});