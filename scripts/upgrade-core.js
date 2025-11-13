/* eslint-disable no-console */
require("dotenv").config();
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const net = hre.network.name;
  if (net === "hardhat" || net === "localhost") {
    console.error("Run with a real network, e.g. --network sepolia");
    process.exit(1);
  }
  const deploymentsPath = path.join(__dirname, "..", "deployments", `${net}.json`);
  if (!fs.existsSync(deploymentsPath)) throw new Error(`Missing deployments JSON: ${deploymentsPath}`);
  const j = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
  if (!j.core) throw new Error("Missing core (proxy) address in deployments JSON");
  const proxyAddr = j.core;

  console.log("Proxy (core):", proxyAddr);
  const [deployer] = await hre.ethers.getSigners();
  console.log("Sender:", deployer.address);

  // Deploy new implementation for upgradeable core
  const libs = await (async () => {
    try {
      const artifact = await hre.artifacts.readArtifact("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable");
      return artifact.linkReferences && Object.keys(artifact.linkReferences).length
        ? undefined
        : undefined;
    } catch { return undefined; }
  })();

  const ImplFactory = await hre.ethers.getContractFactory(
    "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable",
    libs ? { libraries: libs } : undefined
  );
  const implTx = await ImplFactory.deploy();
  const impl = await implTx.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("New implementation:", implAddr);

  // Call upgradeTo on proxy (UUPS)
  const coreProxy = await hre.ethers.getContractAt("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable", proxyAddr);
  const tx = await coreProxy.upgradeToAndCall(implAddr, "0x");
  await tx.wait(1);
  console.log("Upgraded proxy to:", implAddr);

  // Update deployments JSON
  j.core_impl = implAddr;
  j.core_impl_history = Array.isArray(j.core_impl_history) ? [...j.core_impl_history, implAddr] : [implAddr];
  j.txs = j.txs || {};
  j.txs.core_impl = implTx.deploymentTransaction().hash;
  fs.writeFileSync(deploymentsPath, JSON.stringify(j, null, 2));
  console.log("Saved:", deploymentsPath);
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
