const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("HelloWorld Contract", function () {
  it("should return the correct greeting", async function () {
    const HelloWorld = await ethers.getContractFactory("HelloWorld");
    const hello = await HelloWorld.deploy();
    await hello.waitForDeployment(); // ethers v6

    expect(await hello.greet()).to.equal("Hello, World!");
  });
});