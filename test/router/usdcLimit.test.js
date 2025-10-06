const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Router USDC donation limit", function () {
  it("enforces 1100 USDC limit via Security before forwarding to Core", async function () {
    const [owner, donor] = await ethers.getSigners();

    // Deploy mocks
    const Storage = await ethers.getContractFactory("MockStorage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("MockCore");
    const core = await Core.deploy(await storage.getAddress());
    await core.waitForDeployment();

    // Use fully qualified name to avoid HH701
    const Router = await ethers.getContractFactory("contracts/router/PoliDaoRouter.sol:PoliDaoRouter");
    const router = await Router.deploy(await core.getAddress());
    await router.waitForDeployment();

    const Security = await ethers.getContractFactory("PoliDaoSecurity");
    const security = await Security.deploy(await core.getAddress());
    await security.waitForDeployment();

    // USDC mock and limit
    const USDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await USDC.deploy(ethers.parseUnits("1000000", 6));
    await usdc.waitForDeployment();

    await (await security.setUSDC(await usdc.getAddress())).wait();
    await (await security.setDonationLimitUSDC(1_100_000)).wait(); // 1100 USDC

    // Wire security into router
    await (await router.setSecurity(await security.getAddress())).wait();

    // Fundraiser uses USDC
    await (await storage.setFundraiserToken(1, await usdc.getAddress())).wait();

    // Helper: resolve effective limit (fallback to default if security == 0)
    const getEffectiveLimit = async () => {
      const l = await security.donationLimitUSDC();
      return l === 0n ? 1_100_000n : l;
    };

    const limit = await getEffectiveLimit();
    const above = limit + 1n;

    // Above limit should revert
    await expect(
      router.connect(donor).donate(1, above)
    ).to.be.revertedWith("Donation exceeds USDC limit");

    // At limit should pass and forward to core (listen for event)
    await expect(
      router.connect(donor).donate(1, limit)
    ).to.emit(core, "DonateForwarded").withArgs(donor.address, 1, limit);

    // Batch: include one entry above limit should revert
    await expect(
      router.connect(donor).batchDonate([1, 1], [limit / 2n, above])
    ).to.be.revertedWith("Donation exceeds USDC limit");

    // Batch: both within limit should pass
    await expect(
      router.connect(donor).batchDonate([1, 1], [limit / 2n, limit / 2n])
    ).to.emit(core, "BatchDonateForwarded");
  });

  it("respects admin-updated limit from Security (increase and decrease)", async function () {
    const [owner, donor] = await ethers.getSigners();

    // Deploy mocks
    const Storage = await ethers.getContractFactory("MockStorage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("MockCore");
    const core = await Core.deploy(await storage.getAddress());
    await core.waitForDeployment();

    // Use fully qualified name to avoid HH701
    const Router = await ethers.getContractFactory("contracts/router/PoliDaoRouter.sol:PoliDaoRouter");
    const router = await Router.deploy(await core.getAddress());
    await router.waitForDeployment();

    const Security = await ethers.getContractFactory("PoliDaoSecurity");
    const security = await Security.deploy(await core.getAddress());
    await security.waitForDeployment();

    const USDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await USDC.deploy(ethers.parseUnits("1000000", 6));
    await usdc.waitForDeployment();

    // Wire up
    await (await security.setUSDC(await usdc.getAddress())).wait();
    await (await router.setSecurity(await security.getAddress())).wait();
    await (await storage.setFundraiserToken(1, await usdc.getAddress())).wait();

    // Helper: resolve effective limit
    const getEffectiveLimit = async () => {
      const l = await security.donationLimitUSDC();
      return l === 0n ? 1_100_000n : l;
    };

    // Increase limit to 2000 USDC
    await (await security.connect(owner).setDonationLimitUSDC(2_000_000)).wait();
    const limitInc = await getEffectiveLimit();
    expect(limitInc).to.equal(2_000_000n);
    const aboveInc = limitInc + 1n;

    await expect(router.connect(donor).donate(1, aboveInc)).to.be.revertedWith("Donation exceeds USDC limit");
    await expect(router.connect(donor).donate(1, limitInc)).to.emit(core, "DonateForwarded").withArgs(donor.address, 1, limitInc);

    // Decrease limit to 500 USDC
    await (await security.connect(owner).setDonationLimitUSDC(500_000)).wait();
    const limitDec = await getEffectiveLimit();
    expect(limitDec).to.equal(500_000n);
    const aboveDec = limitDec + 1n;

    await expect(router.connect(donor).donate(1, aboveDec)).to.be.revertedWith("Donation exceeds USDC limit");
    await expect(router.connect(donor).donate(1, limitDec)).to.emit(core, "DonateForwarded").withArgs(donor.address, 1, limitDec);
  });

  it("falls back to default limit when admin sets Security limit to zero", async function () {
    const [owner, donor] = await ethers.getSigners();

    // Deploy mocks
    const Storage = await ethers.getContractFactory("MockStorage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("MockCore");
    const core = await Core.deploy(await storage.getAddress());
    await core.waitForDeployment();

    // Use fully qualified name to avoid HH701
    const Router = await ethers.getContractFactory("contracts/router/PoliDaoRouter.sol:PoliDaoRouter");
    const router = await Router.deploy(await core.getAddress());
    await router.waitForDeployment();

    const Security = await ethers.getContractFactory("PoliDaoSecurity");
    const security = await Security.deploy(await core.getAddress());
    await security.waitForDeployment();

    const USDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await USDC.deploy(ethers.parseUnits("1000000", 6));
    await usdc.waitForDeployment();

    await (await security.setUSDC(await usdc.getAddress())).wait();
    await (await router.setSecurity(await security.getAddress())).wait();
    await (await storage.setFundraiserToken(1, await usdc.getAddress())).wait();

    // Set Security limit to zero -> effective = default (1100 USDC)
    await (await security.connect(owner).setDonationLimitUSDC(0)).wait();

    const getEffectiveLimit = async () => {
      const l = await security.donationLimitUSDC();
      return l === 0n ? 1_100_000n : l;
    };

    const limit = await getEffectiveLimit();
    expect(limit).to.equal(1_100_000n);
    const above = limit + 1n;

    await expect(router.connect(donor).donate(1, above)).to.be.revertedWith("Donation exceeds USDC limit");
    await expect(router.connect(donor).donate(1, limit)).to.emit(core, "DonateForwarded").withArgs(donor.address, 1, limit);
  });
});
