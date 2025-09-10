const { expect } = require("chai");
const { deployHelloWorld } = require("./fixtures/basicMocksFixture");

describe("HelloWorld Contract", function () {
    let helloWorld;
    
    beforeEach(async function () {
        helloWorld = await deployHelloWorld();
    });

    it("should return the correct greeting", async function () {
        const greeting = await helloWorld.greet();
        expect(greeting).to.equal("Hello, World!");
    });
});

describe("Hello World Contract", function () {
    it("should return 'Hello, World!'", async function () {
        const helloWorld = await deployHelloWorld();
        const result = await helloWorld.getMessage();
        expect(result).to.equal("Hello, World!");
    });
});