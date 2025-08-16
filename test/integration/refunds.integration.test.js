const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Integration: Factory + Storage + Refunds module (custody flow)", function () {
  let deployer, alice, bob;
  let Storage, Core, Extensions, Router, Refunds, MockToken, Factory;
  let factory, storageImpl, coreImpl, extensionsImpl, routerImpl;

  before(async function () {
    async function waitDeployed(contract) {
      if (!contract) return;
      if (typeof contract.waitForDeployment === 'function') {
        await contract.waitForDeployment();
      } else if (typeof contract.deployed === 'function') {
        await contract.deployed();
      }
    }
    [deployer, alice, bob] = await ethers.getSigners();

    // Prepare contract factories and linked libraries
    Storage = await ethers.getContractFactory("PoliDaoStorage");
    Core = await ethers.getContractFactory("PoliDaoCore");

    const ExtensionLogicLib = await ethers.getContractFactory("ExtensionLogic");
    const extensionLogic = await ExtensionLogicLib.deploy();
    await waitDeployed(extensionLogic);

    const LocationLogicLib = await ethers.getContractFactory("LocationLogic");
    const locationLogic = await LocationLogicLib.deploy();
    await waitDeployed(locationLogic);

    Extensions = await ethers.getContractFactory("PoliDaoExtensions", {
      libraries: {
        "contracts/libraries/ExtensionLogic.sol:ExtensionLogic": await extensionLogic.getAddress(),
        "contracts/libraries/LocationLogic.sol:LocationLogic": await locationLogic.getAddress()
      }
    });

    Router = await ethers.getContractFactory("PoliDaoRouter");
    Refunds = await ethers.getContractFactory("PoliDaoRefunds");
    MockToken = await ethers.getContractFactory("MockToken");
    Factory = await ethers.getContractFactory("PoliDaoFactory");
  });

  it("deploys system via Factory clones and processes a refund via Storage.releaseFunds", async function () {
    // deploy a mock token and mint to deployer
  const token = await MockToken.deploy("TestToken", "TST", 18, 1000, deployer.address);
  await waitDeployed(token);
  // token already minted to deployer by constructor; minting extra is optional
  await token.mint(deployer.address, ethers.utils.parseEther("1000"));

    const commissionWallet = deployer.address;
    const feeToken = token.address;
    const initialToken = token.address;

    // 1) Deploy implementation contracts (these are templates for clones)
  storageImpl = await Storage.deploy(commissionWallet, feeToken, initialToken);
  await waitDeployed(storageImpl);

  coreImpl = await Core.deploy(addressZeroOr(await storageImpl.getAddress()));
    // Note: Core's constructor expects a storage address; we deploy with storageImpl.address as a placeholder
    // but we don't rely on the implementation instance state.
  await waitDeployed(coreImpl);

  extensionsImpl = await Extensions.deploy(await storageImpl.getAddress(), await coreImpl.getAddress());
  await waitDeployed(extensionsImpl);

  routerImpl = await Router.deploy(await coreImpl.getAddress());
  await waitDeployed(routerImpl);

    // 2) Deploy factory and set implementations (owner-only)
    factory = await Factory.deploy();
    await waitDeployed(factory);

    await factory.connect(deployer).setImplementations(
      await storageImpl.getAddress(),
      await coreImpl.getAddress(),
      await extensionsImpl.getAddress(),
      await routerImpl.getAddress()
    );

    // 3) Create a cloned system via factory
    const tx = await factory.connect(deployer).deployFullPoliDao(commissionWallet, feeToken, initialToken, "TestSystem");
    const rc = await tx.wait();
    const ev = rc.events.find(e => e.event === 'PoliDaoDeployed');
    const storageAddr = ev.args.storageContract;
    const coreAddr = ev.args.coreContract;
    const extensionsAddr = ev.args.extensionsContract;
    const routerAddr = ev.args.routerContract;

    // Attach to the cloned contracts
    const storage = await ethers.getContractAt("PoliDaoStorage", storageAddr);
    const core = await ethers.getContractAt("PoliDaoCore", coreAddr);
    const extensions = await ethers.getContractAt("PoliDaoExtensions", extensionsAddr);
    const router = await ethers.getContractAt("PoliDaoRouter", routerAddr);

    // 4) Deploy refunds module against the cloned core
  const refunds = await Refunds.deploy(core.address, commissionWallet);
  await waitDeployed(refunds);

    // 5) Configure modules using core.setModules (core owner is deployer after factory deploy)
    await core.connect(deployer).setModules(
      deployer.address, // governance
      deployer.address, // media
      deployer.address, // updates
      refunds.address,   // refunds
      deployer.address, // security
      deployer.address, // web3
      deployer.address  // analytics
    );

    // 6) Authorize modules in storage (storage owner is deployer)
    await storage.connect(deployer).authorizeContract(refunds.address);
    await storage.connect(deployer).authorizeContract(deployer.address); // dummy modules

    // 7) Transfer tokens into storage custodian
    await token.connect(deployer).transfer(storage.address, ethers.utils.parseEther("100"));

    // 8) Create a fundraiser via storage (simple struct values)
    const data = {
      id: 0,
      creator: alice.address,
      endDate: Math.floor(Date.now() / 1000) - 100, // already ended
      goal: ethers.utils.parseEther("1000"),
      raised: ethers.utils.parseEther("0"),
      status: 3,
      token: token.address
    };

    const createTx = await storage.connect(deployer).createFundraiser(data, "title", "desc", "loc", alice.address, token.address);
    await createTx.wait();

    // Simulate a recorded donation
    await storage.connect(deployer).addDonation(1, bob.address, ethers.utils.parseEther("10"));

    // 9) Trigger refund via core.refund and assert funds were released from storage
    const refundTx = await core.connect(deployer).refund(1);
    const refundRc = await refundTx.wait();

    // Check storage token balance decreased (funds released)
    const storageBal = await token.balanceOf(storage.address);
    expect(storageBal.lt(ethers.utils.parseEther("100"))).to.be.true;
  }).timeout(120000);
});

// helper: when building a placeholder for implementation constructor we sometimes pass address(0).
function addressZeroOr(addr) { return addr || ethers.constants.AddressZero; }

async function waitDeployed(contract) {
  if (!contract) return;
  if (typeof contract.waitForDeployment === 'function') {
    await contract.waitForDeployment();
  } else if (typeof contract.deployed === 'function') {
    await contract.deployed();
  }
}
