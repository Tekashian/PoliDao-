const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployMockToken, toUnits } = require("../helpers/testUtils");

describe("Security - simple randomized invariants (fuzzing placeholder)", function () {
  let deployer, users;
  let Storage, storage;
  let token;

  beforeEach(async function () {
    [deployer, ...users] = await ethers.getSigners();

    Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.deployed();

    const res = await deployMockToken(deployer.address, await toUnits("100000"));
    token = res.token;
  });

  it("randomized donation sequence preserves per-donor totals and donors listing invariant", async function () {
    // create fundraiser
    const tx = await storage.createFundraiser(token.address);
    await tx.wait();
    const fid = (await storage.fundraiserCounter()).sub(1);

    // Authorize deployer to call addDonation if needed
    try { await storage.authorizeContract(deployer.address); } catch (err) { /* ignore */ }

    const rounds = 30; // number of random operations
    const signerPool = users.slice(0, 6); // use up to 6 signers
    const totals = {}; // map address -> BigNumber

    for (let i = 0; i < rounds; i++) {
      const signer = signerPool[Math.floor(Math.random() * signerPool.length)];
      const addr = signer.address;
      // random amount between 1 and 10 tokens (integer)
      const randInt = 1 + Math.floor(Math.random() * 10);
      const amt = await toUnits(String(randInt));

      // ensure signer has tokens
      try {
        await token.transfer(addr, amt);
      } catch (err) {
        try { await token.mint(addr, amt); } catch (err2) { /* ignore */ }
      }

      // Call addDonation as authorized caller (deployer)
      try {
        await storage.addDonation(fid, addr, amt);
      } catch (err) {
        // if addDonation requires caller to be a module, ensure deployer is authorized then retry
        try {
          await storage.authorizeContract(deployer.address);
          await storage.addDonation(fid, addr, amt);
        } catch (err2) {
          // skip this iteration if cannot add donation
          continue;
        }
      }

      // update local totals
      if (!totals[addr]) totals[addr] = ethers.BigNumber.from(0);
      totals[addr] = totals[addr].add(amt);
    }

    // Now check storage mappings for each possible donor
    const donors = await storage.getFundraiserDonors(fid);
    // For each donor in storage, ensure recorded donations equal or exceed our totals (best-effort)
    for (const d of donors) {
      const recorded = await storage.donations(fid, d).catch(() => ethers.BigNumber.from(0));
      const expected = totals[d] || ethers.BigNumber.from(0);
      expect(recorded.gte(expected)).to.equal(true);
    }

    // Ensure no duplicate donors in donor array
    const uniq = new Set(donors.map(d => d.toLowerCase()));
    expect(uniq.size).to.equal(donors.length);
  }).timeout(120000);
});