/* eslint-disable no-console */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const isLocal = (n) => n === "hardhat" || n === "localhost";
const waitMs = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitConf(tx) {
  if (!tx) return;
  const confs = isLocal(hre.network.name) ? 1 : 2;
  await tx.wait(confs);
}

function explorerBase(network) {
  if (network === "sepolia") return "https://sepolia.etherscan.io";
  return "";
}

async function verify(address, args = []) {
  if (isLocal(hre.network.name)) {
    console.log(`Skip verify on '${hre.network.name}' for ${address}`);
    return;
  }
  try {
    // krótka pauza, żeby indeksery nadążyły
    await waitMs(20000);
    await hre.run("verify:verify", { address, constructorArguments: args });
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

async function deploy(name, factoryName, args = []) {
  const F = await hre.ethers.getContractFactory(factoryName);
  const c = await F.deploy(...args);
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
  console.log(`${name}: ${addr} (ctor args: ${JSON.stringify(args)})`);
  console.log(`  ↳ gasUsed=${gasUsedStr}, gasPrice≈${gasPriceGwei} gwei, cost≈${costEth} ETH`);
  return { addr, c, args };
}

async function main() {
  console.log(`\n=== Deploy start | network: ${hre.network.name} ===`);
  if (isLocal(hre.network.name)) {
    console.error("Run with --network sepolia. Example:");
    console.error("npx hardhat run scripts/deploy-and-verify.js --network sepolia");
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
  const core = await deploy("Core", "PoliDaoCore", [storage.addr, deployer.address]);

  // Router(core): [coreAddr]
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

  // TODO: jeśli Core/Router mają settery do rejestracji modułów, dodaj wywołania tutaj:
  // await (await core.c.setModule(...)).wait();
  // await (await router.c.setRoute(...)).wait();

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
  await verify(storage.addr, []);
  await verify(core.addr, [storage.addr, deployer.address]);
  await verify(router.addr, [core.addr]);
  await verify(media.addr, [core.addr]);
  await verify(updates.addr, [core.addr, media.addr]);
  await verify(refunds.addr, [core.addr, deployer.address]);
  await verify(governance.addr, [core.addr]);
  await verify(analytics.addr, [core.addr]);
  await verify(security.addr, [core.addr]);
  await verify(web3.addr, []);

  // Zapis do deployments/<network>.json
  const out = {
    network: hre.network.name,
    deployer: deployer.address,
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