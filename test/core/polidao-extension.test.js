const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployExtensionWithStubCore } = require("../fixtures/deploySystemFixture");

describe("PoliDaoExtension - Extension System", function () {
  it("✅ should deploy extension contract successfully", async function () {
    const env = await loadFixture(deployExtensionWithStubCore);
    expect(env.extension).to.exist;
    expect(await env.extension.getAddress()).to.be.properAddress;
  });
});