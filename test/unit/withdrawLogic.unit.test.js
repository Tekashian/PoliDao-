const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployBasicFixtures } = require("../fixtures/basicMocksFixture");

describe("WithdrawLogic - unit tests (via PoliDaoStorage releaseFunds)", function () {
    let storage, mockToken, owner, user1;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        storage = fixtures.storage;
        mockToken = fixtures.mockToken;
        owner = fixtures.owner;
        user1 = fixtures.user1;
        
        // Fund storage contract for withdraw tests
        try {
            await mockToken.transfer(await storage.getAddress(), ethers.parseEther("1000"));
        } catch (error) {
            throw new Error("Unable to fund storage with MockToken for withdraw tests; update MockToken.");
        }
    });

    it("only authorized/owner can call releaseFunds: unauthorized call reverts", async function () {
        // Unauthorized user should not be able to release funds
        await expect(
            storage.connect(user1).releaseFunds(
                await mockToken.getAddress(), 
                user1.address, 
                ethers.parseEther("100")
            )
        ).to.be.reverted;
        
        // Owner should be able to release funds
        await expect(
            storage.releaseFunds(
                await mockToken.getAddress(), 
                user1.address, 
                ethers.parseEther("100")
            )
        ).to.emit(storage, "FundsReleased");
    });
});
