const { ethers } = require("hardhat");

async function deployStack() {
  const [owner] = await ethers.getSigners();

  const StorageF = await ethers.getContractFactory("PoliDaoStorage");
  const storage = await StorageF.deploy();
  await storage.waitForDeployment();

  const RouterF = await ethers.getContractFactory("PoliDaoRouter");
  // na starcie możemy podać tymczasowo poprawny core po deployu, więc użyjemy initialize poniżej jeśli potrzebne
  const dummyCore = ethers.ZeroAddress;
  const router = await RouterF.deploy(dummyCore);
  await router.waitForDeployment();

  const CoreF = await ethers.getContractFactory("PoliDaoCore");
  // jeśli konstruktor Core wymaga routera, przekaż router
  const core = await CoreF.deploy(await storage.getAddress(), await router.getAddress());
  await core.waitForDeployment();

  // powiązania i autoryzacje
  try {
    await core.connect(owner).setRouterContract(await router.getAddress());
  } catch (_) {}
  try {
    await storage.connect(owner).authorizeContract(await core.getAddress());
  } catch (_) {}

  // jeśli Router ma setCore, ustaw
  try {
    await router.connect(owner).initialize(await core.getAddress(), owner.address);
  } catch (_) {}
  try {
    await router.connect(owner).setCore(await core.getAddress());
  } catch (_) {}

  return { storage, core, router, owner };
}

function makeFundraiserData(overrides = {}) {
  // Uzupełnij wymagane pola struktury FundraiserCreationData.
  // Dodaj brakujące komponenty jak initialImages: []
  const now = Math.floor(Date.now() / 1000);
  return {
    title: "Test",
    description: "Desc",
    location: "PL",
    endDate: now + 7 * 24 * 3600,
    fundraiserType: 0,
    token: ethers.ZeroAddress,
    goalAmount: 0,
    initialImages: [], // KLUCZOWE: brakujący komponent
    ...overrides,
  };
}

module.exports = { deployStack, makeFundraiserData };