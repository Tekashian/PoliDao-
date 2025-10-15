// Wyjaśnienie błędu:
// Revert w teście refundFor wynika z braku rejestracji routera w Storage.
// Choć Core otrzymuje routerAddr w konstruktorze, niektóre modyfikatory/odwołania mogą weryfikować router w Storage (onlyRouter w Storage).
const { expect } = require("chai");
const { ethers } = require("hardhat");

const FundraiserType = {
  WITH_GOAL: 0,
  NO_GOAL: 1,
};

const day = 24 * 60 * 60;

async function increaseTime(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

function toUnits(n, d = 6) {
  return ethers.parseUnits(n.toString(), d);
}

// [ADD] Build default values for any solidity type described in ABI
function defaultForParamType(pt) {
  // Arrays
  if (pt.baseType === "array") return [];
  // Tuples (structs)
  if (pt.baseType === "tuple") {
    const obj = {};
    for (const c of pt.components) {
      obj[c.name] = defaultForParamType(c);
    }
    return obj;
  }
  // Elementary types
  const t = pt.type;
  if (t.startsWith("uint") || t.startsWith("int")) return 0n;
  if (t === "bool") return false;
  if (t === "address") return ethers.ZeroAddress;
  if (t.startsWith("bytes")) {
    // bytes32 etc.
    return "0x" + "00".repeat(parseInt(t.slice(5) || "0") || 32);
  }
  if (t === "string") return "";
  // fallback
  return 0n;
}

// [ADD] Build CreateFundraiser input object from ABI + overrides
async function buildCreateFundraiserData(core, overrides = {}) {
  const fn = core.interface.getFunction("createFundraiser");
  // Zakładamy, że 1. argument to struct (tuple)
  const input = fn.inputs[0];
  if (input.baseType !== "tuple") {
    throw new Error("Unexpected createFundraiser signature");
  }
  const data = defaultForParamType(input);
  // Nadpisz domyślne wartości przekazanymi override'ami
  for (const [k, v] of Object.entries(overrides)) {
    data[k] = v;
  }
  return data;
}

describe("PoliDaoCore: donate/withdraw/refund rules + fees", function () {
  let owner, creator, donor1, donor2, feeWallet, routerEOA;
  let usdc, storage, core;

  async function deployStack() {
    [owner, creator, donor1, donor2, feeWallet, routerEOA] = await ethers.getSigners();

    const USDC = await ethers.getContractFactory("MockUSDC");
    usdc = await USDC.connect(owner).deploy(toUnits(1_000_000_000));
    await usdc.waitForDeployment();

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.connect(owner).deploy();
    await storage.waitForDeployment();

    // DEPLOY Core bez linkowania (biblioteki mają internal funkcje)
    const Core = await ethers.getContractFactory("PoliDaoCore");
    const storageAddr = await storage.getAddress();
    const routerAddr = await routerEOA.getAddress();
    core = await Core.connect(owner).deploy(storageAddr, routerAddr);
    await core.waitForDeployment();

    await (await storage.connect(owner).setCore(await core.getAddress())).wait();
    await (await storage.connect(owner).addWhitelistedToken(await usdc.getAddress())).wait();

    await (await core.connect(owner).setFeeRecipient(await feeWallet.getAddress())).wait();

    await (await usdc.connect(owner).transfer(await donor1.getAddress(), toUnits(100_000))).wait();
    await (await usdc.connect(owner).transfer(await donor2.getAddress(), toUnits(100_000))).wait();
  }

  async function createFundraiser({ type, goal, daysFromNow }) {
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const overrides = {
      title: "Test FR",
      description: "desc",
      location: "loc",
      endDate: now + daysFromNow * day,
      fundraiserType: type,
      token: await usdc.getAddress(),
      goalAmount: toUnits(goal),
      isFlexible: false,
      // Dla pól multimediów/metadata ustawiamy puste wartości – helper wypełni resztę wg ABI
      initialImages: [],
      initialVideos: [],
      metadataHash: ""
    };
    const data = await buildCreateFundraiserData(core, overrides);
    const tx = await core.connect(creator).createFundraiser(data);
    const rc = await tx.wait();
    const ev = rc.logs.find(l => l.fragment && l.fragment.name === "FundraiserCreated");
    const id = ev ? ev.args.fundraiserId : rc.logs[0].args[0];
    return Number(id);
  }

  beforeEach(async () => {
    await deployStack();
  });

  it("donation fee: 2% idzie na feeRecipient, netto do Storage i raised księgowane w Storage przez Core", async () => {
    await core.connect(owner).setDonationFeeBps(200); // 2%
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const storageBefore = await usdc.balanceOf(await storage.getAddress());

    await expect(core.connect(donor1).donate(frId, toUnits(1000)))
      .to.emit(core, "DonationMade");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const storageAfter = await usdc.balanceOf(await storage.getAddress());
    expect(feeAfter - feeBefore).to.equal(toUnits(20));
    expect(storageAfter - storageBefore).to.equal(toUnits(980));

    const info = await core.getFundraiserBasicInfo(frId);
    expect(info[2]).to.equal(toUnits(980));
  });

  it("WITH_GOAL: withdraw (goal reached) nalicza success fee i refundy nieaktywne (GoalReachedNoRefund)", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(200, 0); // 2% success

    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));
    await core.connect(donor1).donate(frId, toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorBefore = await usdc.balanceOf(await creator.getAddress());

    await expect(core.connect(creator).withdrawFunds(frId))
      .to.emit(core, "FundsWithdrawn");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorAfter = await usdc.balanceOf(await creator.getAddress());
    expect(feeAfter - feeBefore).to.equal(toUnits(20));
    expect(creatorAfter - creatorBefore).to.equal(toUnits(980));

    // Fast-forward endDate (refund logic checks post-end conditions)
    await increaseTime(15 * day);

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "GoalReachedNoRefund");
  });

  it("WITH_GOAL: po endDate i goal nieosiągnięty refund działa, potem drugi refund => AlreadyRefunded", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 1 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(400));
    await core.connect(donor1).donate(frId, toUnits(400));

    await increaseTime(2 * day); // po endDate

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.emit(core, "RefundClaimed");

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "AlreadyRefunded");
  });

  it("NO_GOAL: refund zawsze niedozwolony (RefundNotEligible), withdraw dozwolony przed endDate", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(0, 500); // 5% flexible
    const frId = await createFundraiser({ type: FundraiserType.NO_GOAL, goal: 0, daysFromNow: 2 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(300));
    await core.connect(donor1).donate(frId, toUnits(300));

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "RefundNotEligible");

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorBefore = await usdc.balanceOf(await creator.getAddress());
    await expect(core.connect(creator).withdrawFunds(frId))
      .to.emit(core, "FundsWithdrawn");
    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorAfter = await usdc.balanceOf(await creator.getAddress());
    expect(feeAfter - feeBefore).to.equal(toUnits(15));
    expect(creatorAfter - creatorBefore).to.equal(toUnits(285));
  });

  it("router: refundFor może być wywołany przez router także przed endDate (o ile cel nieosiągnięty); tylko router może wywołać", async () => {
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 500, daysFromNow: 1 });
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(200));
    await core.connect(donor1).donate(frId, toUnits(200));

    // Nie-router rewertuje (modifier onlyRouter)
    await expect(core.connect(donor1).refundFor(frId, await donor1.getAddress()))
      .to.be.reverted;

    // Router może zrefundować nawet przed endDate (nowa logika)
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.emit(core, "RefundClaimed");

    // Drugi refund tego samego darczyńcy -> AlreadyRefunded
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "AlreadyRefunded");
  });

  it("WITH_GOAL: refund przed endDate jest dozwolony jeśli cel nieosiągnięty", async () => {
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 5 });
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(100));
    await core.connect(donor1).donate(frId, toUnits(100));
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.emit(core, "RefundClaimed");
  });

  it("DonationMade: wielokrotne wpłaty akumulują raised i fee naliczane per wpłata", async () => {
    await core.connect(owner).setDonationFeeBps(250); // 2.5%
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 2000, daysFromNow: 10 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));
    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const storageBefore = await usdc.balanceOf(await storage.getAddress());

    await core.connect(donor1).donate(frId, toUnits(800));
    await core.connect(donor2).donate(frId, toUnits(600));

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const storageAfter = await usdc.balanceOf(await storage.getAddress());

    expect(feeAfter - feeBefore).to.equal(toUnits(35));
    expect(storageAfter - storageBefore).to.equal(toUnits(1365));

    const info = await core.getFundraiserBasicInfo(frId);
    expect(info[2]).to.equal(toUnits(1365));
  });

  it("refund: nie można zrefundować dwa razy tego samego darczyńcy (AlreadyRefunded)", async () => {
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 500, daysFromNow: 1 });
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(150));
    await core.connect(donor1).donate(frId, toUnits(150));

    await increaseTime(2 * day);
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.emit(core, "RefundClaimed");

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "AlreadyRefunded");
  });

  it("feeRecipient: zmiana odbiorcy działa dla kolejnych wpłat", async () => {
    await core.connect(owner).setDonationFeeBps(100); // 1%
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 5 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(500));
    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(500));

    const feeBefore1 = await usdc.balanceOf(await feeWallet.getAddress());
    await core.connect(donor1).donate(frId, toUnits(200));
    const feeAfter1 = await usdc.balanceOf(await feeWallet.getAddress());
    expect(feeAfter1 - feeBefore1).to.equal(toUnits(2));

    await core.connect(owner).setFeeRecipient(await routerEOA.getAddress());

    const newFeeBefore = await usdc.balanceOf(await routerEOA.getAddress());
    await core.connect(donor2).donate(frId, toUnits(100));
    const newFeeAfter = await usdc.balanceOf(await routerEOA.getAddress());
    expect(newFeeAfter - newFeeBefore).to.equal(toUnits(1));
  });
});