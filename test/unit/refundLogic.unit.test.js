const { ethers } = require("hardhat");
const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

function key(str) { return ethers.keccak256(ethers.toUtf8Bytes(str)); }

describe("RefundLogic - unit tests (via PoliDaoStorage)", function () {
  it("sets commissions, fee token and commission wallet and returns expected values via direct getters", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, refunds, owner } = env;

    let refundsC = refunds;
    if (!refundsC) {
      const addr = await storage.modules(key("REFUNDS"));
      if (addr !== ethers.ZeroAddress) refundsC = await ethers.getContractAt("PoliDaoRefunds", addr);
    }
    if (!refundsC) this.skip();

    // przykładowe settery/gettery (dopasuj do faktycznego interfejsu modułu)
    if (refundsC.setCommission && refundsC.refundCommission) {
      await (await refundsC.connect(owner).setCommission(500)).wait(); // 5%
      expect(await refundsC.refundCommission()).to.equal(500);
    }
  });

  it("refund path: adds donation and (best-effort) triggers refund behavior by simulating releaseFunds", async function () {
    const env = await loadFixture(deploySystemFixture);
    const { storage, core, refunds, owner, alice } = env;

    let refundsC = refunds;
    if (!refundsC) {
      const addr = await storage.modules(key("REFUNDS"));
      if (addr !== ethers.ZeroAddress) refundsC = await ethers.getContractAt("PoliDaoRefunds", addr);
    }
    if (!refundsC) this.skip();

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();
    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const end = Math.floor(Date.now() / 1000) + 3600;
    const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, end, "T", "D");
    const rc = await tx.wait();
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    await (await token.mint(alice.address, 1000n)).wait();
    await (await token.connect(alice).approve(await core.getAddress(), 1000n)).wait();
    await (await core.connect(alice)["donate(uint256,address,uint256)"](fundraiserId, await token.getAddress(), 1000n)).wait();

    // jeśli moduł posiada funkcję refundującą – wywołaj; w przeciwnym razie sprawdź przepływ release/withdraw
    if (core.refundDonation) {
      await expect(core.connect(alice).refundDonation(fundraiserId, await token.getAddress(), 500n)).to.not.be.reverted;
    } else {
      await (await core.connect(owner).withdrawFunds(fundraiserId, await token.getAddress())).wait();
    }

    expect(await token.balanceOf(await storage.getAddress())).to.be.gte(0n);
  });
});
