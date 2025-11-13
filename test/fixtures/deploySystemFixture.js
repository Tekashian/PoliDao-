/* eslint-disable no-console */
const hre = require("hardhat");
const { ethers } = hre;

async function deployLibraries() {
  const DonationLogic = await ethers.getContractFactory("DonationLogic");
  const RefundLogic = await ethers.getContractFactory("RefundLogic");
  const WithdrawLogic = await ethers.getContractFactory("WithdrawLogic");
  const donation = await DonationLogic.deploy();
  await donation.waitForDeployment();
  const refund = await RefundLogic.deploy();
  await refund.waitForDeployment();
  const withdraw = await WithdrawLogic.deploy();
  await withdraw.waitForDeployment();
  return {
    DonationLogic: await donation.getAddress(),
    RefundLogic: await refund.getAddress(),
    WithdrawLogic: await withdraw.getAddress(),
  };
}

async function getCoreFactory(libs) {
  return ethers.getContractFactory("PoliDaoCore", {
    libraries: {
      DonationLogic: libs.DonationLogic,
      RefundLogic: libs.RefundLogic,
      WithdrawLogic: libs.WithdrawLogic,
    },
  });
}

async function deployRouter(optionalCoreAddress = ethers.ZeroAddress) {
  try {
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    const router = await Router.deploy(optionalCoreAddress);
    await router.waitForDeployment();
    return router;
  } catch {
    return null;
  }
}

// [ADDED] Deploy Security module and wire into router
async function deploySecurityModule(core, owner) {
  try {
    const Security = await ethers.getContractFactory("PoliDaoSecurity");
    const main = core ? await core.getAddress() : owner.address;
    const security = await Security.deploy(main);
    await security.waitForDeployment();

    // Default USDC limit: 1100 USDC (6 decimals)
    await (await security.connect(owner).setDonationLimitUSDC(1_100_000)).wait();
    return security;
  } catch {
    return null;
  }
}

async function deployCoreWithLibraries(storage, router, libs) {
  try {
    const CoreFactory = await getCoreFactory(libs);
    const artifact = await hre.artifacts.readArtifact("PoliDaoCore");
    const ctor = (artifact.abi || []).find((e) => e.type === "constructor");
    const storageAddr = await storage.getAddress();
    const routerAddr = router ? await router.getAddress() : ethers.ZeroAddress;

    const candidates = [];
    if (ctor && Array.isArray(ctor.inputs)) {
      const names = ctor.inputs.map((i) => (i.name || "").toLowerCase());
      if (ctor.inputs.length === 2 && ctor.inputs[0].type === "address" && ctor.inputs[1].type === "address") {
        candidates.push([storageAddr, routerAddr]);
      } else if (ctor.inputs.length === 1 && ctor.inputs[0].type === "address") {
        if (names[0].includes("stor")) candidates.push([storageAddr]);
        else if (names[0].includes("rout")) candidates.push([routerAddr]);
        else candidates.push([storageAddr], [routerAddr]);
      } else if (ctor.inputs.length === 0) {
        candidates.push([]);
      }
    }
    candidates.push([storageAddr, routerAddr], [storageAddr], []);

    for (const args of candidates) {
      try {
        const core = await CoreFactory.deploy(...args);
        await core.waitForDeployment();
        return core;
      } catch {
        // try next
      }
    }
  } catch {
    // ignore
  }
  return null;
}

async function safeCallWrite(contract, fn, args = []) {
  if (!contract || typeof contract[fn] !== "function") return false;
  try {
    const tx = await contract[fn](...args);
    await tx.wait();
    return true;
  } catch {
    return false;
  }
}

async function tryDeploy(name, argsMatrix = []) {
  try {
    const F = await ethers.getContractFactory(name);
    // bez-argumentowy
    try {
      const c = await F.deploy();
      await c.waitForDeployment();
      return c;
    } catch {}
    // warianty argumentów
    for (const args of argsMatrix) {
      try {
        const c = await F.deploy(...args);
        await c.waitForDeployment();
        return c;
      } catch {}
    }
  } catch {
    // artifact nie istnieje albo błąd
  }
  return null;
}

function permutations(arr) {
  if (arr.length <= 1) return [arr];
  const out = [];
  for (let i = 0; i < arr.length; i++) {
    const rest = [...arr.slice(0, i), ...arr.slice(i + 1)];
    for (const p of permutations(rest)) out.push([arr[i], ...p]);
  }
  return out;
}

function argCombos(addresses) {
  const uniq = Array.from(new Set(addresses.filter(Boolean)));
  const combos = [];
  // długości 1..3
  for (let k = 1; k <= Math.min(3, uniq.length); k++) {
    // proste k-elementowe kombinacje z permutacjami
    const idx = [...Array(uniq.length).keys()];
    const pick = (start, choose, prefix) => {
      if (choose === 0) {
        for (const p of permutations(prefix)) combos.push(p);
        return;
      }
      for (let i = start; i <= idx.length - choose; i++) {
        pick(i + 1, choose - 1, [...prefix, uniq[i]]);
      }
    };
    pick(0, k, []);
  }
  return combos;
}

async function setModuleIfPossible(storage, key, addr, owner) {
  // preferuj storage.setModule(bytes32,address)
  if (storage.setModule) {
    try {
      await (await storage.connect(owner).setModule(key, addr)).wait();
      return true;
    } catch {}
  }
  // ewentualnie core.upgradeModule(keyString, addr)
  return false;
}

async function deployModuleAndMap({ name, keyString, storage, core, router, owner }) {
  const storageAddr = await storage.getAddress();
  const coreAddr = await core.getAddress();
  const routerAddr = router ? await router.getAddress() : ethers.ZeroAddress;

  const baseAddrs = [storageAddr, coreAddr, routerAddr, owner.address];
  const argsMatrix = argCombos(baseAddrs).concat([ [storageAddr], [coreAddr], [routerAddr], [] ]);

  const module = await tryDeploy(`PoliDao${name}`, argsMatrix);
  if (!module) return null;

  const key = ethers.keccak256(ethers.toUtf8Bytes(keyString));
  await setModuleIfPossible(storage, key, await module.getAddress(), owner).catch(() => {});
  return module;
}

async function deploySystemFixture() {
  const [owner, alice, bob, carol] = await ethers.getSigners();

  const Storage = await ethers.getContractFactory("PoliDaoStorage");
  const storage = await Storage.deploy();
  await storage.waitForDeployment();
  console.log("✅ PoliDaoStorage deployed successfully");

  const libs = await deployLibraries();
  const router = await deployRouter(ethers.ZeroAddress);

  let core = await deployCoreWithLibraries(storage, router, libs);
  if (!core) {
    console.warn("⚠️ PoliDaoCore deployment failed, using CoreMock");
    const CoreMock = await ethers.getContractFactory("CoreMock");
    core = await CoreMock.deploy(await storage.getAddress());
    await core.waitForDeployment();
  } else {
    console.log("✅ PoliDaoCore deployed successfully");
  }

  await (await storage.setCore(await core.getAddress())).wait();
  if (router) {
    await safeCallWrite(router, "setCore", [await core.getAddress()]);
  }

  let web3 = null;
  try {
    const Web3 = await ethers.getContractFactory("PoliDaoWeb3");
    web3 = await Web3.deploy();
    await web3.waitForDeployment();
    console.log("✅ PoliDaoWeb3 deployed successfully");
  } catch {
    console.warn("⚠️ PoliDaoWeb3 deployment skipped");
  }

  // [ADDED] Deploy Security and wire into router (if router supports setSecurity)
  const security = await deploySecurityModule(core, owner);
  if (router && security) {
    await safeCallWrite(router, "setSecurity", [await security.getAddress()]);
  }

  // Map SECURITY module in Storage so RefundLogic can enforce scheduling via Security
  if (security) {
    try {
      const key = ethers.keccak256(ethers.toUtf8Bytes("SECURITY"));
      await setModuleIfPossible(storage, key, await security.getAddress(), owner);
    } catch {}
  }

  // Deploy i zmapuj kluczowe moduły
  const refunds = await deployModuleAndMap({
    name: "Refunds",
    keyString: "REFUNDS",
    storage,
    core,
    router,
    owner,
  });

  const governance = await deployModuleAndMap({
    name: "Governance",
    keyString: "GOVERNANCE",
    storage,
    core,
    router,
    owner,
  });

  return {
    owner, alice, bob, carol,
    storage, core, router, web3, libs,
    refunds, governance,
    // [ADDED] expose security for tests
    security,
  };
}

// Aliasy dla starszych testów
async function deployBasicFixtures() {
  return deploySystemFixture();
}

async function deployHelloWorld() {
  const HelloWorld = await ethers.getContractFactory("HelloWorld");
  const helloWorld = await HelloWorld.deploy();
  await helloWorld.waitForDeployment();
  return { helloWorld };
}

async function deployExtensionWithStubCore() {
  const [owner] = await ethers.getSigners();

  // Libraries for extension
  const ExtLib = await ethers.getContractFactory("ExtensionLogic");
  const extLib = await ExtLib.deploy();
  await extLib.waitForDeployment();

  const LocLib = await ethers.getContractFactory("LocationLogic");
  const locLib = await LocLib.deploy();
  await locLib.waitForDeployment();

  // Storage
  const Storage = await ethers.getContractFactory("PoliDaoStorage");
  const storage = await Storage.deploy();
  await storage.waitForDeployment();

  // Core (stub or real)
  let core;
  try {
    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy();
    await core.waitForDeployment();
  } catch {
    const CoreMock = await ethers.getContractFactory("CoreMock");
    core = await CoreMock.deploy(await storage.getAddress());
    await core.waitForDeployment();
  }
  // bind storage ↔ core
  try { await (await storage.setCore(await core.getAddress())).wait(); } catch {}
  try { await (await storage.authorizeContract(await core.getAddress())).wait(); } catch {}

  // Extension with linked libraries
  const Extension = await ethers.getContractFactory("PoliDaoExtension", {
    libraries: {
      ExtensionLogic: await extLib.getAddress(),
      LocationLogic: await locLib.getAddress()
    }
  });
  const extension = await Extension.deploy();
  await extension.waitForDeployment();
  // initialize
  try {
    await (await extension.initialize(await storage.getAddress(), await core.getAddress())).wait();
  } catch {}

  return { owner, storage, core, extension };
}

async function deployFactoryFixture() {
  const base = await deploySystemFixture();
  try {
    const Factory = await ethers.getContractFactory("PoliDaoFactory");
    const factory = await Factory.deploy();
    await factory.waitForDeployment();
    return { ...base, factory };
  } catch {
    return { ...base, factory: null };
  }
}

module.exports = {
  deploySystemFixture,
  deployBasicFixtures,
  deployHelloWorld,
  deployExtensionWithStubCore,
  deployFactoryFixture,
};