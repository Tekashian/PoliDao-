const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Flexible fundraiser - single withdraw & refund block", () => {
  let token, storage, core, owner, creator, donor, feeRecipient, fid;

  beforeEach(async () => {
    [owner, creator, donor, feeRecipient] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    token = await ERC20Mock.deploy("FlexUSD", "FUSD", owner.address, ethers.parseUnits("500000", 18));

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

  // Deploy Router and bind to Core for onlyRouter flows (refund path)
  const Router = await ethers.getContractFactory("PoliDaoRouter");
  const router = await Router.deploy(await core.getAddress());
  await router.waitForDeployment();
  await core.connect(owner).setRouterContract(await router.getAddress());

    await core.connect(owner).setFeeRecipient(feeRecipient.address);
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(0, 0);

    const data = {
      title: "Flexible",
      description: "Desc",
      endDate: (await ethers.provider.getBlock()).timestamp + 30 * 24 * 3600,
      fundraiserType: 1, // NO_GOAL
      token: token.target,
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Loc",
      isFlexible: true
    };
    const tx = await core.connect(creator).createFundraiser(data);
    const rc = await tx.wait();
    const ev = rc.logs.find(l => l.fragment && l.fragment.name === "FundraiserCreated");
    fid = ev.args.fundraiserId;

    await token.connect(owner).transfer(donor.address, ethers.parseUnits("200", 18));
    await token.connect(donor).approve(core.target, ethers.parseUnits("200", 18));
    await core.connect(donor).donate(fid, ethers.parseUnits("100", 18));
  });

  it("allows single withdraw and blocks second + refunds", async () => {
    const raised = (await storage.fundraisers(fid)).raisedAmount;
    await expect(core.connect(creator).withdrawFunds(fid))
      .to.emit(core, "FundsWithdrawn")
      .withArgs(fid, creator.address, token.target, raised);

    expect(await storage.totalWithdrawn(fid)).to.equal(raised);
    expect(await core.withdrawalsStarted(fid)).to.equal(true);

    await expect(core.connect(creator).withdrawFunds(fid)).to.be.reverted;

    // Refund must be called through Router and should be blocked after withdrawals start
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    const router = Router.attach(await core.routerContract());
    await expect(router.connect(donor).claimRefund(fid))
      .to.be.revertedWith("PoliDaoCore: withdrawals started");
  });
});