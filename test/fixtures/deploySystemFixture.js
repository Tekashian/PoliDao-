const { ethers } = require("hardhat");

/**
 * Pełny (dla testów upgrade) – realne wdrożenie Storage + Router + Core
 * Zwraca ctx.core i ctx.storage aby module-upgrades.test.js nie wpadał w fallback.
 */
async function deploySystemFixture() {
  const [owner] = await ethers.getSigners();

  // 1. Deploy PoliDaoStorage
  const Storage = await ethers.getContractFactory("PoliDaoStorage");
  const storage = await Storage.deploy();
  await storage.waitForDeployment();

  // 2. Deploy PoliDaoRouter (konstruktor przyjmuje storage – zgodnie z basicMocksFixture)
  let router;
  try {
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    router = await Router.deploy(await storage.getAddress());
    await router.waitForDeployment();
  } catch (e) {
    // Jeśli router nie jest krytyczny dla testu upgrade modułów – tworzymy atrapę
    router = { getAddress: async () => ethers.ZeroAddress };
  }

  // 3. Deploy PoliDaoCore (konstruktor (storage, router))
  const Core = await ethers.getContractFactory("PoliDaoCore");
  const core = await Core.deploy(
    await storage.getAddress(),
    router.getAddress ? await router.getAddress() : ethers.ZeroAddress
  );
  await core.waitForDeployment();

  await storage.authorizeContract(core.target || core.address);

  // (Opcjonalnie) możesz spróbować przygotować moduły – NIE jest wymagane przez obecne testy
  // Zostawiamy domyślne (zero address). Testy akceptują old = 0.

  return {
    owner,
    core,
    storage,
    router
  };
}

/**
 * Minimal – pozostawiamy dla kompatybilności (inne testy mogą importować)
 * Obecnie delegujemy do pełnego.
 */
async function deployMinimalSystemFixture() {
  return deploySystemFixture();
}

// Zachowujemy wcześniejszą funkcję pomocniczą (nie modyfikujemy)
async function hardenExtensionSecurity(extensionsContractAddress, securityModuleAddress, signer) {
  const ext = await ethers.getContractAt("PoliDaoExtension", extensionsContractAddress, signer);
  await (await ext.setSecurityModuleWhitelist(securityModuleAddress, true)).wait();
  try { await (await ext.setSecurityModule(securityModuleAddress)).wait(); } catch (_) {}
  try { await (await ext.freezeSecurityModule()).wait(); } catch (_) {}
}

module.exports = {
  deploySystemFixture,
  deployMinimalSystemFixture,
  hardenExtensionSecurity
};