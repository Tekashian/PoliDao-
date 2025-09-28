const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

function hasFn(contract, signature) {
  try { return !!(contract && contract.interface.getFunction(signature)); } catch { return false; }
}

// Low-level invoke by signature (ethers v6-safe)
async function callBySignature(contract, signer, signature, args) {
  const to = await contract.getAddress();
  const data = contract.interface.encodeFunctionData(signature, args);
  const tx = await signer.sendTransaction({ to, data });
  return tx.wait();
}

describe("Interface compliance - Storage ABI", function () {
  let storage;

  before(async function () {
    const fx = await loadFixture(deploySystemFixture);
    storage = fx.storage;
    expect(storage).to.exist;
  });

  it("forbids deprecated shims or locks them behind permissions", async function () {
    const SIG_ADD_DON = "addDonation(uint256,address,address,uint256)";
    const SIG_AUTH_BOOL = "authorizeContract(address,bool)";
    const [owner, nonOwner] = await ethers.getSigners();

    // addDonation(…4) nie powinno istnieć; jeśli istnieje, nie powinno być dostępne dla nie-core
    if (hasFn(storage, SIG_ADD_DON)) {
      await expect(
        callBySignature(storage, nonOwner, SIG_ADD_DON, [1n, nonOwner.address, ethers.ZeroAddress, 1n])
      ).to.be.reverted;
    } else {
      expect(true).to.equal(true);
    }

    // authorizeContract(address,bool) nie powinno istnieć; jeśli istnieje, tylko owner
    if (hasFn(storage, SIG_AUTH_BOOL)) {
      await expect(
        callBySignature(storage, nonOwner, SIG_AUTH_BOOL, [nonOwner.address, true])
      ).to.be.reverted;
      // opcjonalnie: owner może wywołać lub też rewertuje wg implementacji
      await expect(
        callBySignature(storage, owner, SIG_AUTH_BOOL, [nonOwner.address, false])
      ).to.be.reverted; // dopuszczalne, zależnie od implementacji
    } else {
      expect(true).to.equal(true);
    }
  });

  it("exposes canonical authorization functions", async function () {
    const iface = storage.interface;
    expect(iface.getFunction("authorizeContract(address)").name).to.equal("authorizeContract");
    expect(iface.getFunction("deauthorizeContract(address)").name).to.equal("deauthorizeContract");
  });
});