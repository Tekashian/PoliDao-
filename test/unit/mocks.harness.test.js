const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployMockToken, toUnits } = require("../helpers/testUtils");

describe("Mocks harness - MockToken and ReentrancyAttackMock", function () {
  let deployer, attacker;
  let token;
  let ReentrancyAttackMock, attackContract;

  beforeEach(async function () {
    [deployer, attacker] = await ethers.getSigners();
    const res = await deployMockToken(deployer.address, await toUnits("10000"));
    token = res.token;

    ReentrancyAttackMock = await ethers.getContractFactory("ReentrancyAttackMock");
    attackContract = await ReentrancyAttackMock.deploy();
    await attackContract.deployed();
  });

  it("MockToken basic ERC20 behavior: transfer and balanceOf", async function () {
    const amt = await toUnits("100");
    const to = attacker.address;
    // transfer from deployer
    await token.transfer(to, amt);
    const bal = await token.balanceOf(to);
    expect(bal).to.equal(amt);
  });

  it("Reentrancy mock deployed and basic call signature exists", async function () {
    // ensure attack contract has an attack function that is callable (best effort)
    const methods = Object.keys(attackContract.functions);
    const hasAttack = methods.some(m => m.toLowerCase().includes("attack"));
    expect(hasAttack).to.equal(true, "ReentrancyAttackMock should expose an attack function. Update the mock if named differently.");
  });
});
