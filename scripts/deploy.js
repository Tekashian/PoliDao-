const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  const commissionWallet = "0x50a185CfCD1Ce799057EAa83586D1061F3C073c1"; // <-- adres do odbioru prowizji

  const PoliDAO = await ethers.getContractFactory("PoliDAO");
  const dao = await PoliDAO.deploy(deployer.address, commissionWallet);
  await dao.deployed();

  console.log("PoliDAO deployed to:", dao.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
