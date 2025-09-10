const { ethers } = require("hardhat");

async function deployBasicFixtures() {
    const [owner, user1, user2, user3] = await ethers.getSigners();
    
    // Deploy MockToken
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy(
        "Mock Token", 
        "MOCK", 
        ethers.parseEther("1000000")
    );
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
    const refunds = await PoliDaoRefunds.deploy(
        await router.getAddress(), 
        owner.address
    );
    await refunds.waitForDeployment();
    
    // Deploy PoliDaoFactory
    let factory = null;
    try {
        const PoliDaoFactory = await ethers.getContractFactory("PoliDaoFactory");
        factory = await PoliDaoFactory.deploy();
        await factory.waitForDeployment();
    } catch (error) {
        console.log("PoliDaoFactory deployment failed:", error.message);
    }
    
    // Deploy ReentrancyAttackMock
    let reentrancyMock = null;
    try {
        const ReentrancyAttackMock = await ethers.getContractFactory("ReentrancyAttackMock");
        reentrancyMock = await ReentrancyAttackMock.deploy();
        await reentrancyMock.waitForDeployment();
    } catch (error) {
        console.log("ReentrancyAttackMock deployment failed:", error.message);
        // Create a minimal mock
        reentrancyMock = {
            getAddress: async () => ethers.ZeroAddress,
            interface: { fragments: [] }
        };
    }
    
    return {
        storage,
        router,
        refunds,
        factory,
        mockToken,
        reentrancyMock,
        owner,
        user1,
        user2,
        user3
    };
}

async function deployHelloWorld() {
    const HelloWorld = await ethers.getContractFactory("HelloWorld");
    const helloWorld = await HelloWorld.deploy();
    await helloWorld.waitForDeployment();
    return helloWorld;
}

// POPRAWIONA Helper function to create fundraiser with correct interface
async function createFundraiserWithCorrectInterface(storage, mockToken, creator, overrides = {}) {
    const defaults = {
        goalAmount: ethers.parseEther("100"),
        endDate: Math.floor(Date.now() / 1000) + 86400, // 1 day from now
        fundraiserType: 0, // WITH_GOAL
        isFlexible: false,
        title: "Test Campaign",
        description: "Test Description",
        location: "Test Location"
    };
    
    const params = { ...defaults, ...overrides };
    
    // Create PackedFundraiserData struct according to IPoliDaoStructs
    const packedData = {
        goalAmount: params.goalAmount,      // uint128
        raisedAmount: 0n,                   // uint128
        endDate: params.endDate,            // uint64
        originalEndDate: params.endDate,    // uint64
        id: 0,                              // uint32 - will be set by contract
        suspensionTime: 0,                  // uint32
        extensionCount: 0,                  // uint16
        fundraiserType: params.fundraiserType, // uint8
        status: 0,                          // uint8 - ACTIVE
        isSuspended: false,                 // bool
        fundsWithdrawn: false,              // bool
        isFlexible: params.isFlexible       // bool
    };
    
    try {
        // First add token to whitelist if not already
        await storage.addWhitelistedToken(await mockToken.getAddress());
        
        const tx = await storage.createFundraiser(
            packedData,
            params.title,
            params.description,
            params.location,
            creator,
            await mockToken.getAddress()
        );
        
        await tx.wait();
        
        // Get the fundraiser counter to return the ID
        const fundraiserCounter = await storage.fundraiserCounter();
        return fundraiserCounter;
        
    } catch (error) {
        console.log("createFundraiserWithCorrectInterface failed:", error.message);
        throw error;
    }
}

module.exports = { 
    deployBasicFixtures, 
    deployHelloWorld, 
    createFundraiserWithCorrectInterface 
};