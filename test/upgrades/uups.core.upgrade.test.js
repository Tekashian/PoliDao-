const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("UUPS Proxy – CoreUUPSMock upgrade flow", function () {
  it("deploys V1 behind ERC1967Proxy, then upgrades to V2 preserving state", async () => {
    const [owner] = await ethers.getSigners();

    // Deploy real Storage for realism
    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();

    // Deploy implementation V1
    const V1 = await ethers.getContractFactory("CoreUUPSMockV1");
    const v1 = await V1.deploy();
    await v1.waitForDeployment();

    // Encode initializer
    const initData = V1.interface.encodeFunctionData("initialize", [
      await storage.getAddress(),
      "hello",
    ]);

    // Deploy ERC1967Proxy targeting V1
  const Proxy = await ethers.getContractFactory("contracts/test/UUPS/ERC1967Proxy.sol:ERC1967Proxy");
    const proxy = await Proxy.deploy(await v1.getAddress(), initData);
    await proxy.waitForDeployment();

    // Interact through proxy using V1 ABI
    const coreV1 = await ethers.getContractAt(
      "CoreUUPSMockV1",
      await proxy.getAddress()
    );

    expect(await coreV1.greeting()).to.equal("hello");
    expect(await coreV1.version()).to.equal("V1");

    await expect(coreV1.connect(owner).setGreeting("world")).to.not.be.reverted;
    expect(await coreV1.greeting()).to.equal("world");

    // Deploy implementation V2
    const V2 = await ethers.getContractFactory("CoreUUPSMockV2");
    const v2 = await V2.deploy();
    await v2.waitForDeployment();

    // Perform UUPS upgrade via proxy (authorizeUpgrade inside impl requires owner)
    // Use upgradeToAndCall for OZ v5 compatibility (empty data)
    await expect(
      coreV1.connect(owner).upgradeToAndCall(await v2.getAddress(), "0x")
    ).to.not.be.reverted;

    // Attach V2 ABI to same proxy address
    const coreV2 = await ethers.getContractAt(
      "CoreUUPSMockV2",
      await proxy.getAddress()
    );

    // State preserved, logic changed
    expect(await coreV2.greeting()).to.equal("world");
    expect(await coreV2.version()).to.equal("V2");
    expect(await coreV2.double(7)).to.equal(14n);
  });
});
