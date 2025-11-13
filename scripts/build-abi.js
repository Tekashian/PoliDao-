/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");

// Lista artefaktów (po kompilacji Hardhat)
// Preferuj upgradeowalny Core jeśli istnieje; w przeciwnym razie użyj klasycznego
const CONTRACTS = [
  // Core (prefer UUPS)
  "core/PoliDaoCoreUpgradeable.sol/PoliDaoCoreUpgradeable.json|AS:PoliDaoCore.abi.json",
  "core/PoliDaoCore.sol/PoliDaoCore.json|AS:PoliDaoCore.abi.json",
  "router/PoliDaoRouter.sol/PoliDaoRouter.json",
  "modules/PoliDaoMedia.sol/PoliDaoMedia.json",
  "modules/PoliDaoUpdates.sol/PoliDaoUpdates.json",
  "modules/PoliDaoRefunds.sol/PoliDaoRefunds.json",
  "modules/PoliDaoGovernance.sol/PoliDaoGovernance.json",
  "modules/PoliDaoAnalytics.sol/PoliDaoAnalytics.json",
  "modules/PoliDaoSecurity.sol/PoliDaoSecurity.json",
  "modules/PoliDaoWeb3.sol/PoliDaoWeb3.json",
  "storage/PoliDaoStorage.sol/PoliDaoStorage.json" // opcjonalnie
];

// Gdzie zapisać ABI (zmień jeśli frontend jest osobno)
const OUT_DIR = path.join(__dirname, "..", "frontend-abi");

function ensureDir(d) {
  if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true });
}

function main() {
  const artifactsDir = path.join(__dirname, "..", "artifacts", "contracts");
  ensureDir(OUT_DIR);

  const combined = [];
  const sigSet = new Set();

  for (const entry of CONTRACTS) {
    // allow mapping output filename via suffix "|AS:<file>"
    const [rel, asOut] = entry.split("|AS:");
    const artifactPath = path.join(artifactsDir, rel);
    if (!fs.existsSync(artifactPath)) {
      // Silently skip when upgradeable core is missing; classic core fallback will handle it
      if (!rel.includes("PoliDaoCoreUpgradeable")) {
        console.warn("Missing artifact (skip):", rel);
      }
      continue;
    }
    const json = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const abi = json.abi || [];

    // Zapis pojedynczego ABI (z mapowaniem nazwy jeśli podano |AS:)
    const defaultOut = rel.split("/").pop().replace(".json", ".abi.json");
    const shortName = asOut || defaultOut;
    fs.writeFileSync(path.join(OUT_DIR, shortName), JSON.stringify(abi, null, 2));

    // Dodawanie do combined (unikając duplikatów sygnatur)
    for (const entry of abi) {
      if (entry.type === "function" || entry.type === "event" || entry.type === "error") {
        const sig = JSON.stringify({
          t: entry.type,
          n: entry.name,
          i: entry.inputs,
          a: entry.anonymous
        });
        if (sigSet.has(sig)) continue;
        sigSet.add(sig);
      }
      combined.push(entry);
    }
  }

  // Zapis Combined
  const combinedPath = path.join(OUT_DIR, "CombinedABI.json");
  fs.writeFileSync(combinedPath, JSON.stringify(combined, null, 2));

  console.log("Zapisano pojedyncze ABI oraz CombinedABI.json w:", OUT_DIR);
  console.log("Pliki do skopiowania do frontendu.");
}

main();