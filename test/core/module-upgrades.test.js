const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

async function loadSystemFixture() {
  // Elastyczny import – obsługa różnych eksportów
  const fixtureMod = require("../fixtures/deploySystemFixture");
  const deployFn =
    fixtureMod.deployFullSystem ||
    fixtureMod.deploySystemFixture ||
    fixtureMod.default ||
    fixtureMod; // jeśli export = function
  return await deployFn();
}

describe("PoliDaoCore Module Upgrades", function () {
  async function deployFixture() {
    const ctx = await loadSystemFixture();
    // Heurystyka: jeśli fixture podmieniła na mock (np. ctx.core.mock === true) – fail fast
    if (!ctx.core || !ctx.core.upgradeGovernanceModule) {
      throw new Error("Real PoliDaoCore not deployed (fixture fell back to mock)");
    }
    return ctx;
  }

  it("owner can upgrade governance module", async () => {
    const ctx = await loadFixture(deployFixture);
    const GovMock = await ethers.getContractFactory("PoliDaoGovernance");
    const newGov = await GovMock.deploy(ctx.storage.target || ctx.storage.address);

    const old = await ctx.core.governanceModule();
    await expect(
      ctx.core.upgradeGovernanceModule(newGov.target || newGov.address)
    )
      .to.emit(ctx.core, "ModuleUpgraded")
      .withArgs("GOVERNANCE", old, newGov.target || newGov.address);

    expect(await ctx.core.governanceModule()).to.equal(newGov.target || newGov.address);
  });

  it("non-owner cannot upgrade", async () => {
    const ctx = await loadFixture(deployFixture);
    const [, attacker] = await ethers.getSigners();
    await expect(
      ctx.core.connect(attacker).upgradeMediaModule(attacker.address)
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("disabling module emits event", async () => {
    const ctx = await loadFixture(deployFixture);
    const old = await ctx.core.mediaModule();
    await expect(ctx.core.upgradeMediaModule(ethers.ZeroAddress))
      .to.emit(ctx.core, "ModuleDisabled")
      .withArgs("MEDIA", old);
    expect(await ctx.core.mediaModule()).to.equal(ethers.ZeroAddress);
  });

  it("locks further upgrades", async () => {
    const ctx = await loadFixture(deployFixture);
    await ctx.core.lockModuleUpgrades();
    await expect(
      ctx.core.upgradeAnalyticsModule(ethers.ZeroAddress)
    ).to.be.revertedWith("Modules locked");
  });
});

describe("Module disable flag", function () {
  it("fully disables governance module (no fallback)", async function () {
    const { core, storage, owner } = await loadFixture(deploySystemFixture);
    const key = ethers.keccak256(ethers.toUtf8Bytes("GOVERNANCE"));

    // Deploy governance module locally (fixture may not provide governanceMock anymore)
    const GovMock = await ethers.getContractFactory("PoliDaoGovernance");
    const gov = await GovMock.deploy(storage.target || storage.address);
    const govAddr = gov.target || gov.address;

    // Set legacy mapping directly in storage (owner only)
    await storage.connect(owner).setModule(key, govAddr);

    // Disable via core
    await expect(core.upgradeGovernanceModule(ethers.ZeroAddress))
      .to.emit(core, "ModuleDisabled");

    // Mapping should be cleared (best-effort)
    const mapped = await storage.modules(key);
    expect(mapped).to.equal(ethers.ZeroAddress);

    // Flag set
    expect(await core.isModuleDisabled("GOVERNANCE")).to.equal(true);
  });
});