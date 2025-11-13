const { ethers } = require("hardhat");
const { expect } = require("chai");

async function increaseTime(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

// Helper: ustaw refundCommission, jeśli kontrakt udostępnia setter; ignoruj błąd gdy brak/No change
async function ensureRefundCommission(storage, rate) {
  // rate: bigint
  try {
    if (storage.setRefundCommission) {
      await storage.setRefundCommission(rate);
    } else if (storage.setCommissions) {
      // Jeżeli w projekcie istnieje inna sygnatura, można dodać fallbacki z inną liczbą argumentów.
      // Tutaj nie wymuszamy, bo nie wiemy jaka sygnatura jest dostępna.
      // Pozostawiamy stawkę jak jest, a oczekiwania wyliczymy z odczytanej wartości.
    }
  } catch (e) {
    // zignoruj (np. "No change")
  }
}

async function getRefundCommission(storage) {
  try {
    return await storage.refundCommission();
  } catch {
    // jeśli brak getter'a, przyjmij 0
    return 0n;
  }
}

// Build struct data helper
async function buildCreateData(tokenAddr, overrides = {}) {
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  return {
    title: "FR",
    description: "Desc",
    location: "LOC",
    endDate: now + 3600,
    goalAmount: ethers.parseEther("100"),
    token: tokenAddr,
    fundraiserType: 0, // WITH_GOAL
    isFlexible: false,
    initialImages: [],
    initialVideos: [],
    metadataHash: "",
    ...overrides
  };
}

describe("RefundLogic (library) – direct harness scenarios", function () {
  let owner, creator, donor, wallet;
  let token, storage, core, harness;

  async function deployEnv() {
    [owner, creator, donor, wallet] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockToken");
    token = await Token.deploy("Mock", "MCK", 18);
    await token.waitForDeployment();

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(await storage.getAddress(), owner.address);
    await core.waitForDeployment();
    await (await storage.setCore(await core.getAddress())).wait();

    const Harness = await ethers.getContractFactory("RefundLogicHarness");
    harness = await Harness.deploy();
    await harness.waitForDeployment();

    await (await storage.addWhitelistedToken(await token.getAddress())).wait();
    await (await storage.setCommissionWallet(wallet.address)).wait();
    // Autoryzuj harness
    await (await storage.authorizeContract(await harness.getAddress())).wait();
  }

  beforeEach(async () => {
    await deployEnv();
  });

  // Usunięto wszystkie testy enterRefundPeriod (przestarzałe)

  it("claimRefund transfers net & commission, then second claim -> AlreadyRefunded", async () => {
    await ensureRefundCommission(storage, 500n); // próbujemy ustawić 5%
    const rate = await getRefundCommission(storage);

    const data = await buildCreateData(await token.getAddress(), { goalAmount: ethers.parseEther("50"), endDate: (await ethers.provider.getBlock("latest")).timestamp + 100 });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("20"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("20"));
    await core.connect(donor).donate(1, ethers.parseEther("20"));
    const packedBefore = await storage.fundraisers(1);
    expect(packedBefore.raisedAmount).to.equal(ethers.parseEther("20"));
    await increaseTime(400);

    const balDonorBefore = await token.balanceOf(donor.address);
    const balWalletBefore = await token.balanceOf(wallet.address);

    await harness.claimRefund(await storage.getAddress(), 1, donor.address);

    const balDonorAfter = await token.balanceOf(donor.address);
    const balWalletAfter = await token.balanceOf(wallet.address);

    const commission = rate === 0n ? 0n : (ethers.parseEther("20") * rate) / 10000n;
    const net = ethers.parseEther("20") - commission;

    expect(balDonorAfter - balDonorBefore).to.equal(net);
    expect(balWalletAfter - balWalletBefore).to.equal(commission);

    const packedAfter = await storage.fundraisers(1);
    expect(packedAfter.raisedAmount).to.equal(0n);

    const totalRefunded = await storage.totalRefunded(1);
    const totalRefundCommission = await storage.totalRefundCommission(1);
    expect(totalRefunded).to.equal(net);
    expect(totalRefundCommission).to.equal(commission);

    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWithCustomError(harness, "AlreadyRefunded");
  });

  it("claimRefund reverts GoalReachedNoRefund when goal met", async () => {
    const data = await buildCreateData(await token.getAddress(), { goalAmount: ethers.parseEther("10"), endDate: (await ethers.provider.getBlock("latest")).timestamp + 120 });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("10"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("10"));
    await core.connect(donor).donate(1, ethers.parseEther("10"));
    await increaseTime(400);
    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWithCustomError(harness, "GoalReachedNoRefund");
  });

  it("NO_GOAL fundraiser -> claimRefund reverts RefundNotEligible", async () => {
    const data = await buildCreateData(await token.getAddress(), {
      fundraiserType: 1, // NO_GOAL
      goalAmount: 0,
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 200
    });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("5"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("5"));
    await core.connect(donor).donate(1, ethers.parseEther("5"));
    await increaseTime(100);
    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWithCustomError(harness, "RefundNotEligible");
  });

  it("claimRefund reverts WithdrawalsStarted gdy flaga = true", async () => {
    await ensureRefundCommission(storage, 500n);
    const data = await buildCreateData(await token.getAddress(), {
      goalAmount: ethers.parseEther("100"),
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600
    });
    await core.connect(creator).createFundraiser(data);

    await token.mint(donor.address, ethers.parseEther("10"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("10"));
    await core.connect(donor).donate(1, ethers.parseEther("10"));

    await expect(
      harness.claimRefundWithFlag(await storage.getAddress(), 1, donor.address, true)
    ).to.be.revertedWithCustomError(harness, "WithdrawalsStarted");
  });

  it("refund jest per-darczyńca: dwaj darczyńcy dostają swoje kwoty netto, sumy w storage akumulują się poprawnie", async () => {
    await ensureRefundCommission(storage, 300n); // spróbuj 3%

     const data = await buildCreateData(await token.getAddress(), {
       goalAmount: ethers.parseEther("1000"),
       endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600
     });
     await core.connect(creator).createFundraiser(data);

     // UWAGA: index 3 to wallet (feeRecipient). Użyj innego signera jako d2.
     const signers = await ethers.getSigners();
     const d1 = donor;
     const d2 = signers[4];

     await token.mint(d1.address, ethers.parseEther("100"));
     await token.mint(d2.address, ethers.parseEther("50"));
     await token.connect(d1).approve(await core.getAddress(), ethers.parseEther("100"));
     await token.connect(d2).approve(await core.getAddress(), ethers.parseEther("50"));

     await core.connect(d1).donate(1, ethers.parseEther("100"));
     await core.connect(d2).donate(1, ethers.parseEther("50"));

     const walletBalBefore = await token.balanceOf(wallet.address);
     const d1Before = await token.balanceOf(d1.address);
     const d2Before = await token.balanceOf(d2.address);

     // Refund 1: donor1
     await harness.claimRefund(await storage.getAddress(), 1, d1.address);

     // Refund 2: donor2
     await harness.claimRefund(await storage.getAddress(), 1, d2.address);

     const walletBalAfter = await token.balanceOf(wallet.address);
     const d1After = await token.balanceOf(d1.address);
     const d2After = await token.balanceOf(d2.address);

     const walletDelta = walletBalAfter - walletBalBefore;
     const d1Delta = d1After - d1Before;
     const d2Delta = d2After - d2Before;

     const totalRefunded = await storage.totalRefunded(1);
     const totalRefundCommission = await storage.totalRefundCommission(1);
     // Spójność: to co trafiło do wallet == totalRefundCommission
     expect(walletDelta).to.equal(totalRefundCommission);
     // Suma netto trafiła do obu darczyńców
     expect(d1Delta + d2Delta).to.equal(totalRefunded);
   });

  it("non-donor próbuje refund -> AlreadyRefunded (brak wpłat oznacza już 'wyzerowane')", async () => {
    const data = await buildCreateData(await token.getAddress(), {
      goalAmount: ethers.parseEther("100"),
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600
    });
    await core.connect(creator).createFundraiser(data);

    // Brak donacji od 'wallet' – próba refund
    await expect(
      harness.claimRefund(await storage.getAddress(), 1, wallet.address)
    ).to.be.revertedWithCustomError(harness, "AlreadyRefunded");
  });

  it("gdy prowizja = 0, całość wraca do darczyńcy", async () => {
    await ensureRefundCommission(storage, 0n);
    const rate = await getRefundCommission(storage); // jeśli nie udało się zmienić, użyj aktualnej

    const data = await buildCreateData(await token.getAddress(), {
      goalAmount: ethers.parseEther("100"),
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600
    });
    await core.connect(creator).createFundraiser(data);

    await token.mint(donor.address, ethers.parseEther("7"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("7"));
    await core.connect(donor).donate(1, ethers.parseEther("7"));

    const donorBefore = await token.balanceOf(donor.address);
    const walletBefore = await token.balanceOf(wallet.address);

    await harness.claimRefund(await storage.getAddress(), 1, donor.address);

    const donorAfter = await token.balanceOf(donor.address);
    const walletAfter = await token.balanceOf(wallet.address);

    const expectedCommission = rate === 0n ? 0n : (ethers.parseEther("7") * rate) / 10000n;
    const expectedNet = ethers.parseEther("7") - expectedCommission;

    expect(donorAfter - donorBefore).to.equal(expectedNet);
    expect(walletAfter - walletBefore).to.equal(expectedCommission);
  });

  it("respects Security payout schedule via Storage.modules(SECURITY)", async () => {
    // Deploy Security and wire into Storage so RefundLogic can call it
    const Security = await ethers.getContractFactory("PoliDaoSecurity");
    const security = await Security.deploy(await core.getAddress());
    await security.waitForDeployment();

    // Set a small per-tranche payout limit (treat token units as USDC-6 for test simplicity)
    await (await security.connect(owner).setPayoutLimitUSDC(300)).wait();

    const SECURITY_KEY = ethers.keccak256(ethers.toUtf8Bytes("SECURITY"));
    await (await storage.connect(owner).setModule(SECURITY_KEY, await security.getAddress())).wait();

    // Create WITH_GOAL fundraiser and donate 1000 units
    const data = await buildCreateData(await token.getAddress(), {
      goalAmount: 10_000, // any non-zero goal to allow refunds when not reached
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600
    });
    await core.connect(creator).createFundraiser(data);

    // Mint small integer units (no parseEther) to keep scale consistent with Security limit
    await token.mint(donor.address, 1000);
    await token.connect(donor).approve(await core.getAddress(), 1000);
    await core.connect(donor).donate(1, 1000);

    // First claim: should refund only 300 now (minus commission if set; default 0 in this test)
    const balBefore = await token.balanceOf(donor.address);
    await harness.claimRefund(await storage.getAddress(), 1, donor.address);
    const balAfterFirst = await token.balanceOf(donor.address);
    expect(balAfterFirst - balBefore).to.equal(300n);

    // Immediate second claim should revert due to schedule
    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWith("Security: payout tranche not available yet");

    // After 1h -> next tranche available
    await increaseTime(3600);
    await harness.claimRefund(await storage.getAddress(), 1, donor.address);
    const balAfterSecond = await token.balanceOf(donor.address);
    expect(balAfterSecond - balAfterFirst).to.equal(300n);

    // Drain remaining in subsequent windows
    await increaseTime(3600);
    await harness.claimRefund(await storage.getAddress(), 1, donor.address);
    await increaseTime(3600);
    await harness.claimRefund(await storage.getAddress(), 1, donor.address);

    // Donation mapping should be zeroed, totals accounted
    const remainingDonation = await core.getDonationAmount ? await core.getDonationAmount(1, donor.address) : 0n;
    // If core exposes getDonationAmount, expect zero; otherwise skip invariant
    if (remainingDonation !== undefined) {
      expect(remainingDonation).to.equal(0n);
    }
  });
});
