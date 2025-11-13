const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Router -> CoreUpgradeable e2e", function () {
  it("router can create, donate and withdraw via UUPS Core (onlyRouter enforced)", async function () {
    const [owner, creator, donor] = await ethers.getSigners();

    // Token
    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    // Storage
    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();
    await (await storage.connect(owner).setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();

    // Core (UUPS impl + proxy)
    const CoreImplFactory = await ethers.getContractFactory(
      "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable"
    );
    const impl = await CoreImplFactory.deploy();
    await impl.waitForDeployment();
    const init = CoreImplFactory.interface.encodeFunctionData("initialize", [await storage.getAddress(), owner.address]);
    const Proxy = await ethers.getContractFactory("@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
    const proxy = await Proxy.deploy(await impl.getAddress(), init);
    await proxy.waitForDeployment();
    const core = await ethers.getContractAt(
      "contracts/core/PoliDaoCoreUpgradeable.sol:PoliDaoCoreUpgradeable",
      await proxy.getAddress()
    );

    // Bind storage<->core
    await (await storage.connect(owner).setCore(await core.getAddress())).wait();
    await (await storage.connect(owner).authorizeContract(await core.getAddress())).wait();

    // Router
    const Router = await ethers.getContractFactory("PoliDaoRouter");
    const router = await Router.deploy(await core.getAddress());
    await router.waitForDeployment();
    await (await core.connect(owner).setRouterContract(await router.getAddress())).wait();

    // Create NO_GOAL fundraiser via Router (routes to createFundraiserFor)
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const data = {
      title: "R",
      description: "E2E",
      endDate: now + 7 * 24 * 3600,
      fundraiserType: 1, // NO_GOAL
      token: await token.getAddress(),
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "",
      isFlexible: true
    };
  await (await router.connect(creator).createFundraiser(data)).wait();
  const fid = await core.getFundraiserCount();

    // Donate via Router (donateFrom -> onlyRouter)
    const amount = 1_000n;
    await (await token.mint(donor.address, amount)).wait();
    await (await token.connect(donor).approve(await core.getAddress(), amount)).wait();
    await expect(router.connect(donor).donate(fid, amount)).to.emit(core, "DonationMade");

    // Direct call to core.donateFrom should revert (only router)
    await expect(core.connect(donor).donateFrom(fid, donor.address, 1n)).to.be.revertedWith("PoliDaoCore: only router");

    // Withdraw via Router (withdrawFundsFor)
    const balCreatorBefore = await token.balanceOf(creator.address);
    await expect(router.connect(creator).withdrawFunds(fid)).to.emit(core, "FundsWithdrawn");
    const balCreatorAfter = await token.balanceOf(creator.address);
    expect(balCreatorAfter).to.be.gt(balCreatorBefore);
  });
});
