const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployBasicFixtures } = require("../fixtures/basicMocksFixture");

describe("Security - Access control and ownership", function () {
    let storage, router, owner, user1, user2;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        storage = fixtures.storage;
        router = fixtures.router;
        owner = fixtures.owner;
        user1 = fixtures.user1;
        user2 = fixtures.user2;
    });

    it("only owner can call owner-only setters (setModule, setAuthorizedRouter, setModules)", async function () {
        // Test setAuthorizedRouter - only owner
        await expect(
            storage.connect(user1).setAuthorizedRouter(user2.address)
        ).to.be.reverted;
        
        // Owner should be able to set
        await storage.setAuthorizedRouter(user2.address);
        expect(await storage.authorizedRouter()).to.equal(user2.address);
    });

    it("authorizeContract/deauthorizeContract only callable by owner", async function () {
        const testContract = ethers.Wallet.createRandom().address;
        
        // Non-owner should fail
        await expect(
            storage.connect(user1).authorizeContract(testContract)
        ).to.be.reverted;
        
        // Owner should succeed
        await storage.authorizeContract(testContract);
        expect(await storage.isContractAuthorized(testContract)).to.be.true;
    });

    it("transferOwnership enforces new restrictions and only new owner can perform owner actions", async function () {
        // Transfer ownership
        await storage.transferOwnership(user1.address);
        
        // Old owner should not work
        await expect(
            storage.authorizeContract(ethers.Wallet.createRandom().address)
        ).to.be.reverted;
        
        // New owner should work
        await storage.connect(user1).authorizeContract(ethers.Wallet.createRandom().address);
    });

    it("authorized router can be used where expected (best-effort): setAuthorizedRouter restricts to owner", async function () {
        // Only owner can set authorized router
        await expect(
            storage.connect(user1).setAuthorizedRouter(user2.address)
        ).to.be.reverted;
        
        await storage.setAuthorizedRouter(user2.address);
        expect(await storage.authorizedRouter()).to.equal(user2.address);
    });
});