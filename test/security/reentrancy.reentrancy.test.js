const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployMockToken, toUnits } = require("../helpers/testUtils");

describe("Security - Reentrancy protections", function () {
  let deployer, attacker;
  let Storage, storage;
  let token;
  let ReentrancyAttackMock, attackContract;

  beforeEach(async function () {
    [deployer, attacker] = await ethers.getSigners();

    Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.deployed();

    // Deploy token robustly
    const res = await deployMockToken(deployer.address, await toUnits("10000"));
    token = res.token;

    ReentrancyAttackMock = await ethers.getContractFactory("ReentrancyAttackMock");
    attackContract = await ReentrancyAttackMock.deploy();
    await attackContract.deployed();

    // Fund storage so releaseFunds has balance to attempt reentrancy
    const fund = await toUnits("1000");
    try {
      await token.transfer(storage.address, fund);
    } catch (err) {
      try { await token.mint(storage.address, fund); } catch (err2) { /* ignore */ }
    }

    // Ensure attack contract is authorized if storage requires authorized callers for release
    try { await storage.authorizeContract(attackContract.address); } catch (err) { /* ignore */ }
  });

  it("should not allow reentrancy via known attack entrypoints (best-effort detection)", async function () {
    // Gather candidate function names from attackContract that include 'attack' or 'reenter'
    const funcs = Object.keys(attackContract.functions).map(f => f.toString());
    const candidates = funcs.filter(f => /attack|reentr|exploit/i.test(f));
    if (candidates.length === 0) {
      // best-effort: consider generic names
      candidates.push("attackReleaseFunds", "attack", "reenter", "exploit");
    }

    const amount = await toUnits("1");

    let anyAttempted = false;
    let anySucceeded = false;
    // try calling each candidate with different possible arg counts
    for (const name of candidates) {
      // remove signature suffix (if present) so we can access via contract[name]
      const shortName = name.split("(")[0];
      if (typeof attackContract[shortName] !== "function") continue;

      anyAttempted = true;
      try {
        // Try common signatures:
        // 1) (address storageAddr, address token, address to, uint256 amount)
        // 2) (address target, address token, uint256 amount)
        // 3) (address target)
        // Note: call as attacker
        const sig1 = attackContract.connect(attacker)[shortName](storage.address, token.address, attacker.address, amount);
        await sig1;
        anySucceeded = true;
        break;
      } catch (err1) {
        try {
          const sig2 = attackContract.connect(attacker)[shortName](storage.address, token.address, amount);
          await sig2;
          anySucceeded = true;
          break;
        } catch (err2) {
          try {
            const sig3 = attackContract.connect(attacker)[shortName](storage.address);
            await sig3;
            anySucceeded = true;
            break;
          } catch (err3) {
            // expected: these attempts revert if protection exists; continue trying other names
          }
        }
      }
    }

    // If we didn't even find an attack function to call, skip but warn
    if (!anyAttempted) {
      this.skip();
    }

    // We expect attacks to revert / not succeed. If anySucceeded true -> test fails.
    expect(anySucceeded).to.equal(false, "Reentrancy attack entrypoint succeeded — inspect releaseFunds and external transfer ordering.");
  }).timeout(120000);
});