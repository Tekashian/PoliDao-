const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", await deployer.getAddress());

  // 1) biblioteki
  const DonationLogic = await ethers.getContractFactory("DonationLogic");
  const donationLib = await DonationLogic.deploy();
  await donationLib.waitForDeployment();

  const WithdrawLogic = await ethers.getContractFactory("WithdrawLogic");
  const withdrawLib = await WithdrawLogic.deploy();
  await withdrawLib.waitForDeployment();

  // 2) Core z linkiem do bibliotek
  const storageAddr = "0x2207Be06409BB71bc8BA5624B013D4847DC27fB5"; // z sepolia.json
  const routerAddr = "0x22Fd3e4c1fCBb2cABCBCc8253926446E8E4484a4";  // z sepolia.json

  const CoreFactory = await ethers.getContractFactory("PoliDaoCore", {
    libraries: {
      DonationLogic: await donationLib.getAddress(),
      WithdrawLogic: await withdrawLib.getAddress(),
    },
  });

  const core = await CoreFactory.deploy(storageAddr, routerAddr);
  await core.waitForDeployment();

  console.log("DonationLogic:", await donationLib.getAddress());
  console.log("WithdrawLogic:", await withdrawLib.getAddress());
  console.log("Core:", await core.getAddress());
}

main().catch((e) => { console.error(e); process.exit(1); });