const { ethers } = require("hardhat");
const { expect } = require("chai");

/**
 * Common test utilities and helper functions
 */

/**
 * Create a sample fundraiser with default values
 */
async function createSampleFundraiser(storage, tokenAddress, overrides = {}) {
    const defaults = {
        title: "Test Fundraiser",
        description: "Test Description",
        location: "Test Location",
        goalAmount: ethers.parseEther("100"),
        endTime: Math.floor(Date.now() / 1000) + 86400, // 1 day from now
        isFlexible: false
    };
    
    const params = { ...defaults, ...overrides };
    
    const tx = await storage.createFundraiser(
        params.title,
        params.description,
        params.location,
        params.goalAmount,
        params.endTime,
        tokenAddress,
        params.isFlexible
    );
    
    await tx.wait();
    return 1n; // First fundraiser ID
}

/**
 * Fund user with tokens and approve spending
 */
async function fundAndApprove(token, user, spender, amount) {
    await token.transfer(user.address, amount);
    await token.connect(user).approve(spender, amount);
}

/**
 * Make a donation to a fundraiser
 */
async function makeDonation(storage, token, user, fundraiserId, amount) {
    await fundAndApprove(token, user, await storage.getAddress(), amount);
    await storage.connect(user).addDonation(fundraiserId, amount);
}

/**
 * Fast forward time
 */
async function fastForwardTime(seconds) {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine");
}

/**
 * Get current timestamp
 */
async function getCurrentTimestamp() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp;
}

/**
 * Assert that transaction reverts with specific message
 */
async function expectRevertWithMessage(transaction, message) {
    await expect(transaction).to.be.revertedWith(message);
}

/**
 * Assert that transaction emits specific event
 */
async function expectEventEmitted(transaction, contract, eventName, ...args) {
    await expect(transaction).to.emit(contract, eventName).withArgs(...args);
}

/**
 * Generate random string of specified length
 */
function randomString(length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

/**
 * Generate random address
 */
function randomAddress() {
    return ethers.Wallet.createRandom().address;
}

/**
 * Convert percentage to basis points
 */
function percentToBps(percent) {
    return Math.floor(percent * 100);
}

/**
 * Calculate percentage of amount
 */
function calculatePercentage(amount, percentage) {
    return (BigInt(amount) * BigInt(percentToBps(percentage))) / 10000n;
}

/**
 * Check if two BigInt values are approximately equal (within tolerance)
 */
function approximately(actual, expected, tolerance = 1n) {
    const diff = actual > expected ? actual - expected : expected - actual;
    return diff <= tolerance;
}

/**
 * Create test accounts with ETH and token balances
 */
async function createTestAccounts(token, count = 3) {
    const signers = await ethers.getSigners();
    const accounts = signers.slice(1, count + 1); // Skip owner
    
    for (const account of accounts) {
        await token.transfer(account.address, ethers.parseEther("1000"));
    }
    
    return accounts;
}

/**
 * Deploy and configure basic test environment
 */
async function setupTestEnvironment() {
    const [owner] = await ethers.getSigners();
    
    // This would typically call fixture functions
    // For now, just return owner
    return { owner };
}

module.exports = {
    createSampleFundraiser,
    fundAndApprove,
    makeDonation,
    fastForwardTime,
    getCurrentTimestamp,
    expectRevertWithMessage,
    expectEventEmitted,
    randomString,
    randomAddress,
    percentToBps,
    calculatePercentage,
    approximately,
    createTestAccounts,
    setupTestEnvironment
};