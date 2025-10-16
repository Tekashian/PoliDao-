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

// Zadania: verify Core z deployments/<network>.json (ctor: storage, router)
task("verify-core", "Verify PoliDaoCore using deployments/<network>.json")
  .addOptionalParam("file", "Deployments JSON path", undefined)
  .addOptionalParam("donationlib", "DonationLogic library address", undefined)
  .addOptionalParam("withdrawlib", "WithdrawLogic library address", undefined)
  .setAction(async (args, hre) => {
    const net = hre.network.name;
    const fp = args.file
      ? (path.isAbsolute(args.file) ? args.file : path.join(process.cwd(), args.file))
      : path.join(process.cwd(), "deployments", `${net}.json`);
    if (!fs.existsSync(fp)) throw new Error(`Deployments file not found: ${fp}`);
    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    const core = j.core;
    const storage = j.storage;
    const router = j.router;
    if (!core || !storage || !router) throw new Error(`Missing core/storage/router in ${fp}`);

    await hre.run("compile");

    const libraries = {};
    if (args.donationlib) libraries["DonationLogic"] = args.donationlib;
    if (args.withdrawlib) libraries["WithdrawLogic"] = args.withdrawlib;

    // Prefer ctor args zapisane przy deployu; fallback do [storage, router] tylko jeśli brak
    const ctorArgs = (j.args && Array.isArray(j.args.core)) ? j.args.core : [storage, router];
    await hre.run("verify:verify", {
      address: core,
      constructorArguments: ctorArgs,
      contract: "contracts/core/PoliDaoCore.sol:PoliDaoCore",
      libraries: Object.keys(libraries).length ? libraries : undefined,
    });
    console.log("Verified Core:", core);
  });

task("verify-core-args", "Verify PoliDaoCore with explicit args (storage, router)")
  .addParam("core", "Core address")
  .addParam("storage", "Storage address (ctor arg #1)")
  .addOptionalParam("router", "Router address (ctor arg #2)")
  .addOptionalParam("owner", "Owner address (ctor arg #2 when Router not passed)")
  .addOptionalParam("donationlib", "DonationLogic library address", undefined)
  .addOptionalParam("withdrawlib", "WithdrawLogic library address", undefined)
  .setAction(async (args, hre) => {
    await hre.run("compile");

    const libraries = {};
    if (args.donationlib) libraries["DonationLogic"] = args.donationlib;
    if (args.withdrawlib) libraries["WithdrawLogic"] = args.withdrawlib;

    const ctor2 = args.owner || args.router;
    if (!ctor2) throw new Error("Provide either --router or --owner for ctor arg #2");
    await hre.run("verify:verify", {
      address: args.core,
      constructorArguments: [args.storage, ctor2],
      contract: "contracts/core/PoliDaoCore.sol:PoliDaoCore",
      libraries: Object.keys(libraries).length ? libraries : undefined,
    });
    console.log("Verified Core:", args.core);
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