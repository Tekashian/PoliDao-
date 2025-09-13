const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    
    console.log("Deploying tokens whitelist with account:", deployer.address);
    console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());
    
    // Get deployed core contract address from command line or environment
    const coreAddress = process.env.CORE_ADDRESS || process.argv[2];
    if (!coreAddress) {
        throw new Error("Please provide CORE_ADDRESS environment variable or as command line argument");
    }
    
    console.log("Core contract address:", coreAddress);
    
    const core = await ethers.getContractAt("PoliDaoCore", coreAddress);
    
    // Network-specific tokens
    const tokens = {
        mainnet: [
            { address: "0xA0b86a33E6Ba6B641be77678579bA0f5DCC4644", name: "USDC" },
            { address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", name: "USDT" }
        ],
        polygon: [
            { address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", name: "USDC" },
            { address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", name: "USDT" }
        ],
        sepolia: [
            // Mock tokens for testnet
        ],
        hardhat: [
            // Will be deployed mock tokens
        ]
    };
    
    const networkTokens = tokens[hre.network.name] || [];
    
    if (networkTokens.length === 0) {
        console.log("No predefined tokens for network:", hre.network.name);
        return;
    }
    
    console.log(`Adding ${networkTokens.length} tokens to whitelist...`);
    
    for (const token of networkTokens) {
        try {
            const tx = await core.whitelistToken(token.address);
            await tx.wait();
            console.log(`✅ Added ${token.name}: ${token.address}`);
        } catch (error) {
            console.log(`❌ Failed to add ${token.name}: ${error.message}`);
        }
    }
    
    // List all whitelisted tokens
    try {
        const whitelistedTokens = await core.getWhitelistedTokens();
        console.log("\nCurrent whitelisted tokens:");
        whitelistedTokens.forEach((token, index) => {
            console.log(`${index + 1}. ${token}`);
        });
    } catch (error) {
        console.log("Error fetching whitelisted tokens:", error.message);
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});