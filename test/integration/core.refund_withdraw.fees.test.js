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
    // MockUSDC constructor(uint256 initialSupply)
    usdc = await USDC.connect(owner).deploy(toUnits(1_000_000_000)); // 1B USDC(6)
    await usdc.waitForDeployment();

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.connect(owner).deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("PoliDaoCore");
    const storageAddr = await storage.getAddress();
    const routerAddr = await routerEOA.getAddress();

    // Core ma konstruktor (storage, router)
    core = await Core.connect(owner).deploy(storageAddr, routerAddr);
    await core.waitForDeployment();

    // Autoryzacja Core w Storage + whitelist tokenu
    await (await storage.connect(owner).setCore(await core.getAddress())).wait();

    // [FIX] zarejestruj router również w Storage, jeśli interfejs istnieje
    if (storage.setRouter) {
      await (await storage.connect(owner).setRouter(routerAddr)).wait();
    }

    if (storage.authorizeContract) {
      await (await storage.connect(owner).authorizeContract(await core.getAddress())).wait();
    }
    await (await storage.connect(owner).addWhitelistedToken(await usdc.getAddress())).wait();

    // Fee recipient
    await (await core.connect(owner).setFeeRecipient(await feeWallet.getAddress())).wait();

    // Rozdystrybuuj tokeny do donorów zamiast mint
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
    const ev = rc.logs.find((l) => l.fragment && l.fragment.name === "FundraiserCreated");
    const id = ev ? ev.args.fundraiserId : rc.logs[0].args[0];
    return Number(id);
  }

  beforeEach(async () => {
    await deployStack();
  });

  it("donation fee: 2% idzie na feeRecipient, netto do Storage i raised księgowane w Storage przez Core", async () => {
    await core.connect(owner).setDonationFeeBps(200); // 2%

    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });

    // donor1 approve na Core
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const storageBefore = await usdc.balanceOf(await storage.getAddress());

    await expect(core.connect(donor1).donate(frId, toUnits(1000)))
      .to.emit(core, "DonationMade");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const storageAfter = await usdc.balanceOf(await storage.getAddress());

    expect(feeAfter - feeBefore).to.equal(toUnits(20));     // 2% z 1000
    expect(storageAfter - storageBefore).to.equal(toUnits(980)); // netto

    // raised zgadza się z netto
    const info = await core.getFundraiserBasicInfo(frId);
    expect(info[2]).to.equal(toUnits(980));
  });

  it("WITH_GOAL: withdraw (goal reached przed endDate) – nalicza success fee, zamyka wpłaty i blokuje refund", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(200, 0); // 2% sukces

    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });

    // darowizna 1000 osiąga cel
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));
    await core.connect(donor1).donate(frId, toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorBefore = await usdc.balanceOf(await creator.getAddress());

    await expect(core.connect(creator).withdrawFunds(frId))
      .to.emit(core, "FundsWithdrawn");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorAfter = await usdc.balanceOf(await creator.getAddress());

    expect(feeAfter - feeBefore).to.equal(toUnits(20));   // 2% z 1000
    expect(creatorAfter - creatorBefore).to.equal(toUnits(980));

    // próba donacji po fundsWithdrawn → DonationsClosed
    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(1));
    await expect(core.connect(donor2).donate(frId, toUnits(1)))
      .to.be.revertedWithCustomError(core, "DonationsClosed");

    // refund zablokowany (goal reached)
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "RefundNotAllowed");
  });

  it("WITH_GOAL: po endDate, cel nieosiągnięty → refund dozwolony do pierwszej wypłaty; po niej blokada refundów i fee flexible", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(0, 300); // 3% flexible

    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 1 });

    // wpłata < goal
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(400));
    await core.connect(donor1).donate(frId, toUnits(400));

    // po endDate
    await increaseTime(2 * day);

    // refund dozwolony zanim nastąpi withdraw
    const [canRefundBefore] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundBefore).to.eq(true);

    // formalnie uruchom refundFor przez router (routerEOA już ustawiony)
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.not.be.reverted;

    // teraz withdraw – nalicza się flexible fee, a refundy po tym zablokowane
    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorBefore = await usdc.balanceOf(await creator.getAddress());

    await expect(core.connect(creator).withdrawFunds(frId))
      .to.emit(core, "FundsWithdrawn");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorAfter = await usdc.balanceOf(await creator.getAddress());

    expect(feeAfter - feeBefore).to.equal(toUnits(12));  // 3% z 400
    expect(creatorAfter - creatorBefore).to.equal(toUnits(388));

    const [canRefundAfter] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundAfter).to.eq(false);

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "RefundNotAllowed");
  });

  it("NO_GOAL: donate/withdraw dozwolone tylko przed endDate; po endDate obie zablokowane; refund dozwolony do pierwszej wypłaty", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(0, 500); // 5% flexible

    const frId = await createFundraiser({ type: FundraiserType.NO_GOAL, goal: 0, daysFromNow: 1 });

    // donate przed endDate
    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(300));
    await core.connect(donor1).donate(frId, toUnits(300));

    // refund dozwolony przed withdraw
    let [canRefundBefore] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundBefore).to.eq(true);

    // withdraw przed endDate (nakłada fee i blokuje refundy od teraz)
    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorBefore = await usdc.balanceOf(await creator.getAddress());

    await expect(core.connect(creator).withdrawFunds(frId))
      .to.emit(core, "FundsWithdrawn");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const creatorAfter = await usdc.balanceOf(await creator.getAddress());

    expect(feeAfter - feeBefore).to.equal(toUnits(15));  // 5% z 300
    expect(creatorAfter - creatorBefore).to.equal(toUnits(285));

    // po pierwszej wypłacie refundy zablokowane
    const [canRefundAfter] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundAfter).to.eq(false);

    // po endDate donate/withdraw zablokowane
    await increaseTime(2 * day);

    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(1));
    await expect(core.connect(donor2).donate(frId, toUnits(1)))
      .to.be.revertedWithCustomError(core, "DonationsClosed");

    await expect(core.connect(creator).withdrawFunds(frId)).to.be.reverted;
  });

  // [NEW TESTS] Dodatkowe testy bazujące na istniejących scenariuszach

  it("router: refundFor dozwolone tylko dla routera; inne adresy rewertują", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 1 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(200));
    await core.connect(donor1).donate(frId, toUnits(200));

    await increaseTime(2 * day);

    // Próba wywołania refundFor przez nie-router → revert
    await expect(core.connect(donor1).refundFor(frId, await donor1.getAddress())).to.be.reverted;

    // Router może zrefundować
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress())).to.not.be.reverted;
  });

  it("WITH_GOAL: refund przed endDate nie dozwolony nawet bez osiągnięcia celu", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(100));
    await core.connect(donor1).donate(frId, toUnits(100));

    const [canRefundBefore] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundBefore).to.eq(false);

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.be.revertedWithCustomError(core, "RefundNotAllowed");
  });

  it("WITH_GOAL: refund przed endDate dozwolony jeżeli cel nieosiągnięty i nie było wypłaty", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 10 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(100));
    await core.connect(donor1).donate(frId, toUnits(100));

    const [canRefundBefore] = await core.canRefund(frId, await donor1.getAddress());
    expect(canRefundBefore).to.eq(true);

    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress()))
      .to.not.be.reverted;
  });

  it("DonationMade: wielokrotne wpłaty akumulują raised i fee jest naliczane dla każdej wpłaty", async () => {
    await core.connect(owner).setDonationFeeBps(250); // 2.5%
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 2000, daysFromNow: 10 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(1000));
    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(1000));

    const feeBefore = await usdc.balanceOf(await feeWallet.getAddress());
    const storageBefore = await usdc.balanceOf(await storage.getAddress());

    await expect(core.connect(donor1).donate(frId, toUnits(800))).to.emit(core, "DonationMade");
    await expect(core.connect(donor2).donate(frId, toUnits(600))).to.emit(core, "DonationMade");

    const feeAfter = await usdc.balanceOf(await feeWallet.getAddress());
    const storageAfter = await usdc.balanceOf(await storage.getAddress());

    // 2.5% z 800 = 20; 2.5% z 600 = 15; razem 35
    expect(feeAfter - feeBefore).to.equal(toUnits(35));
    // netto: 800-20 + 600-15 = 1365
    expect(storageAfter - storageBefore).to.equal(toUnits(1365));

    const info = await core.getFundraiserBasicInfo(frId);
    expect(info[2]).to.equal(toUnits(1365));
  });

  it("refund: nie można zrefundować dwa razy tego samego darczyńcy", async () => {
    await core.connect(owner).setDonationFeeBps(0);
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 1 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(150));
    await core.connect(donor1).donate(frId, toUnits(150));

    await increaseTime(2 * day);

    // Pierwszy refund OK
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress())).to.not.be.reverted;

    // Drugi refund powinien się wywalić
    await expect(core.connect(routerEOA).refundFor(frId, await donor1.getAddress())).to.be.reverted;
  });

  it("feeRecipient: zmiana odbiorcy opłat działa natychmiast przy kolejnych wpłatach", async () => {
    await core.connect(owner).setDonationFeeBps(100); // 1%
    const frId = await createFundraiser({ type: FundraiserType.WITH_GOAL, goal: 1000, daysFromNow: 5 });

    await usdc.connect(donor1).approve(await core.getAddress(), toUnits(500));
    await usdc.connect(donor2).approve(await core.getAddress(), toUnits(500));

    // Pierwsza wpłata → fee na current feeWallet
    const feeBefore1 = await usdc.balanceOf(await feeWallet.getAddress());
    await expect(core.connect(donor1).donate(frId, toUnits(200))).to.emit(core, "DonationMade");
    const feeAfter1 = await usdc.balanceOf(await feeWallet.getAddress());
    expect(feeAfter1 - feeBefore1).to.equal(toUnits(2));

    // Zmień fee recipient na inny adres niż donor płacący, aby nie mieszać z jego wpłatą
    await (await core.connect(owner).setFeeRecipient(await routerEOA.getAddress())).wait();

    // Druga wpłata (donor2) → fee trafia do routerEOA
    const newFeeBefore = await usdc.balanceOf(await routerEOA.getAddress());
    await expect(core.connect(donor2).donate(frId, toUnits(100))).to.emit(core, "DonationMade");
    const newFeeAfter = await usdc.balanceOf(await routerEOA.getAddress());
    expect(newFeeAfter - newFeeBefore).to.equal(toUnits(1));
  });

  it("sanity: router adresy ustawione poprawnie w Core/Storage (o ile gettery istnieją)", async () => {
    if (core.router) {
      expect(await core.router()).to.equal(await routerEOA.getAddress());
    }
    if (storage.router) {
      expect(await storage.router()).to.equal(await routerEOA.getAddress());
    }
  });
});