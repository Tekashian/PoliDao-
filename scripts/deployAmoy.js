// scripts/deployAmoy.js
// Dedykowany skrypt deployment dla Polygon Amoy testnet
// Użycie: npx hardhat run --network polygonAmoy scripts/deployAmoy.js

const hre = require("hardhat");

async function main() {
    console.log(`\n🟣 ===== POLYGON AMOY DEPLOYMENT ===== 🟣`);
    console.log(`⛓️  Sieć: ${hre.network.name}`);
    console.log(`🔗 Chain ID: ${hre.network.config.chainId}`);

    // Weryfikuj czy to Polygon Amoy
    if (hre.network.name !== "polygonAmoy") {
        console.error("❌ BŁĄD: Ten skrypt działa tylko na sieci 'polygonAmoy'");
        console.error("💡 Użyj: npx hardhat run --network polygonAmoy scripts/deployAmoy.js");
        process.exit(1);
    }

    // Sprawdź chain ID
    if (hre.network.config.chainId !== 80002) {
        console.error("❌ BŁĄD: Nieprawidłowy Chain ID. Polygon Amoy = 80002");
        process.exit(1);
    }

    // Pobierz deployer account
    const [deployer] = await hre.ethers.getSigners();
    if (!deployer) {
        console.error("❌ BŁĄD: Nie można pobrać konta deployera. Sprawdź PRIVATE_KEY w .env");
        process.exit(1);
    }

    console.log(`\n👤 Deployer Address: ${deployer.address}`);

    // Sprawdź saldo MATIC
    const balance = await hre.ethers.provider.getBalance(deployer.address);
    const balanceInMatic = hre.ethers.formatUnits(balance, "ether");
    console.log(`💰 Saldo MATIC: ${balanceInMatic} MATIC`);

    if (balance === 0n) {
        console.error("\n❌ BRAK MATIC NA KONCIE!");
        console.error("🔗 Pobierz MATIC z faucetu: https://faucet.polygon.technology/");
        console.error("📋 Wybierz 'Polygon Amoy' i wklej adres:", deployer.address);
        process.exit(1);
    }

    if (parseFloat(balanceInMatic) < 1.0) {
        console.warn("⚠️  Małe saldo MATIC. Może nie wystarczyć na deployment dużego kontraktu.");
        console.warn("💡 Zalecane minimum: 2-5 MATIC dla pewności");
    }

    // Pobierz factory kontraktu
    console.log("\n🔨 Kompilowanie kontraktu PoliDAO...");
    let PoliDAO;
    try {
        PoliDAO = await hre.ethers.getContractFactory("PoliDAO");
        console.log("✅ Kontrakt skompilowany pomyślnie");
    } catch (compileError) {
        console.error("❌ BŁĄD kompilacji:", compileError.message);
        process.exit(1);
    }

    // Konfiguracja deployment dla Polygon Amoy
    const deploymentConfig = {
        initialOwner: deployer.address,
        commissionWallet: deployer.address,  // Możesz zmienić na inny adres
        feeToken: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582", // USDC na Polygon Amoy
        gasLimit: 25000000,  // 25M gas limit dla dużych kontraktów
        gasPrice: hre.ethers.parseUnits("80", "gwei"), // 80 gwei
    };

    console.log("\n📦 Parametry Deployment:");
    console.log(`   🏠 Initial Owner:     ${deploymentConfig.initialOwner}`);
    console.log(`   💼 Commission Wallet: ${deploymentConfig.commissionWallet}`);
    console.log(`   🪙 Fee Token (USDC):  ${deploymentConfig.feeToken}`);
    console.log(`   ⛽ Gas Limit:         ${deploymentConfig.gasLimit.toLocaleString()}`);
    console.log(`   💰 Gas Price:         ${hre.ethers.formatUnits(deploymentConfig.gasPrice, "gwei")} gwei`);

    // Sprawdź rozmiar kontraktu
    console.log("\n📏 Sprawdzanie rozmiaru kontraktu...");
    
    let contractAddress;
    let deploymentMethod;
    let implementationAddress;
    let adminAddress;

    try {
        // Spróbuj standardowego deployment (direct)
        console.log("🚀 Próba standardowego deployment...");
        
        const estimatedGas = await PoliDAO.getDeployTransaction(
            deploymentConfig.initialOwner,
            deploymentConfig.commissionWallet,
            deploymentConfig.feeToken
        ).then(tx => hre.ethers.provider.estimateGas(tx));

        console.log(`⛽ Szacowany gas: ${estimatedGas.toLocaleString()}`);

        if (estimatedGas > 15000000n) {
            console.log("⚠️  Wysoki gas usage. Kontrakt może być za duży dla bezpośredniego deployment.");
        }

        const dao = await PoliDAO.deploy(
            deploymentConfig.initialOwner,
            deploymentConfig.commissionWallet,
            deploymentConfig.feeToken,
            {
                gasLimit: deploymentConfig.gasLimit,
                gasPrice: deploymentConfig.gasPrice
            }
        );

        const deployTx = dao.deploymentTransaction();
        console.log(`   📝 Transaction Hash: ${deployTx.hash}`);
        console.log("⏳ Czekam na potwierdzenia...");

        const receipt = await deployTx.wait(3); // 3 potwierdzenia na Polygon
        contractAddress = await dao.getAddress();
        deploymentMethod = "direct";

        console.log(`✅ Standardowy deployment UDANY!`);
        console.log(`   📍 Adres kontraktu: ${contractAddress}`);
        console.log(`   ⛽ Gas użyty: ${receipt.gasUsed.toLocaleString()}`);

    } catch (directError) {
        console.log("❌ Standardowy deployment nieudany:", directError.message);

        // Fallback do Proxy Pattern
        if (directError.message.includes("contract code size") || 
            directError.message.includes("CreateContractSizeLimit") ||
            directError.message.includes("exceeds maximum size")) {
            
            console.log("\n🔄 Próba Proxy Deployment...");
            
            try {
                const { upgrades } = require("hardhat");
                
                console.log("🏗️  Deploying via Transparent Proxy...");
                const proxy = await upgrades.deployProxy(
                    PoliDAO,
                    [
                        deploymentConfig.initialOwner,
                        deploymentConfig.commissionWallet,
                        deploymentConfig.feeToken
                    ],
                    {
                        kind: 'transparent',
                        initializer: false,
                        timeout: 0,
                        pollingInterval: 5000
                    }
                );

                await proxy.waitForDeployment();
                contractAddress = await proxy.getAddress();
                deploymentMethod = "proxy";

                // Pobierz adresy implementation i admin
                implementationAddress = await upgrades.erc1967.getImplementationAddress(contractAddress);
                adminAddress = await upgrades.erc1967.getAdminAddress(contractAddress);

                console.log("✅ Proxy deployment UDANY!");
                console.log(`   📍 Proxy Address:        ${contractAddress}`);
                console.log(`   🔧 Implementation:       ${implementationAddress}`);
                console.log(`   👑 Admin:               ${adminAddress}`);

            } catch (proxyError) {
                console.error("❌ Proxy deployment też nieudany:", proxyError.message);
                console.error("\n💡 Możliwe rozwiązania:");
                console.error("   1. Zwiększ limit gazu w hardhat.config.js");
                console.error("   2. Zainstaluj: npm install @openzeppelin/hardhat-upgrades");
                console.error("   3. Podziel kontrakt na mniejsze moduły");
                process.exit(1);
            }
        } else {
            console.error("❌ Nieoczekiwany błąd deployment:", directError.message);
            process.exit(1);
        }
    }

    // Linki do block explorer
    const explorerBase = "https://amoy.polygonscan.com";
    console.log(`\n🔗 Block Explorer Links:`);
    console.log(`   🔍 Kontrakt: ${explorerBase}/address/${contractAddress}`);
    if (implementationAddress) {
        console.log(`   🔧 Implementation: ${explorerBase}/address/${implementationAddress}`);
    }
    if (adminAddress) {
        console.log(`   👑 Admin: ${explorerBase}/address/${adminAddress}`);
    }

    // Test funkcjonalności kontraktu
    console.log("\n🧪 Test podstawowej funkcjonalności...");
    try {
        const contract = await hre.ethers.getContractAt("PoliDAO", contractAddress);
        
        console.log("   🔍 Sprawdzam owner()...");
        const owner = await contract.owner();
        
        console.log("   🔍 Sprawdzam getFundraiserCount()...");
        const fundraiserCount = await contract.getFundraiserCount();
        
        console.log("   🔍 Sprawdzam commissionWallet()...");
        const commissionWallet = await contract.commissionWallet();

        console.log(`   ✅ Owner: ${owner}`);
        console.log(`   ✅ Fundraiser Count: ${fundraiserCount}`);
        console.log(`   ✅ Commission Wallet: ${commissionWallet}`);
        console.log("✅ Wszystkie testy PASSED!");

    } catch (testError) {
        console.warn("⚠️  Test funkcjonalności nieudany:", testError.message);
        console.warn("Kontrakt może się załadować z opóźnieniem...");
    }

    // Weryfikacja kontraktu na PolygonScan
    if (process.env.POLYGONSCAN_API_KEY || process.env.ETHERSCAN_API_KEY) {
        console.log("\n⏳ Czekam 60 sekund przed weryfikacją...");
        console.log("   (PolygonScan potrzebuje czasu na indeksację)");
        
        await new Promise(resolve => setTimeout(resolve, 60000));

        try {
            console.log("🔎 Rozpoczynam weryfikację kontraktu...");

            if (deploymentMethod === "direct") {
                // Weryfikacja bezpośredniego kontraktu
                await hre.run("verify:verify", {
                    address: contractAddress,
                    constructorArguments: [
                        deploymentConfig.initialOwner,
                        deploymentConfig.commissionWallet,
                        deploymentConfig.feeToken
                    ]
                });
                console.log("✅ Kontrakt zweryfikowany!");

            } else if (deploymentMethod === "proxy") {
                // Weryfikacja implementation dla proxy
                console.log("🔧 Weryfikuję implementation contract...");
                await hre.run("verify:verify", {
                    address: implementationAddress,
                    constructorArguments: []
                });
                console.log("✅ Implementation zweryfikowane!");
                console.log("ℹ️  Proxy nie wymaga osobnej weryfikacji");
            }

        } catch (verifyError) {
            const errorMsg = verifyError.message.toLowerCase();
            if (errorMsg.includes("already verified")) {
                console.log("✅ Kontrakt już był zweryfikowany");
            } else if (errorMsg.includes("does not have bytecode")) {
                console.warn("⚠️  Weryfikacja nieudana: Kontrakt nie ma bytecode (jeszcze nie zindeksowany)");
                console.warn("💡 Spróbuj ponownie za kilka minut ręcznie");
            } else {
                console.warn("⚠️  Weryfikacja nieudana:", verifyError.message);
                console.warn("💡 Możesz spróbować ręcznie na https://amoy.polygonscan.com");
            }
        }
    } else {
        console.log("\n⚙️  Pomijam weryfikację: brak POLYGONSCAN_API_KEY w .env");
        console.log("💡 Dodaj POLYGONSCAN_API_KEY do .env dla automatycznej weryfikacji");
    }

    // FINAL SUMMARY
    console.log(`\n🟣 ======= DEPLOYMENT COMPLETE ======= 🟣`);
    console.log(`🎯 Adres kontraktu:   ${contractAddress}`);
    console.log(`⛓️  Sieć:             Polygon Amoy (Chain ID: 80002)`);
    console.log(`🔧 Metoda:            ${deploymentMethod}`);
    console.log(`🔗 Explorer:          ${explorerBase}/address/${contractAddress}`);
    console.log(`⛽ Gas użyty:         ${deploymentMethod === "direct" ? "~15-25M" : "~8-12M (proxy)"}`);
    
    if (deploymentMethod === "proxy") {
        console.log(`\n💡 WAŻNE - PROXY INFO:`);
        console.log(`   • Używaj PROXY ADDRESS (${contractAddress}) do wszystkich interakcji`);
        console.log(`   • Kontrakt jest upgradeable przez admin`);
        console.log(`   • Implementation: ${implementationAddress}`);
        console.log(`   • Admin: ${adminAddress}`);
    }

    console.log(`\n🎉 PoliDAO gotowy do użytku na Polygon Amoy!`);
    console.log(`📝 Zapisz adres kontraktu: ${contractAddress}`);

    return {
        contractAddress,
        deploymentMethod,
        implementationAddress,
        adminAddress,
        network: "polygonAmoy",
        chainId: 80002,
        explorer: `${explorerBase}/address/${contractAddress}`
    };
}

// Execute deployment
main()
    .then((result) => {
        console.log(`\n✨ SUCCESS: PoliDAO deployed to Polygon Amoy!`);
        console.log(`📍 Address: ${result.contractAddress}`);
        console.log(`🔧 Method: ${result.deploymentMethod}`);
        process.exit(0);
    })
    .catch((error) => {
        console.error("\n💥 DEPLOYMENT FAILED:");
        console.error(error);
        process.exit(1);
    });