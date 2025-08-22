const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

async function toUnits(amount, decimals = 18) {
    return ethers.utils.parseUnits(String(amount), decimals);
}

function fromUnits(bn, decimals = 18) {
    return ethers.utils.formatUnits(bn, decimals);
}

function nowPlusDays(days) {
    return Math.floor(Date.now() / 1000) + days * 24 * 3600;
}

function bpsToFraction(bps) {
    // returns numerator, denominator
    return { numerator: bps, denominator: 10000 };
}

/**
 * Deploy MockToken robustly: tries common constructor signatures, then ensures target account has `amount`.
 * Returns { token, minted }.
 */
async function deployMockToken(minterAddress, amountWei) {
    const MockToken = await ethers.getContractFactory("MockToken");
    let token;
    // Try common constructors
    const tries = [
        async () => MockToken.deploy("MockToken", "MCK", 18),
        async () => MockToken.deploy("MockToken", "MCK"),
        async () => MockToken.deploy("MCK", 18),
        async () => MockToken.deploy(ethers.utils.parseUnits("1000000", 18)),
        async () => MockToken.deploy()
    ];
    let deployed = false;
    for (const t of tries) {
        try {
            token = await t();
            await token.deployed();
            deployed = true;
            break;
        } catch (err) {
            // continue
        }
    }
    if (!deployed) throw new Error("deployMockToken: unable to deploy MockToken - check MockToken constructor");

    // Ensure minterAddress has amountWei
    let minted = false;
    if (minterAddress && amountWei) {
        // try mint function
        try {
            if (typeof token.mint === "function") {
                await token.mint(minterAddress, amountWei);
                minted = true;
            }
        } catch (err) { /* ignore */ }

        // fallback transfer if deployer has balance
        if (!minted) {
            try {
                const [deployer] = await ethers.getSigners();
                const deployerBal = await token.balanceOf(deployer.address);
                if (deployerBal.gte(amountWei)) {
                    await token.transfer(minterAddress, amountWei);
                    minted = true;
                }
            } catch (err) { /* ignore */ }
        }

        if (!minted) {
            // Last resort: attempt call to faucet-like function names
            const tryNames = ["faucet", "getTokens", "drip"];
            for (const fn of tryNames) {
                if (typeof token[fn] === "function") {
                    try {
                        await token[fn](minterAddress, amountWei);
                        minted = true;
                        break;
                    } catch (err) { /* ignore */ }
                }
            }
        }
    }

    return { token, minted };
}

/**
 * Helper to assert revert with substring message
 */
async function expectRevert(promise, messageSubstring) {
    try {
        await promise;
    } catch (err) {
        const msg = err.message || err.toString();
        if (!messageSubstring || msg.includes(messageSubstring)) return;
        throw new Error(`Expected revert containing "${messageSubstring}", got: ${msg}`);
    }
    throw new Error("Expected revert but tx succeeded");
}

module.exports = {
    toUnits,
    fromUnits,
    nowPlusDays,
    bpsToFraction,
    deployMockToken,
    expectRevert,
    loadFixture,
};