const { ethers } = require("hardhat");

async function deployBasicFixtures() {
    const [owner, user1, user2, user3] = await ethers.getSigners();
    
    // Deploy MockToken
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Mock Token", "MOCK", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();
    
    // Deploy PoliDaoStorage
    const PoliDaoStorage = await ethers.getContractFactory("PoliDaoStorage");
    const storage = await PoliDaoStorage.deploy();
    await storage.waitForDeployment();
    
    // Deploy PoliDaoRouter
    const PoliDaoRouter = await ethers.getContractFactory("PoliDaoRouter");
    const router = await PoliDaoRouter.deploy(await storage.getAddress());
    await router.waitForDeployment();
    
    // Deploy PoliDaoRefunds
    const PoliDaoRefunds = await ethers.getContractFactory("PoliDaoRefunds");
    const refunds = await PoliDaoRefunds.deploy(await router.getAddress(), owner.address);
    await refunds.waitForDeployment();
    
    return {
        storage,
        router,
        refunds,
        mockToken,
        owner,
        user1,
        user2,
        user3
    };
}

module.exports = { deployBasicFixtures };