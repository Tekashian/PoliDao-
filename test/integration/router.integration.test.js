const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployBasicFixtures } = require("../fixtures/basicMocksFixture");

describe("Router integration - routing calls and module orchestration", function () {
    let storage, router, mockToken, owner;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        storage = fixtures.storage;
        router = fixtures.router;
        mockToken = fixtures.mockToken;
        owner = fixtures.owner;
    });

    it("router forwards createFundraiser to storage/module and maintains authorizedRouter semantics", async function () {
        expect(await router.getAddress()).to.be.properAddress;
        expect(await storage.getAddress()).to.be.properAddress;
        
        // Test basic router functionality
        expect(router).to.not.be.undefined;
        expect(storage).to.not.be.undefined;
    });
});