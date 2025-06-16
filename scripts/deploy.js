// scripts/deploy.js
// Skrypt wdrożeniowy kontraktu PoliDAO z automatyczną weryfikacją na Etherscan (Sepolia, Mainnet itd.)
// Użycie: npx hardhat run --network <network> scripts/deploy.js

const hre = require("hardhat");

async function main() {
    console.log(`\n--- Rozpoczynanie wdrażania kontraktu PoliDAO na sieć: ${hre.network.name} ---`);

    // Pobieramy konto deployera
    const [deployer] = await hre.ethers.getSigners();
    if (!deployer) {
        console.error("❌ BŁĄD: Nie można uzyskać konta deployera. Sprawdź konfigurację sieci i plik .env (PRIVATE_KEY).");
        process.exit(1);
    }
    console.log(`👤 Używane konto (Deployer): ${deployer.address}`);

    // Sprawdzamy saldo konta
    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log(`💰 Saldo konta: ${hre.ethers.formatUnits(balance, "ether")} ${hre.network.name.includes('bsc') ? 'BNB' : 'ETH'}`);
    if (balance === 0n) {
        console.warn(`⚠️  Saldo wynosi 0 – wdrożenie może się nie powieść. Uzupełnij konto z faucetu!`);
    }

    // Pobieramy skompilowany kontrakt
    console.log("\n🔨 Pobieranie factory kontraktu PoliDAO...");
    const PoliDAO = await hre.ethers.getContractFactory("PoliDAO");
    console.log("✅ Factory pobrana.");

    // Argumenty konstruktora
    const initialOwner = deployer.address;
    const commissionWallet = deployer.address; // można zmienić na inny adres
    console.log("\n📦 Argumenty konstruktora:");
    console.log(`   - initialOwner:       ${initialOwner}`);
    console.log(`   - commissionWallet:   ${commissionWallet}`);

    // Deployment
    console.log("\n🚀 Wysyłanie transakcji wdrożeniowej...");
    const dao = await PoliDAO.deploy(initialOwner, commissionWallet);
    const tx = dao.deploymentTransaction();
    if (!tx) {
        console.error("❌ BŁĄD: Nie udało się pobrać obiektu transakcji wdrożeniowej.");
        process.exit(1);
    }
    console.log(`   • Tx hash: ${tx.hash}`);
    console.log("⏳ Oczekiwanie na potwierdzenia transakcji...");
    const confirmations = ["hardhat", "localhost"].includes(hre.network.name) ? 1 : 2;
    await tx.wait(confirmations);
    console.log(`✅ Transakcja potwierdzona (${confirmations} bloków).`);

    // Pobieramy adres wdrożonego kontraktu
    const contractAddress = await dao.getAddress();
    console.log(`\n🏷️  Adres kontraktu PoliDAO: ${contractAddress}`);

    // Generowanie linku do eksploratora
    console.log("\n🔗 Generowanie linku do block explorer...");
    let explorerUrl;
    const customChains = hre.config.etherscan.customChains || [];
    const chainConfig = customChains.find(c => c.network === hre.network.name);
    if (chainConfig && chainConfig.urls.browserURL) {
        explorerUrl = `${chainConfig.urls.browserURL.replace(/\/$/, "")}/address/${contractAddress}`;
    } else {
        const explorerMap = {
            sepolia:       "https://sepolia.etherscan.io",
            mainnet:       "https://etherscan.io",
            bscTestnet:    "https://testnet.bscscan.com",
            bsc:           "https://bscscan.com",
            polygon:       "https://polygonscan.com",
            polygonMumbai: "https://mumbai.polygonscan.com"
        };
        if (explorerMap[hre.network.name]) {
            explorerUrl = `${explorerMap[hre.network.name]}/address/${contractAddress}`;
        } else {
            explorerUrl = `Eksplorator dla sieci '${hre.network.name}' nie jest zdefiniowany.`;
        }
    }
    console.log(`🔍 Sprawdź kontrakt: ${explorerUrl}`);

    // Automatyczna weryfikacja na Etherscan
    if (!["hardhat", "localhost"].includes(hre.network.name) && hre.config.etherscan.apiKey) {
        console.log("\n⏳ Czekam 60s przed weryfikacją, aby explorer zindeksował transakcję...");
        await new Promise(res => setTimeout(res, 60000));

        try {
            console.log("🔎 Rozpoczynam weryfikację kontraktu na block explorer...");
            await hre.run("verify:verify", {
                address: contractAddress,
                constructorArguments: [initialOwner, commissionWallet]
            });
            console.log("✅ Weryfikacja zakończona pomyślnie.");
        } catch (err) {
            const msg = err.message.toLowerCase();
            if (msg.includes("already verified")) {
                console.log("ℹ️  Kontrakt już wcześniej zweryfikowany.");
            } else if (msg.includes("does not have bytecode") || msg.includes("unable to locate contract code")) {
                console.error("❌ Błąd: Kontrakt nie ma bytecode lub nie został jeszcze zindeksowany. Spróbuj ponownie później.");
            } else {
                console.error("❌ Błąd podczas weryfikacji:", err.message);
            }
        }
    } else {
        console.log("\n⚙️  Pomijam weryfikację: sieć lokalna lub brak etherscan.apiKey.");
    }

    return contractAddress;
}

main()
    .then(address => {
        console.log("\n🎉 Skrypt wdrożeniowy zakończony. Adres kontraktu:", address);
        process.exit(0);
    })
    .catch(err => {
        console.error("\n💥 Krytyczny błąd podczas wdrażania:", err);
        process.exit(1);
    });
