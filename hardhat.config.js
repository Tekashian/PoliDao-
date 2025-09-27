require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();

const { SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY } = process.env;
const pk = PRIVATE_KEY ? (PRIVATE_KEY.startsWith("0x") ? PRIVATE_KEY : `0x${PRIVATE_KEY}`) : undefined;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  // ========== SOLIDITY CONFIGURATION ==========
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 800 },
      viaIR: true,
      metadata: { bytecodeHash: "none" }
      // debug: { revertStrings: "strip" } // tylko dla buildów prod, NIE dla testów
    }
  },

  // ========== NETWORKS CONFIGURATION ==========
  networks: {
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: true, // ⭐ Pozwala na duże kontrakty lokalnie
      blockGasLimit: 50000000,
      gas: 50000000,
      gasPrice: 1000000000,
      initialBaseFeePerGas: 1000000000,
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
        count: 20,
        accountsBalance: "10000000000000000000000"
      },
      mining: {
        auto: true,
        interval: 0
      }
    },

    sepolia: {
      url: SEPOLIA_RPC_URL,
      accounts: pk ? [pk] : [],
      timeout: 120000,
      confirmations: 2
    },

    polygonAmoy: {
      url: process.env.POLYGON_AMOY_RPC || "https://rpc-amoy.polygon.technology/",
      chainId: 80002,
      accounts: pk ? [pk] : [],
      gas: 30000000,
      gasPrice: 80000000000,
      timeout: 60000,
      confirmations: 3,
      skipDryRun: false,
      allowUnlimitedContractSize: false, // ⭐ Wymusza sprawdzenie limitu
      blockGasLimit: 30000000
    },

    polygonMainnet: {
      url: process.env.POLYGON_MAINNET_RPC || "https://polygon-rpc.com/",
      chainId: 137,
      accounts: pk ? [pk] : [],
      gas: 25000000,
      gasPrice: 50000000000,
      timeout: 120000,
      confirmations: 5,
      allowUnlimitedContractSize: false
    }
  },

  // ========== ETHERSCAN VERIFICATION ==========
  etherscan: {
    apiKey: {
      polygon: process.env.POLYGONSCAN_API_KEY || "",
      polygonAmoy: process.env.POLYGONSCAN_API_KEY || "",
      sepolia: ETHERSCAN_API_KEY,
    },
    customChains: [
      {
        network: "polygonAmoy",
        chainId: 80002,
        urls: {
          apiURL: "https://api-amoy.polygonscan.com/api",
          browserURL: "https://amoy.polygonscan.com"
        }
      }
    ]
  },

  // ========== CONTRACT SIZER PLUGIN ==========
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true, // ⭐ Automatycznie pokazuje rozmiary po kompilacji
    strict: true,
    only: [':PoliDao$'], // ⭐ POPRAWIONE: szuka PoliDao (bez wielkich liter)
    except: [':Mock', ':Test']
  },

  // ========== GAS REPORTER ==========
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 80,
    coinmarketcap: process.env.COINMARKETCAP_API_KEY
  },

  // ========== SOLIDITY COVERAGE ==========
  solidity_coverage: {
    enabled: false,
    skipFiles: ['test/', 'mocks/']
  },

  // ========== COMPILER OPTIMIZATION ==========
  mocha: {
    reporter: "spec",
    forbidPending: true
  },

  // ========== PATHS ==========
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },

  // ========== DEFENDER (opcjonalne) ==========
  defender: {
    apiKey: process.env.DEFENDER_API_KEY || "",
    apiSecret: process.env.DEFENDER_API_SECRET || ""
  }
};

// ========== DODATKOWE ZADANIA ==========

// Zadanie do sprawdzania rozmiaru kontraktu
task("contract-size", "Sprawdź rozmiar kontraktu")
  .setAction(async (taskArgs, hre) => {
    await hre.run("compile");
    
    const artifacts = await hre.artifacts.readArtifact("PoliDao"); // ⭐ POPRAWIONE
    const bytecode = artifacts.bytecode;
    const deployedBytecode = artifacts.deployedBytecode;
    
    const bytecodeSize = (bytecode.length - 2) / 2;
    const deployedSize = (deployedBytecode.length - 2) / 2;
    
    const maxSize = 24576; // 24KB limit
    
    console.log(`📦 Rozmiar kontraktu PoliDao:`);
    console.log(`   Bytecode: ${bytecodeSize.toLocaleString()} bytes`);
    console.log(`   Deployed: ${deployedSize.toLocaleString()} bytes`);
    console.log(`   Limit:    ${maxSize.toLocaleString()} bytes`);
    console.log(`   Status:   ${deployedSize <= maxSize ? '✅ ZMIEŚCI SIĘ' : '❌ ZA DUŻY'}`);
    
    if (deployedSize > maxSize) {
      console.log(`   Przekroczenie: ${(deployedSize - maxSize).toLocaleString()} bytes`);
      console.log(`   Potrzebna redukcja: ${(((deployedSize - maxSize) / deployedSize) * 100).toFixed(1)}%`);
      
      // ⭐ DODANE: Sugestie optymalizacji
      console.log(`\n💡 Sugestie dalszych optymalizacji:`);
      console.log(`   1. Skróć error messages (oszczędzi ~1-2KB)`);
      console.log(`   2. Usuń funkcje view (przeniesienie do library)`);
      console.log(`   3. Użyj proxy pattern (CREATE2 + minimal proxy)`);
      console.log(`   4. Zmniejsz runs do 0 (jeśli gas nie jest problemem)`);
    }
  });

// Zadanie do testowego deploymentu
task("test-deploy", "Test deployment bez faktycznego deploymentu")
  .setAction(async (taskArgs, hre) => {
    console.log("🧪 Testowy deployment...");
    
    const [deployer] = await hre.ethers.getSigners();
    const PoliDao = await hre.ethers.getContractFactory("PoliDao"); // ⭐ POPRAWIONE
    
    try {
      const deployTx = PoliDao.getDeployTransaction(
        deployer.address,
        deployer.address,
        "0x0000000000000000000000000000000000000001"
      );
      
      const estimatedGas = await hre.ethers.provider.estimateGas(deployTx);
      console.log(`⛽ Szacowany gas: ${estimatedGas.toLocaleString()}`);
      
      const gasPrice = await hre.ethers.provider.getFeeData();
      const estimatedCost = estimatedGas * gasPrice.gasPrice;
      console.log(`💰 Szacowany koszt: ${hre.ethers.formatEther(estimatedCost)} ETH/MATIC`);
      
      if (estimatedGas > 15000000n) {
        console.log("⚠️  UWAGA: Wysoki gas usage. Rozważ proxy deployment.");
      } else {
        console.log("✅ Gas usage w normie. Standardowy deployment powinien zadziałać.");
      }
      
    } catch (error) {
      if (error.message.includes("contract code size")) {
        console.log("❌ KONTRAKT ZA DUŻY dla bezpośredniego deploymentu");
        console.log("💡 Użyj proxy deployment lub zmniejsz rozmiar kontraktu");
      } else {
        console.log("❌ Błąd:", error.message);
      }
    }
  });

// ⭐ NOWE ZADANIE: Wyczyść cache i skompiluj od nowa
task("fresh-compile", "Wyczyść cache i skompiluj od nowa")
  .setAction(async (taskArgs, hre) => {
    console.log("🧹 Czyszczenie cache...");
    await hre.run("clean");
    
    console.log("🔨 Kompilacja od nowa...");
    await hre.run("compile");
    
    console.log("📏 Sprawdzanie rozmiaru...");
    await hre.run("contract-size");
  });

// ⭐ NOWE ZADANIE: Wyświetl rozmiary wszystkich skompilowanych kontraktów
task("sizes-all", "Wyświetl rozmiary wszystkich skompilowanych kontraktów")
  .setAction(async (taskArgs, hre) => {
    console.log("🔨 Kompilacja (jeśli potrzeba) i zbieranie artefaktów...");
    await hre.run("compile");

    const names = await hre.artifacts.getAllFullyQualifiedNames();
    const maxSize = 24576;

    console.log(`\n📦 Znaleziono ${names.length} artefakt(ów).`);

    for (const fqn of names) {
      try {
        const artifact = await hre.artifacts.readArtifact(fqn);
        const bytecode = artifact.bytecode || "";
        const deployed = artifact.deployedBytecode || "";
        const bytecodeSize = bytecode.length ? (bytecode.length - 2) / 2 : 0;
        const deployedSize = deployed.length ? (deployed.length - 2) / 2 : 0;
        const kb = (deployedSize / 1024).toFixed(2);

        console.log(`\n- ${fqn}`);
        console.log(`   Contract: ${artifact.contractName}`);
        console.log(`   Deployed size: ${deployedSize.toLocaleString()} bytes (${kb} KB) ${deployedSize > maxSize ? '❌ OVER 24KB' : '✅ OK'}`);

        if (artifact.linkReferences && Object.keys(artifact.linkReferences).length) {
          console.log('   Linked libraries:');
          for (const src in artifact.linkReferences) {
            for (const lib in artifact.linkReferences[src]) {
              console.log(`     - ${src}:${lib}`);
            }
          }
        }
      } catch (err) {
        console.log(`Failed to read artifact ${fqn}: ${err.message}`);
      }
    }
  });