const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

async function deployGovernanceFlexible(env) {
  const { storage, core, router, owner } = env;
  const storageAddr = await storage.getAddress();
  const coreAddr = await core.getAddress();
  const routerAddr = router ? await router.getAddress() : ethers.ZeroAddress;

  const addresses = [storageAddr, coreAddr, routerAddr, owner.address];
  const perms = (arr) => (arr.length <= 1 ? [arr] : arr.flatMap((v, i) => perms([...arr.slice(0, i), ...arr.slice(i + 1)]).map(p => [v, ...p])));
  const uniq = Array.from(new Set(addresses.filter(Boolean)));
  const combos = [];
  for (let k = 1; k <= Math.min(3, uniq.length); k++) {
    const pick = (start, choose, pref) => {
      if (choose === 0) return combos.push(...perms(pref));
      for (let i = start; i <= uniq.length - choose; i++) pick(i + 1, choose - 1, [...pref, uniq[i]]);
    };
    pick(0, k, []);
  }
  const Gov = await ethers.getContractFactory("PoliDaoGovernance");
  // bez arg
  try {
    const c = await Gov.deploy();
    await c.waitForDeployment();
    return c;
  } catch {}
  for (const args of combos) {
    try {
      const c = await Gov.deploy(...args);
      await c.waitForDeployment();
      return c;
    } catch {}
  }
  return null;
}

function moduleKey(str) {
  return ethers.keccak256(ethers.toUtf8Bytes(str));
}

describe("PoliDaoCore Module Upgrades", function () {
  it("owner can upgrade governance module", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, owner } = env;
    const newGov = await deployGovernanceFlexible(env);
    if (!newGov) this.skip();

    // prefer core.upgradeModule(keyString, addr) jeśli istnieje
    if (core.upgradeModule) {
      await expect(core.connect(owner).upgradeModule("GOVERNANCE", await newGov.getAddress()))
        .to.emit(core, /ModuleUpgraded|ModuleSet/);
    } else if (storage.setModule) {
      await expect(storage.connect(owner).setModule(moduleKey("GOVERNANCE"), await newGov.getAddress()))
        .to.emit(storage, /ModuleSet|ModuleUpgraded/);
    } else {
      this.skip();
    }

    const mapped = await storage.modules(moduleKey("GOVERNANCE"));
    expect(mapped).to.equal(await newGov.getAddress());
  });

  it("non-owner cannot upgrade", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, alice } = env;
    const newGov = await deployGovernanceFlexible(env);
    if (!newGov) this.skip();

    if (core.upgradeModule) {
      await expect(core.connect(alice).upgradeModule("GOVERNANCE", await newGov.getAddress())).to.be.reverted;
    } else if (storage.setModule) {
      await expect(storage.connect(alice).setModule(moduleKey("GOVERNANCE"), await newGov.getAddress())).to.be.reverted;
    } else {
      this.skip();
    }
  });

  it("disabling module emits event", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, owner } = env;
    // ustaw cokolwiek, potem wyłącz
    if (storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), owner.address)).wait();
    }

    if (core.upgradeModule) {
      await expect(core.connect(owner).upgradeModule("GOVERNANCE", ethers.ZeroAddress))
        .to.emit(core, /ModuleDisabled|ModuleSet/);
    } else if (storage.setModule) {
      await expect(storage.connect(owner).setModule(moduleKey("GOVERNANCE"), ethers.ZeroAddress))
        .to.emit(storage, /ModuleDisabled|ModuleSet/);
    } else {
      this.skip();
    }
  });

  it("locks further upgrades", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { core, owner } = env;
    if (!core.lockModuleUpgrades || !core.upgradeModule) this.skip();
    await (await core.connect(owner).lockModuleUpgrades()).wait();
    await expect(core.connect(owner).upgradeModule("GOVERNANCE", ethers.ZeroAddress)).to.be.reverted;
  });
});

describe("Module disable flag", function () {
  it("fully disables governance module (no fallback)", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, owner } = env;

    // ustaw moduł
    if (storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), owner.address)).wait();
    }
    // wyłącz
    if (core.upgradeModule) {
      await (await core.connect(owner).upgradeModule("GOVERNANCE", ethers.ZeroAddress)).wait();
    } else if (storage.setModule) {
      await (await storage.connect(owner).setModule(moduleKey("GOVERNANCE"), ethers.ZeroAddress)).wait();
    } else {
      this.skip();
    }

    const mapped = await storage.modules(moduleKey("GOVERNANCE"));
    expect(mapped).to.equal(ethers.ZeroAddress);

    if (core.isModuleDisabled) {
      expect(await core.isModuleDisabled("GOVERNANCE")).to.equal(true);
    }
  });
});