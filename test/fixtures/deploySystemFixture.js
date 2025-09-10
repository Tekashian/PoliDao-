const { ethers } = require("hardhat");

/**
 * Deploy complete PoliDao system with all modules
 */
async function deploySystemFixture() {
    const [owner, user1, user2, user3, commissionWallet] = await ethers.getSigners();
    
    // Deploy MockToken for testing
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Test Token", "TEST", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();
    
    // Deploy core storage
    const PoliDaoStorage = await ethers.getContractFactory("PoliDaoStorage");
    const storage = await PoliDaoStorage.deploy();
    await storage.waitForDeployment();
    
    // Deploy router
    const PoliDaoRouter = await ethers.getContractFactory("PoliDaoRouter");
    const router = await PoliDaoRouter.deploy(await storage.getAddress());
    await router.waitForDeployment();
    
    // Deploy factory
    const PoliDaoFactory = await ethers.getContractFactory("PoliDaoFactory");
    const factory = await PoliDaoFactory.deploy();
    await factory.waitForDeployment();
    
    // Deploy modules
    const PoliDaoRefunds = await ethers.getContractFactory("PoliDaoRefunds");
    const refunds = await PoliDaoRefunds.deploy(await router.getAddress(), commissionWallet.address);
    await refunds.waitForDeployment();
    
    const PoliDaoAnalytics = await ethers.getContractFactory("PoliDaoAnalytics");
    const analytics = await PoliDaoAnalytics.deploy(await storage.getAddress());
    await analytics.waitForDeployment();
    
    const PoliDaoSecurity = await ethers.getContractFactory("PoliDaoSecurity");
    const security = await PoliDaoSecurity.deploy(await storage.getAddress());
    await security.waitForDeployment();
    
    // Setup initial configuration
    await storage.setAuthorizedRouter(await router.getAddress());
    await storage.authorizeContract(await refunds.getAddress());
    await storage.authorizeContract(await analytics.getAddress());
    await storage.authorizeContract(await security.getAddress());
    
    // Add mock token to whitelist
    await storage.addWhitelistedToken(await mockToken.getAddress());
    
    return {
        // Core
        storage,
        router,
        factory,
        
        // Modules
        refunds,
        analytics,
        security,
        
        // Tokens
        mockToken,
        
        // Accounts
        owner,
        user1,
        user2,
        user3,
        commissionWallet
    };
}

/**
 * Deploy minimal system (storage + router only)
 */
async function deployMinimalSystemFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Test Token", "TEST", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();
    
    const PoliDaoStorage = await ethers.getContractFactory("PoliDaoStorage");
    const storage = await PoliDaoStorage.deploy();
    await storage.waitForDeployment();
    
    const PoliDaoRouter = await ethers.getContractFactory("PoliDaoRouter");
    const router = await PoliDaoRouter.deploy(await storage.getAddress());
    await router.waitForDeployment();
    
    await storage.setAuthorizedRouter(await router.getAddress());
    await storage.addWhitelistedToken(await mockToken.getAddress());
    
    return {
        storage,
        router,
        mockToken,
        owner,
        user1,
        user2
    };
}

module.exports = {
    deploySystemFixture,
    deployMinimalSystemFixture
};