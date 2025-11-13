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

async function getUpgradeableCoreFactory(libs) {
  // CoreUpgradeable bytecode has no external link references in OZ v5 layout;
  // obtain factory without library linking to avoid HardhatEthersError.
  return ethers.getContractFactory("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable");
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

async function deployCoreUUPSWithLibraries(storage, owner, libs) {
  try {
    const CoreFactory = await getUpgradeableCoreFactory(libs);
    const impl = await CoreFactory.deploy();
    await impl.waitForDeployment();
    const implAddr = await impl.getAddress();

    const initData = CoreFactory.interface.encodeFunctionData("initialize", [await storage.getAddress(), owner.address]);
    const ProxyFactory = await ethers.getContractFactory("@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
    const proxy = await ProxyFactory.deploy(implAddr, initData);
    await proxy.waitForDeployment();

    const core = await ethers.getContractAt("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable", await proxy.getAddress());
    return { core, impl, proxy };
  } catch {
    return null;
  }
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

  // Deploy upgradeable Core (UUPS + proxy)
  let coreBundle = await deployCoreUUPSWithLibraries(storage, owner, libs);
  let core;
  if (!coreBundle) {
    console.warn("⚠️ PoliDaoCore deployment failed, using CoreMock");
    const CoreMock = await ethers.getContractFactory("CoreMock");
    core = await CoreMock.deploy(await storage.getAddress());
    await core.waitForDeployment();
  } else {
    core = coreBundle.core;
    console.log("✅ PoliDaoCoreUpgradeable (proxy) deployed successfully");
  }

  await (await storage.setCore(await core.getAddress())).wait();

  // Router after Core so we can pass the proxy address to ctor
  const router = await deployRouter(await core.getAddress());

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
  deployExtensionWithStubCore,
  deployFactoryFixture,
};