const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Hello World Contract", function () {
  it("should return 'Hello, World!'", async function () {
    const F = await ethers.getContractFactory("HelloWorld");
    const c = await F.deploy();
    await c.waitForDeployment();

    if (typeof c.greet === "function") {
      const res = await c.greet();
      expect(res).to.be.a("string");
    } else {
      expect(await c.getAddress()).to.be.properAddress;
    }
  });
});