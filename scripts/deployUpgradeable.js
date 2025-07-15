// scripts/deployUpgradeable.js
// Deploy PoliDAO jako upgradeable proxy z initialize()

const { ethers, upgrades } = require("hardhat");

async function main() {
    console.log(`\n--- Deploying PoliDAO Upgradeable na ${hre.network.name} ---`);

    const [deployer] = await ethers.getSigners();
    console.log(`👤 Deployer: ${deployer.address}`);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log(`💰 Balance: ${ethers.formatEther(balance)} ETH`);

    // Parametry dla initialize()
    const initialOwner = deployer.address;
    const commissionWallet = deployer.address;
    const feeToken = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"; // USDC Sepolia

    console.log("\n📦 Initialize parameters:");
    console.log(`   initialOwner: ${initialOwner}`);
    console.log(`   commissionWallet: ${commissionWallet}`);
    console.log(`   feeToken: ${feeToken}`);

    console.log("\n🚀 Deploying upgradeable proxy...");
    
    try {
        // Get factory dla upgradeable wersji
        const PoliDAOUpgradeable = await ethers.getContractFactory("PoliDAOUpgradeable");
        console.log("✅ Factory retrieved");

        // Deploy przez proxy z initialize()
        const proxy = await upgrades.deployProxy(
            PoliDAOUpgradeable,
            [initialOwner, commissionWallet, feeToken],
            {
                kind: 'uups',              // UUPS proxy pattern
                initializer: 'initialize'  // Użyj initialize() zamiast constructor
            }
        );

        console.log("⏳ Waiting for deployment...");
        await proxy.waitForDeployment();
        
        const proxyAddress = await proxy.getAddress();
        console.log(`✅ SUCCESS! Proxy deployed at: ${proxyAddress}`);

        // Get implementation address
        const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
        console.log(`🔧 Implementation: ${implementationAddress}`);

        // Test basic functionality
        console.log("\n🧪 Testing contract...");
        const owner = await proxy.owner();
        const feeTokenSet = await proxy.feeToken();
        const fundraiserCount = await proxy.getFundraiserCount();
        
        console.log(`✅ Owner: ${owner}`);
        console.log(`✅ Fee Token: ${feeTokenSet}`);
        console.log(`✅ Fundraiser Count: ${fundraiserCount}`);
        
        // Whitelist test token
        console.log("\n🪙 Whitelisting USDC token...");
        const tx = await proxy.whitelistToken(feeToken);
        await tx.wait();
        console.log("✅ USDC token whitelisted");

        console.log(`\n🔗 Etherscan Links:`);
        console.log(`   📋 Proxy (main): https://sepolia.etherscan.io/address/${proxyAddress}`);
        console.log(`   🔧 Implementation: https://sepolia.etherscan.io/address/${implementationAddress}`);

        console.log(`\n💡 IMPORTANT:`);
        console.log(`   • Use PROXY ADDRESS for all interactions: ${proxyAddress}`);
        console.log(`   • Contract is upgradeable using UUPS pattern`);
        console.log(`   • Only owner can authorize upgrades`);

        // Optional verification
        if (process.env.ETHERSCAN_API_KEY && !["hardhat", "localhost"].includes(hre.network.name)) {
            console.log("\n⏳ Waiting 60s before verification...");
            await new Promise(resolve => setTimeout(resolve, 60000));

            try {
                console.log("🔎 Verifying implementation...");
                await hre.run("verify:verify", {
                    address: implementationAddress,
                    constructorArguments: []
                });
                console.log("✅ Verification successful!");
            } catch (verifyError) {
                console.warn("⚠️ Verification failed:", verifyError.message);
            }
        }

        return {
            proxy: proxyAddress,
            implementation: implementationAddress
        };

    } catch (error) {
        console.error("💥 Deployment failed:", error.message);
        throw error;
    }
}

main()
    .then(result => {
        console.log("\n🎉 DEPLOYMENT SUCCESSFUL!");
        console.log(`📍 Proxy Address: ${result.proxy}`);
        console.log(`🔧 Implementation: ${result.implementation}`);
        console.log("\n💡 Use the PROXY ADDRESS for all contract interactions!");
        process.exit(0);
    })
    .catch(error => {
        console.error("\n💥 DEPLOYMENT FAILED:", error.message);
        process.exit(1);
    });