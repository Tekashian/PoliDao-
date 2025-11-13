const { expect } = require("chai");
const { ethers } = require("hardhat");

let core, storage, token, owner, creator, donor, feeRecipient, fid;

before(async () => {
  [owner, creator, donor, feeRecipient] = await ethers.getSigners();

  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  token = await ERC20Mock.deploy("TestUSD", "TUSD", owner.address, ethers.parseUnits("1000000", 18));

  const Storage = await ethers.getContractFactory("PoliDaoStorage");
  storage = await Storage.deploy();
  await storage.connect(owner).addWhitelistedToken(token.target);

  // Deploy upgradeable Core (UUPS): impl + proxy + initialize (no external library linking required)
  const CoreImplFactory = await ethers.getContractFactory(
    "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable"
  );
  const impl = await CoreImplFactory.deploy();
  await impl.waitForDeployment();
  const initData = CoreImplFactory.interface.encodeFunctionData("initialize", [storage.target, owner.address]);
  const ProxyFactory = await ethers.getContractFactory("@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
  const proxy = await ProxyFactory.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();
  core = await ethers.getContractAt("contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable", await proxy.getAddress());
  // Bind storage to core and authorize if required by guards
  await storage.connect(owner).setCore(core.target);
  await storage.connect(owner).authorizeContract(core.target);

  // fee setup
  await core.connect(owner).setFeeRecipient(feeRecipient.address);
  await core.connect(owner).setDonationFeeBps(0);
  await core.connect(owner).setWithdrawFeesBps(0, 0);

  const data = {
    title: "Goal campaign",
    description: "Desc",
    endDate: (await ethers.provider.getBlock()).timestamp + 7 * 24 * 3600,
    fundraiserType: 0, // WITH_GOAL
    token: token.target,
    goalAmount: ethers.parseUnits("50", 18),
    initialImages: [],
    initialVideos: [],
    metadataHash: "",
    location: "Loc",
    isFlexible: false
  };
  const tx = await core.connect(creator).createFundraiser(data);
  const rc = await tx.wait();
  const ev = rc.logs.find(l => l.fragment && l.fragment.name === "FundraiserCreated");
  fid = ev.args.fundraiserId;

  await token.connect(owner).transfer(donor.address, ethers.parseUnits("100", 18));
  await token.connect(donor).approve(core.target, ethers.parseUnits("100", 18));
  await core.connect(donor).donate(fid, ethers.parseUnits("60", 18)); // exceed goal
});

describe("Withdraw integration", function () {
  it("withdraws once and updates totals; prevents second withdraw (no tranching)", async function () {
    // ...existing code to donate 'amount'...
    // compute fees as in Core: donation fee already applied before adding to storage. For withdraw fee, check current bps.
    const successFeeBps = await core.successWithdrawFeeBps();
    const flexibleFeeBps = await core.flexibleWithdrawFeeBps();
    // For WITH_GOAL reached, success fee applies; otherwise flexible fee.
    const f = await storage.fundraisers(fid);
    const goalReached = f.fundraiserType === 0 /* WITH_GOAL */ && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount;
    const withdrawFeeBps = goalReached ? successFeeBps : flexibleFeeBps;
    const gross = f.raisedAmount; // no tranching in this test
    const expectedFee = gross * withdrawFeeBps / 10000n;
    const expectedNet = gross - expectedFee;

    await expect(core.withdrawFunds(fid))
      .to.emit(core, "FundsWithdrawn")
      // FundsWithdrawn emits net paid to creator
      .withArgs(fid, await storage.fundraiserCreators(fid), await storage.fundraiserTokens(fid), expectedNet);

    // Storage should record gross amount withdrawn
    const totalWithdrawn = await storage.totalWithdrawn(fid);
    expect(totalWithdrawn).to.equal(gross);

    // Second withdraw should fail (funds drained -> AlreadyWithdrawn/NothingToWithdraw)
    await expect(core.withdrawFunds(fid)).to.be.reverted;
  });
});
