require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();
const { task } = require("hardhat/config");
const fs = require("fs");
const path = require("path");

const { SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY } = process.env;
const pk = PRIVATE_KEY ? (PRIVATE_KEY.startsWith("0x") ? PRIVATE_KEY : `0x${PRIVATE_KEY}`) : undefined;

// UUPS verification tasks (implementation + proxy)
// verify-core-uups: verifies implementation and proxy using deployments/<network>.json
task("verify-core-uups", "Verify UUPS Core (implementation + proxy) using deployments/<network>.json")
  .addOptionalParam("file", "Deployments JSON path", undefined)
  .setAction(async (args, hre) => {
    const net = hre.network.name;
    const fp = args.file
      ? (path.isAbsolute(args.file) ? args.file : path.join(process.cwd(), args.file))
      : path.join(process.cwd(), "deployments", `${net}.json`);
    if (!fs.existsSync(fp)) throw new Error(`Deployments file not found: ${fp}`);
    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    const proxy = j.core;
    const impl = j.core_impl || (j.core_impl_history && j.core_impl_history[j.core_impl_history.length - 1]);
    if (!proxy) throw new Error(`Missing core proxy address in ${fp}`);
    if (!impl) throw new Error(`Missing core implementation address in ${fp}`);

    await hre.run("compile");

    // Verify implementation
    await hre.run("verify:verify", {
      address: impl,
      constructorArguments: [],
      contract: "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable",
    });
    console.log("Verified Core Implementation:", impl);

    // Verify proxy with (implementation, initData)
    try {
      const ImplIface = (await hre.ethers.getContractFactory("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable")).interface;
      const coreArgs = (j.args && Array.isArray(j.args.core)) ? j.args.core : [j.storage, j.owner || j.router];
      const initData = ImplIface.encodeFunctionData("initialize", coreArgs);
      await hre.run("verify:verify", {
        address: proxy,
        constructorArguments: [impl, initData],
        contract: "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
      });
      console.log("Verified Core Proxy:", proxy);
    } catch (e) {
      console.warn("Verify proxy failed:", e?.message || e);
    }
  });

// verify-core-uups-impl: verify implementation only
task("verify-core-uups-impl", "Verify UUPS Core implementation")
  .addParam("impl", "Implementation address")
  .setAction(async (args, hre) => {
    await hre.run("compile");
    await hre.run("verify:verify", {
      address: args.impl,
      constructorArguments: [],
      contract: "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable",
    });
    console.log("Verified Core Implementation:", args.impl);
  });

// verify-core-uups-proxy: verify proxy only with explicit initialization args
task("verify-core-uups-proxy", "Verify UUPS Core proxy with init args")
  .addParam("proxy", "Proxy address")
  .addParam("impl", "Implementation address used in constructor")
  .addParam("storage", "Storage address (initialize arg #1)")
  .addParam("owner", "Owner address (initialize arg #2)")
  .setAction(async (args, hre) => {
    await hre.run("compile");
    const ImplIface = (await hre.ethers.getContractFactory("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable")).interface;
    const initData = ImplIface.encodeFunctionData("initialize", [args.storage, args.owner]);
    await hre.run("verify:verify", {
      address: args.proxy,
      constructorArguments: [args.impl, initData],
      contract: "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
    });
    console.log("Verified Core Proxy:", args.proxy);
  });

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: "paris" },
      },
      {
        version: "0.8.26",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: "paris" },
      },
    ],
    overrides: {
      "@openzeppelin/contracts/utils/ReentrancyGuard.sol": {
        version: "0.8.20",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: false, evmVersion: "paris" },
      },
      "node_modules/@openzeppelin/contracts/utils/ReentrancyGuard.sol": {
        version: "0.8.20",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: false, evmVersion: "paris" },
      },
    },
  },
  sourcify: { enabled: false },
  networks: {
    sepolia: SEPOLIA_RPC_URL && pk ? {
      url: SEPOLIA_RPC_URL,
      accounts: [pk],
    } : undefined,
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY || "",
  },
  // ========== CONTRACT SIZER PLUGIN ==========
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
    only: [":PoliDao$"],
    except: [":Mock", ":Test"],
  },
  // ========== GAS REPORTER ==========
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 80,
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  // ========== MOCHA ==========
  mocha: {
    require: [
      "test/setup/no-skip.js",
      "test/helpers/v6-compat.js",
    ],
    timeout: 600000,
  },
  // ========== PATHS ==========
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  // ========== DEFENDER (opcjonalne) ==========
  defender: {
    apiKey: process.env.DEFENDER_API_KEY || "",
    apiSecret: process.env.DEFENDER_API_SECRET || "",
  },
};