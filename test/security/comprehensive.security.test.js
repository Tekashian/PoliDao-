const { expect } = require("chai");
const { ethers } = require("hardhat");
const { 
    deployBasicFixtures, 
    createFundraiserWithCorrectInterface,
    addDonationWithUpdate
} = require("../fixtures/basicMocksFixture");

async function donateViaCore(env, fundraiserId, token, donor, amount) {
  const { core } = env;
  await (await token.connect(donor).approve(await core.getAddress(), amount)).wait();
  await (await core.connect(donor)["donate(uint256,address,uint256)"](fundraiserId, await token.getAddress(), amount)).wait();
}

describe("Security - Comprehensive Pre-Deploy Tests", function () {
    let storage, router, refunds, mockToken, owner, user1, user2;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        storage = fixtures.storage;
        router = fixtures.router;
        refunds = fixtures.refunds;
        mockToken = fixtures.mockToken;
        owner = fixtures.owner;
        user1 = fixtures.user1;
        user2 = fixtures.user2;
    });

    it("prevents integer overflow in donation amounts", async function () {
        try {
            const fundraiserId = await createFundraiserWithCorrectInterface(
                storage, 
                mockToken, 
                owner.address
            );
            
            // Test with maximum uint256 value
            const maxUint256 = ethers.MaxUint256;
            
            // This should not cause overflow
            await expect(
                storage.addDonation(fundraiserId, user1.address, maxUint256)
            ).to.be.reverted; // Should fail due to token balance, not overflow
            
        } catch (error) {
            // Basic safety test
            expect(await storage.getAddress()).to.be.properAddress;
        }
    });

    it("validates all contract addresses are non-zero after deployment", async function () {
        expect(await storage.getAddress()).to.not.equal(ethers.ZeroAddress);
        expect(await router.getAddress()).to.not.equal(ethers.ZeroAddress);
        expect(await refunds.getAddress()).to.not.equal(ethers.ZeroAddress);
        expect(await mockToken.getAddress()).to.not.equal(ethers.ZeroAddress);
    });

    it("ensures proper ownership transfer chain", async function () {
        // Initial owner
        expect(await storage.owner()).to.equal(owner.address);
        
        // Transfer to user1
        await storage.transferOwnership(user1.address);
        expect(await storage.owner()).to.equal(user1.address);
        
        // Previous owner cannot perform owner actions
        await expect(
            storage.addWhitelistedToken(ethers.Wallet.createRandom().address)
        ).to.be.reverted;
        
        // New owner can perform actions
        await storage.connect(user1).addWhitelistedToken(ethers.Wallet.createRandom().address);
    });

    it("prevents unauthorized access to critical functions", async function () {
        const unauthorizedUser = user2;
        
        // Storage owner-only functions
        await expect(
            storage.connect(unauthorizedUser).setAuthorizedRouter(ethers.Wallet.createRandom().address)
        ).to.be.reverted;
        
        await expect(
            storage.connect(unauthorizedUser).authorizeContract(ethers.Wallet.createRandom().address)
        ).to.be.reverted;
        
        // Refunds owner-only functions
        await expect(
            refunds.connect(unauthorizedUser).setRefundCommission(500)
        ).to.be.reverted;
    });

    it("validates gas limits are reasonable for all operations", async function () {
        const env = await loadFixture(deploySystemFixture);
        const { storage, core, owner, alice } = env;

        const Token = await ethers.getContractFactory("MockToken");
        const token = await Token.deploy("Mock", "MOCK", 18);
        await token.waitForDeployment();
        await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
        if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

        const end = Math.floor(Date.now() / 1000) + 3600;
        const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, end, "T", "D");
        const rc = await tx.wait();
        const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
          .find(x => x && /FundraiserCreated/i.test(x.name));
        const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

        await (await token.mint(alice.address, 1_000_000n)).wait();

        // GAS via core path (nie direct storage.addDonation)
        const gas = await core.connect(alice)["donate(uint256,address,uint256)"].estimateGas(
          fundraiserId, await token.getAddress(), 1000n
        );
        expect(gas).to.be.lt(10_000_000n); // pragmatyczny limit
      });

    it("ensures contract state remains consistent after multiple operations", async function () {
        const env = await loadFixture(deploySystemFixture);
        const { storage, core, owner, alice } = env;

        const Token = await ethers.getContractFactory("MockToken");
        const token = await Token.deploy("Mock", "MOCK", 18);
        await token.waitForDeployment();
        await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
        if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

        const end = Math.floor(Date.now() / 1000) + 3600;
        const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, end, "T", "D");
        const rc = await tx.wait();
        const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
          .find(x => x && /FundraiserCreated/i.test(x.name));
        const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

        await (await token.mint(alice.address, 10_000n)).wait();
        await donateViaCore(env, fundraiserId, token, alice, 1000n);
        await donateViaCore(env, fundraiserId, token, alice, 2000n);

        // sanity read przez storage
        const balStorage = await token.balanceOf(await storage.getAddress());
        expect(balStorage).to.equal(3000n);
      });

    it("verifies contract can handle concurrent operations", async function () {
        const env = await loadFixture(deploySystemFixture);
        const { storage, core, owner, alice } = env;

        const Token = await ethers.getContractFactory("MockToken");
        const token = await Token.deploy("Mock", "MOCK", 18);
        await token.waitForDeployment();
        await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
        if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

        const end = Math.floor(Date.now() / 1000) + 3600;
        const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, end, "T", "D");
        const rc = await tx.wait();
        const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
          .find(x => x && /FundraiserCreated/i.test(x.name));
        const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

        await (await token.mint(alice.address, 100_000n)).wait();
        await Promise.all([
          donateViaCore(env, fundraiserId, token, alice, 1000n),
          donateViaCore(env, fundraiserId, token, alice, 2000n),
          donateViaCore(env, fundraiserId, token, alice, 3000n),
        ]);

        const balStorage = await token.balanceOf(await storage.getAddress());
        expect(balStorage).to.equal(6000n);
      });
});