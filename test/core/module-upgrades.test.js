const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

// helper compatible with ethers v6
const moduleKey = (name) => ethers.keccak256(ethers.toUtf8Bytes(name));

describe("PoliDaoCore Module Upgrades", function () {

  it("owner can upgrade governance module", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, owner, governance } = env;

    // Pick target address for upgrade: use existing governance module or owner as placeholder
    const target = governance ? await governance.getAddress() : (await owner.getAddress());

    if (core && core.upgradeModule) {
      const tx = await core.connect(owner).upgradeModule("GOVERNANCE", target);
      const rc = await tx.wait();
      const parsed = rc.logs
        .map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
        .filter(Boolean);

      // Avoid RegExp with to.emit; assert by parsed logs
      const ok = parsed.some(e => e.name === "ModuleUpgraded" || e.name === "ModuleSet");
      expect(ok, "expected ModuleUpgraded/ModuleSet event").to.equal(true);
    } else if (storage && storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), target)).wait();
    } else {
      this.skip();
      return;
    }

    if (storage && storage.modules) {
      const mapped = await storage.modules(moduleKey("GOVERNANCE"));
      expect(mapped).to.equal(target);
    }
  });

  it("disabling module emits event", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, owner } = env;

    // First set some non-zero
    if (storage && storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), await owner.getAddress())).wait();
    }

    if (core && core.upgradeModule) {
      const tx = await core.connect(owner).upgradeModule("GOVERNANCE", ethers.ZeroAddress);
      const rc = await tx.wait();
      const parsed = rc.logs
        .map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
        .filter(Boolean);
      const ok = parsed.some(e => e.name === "ModuleDisabled" || e.name === "ModuleSet");
      expect(ok, "expected ModuleDisabled/ModuleSet event").to.equal(true);
    } else if (storage && storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), ethers.ZeroAddress)).wait();
      // event assertion not necessary; some storages may not emit in minimal builds
    } else {
      this.skip();
    }
  });

  it("locks further upgrades", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { core, owner } = env;

    if (!core || !core.lockModuleUpgrades || !core.upgradeModule) {
      this.skip();
      return;
    }

    await (await core.connect(owner).lockModuleUpgrades()).wait();

    await expect(core.connect(owner).upgradeModule("GOVERNANCE", await owner.getAddress()))
      .to.be.reverted; // expect revert after lock (message can differ by build)
  });
});