require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL || "";
const BSC_TESTNET_RPC_URL = process.env.BSC_TESTNET_RPC_URL || "";
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";
const BSCSCAN_API_KEY = process.env.BSCSCAN_API_KEY || "";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      { 
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200  // Niska wartość dla lepszej kompresji kodu
          },
          // Dodaj aby obsłużyć duże kontrakty
          viaIR: true
        }
      },
      { 
        version: "0.8.30",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200  // Niska wartość dla lepszej kompresji kodu
          },
          viaIR: true
        }
      },
    ],
  },
  networks: {
    hardhat: {
      // Pozwól na nieograniczony rozmiar kontraktu w środowisku testowym
      allowUnlimitedContractSize: true,
      // Zwiększ limit gazu
      gas: 30000000,
      blockGasLimit: 30000000
    },
    sepolia: {
      url: SEPOLIA_RPC_URL,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      gas: 30000000,
      gasPrice: 20000000000 // 20 gwei
    },
    bscTestnet: {
      url: BSC_TESTNET_RPC_URL,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      gas: 30000000,
      gasPrice: 10000000000 // 10 gwei
    },
  },
  etherscan: {
    apiKey: {
      sepolia: ETHERSCAN_API_KEY,
      bscTestnet: BSCSCAN_API_KEY,
    },
  },
  // Dodatkowe ustawienia dla dużych kontraktów
  mocha: {
    timeout: 60000 // 60 sekund timeout dla testów
  }
};