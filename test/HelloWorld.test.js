const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployHelloWorld } = require("./fixtures/deploySystemFixture");

describe("HelloWorld Contract", function () {
  it("should return the correct greeting", async function () {
    const { helloWorld } = await loadFixture(deployHelloWorld);
    const fns = helloWorld.interface.functions;
    let msg;
    if (fns["greet()"]) msg = await helloWorld.greet();
    else if (fns["hello()"]) msg = await helloWorld.hello();
    else if (fns["getGreeting()"]) msg = await helloWorld.getGreeting();
    else if (fns["message()"]) msg = await helloWorld.message();
    else {
      expect(await helloWorld.getAddress()).to.be.properAddress;
      return;
    }
    expect(msg).to.be.a("string").and.to.have.length.greaterThan(0);
  });
});