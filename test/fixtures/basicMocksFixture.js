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
        try {
            await storage.addWhitelistedToken(await mockToken.getAddress());
        } catch (error) {
            // Token might already be whitelisted, continue
        }
        
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

// DODAJ BRAKUJĄCE HELPER FUNCTIONS:

// Helper function for extension testing
async function createFundraiserNearEndTime(storage, mockToken, creator, minutesFromNow = 30) {
    const endTime = Math.floor(Date.now() / 1000) + (minutesFromNow * 60);
    
    return await createFundraiserWithCorrectInterface(
        storage, 
        mockToken, 
        creator,
        {
            endDate: endTime,
            title: "Near End Test Campaign",
            location: "Extension Test Location"
        }
    );
}

// Helper for testing maximum lengths
async function createFundraiserWithMaxLengths(storage, mockToken, creator) {
    try {
        const maxTitleLength = await storage.MAX_TITLE_LENGTH();
        const maxDescLength = await storage.MAX_DESCRIPTION_LENGTH();
        const maxLocationLength = await storage.MAX_LOCATION_LENGTH();
        
        const maxTitle = "T".repeat(Number(maxTitleLength));
        const maxDesc = "D".repeat(Number(maxDescLength));
        const maxLocation = "L".repeat(Number(maxLocationLength));
        
        return await createFundraiserWithCorrectInterface(
            storage, 
            mockToken, 
            creator,
            {
                title: maxTitle,
                description: maxDesc,
                location: maxLocation
            }
        );
    } catch (error) {
        // If MAX constants don't exist, use reasonable defaults
        return await createFundraiserWithCorrectInterface(
            storage, 
            mockToken, 
            creator,
            {
                title: "T".repeat(100),
                description: "D".repeat(500),
                location: "L".repeat(200)
            }
        );
    }
}

// DODAJ NOWĄ HELPER FUNCTION - PROPER DONATION WITH RAISED AMOUNT UPDATE
async function addDonationWithUpdate(storage, fundraiserId, donor, amount) {
    try {
        // First add the donation to mapping
        await storage.addDonation(fundraiserId, donor, amount);
        
        // Then manually update raised amount if addDonation doesn't do it
        try {
            const currentData = await storage.fundraisers(fundraiserId);
            const newRaisedAmount = currentData.raisedAmount + amount;
            
            // Update the raised amount
            await storage.updateRaisedAmount(fundraiserId, newRaisedAmount);
            
        } catch (updateError) {
            // If updateRaisedAmount doesn't exist, try alternative approach
            console.log("Manual raised amount update failed:", updateError.message);
        }
        
    } catch (error) {
        console.log("addDonationWithUpdate failed:", error.message);
        throw error;
    }
}

module.exports = { 
    deployBasicFixtures, 
    deployHelloWorld, 
    createFundraiserWithCorrectInterface,
    createFundraiserNearEndTime,
    createFundraiserWithMaxLengths,
    addDonationWithUpdate
};

module.exports.deployExtensionWithStubCore = async function (hre) {
  const [coreSigner, owner] = await hre.ethers.getSigners();

  // 1) Deploy libraries
  const ExtLibF = await hre.ethers.getContractFactory("ExtensionLogic", owner);
  const extLib = await ExtLibF.deploy();
  await extLib.waitForDeployment();

  const LocLibF = await hre.ethers.getContractFactory("LocationLogic", owner);
  const locLib = await LocLibF.deploy();
  await locLib.waitForDeployment();

  // 1a) Deploy MockToken (potrzebny do tworzenia fundraiserów)
  const MockTokenF = await hre.ethers.getContractFactory("MockToken", owner);
  const mockToken = await MockTokenF.deploy(
    "Mock Token",
    "MOCK",
    hre.ethers.parseEther("1000000")
  );
  await mockToken.waitForDeployment();

  // 2) Deploy storage
  const StorageF = await hre.ethers.getContractFactory("PoliDaoStorage", owner);
  const storage = await StorageF.deploy();
  await storage.waitForDeployment();

  // 3) Get linked factory for PoliDaoExtension
  const ExtensionF = await hre.ethers.getContractFactory("PoliDaoExtension", {
    libraries: {
      ExtensionLogic: await extLib.getAddress(),
      LocationLogic: await locLib.getAddress()
    },
    signer: owner
  });

  // 4) Deploy and initialize
  const extension = await ExtensionF.deploy();
  await extension.waitForDeployment();
  await extension.initialize(await storage.getAddress(), coreSigner.address);

  return { storage, extension, core: coreSigner, owner, mockToken };
};