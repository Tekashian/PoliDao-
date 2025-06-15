// scripts/deploy_polidao.js
// Skrypt wdrożeniowy kontraktu PoliDAO z automatyczną weryfikacją na Etherscan/BSCScan
// Użycie: npx hardhat run scripts/deploy_polidao.js --network <network>

const hre = require("hardhat");

async function main() {
  console.log(`\n--- Deploying PoliDAO to network: ${hre.network.name} ---`);

  // Pobieramy konto deployera
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) {
    console.error("ERROR: Brak deployera. Sprawdź konfigurację sieci i klucz prywatny.");
    process.exit(1);
  }
  console.log(`Deployer address: ${deployer.address}`);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`Deployer balance: ${hre.ethers.formatUnits(balance, "ether")} ${hre.network.name.includes('bsc') ? 'BNB' : 'ETH'}`);
  if (balance.eq(0)) {
    console.warn("WARNING: Deployer ma 0 środków — wdrożenie może się nie powieść.");
  }

  // Kontrakt PoliDAO
  console.log("\nCompiling and fetching PoliDAO contract factory...");
  const PoliDAO = await hre.ethers.getContractFactory("PoliDAO");

  // Argumenty konstruktora
  const initialOwner = deployer.address;
  // Domyślnie komisja trafia do deployera, można zmienić poniżej:
  const commissionWallet = deployer.address;

  console.log("Constructor args:", { initialOwner, commissionWallet });

  // Deploy
  console.log("\nDeploying PoliDAO...");
  const dao = await PoliDAO.deploy(initialOwner, commissionWallet);

  console.log(`Tx hash: ${dao.deploymentTransaction().hash}`);
  const confirmations = hre.network.name === "hardhat" || hre.network.name === "localhost" ? 1 : 2;
  await dao.deploymentTransaction().wait(confirmations);

  const address = dao.address;
  console.log(`\n✅ PoliDAO deployed at: ${address}`);

  // Generowanie URL eksploratora
  let explorerUrl;
  const explorerMap = {
    bscTestnet: "https://testnet.bscscan.com",
    bsc: "https://bscscan.com",
    sepolia: "https://sepolia.etherscan.io",
    mainnet: "https://etherscan.io",
    polygon: "https://polygonscan.com",
    polygonMumbai: "https://mumbai.polygonscan.com"
  };
  if (explorerMap[hre.network.name]) {
    explorerUrl = `${explorerMap[hre.network.name]}/address/${address}`;
  } else {
    explorerUrl = `Brak zdefiniowanego eksploratora dla ${hre.network.name}.`;
  }
  console.log(`Explorer: ${explorerUrl}`);

  // Automatyczna weryfikacja
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost" && hre.config.etherscan.apiKey) {
    console.log("\nWaiting 60s for block explorer indexing...");
    await new Promise(res => setTimeout(res, 60000));
    try {
      console.log("Verifying contract on block explorer...");
      await hre.run("verify:verify", {
        address,
        constructorArguments: [initialOwner, commissionWallet]
      });
      console.log("Verification successful.");
    } catch (err) {
      if (err.message.toLowerCase().includes("already verified")) {
        console.log("Contract already verified.");
      } else {
        console.error("Verification error:", err.message);
      }
    }
  } else {
    console.log("\nSkipping verification: network is localhost or missing etherscan.apiKey.");
  }

  return address;
}

main()
  .then(addr => {
    console.log(`\nScript finished. PoliDAO address: ${addr}`);
    process.exit(0);
  })
  .catch(err => {
    console.error("Deployment script error:", err);
    process.exit(1);
  });
