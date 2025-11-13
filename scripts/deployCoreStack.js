/* eslint-disable no-console */
// DEPRECATED: This script targets the legacy non-upgradeable Core. Prefer scripts/deploy-and-verify.js
// with USE_UUPS_CORE=1 for production deployments. Kept for historical reference only.
const { ethers } = require("hardhat");

function selector(signature) {
  return ethers.id(signature).slice(0, 10); // bytes4
}

async function deployWithArgs(name, args = []) {
  const F = await ethers.getContractFactory(name);
  const c = await F.deploy(...args);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  console.log(`Deployed ${name} at ${addr}`);
  return c;
}

async function tryCall(c, fn, args = []) {
  if (typeof c[fn] !== "function") return false;
  const tx = await c[fn](...args);
  await tx.wait();
  return true;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  // 1) Deploy Storage
  const storage = await deployWithArgs("PoliDaoStorage", []);

  // 2) Deploy Core z tymczasowym routerem (nie-zero: użyj adresu deployera)
  const tempRouter = deployer.address;
  const core = await deployWithArgs("PoliDaoCore", [await storage.getAddress(), tempRouter]);

  // 3) Deploy Router (spróbuj z parametrem Core; fallback bez)
  let router;
  try {
    router = await deployWithArgs("PoliDaoRouter", [await core.getAddress()]);
  } catch (e) {
    console.warn("PoliDaoRouter(core) constructor failed, trying no-args...", e.message || e);
    router = await deployWithArgs("PoliDaoRouter", []);
    // jeśli jest setter core w Routerze, ustaw
    await tryCall(router, "setCoreContract", [await core.getAddress()]);
  }

  // 4) Powiąż Core <-> Router
  {
    const tx = await core.setRouterContract(await router.getAddress());
    await tx.wait();
    console.log("Core.routerContract set");
  }

  // 5) Ustaw twarde ACL w Storage (onlyCore) i zamroź
  {
    const tx1 = await storage.setCore(await core.getAddress());
    await tx1.wait();
    console.log("Storage.core set");

    const tx2 = await storage.freezeCore();
    await tx2.wait();
    console.log("Storage.core frozen");
  }

  // 6) (Opcjonalnie) Deploy Extensions i podłącz do Core
  // if you have PoliDaoExtension deployed in your project, uncomment:
  // const ext = await deployWithArgs("PoliDaoExtension", [await storage.getAddress(), await core.getAddress()]);
  // await (await core.setExtensionsContract(await ext.getAddress())).wait();
  // console.log("Extensions bound to Core");

  // 7) Deploy modułu Refunds, zbindowanie do Core, rejestracja w Storage
  let refunds;
  try {
    refunds = await deployWithArgs("PoliDaoRefunds", []);
    // setCore + freezeCore w module (ACL onlyCore)
    if (typeof refunds.setCore === "function") {
      await (await refunds.setCore(await core.getAddress())).wait();
      console.log("Refunds.setCore done");
    }
    if (typeof refunds.freezeCore === "function") {
      await (await refunds.freezeCore()).wait();
      console.log("Refunds.freezeCore done");
    }

    // zarejestruj moduł w Storage pod kluczem "REFUNDS"
    const REFUNDS_KEY = ethers.keccak256(ethers.toUtf8Bytes("REFUNDS"));
    await (await storage.setModule(REFUNDS_KEY, await refunds.getAddress())).wait();
    console.log("Storage.setModule(REFUNDS) done");
  } catch (e) {
    console.warn("Refunds module not deployed or not present. Skipping.", e.message || e);
  }

  // 7b) (Opcjonalnie) Deploy Security module, rejestracja w Storage i podłączenie w Routerze
  let security;
  try {
    security = await deployWithArgs("PoliDaoSecurity", [await core.getAddress()]);
    // Zmapuj w Storage pod kluczem SECURITY, aby RefundLogic mogła egzekwować harmonogram refundów
    try {
      const SECURITY_KEY = ethers.keccak256(ethers.toUtf8Bytes("SECURITY"));
      await (await storage.setModule(SECURITY_KEY, await security.getAddress())).wait();
      console.log("Storage.setModule(SECURITY) done");
    } catch (e) {
      console.warn("Setting SECURITY module mapping failed (optional)", e.message || e);
    }
    // Podłącz Security do Routera, jeśli dostępny setter
    try {
      if (router && typeof router.setSecurity === "function") {
        await (await router.setSecurity(await security.getAddress())).wait();
        console.log("Router.setSecurity done");
      }
    } catch (e) {
      console.warn("Router.setSecurity failed (optional)", e.message || e);
    }
  } catch (e) {
    console.warn("Security module not deployed or not present. Skipping.", e.message || e);
  }

  // 8) Allow‑lista selectorów w Routerze (dla routeModule/routeModuleStatic)
  try {
    const batch = [];
    // Przykładowe selektory (dopasuj do faktycznych modułów):
    if (refunds) {
      batch.push(selector("claimRefund(uint256,address)"));
      // jeśli moduł ma więcej funkcji udostępnianych przez routeModule, dodaj tutaj
    }
    // MEDIA przykład:
    // const MEDIA_KEY = ethers.keccak256(ethers.toUtf8Bytes("MEDIA"));
    // const mediaSelectors = [ selector("addMedia(uint256,(string,string)[])") ];
    // await (await router.setAllowedSelectorsBatch(MEDIA_KEY, mediaSelectors, true)).wait();

    // Rejestracja allow‑listy dla REFUNDS
    if (batch.length > 0) {
      const REFUNDS_KEY = ethers.keccak256(ethers.toUtf8Bytes("REFUNDS"));
      await (await router.setAllowedSelectorsBatch(REFUNDS_KEY, batch, true)).wait();
      console.log("Router allow‑list set for REFUNDS");
    }
  } catch (e) {
    console.warn("Router allow‑list configuration skipped:", e.message || e);
  }

  // 9) Walidacja konfiguracji
  const cs = await core.getContractStatus();
  console.log("Core status:", cs);

  // Krótkie asercje
  if (cs.routerAddress.toLowerCase() !== (await router.getAddress()).toLowerCase()) {
    throw new Error("Router not set in Core");
  }
  if ((await storage.core()).toLowerCase() !== (await core.getAddress()).toLowerCase()) {
    throw new Error("Storage.core not set to Core");
  }

  console.log("Deployment and initialization completed.");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}