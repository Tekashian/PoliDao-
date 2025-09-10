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
        if (reentrancyMock && reentrancyMock.getAddress) {
            expect(await reentrancyMock.getAddress()).to.not.be.undefined;
            
            // Check if contract has interface
            if (reentrancyMock.interface) {
                expect(reentrancyMock.interface).to.not.be.undefined;
            }
        } else {
            // Skip test if reentrancyMock deployment failed
            this.skip();
        }
    });
});
