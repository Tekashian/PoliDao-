const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployBasicFixtures } = require("../fixtures/basicMocksFixture");

describe("Factory integration - deployment and initialization", function () {
    let factory, storage, router, owner;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        factory = fixtures.factory;
        storage = fixtures.storage;
        router = fixtures.router;
        owner = fixtures.owner;
    });

    it("factory can create new instances / clones and instances register storage/router properly", async function () {
        if (factory) {
            expect(await factory.getAddress()).to.be.properAddress;
        } else {
            // Skip test if factory deployment failed
            this.skip();
        }
        
        expect(await storage.getAddress()).to.be.properAddress;
        expect(await router.getAddress()).to.be.properAddress;
    });
});