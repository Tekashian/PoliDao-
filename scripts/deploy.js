// scripts/deploy.js
// ZAKTUALIZOWANY skrypt wdrożeniowy z proxy support dla dużych kontraktów
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
    
    // Adresy tokenów dla różnych sieci
    const feeTokenAddresses = {
        sepolia: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", // USDC na Sepolia
        mainnet: "0xA0b86a33E6Ba6B641be77678579bA0f5DCC4644", // USDC na Mainnet
        polygon: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", // USDC na Polygon
        bsc: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",     // USDC na BSC
        // Fallback dla testnetów - używamy deployer address jako mock
        hardhat: deployer.address,
        localhost: deployer.address
    };
    
    const feeToken = feeTokenAddresses[hre.network.name] || deployer.address;
    
    console.log("\n📦 Argumenty konstruktora:");
    console.log(`   - initialOwner:       ${initialOwner}`);
    console.log(`   - commissionWallet:   ${commissionWallet}`);
    console.log(`   - feeToken:           ${feeToken}`);
    
    if (feeToken === deployer.address && !["hardhat", "localhost"].includes(hre.network.name)) {
        console.warn("⚠️  UWAGA: Używam deployer address jako feeToken. Rozważ zmianę na rzeczywisty adres USDC!");
    }

    // NOWE: Sprawdź rozmiar kontraktu i wybierz metodę deployment
    console.log("\n🔍 Sprawdzanie rozmiaru kontraktu...");
    
    let contractAddress;
    let deploymentMethod;
    
    try {
        // Spróbuj standardowego deployment
        console.log("🚀 Próba standardowego deployment...");
        const dao = await PoliDAO.deploy(initialOwner, commissionWallet, feeToken);
        const tx = dao.deploymentTransaction();
        
        if (!tx) {
            throw new Error("Nie można pobrać obiektu transakcji");
        }
        
        console.log(`   • Tx hash: ${tx.hash}`);
        console.log("⏳ Oczekiwanie na potwierdzenia transakcji...");
        const confirmations = ["hardhat", "localhost"].includes(hre.network.name) ? 1 : 2;
        await tx.wait(confirmations);
        console.log(`✅ Transakcja potwierdzona (${confirmations} bloków).`);
        
        contractAddress = await dao.getAddress();
        deploymentMethod = "standard";
        console.log("✅ Standardowy deployment udany!");
        
    } catch (error) {
        // Jeśli standardowy deployment nie udał się z powodu rozmiaru, użyj proxy
        if (error.message.includes("CreateContractSizeLimit") || error.message.includes("contract code size")) {
            console.log("⚠️  Kontrakt za duży dla standardowego deployment. Używam Proxy Pattern...");
            
            try {
                // Import upgrades module dynamically
                const { upgrades } = require("hardhat");
                
                console.log("🏗️  Deploying przez Upgradeable Proxy...");
                const proxy = await upgrades.deployProxy(
                    PoliDAO,
                    [initialOwner, commissionWallet, feeToken],
                    {
                        kind: 'transparent',
                        initializer: false
                    }
                );
                
                await proxy.waitForDeployment();
                contractAddress = await proxy.getAddress();
                deploymentMethod = "proxy";
                
                // Dodatkowe info o proxy
                const implAddress = await upgrades.erc1967.getImplementationAddress(contractAddress);
                const adminAddress = await upgrades.erc1967.getAdminAddress(contractAddress);
                
                console.log("✅ Proxy deployment udany!");
                console.log(`📍 Proxy Address: ${contractAddress}`);
                console.log(`🔧 Implementation: ${implAddress}`);
                console.log(`👑 Admin: ${adminAddress}`);
                
            } catch (proxyError) {
                console.error("❌ BŁĄD: Nie udał się ani standardowy ani proxy deployment:");
                console.error("Standard error:", error.message);
                console.error("Proxy error:", proxyError.message);
                process.exit(1);
            }
        } else {
            console.error("❌ BŁĄD podczas standardowego deployment:", error.message);
            process.exit(1);
        }
    }

    console.log(`\n🏷️  Adres kontraktu PoliDAO (${deploymentMethod}): ${contractAddress}`);

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

    // Test funkcjonalności kontraktu
    console.log("\n🧪 Test podstawowej funkcjonalności...");
    try {
        const contract = await hre.ethers.getContractAt("PoliDAO", contractAddress);
        const owner = await contract.owner();
        const tokenCount = await contract.getFundraiserCount();
        console.log(`✅ Owner: ${owner}`);
        console.log(`✅ Fundraiser Count: ${tokenCount}`);
        console.log("✅ Kontrakt działa poprawnie!");
    } catch (testError) {
        console.warn("⚠️  Nie można przetestować kontraktu:", testError.message);
    }

    // Automatyczna weryfikacja na Etherscan
    if (!["hardhat", "localhost"].includes(hre.network.name) && hre.config.etherscan.apiKey) {
        console.log("\n⏳ Czekam 60s przed weryfikacją, aby explorer zindeksował transakcję...");
        await new Promise(res => setTimeout(res, 60000));

        try {
            console.log("🔎 Rozpoczynam weryfikację kontraktu na block explorer...");
            
            if (deploymentMethod === "standard") {
                // Weryfikacja standardowego kontraktu
                await hre.run("verify:verify", {
                    address: contractAddress,
                    constructorArguments: [initialOwner, commissionWallet, feeToken]
                });
            } else {
                // Weryfikacja implementation dla proxy
                const { upgrades } = require("hardhat");
                const implAddress = await upgrades.erc1967.getImplementationAddress(contractAddress);
                await hre.run("verify:verify", {
                    address: implAddress,
                    constructorArguments: []
                });
                console.log("ℹ️  Zweryfikowano implementation contract. Proxy nie wymaga osobnej weryfikacji.");
            }
            
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

    // Podsumowanie deployment
    console.log(`\n📋 PODSUMOWANIE DEPLOYMENT:`);
    console.log(`   🏷️  Adres kontraktu: ${contractAddress}`);
    console.log(`   🔧 Metoda: ${deploymentMethod}`);
    console.log(`   🌐 Sieć: ${hre.network.name}`);
    console.log(`   🔗 Explorer: ${explorerUrl}`);
    
    if (deploymentMethod === "proxy") {
        console.log(`\n💡 WAŻNE dla Proxy:`);
        console.log(`   • Używaj PROXY ADDRESS (${contractAddress}) do wszystkich interakcji`);
        console.log(`   • Kontrakt jest upgradeable`);
        console.log(`   • Implementation zostanie automatycznie zweryfikowane`);
    }

    return { address: contractAddress, method: deploymentMethod };
}

main()
    .then(result => {
        console.log(`\n🎉 Skrypt wdrożeniowy zakończony pomyślnie!`);
        console.log(`📍 Adres: ${result.address}`);
        console.log(`🔧 Metoda: ${result.method}`);
        process.exit(0);
    })
    .catch(err => {
        console.error("\n💥 Krytyczny błąd podczas wdrażania:", err);
        process.exit(1);
    });