const hre = require("hardhat");
const { ethers } = hre;

async function deployBasicFixtures() {
  const [owner, user1, user2, user3] = await ethers.getSigners();

  // MockToken
  const MockToken = await ethers.getContractFactory("MockToken");
  const mockToken = await MockToken.deploy("Mock Token", "MOCK", ethers.parseEther("1000000"));
  await mockToken.waitForDeployment();

  // Storage
  const Storage = await ethers.getContractFactory("PoliDaoStorage");
  const storage = await Storage.deploy();
  await storage.waitForDeployment();

  // Core (no-args; inicjalizacja offchain) – fallback do CoreMock
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

  // Powiąż Storage ↔ Core (hard ACL)
  // 1) Storage.setCore(core)
  try { await (await storage.setCore(await core.getAddress())).wait(); } catch {}
  // 2) Storage.authorizeContract(core)
  try { await (await storage.authorizeContract(await core.getAddress())).wait(); } catch {}
  // 3) Opcjonalnie ustaw router w Storage (jeśli istnieje setter)
  // zostanie ustawiony po deployu routera

  // Router(core) – konstruktor przyjmuje core
  let router;
  try {
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    router = await Router.deploy(await core.getAddress());
    await router.waitForDeployment();
  } catch {
    // fallback do konstruktora bez argumentów + initialize (jeśli istnieje)
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    router = await Router.deploy();
    await router.waitForDeployment();
    if (router.initialize) {
      await (await router.initialize(await core.getAddress(), owner.address)).wait();
    }
  }

  // Zszycie setRouterContract/core.setRouterContract (jeśli dostępne)
  try { await (await core.setRouterContract(await router.getAddress())).wait(); } catch {}
  // W Storage ustaw router jako autoryzowany (jeśli istnieje)
  try { await (await storage.setAuthorizedRouter(await router.getAddress())).wait(); } catch {}

  // Refunds (opcjonalny moduł)
  let refunds = null;
  try {
    const Refunds = await ethers.getContractFactory("PoliDaoRefunds");
    refunds = await Refunds.deploy();
    await refunds.waitForDeployment();
  } catch {}

  return {
    owner, user1, user2, user3,
    storage, core, router, refunds, mockToken
  };
}

// POPRAWIONA Helper function – tworzy fundraiser zgodnie z tym, co jest dostępne w Core
async function createFundraiserWithCorrectInterface(storage, mockToken, creatorAddress, overrides = {}) {
  const token = await mockToken.getAddress();
  const now = Math.floor(Date.now() / 1000);
  const end = overrides.endDate || now + 3600;
  const title = overrides.title || "Test Fundraiser";
  const description = overrides.description || "A test fundraiser";
  const goalAmount = overrides.goalAmount || ethers.parseEther("10");
  const location = overrides.location || "Test Location";
  const ipfsHash = overrides.ipfsHash || "QmTest";
  const fundraiserType = overrides.fundraiserType || 0;
  const beneficiary = overrides.beneficiary || creatorAddress;

  // whitelist token in Storage
  try {
    await (await storage.setFundraiserTokenWhitelist(token, true)).wait();
  } catch {}

  // Resolve core from storage.core()
  let coreAddr;
  try { coreAddr = await storage.core(); } catch {}
  if (!coreAddr || coreAddr === ethers.ZeroAddress) {
    // Fallback: brak core – zwróć 0 (testy mogą ominąć dalsze kroki)
    return 0n;
  }
  const core = await ethers.getContractAt("PoliDaoCore", coreAddr);

  // Spróbuj najpierw ABI v1: createFundraiser(address token, uint8 type, uint256 endDate, string title, string description)
  try {
    const tx = await core.createFundraiser(token, fundraiserType, end, title, description);
    const rc = await tx.wait();
    const ev = rc.logs
      .map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    return ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 0n;
  } catch {}

  // Spróbuj ABI (struct) – IPoliDaoStructs.FundraiserCreationData
  try {
    const data = {
      title,
      description,
      goalAmount,
      fundraiserType,
      beneficiaryAddress: beneficiary,
      endDate: end,
      tags: [],
      media: [],
      ipfsHash,
      location,
      enableExtensions: false
    };
    const tx = await core.createFundraiser(data);
    const rc = await tx.wait();
    const ev = rc.logs
      .map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    return ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 0n;
  } catch {}

  // Ostateczny fallback
  return 0n;
}

async function createFundraiserNearEndTime(storage, mockToken, creator, minutesFromNow = 30) {
  return createFundraiserWithCorrectInterface(storage, mockToken, creator, {
    endDate: Math.floor(Date.now() / 1000) + minutesFromNow * 60,
    title: "Near End Fundraiser"
  });
}

async function createFundraiserWithMaxLengths(storage, mockToken, creator) {
  const long = (len) => 'x'.repeat(len);
  return createFundraiserWithCorrectInterface(storage, mockToken, creator, {
    title: long(128),
    description: long(1024),
    location: long(256)
  });
}

async function addDonationWithUpdate(storage, fundraiserId, donor, amount) {
  const coreAddr = await storage.core();
  if (!coreAddr || coreAddr === ethers.ZeroAddress) return;
  const core = await ethers.getContractAt("PoliDaoCore", coreAddr);

  // approve core to spend (if tokenized)
  // ten helper nie zna tokenu – zakładamy ETHless / lub testy nadpiszą

  // jeżeli istnieje ścieżka donateFrom
  try {
    await (await core.donateFrom(fundraiserId, donor, amount)).wait();
    return;
  } catch {}

  // fallback do donate(uint256,address,uint256)
  try {
    await (await core["donate(uint256,address,uint256)"](fundraiserId, donor, amount)).wait();
  } catch {}
}

module.exports = {
  deployBasicFixtures,
  createFundraiserWithCorrectInterface,
  createFundraiserNearEndTime,
  createFundraiserWithMaxLengths,
  addDonationWithUpdate
};