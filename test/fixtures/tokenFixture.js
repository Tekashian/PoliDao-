const { ethers } = require("hardhat");

/**
 * Deploy various token fixtures for testing
 */

/**
 * Deploy standard MockToken
 */
async function deployMockTokenFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Mock Token", "MOCK", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();
    
    return {
        mockToken,
        owner,
        user1,
        user2
    };
}

/**
 * Deploy multiple test tokens
 */
async function deployMultipleTokensFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    
    const MockToken = await ethers.getContractFactory("MockToken");
    
    const tokenA = await MockToken.deploy("Token A", "TOKA", ethers.parseEther("1000000"));
    await tokenA.waitForDeployment();
    
    const tokenB = await MockToken.deploy("Token B", "TOKB", ethers.parseEther("500000"));
    await tokenB.waitForDeployment();
    
    const tokenC = await MockToken.deploy("Token C", "TOKC", ethers.parseEther("2000000"));
    await tokenC.waitForDeployment();
    
    return {
        tokenA,
        tokenB,
        tokenC,
        owner,
        user1,
        user2
    };
}

/**
 * Deploy token with pre-funded users
 */
async function deployFundedTokenFixture() {
    const [owner, user1, user2, user3] = await ethers.getSigners();
    
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Funded Token", "FUND", ethers.parseEther("10000000"));
    await mockToken.waitForDeployment();
    
    // Fund users with tokens
    await mockToken.transfer(user1.address, ethers.parseEther("100000"));
    await mockToken.transfer(user2.address, ethers.parseEther("50000"));
    await mockToken.transfer(user3.address, ethers.parseEther("25000"));
    
    return {
        mockToken,
        owner,
        user1,
        user2,
        user3
    };
}

/**
 * Deploy token with custom decimals
 */
async function deployCustomDecimalsTokenFixture(decimals = 6) {
    const [owner, user1, user2] = await ethers.getSigners();
    
    // For custom decimals, we'd need a different mock contract
    // For now, use standard MockToken
    const MockToken = await ethers.getContractFactory("MockToken");
    const mockToken = await MockToken.deploy("Custom Token", "CUST", ethers.parseUnits("1000000", decimals));
    await mockToken.waitForDeployment();
    
    return {
        mockToken,
        decimals,
        owner,
        user1,
        user2
    };
}

/**
 * Deploy token fixture with approvals set up
 */
async function deployApprovedTokenFixture(spenderAddress) {
    const fixture = await deployFundedTokenFixture();
    const { mockToken, user1, user2, user3 } = fixture;
    
    if (spenderAddress) {
        // Set up approvals for spender
        await mockToken.connect(user1).approve(spenderAddress, ethers.parseEther("50000"));
        await mockToken.connect(user2).approve(spenderAddress, ethers.parseEther("25000"));
        await mockToken.connect(user3).approve(spenderAddress, ethers.parseEther("12500"));
    }
    
    return {
        ...fixture,
        spenderAddress
    };
}

module.exports = {
    deployMockTokenFixture,
    deployMultipleTokensFixture,
    deployFundedTokenFixture,
    deployCustomDecimalsTokenFixture,
    deployApprovedTokenFixture
};