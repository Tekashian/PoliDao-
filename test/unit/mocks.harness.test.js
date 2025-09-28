const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployBasicFixtures } = require("../fixtures/basicMocksFixture");

describe("Mocks harness - MockToken and ReentrancyAttackMock", function () {
    let mockToken, reentrancyMock;
    
    beforeEach(async function () {
        const fixtures = await deployBasicFixtures();
        mockToken = fixtures.mockToken;
        reentrancyMock = fixtures.reentrancyMock;
    });

    it("MockToken basic ERC20 behavior: transfer and balanceOf", async function () {
        const [owner, user1] = await ethers.getSigners();
        
        await mockToken.transfer(user1.address, ethers.parseEther("100"));
        const balance = await mockToken.balanceOf(user1.address);
        expect(balance).to.equal(ethers.parseEther("100"));
    });

    it("Reentrancy mock deployed and basic call signature exists", async function () {
        const Mock = await ethers.getContractFactory("ReentrancyAttackMock");
        const mock = await Mock.deploy();
        await mock.waitForDeployment();

        // ethers v6: inspect ABI fragments
        const frags = mock.interface.fragments.filter(f => f.type === "function");
        const hasAttackName = frags.some(f => (f.name || "").toLowerCase().includes("attack") || (f.name || "").toLowerCase().includes("reenter"));
        const hasAddressParam = frags.some(f => Array.isArray(f.inputs) && f.inputs.some(i => i.type === "address"));

        expect(hasAttackName || hasAddressParam).to.equal(true);
      });
});
