const { expect } = require("chai");
const { deployHelloWorld } = require("../fixtures/basicMocksFixture");

describe("Hello World Contract", function () {
    it("should return 'Hello, World!'", async function () {
        const helloWorld = await deployHelloWorld();
        const result = await helloWorld.getMessage();
        expect(result).to.equal("Hello, World!");
    });
});