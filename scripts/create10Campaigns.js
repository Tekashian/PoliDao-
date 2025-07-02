const hre = require("hardhat");
const { ethers } = hre;

// Contract ABI - tylko potrzebne funkcje
const DAO_ABI = [
  "function createFundraiser(address token, uint256 target, uint256 duration, bool isFlexible)",
  "function getFundraiserCount() view returns (uint256)",
  "function getFundraiserSummary(uint256 id) view returns (tuple(uint256 id, address creator, address token, uint256 target, uint256 raised, uint256 endTime, bool isFlexible, bool closureInitiated))",
  "function getAllFundraiserIds() view returns (uint256[])",
  "function timeLeftOnFundraiser(uint256 id) view returns (uint256)",
  "function owner() view returns (address)",
  "function commissionWallet() view returns (address)",
  "function isTokenWhitelisted(address) view returns (bool)",
  "function whitelistToken(address token)",
  "function getWhitelistedTokens() view returns (address[])"
];

async function main() {
  console.log("🚀 Starting campaign creation script for PoliDAO...\n");

  // Get signers
  const [deployer] = await ethers.getSigners();
  console.log("📋 Using account:", deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // Contract addresses
  const DAO_ADDRESS = "0xec0d7574E6f4A269Eea62011Af02b85D86d4c171";
  
  // Get contract instance
  const dao = new ethers.Contract(DAO_ADDRESS, DAO_ABI, deployer);

  console.log("📄 Connected to DAO contract at:", DAO_ADDRESS);
  
  try {
    const owner = await dao.owner();
    const commissionWallet = await dao.commissionWallet();
    console.log("🏛️ DAO Owner:", owner);
    console.log("💼 Commission Wallet:", commissionWallet);
  } catch (error) {
    console.log("⚠️ Could not fetch contract details:", error.message);
  }

  // Get whitelisted tokens
  let tokenAddress;
  try {
    const whitelistedTokens = await dao.getWhitelistedTokens();
    console.log("🪙 Whitelisted tokens:", whitelistedTokens.length);
    
    if (whitelistedTokens.length > 0) {
      tokenAddress = whitelistedTokens[0]; // Use first whitelisted token
      console.log("✅ Using token:", tokenAddress);
    } else {
      console.log("❌ No whitelisted tokens found! You need to whitelist a token first.");
      return;
    }
  } catch (error) {
    console.log("❌ Error getting whitelisted tokens:", error.message);
    return;
  }
  console.log();

  // Campaign configurations
  const flexibleCampaigns = [
    {
      name: "Community Development Fund",
      target: 0, // No target for flexible
      duration: 30 * 24 * 3600, // 30 days
      flexible: true
    },
    {
      name: "Open Source Project Support",
      target: 0,
      duration: 45 * 24 * 3600, // 45 days
      flexible: true
    },
    {
      name: "Educational Initiative",
      target: 0,
      duration: 60 * 24 * 3600, // 60 days
      flexible: true
    },
    {
      name: "Environmental Conservation",
      target: 0,
      duration: 90 * 24 * 3600, // 90 days
      flexible: true
    },
    {
      name: "Innovation Lab",
      target: 0,
      duration: 120 * 24 * 3600, // 120 days
      flexible: true
    }
  ];

  const targetedCampaigns = [
    {
      name: "Blockchain Infrastructure",
      target: ethers.parseUnits("10000", 18), // 10,000 tokens
      duration: 30 * 24 * 3600, // 30 days
      flexible: false
    },
    {
      name: "DeFi Protocol Development",
      target: ethers.parseUnits("25000", 18), // 25,000 tokens
      duration: 45 * 24 * 3600, // 45 days
      flexible: false
    },
    {
      name: "NFT Marketplace Platform",
      target: ethers.parseUnits("50000", 18), // 50,000 tokens
      duration: 60 * 24 * 3600, // 60 days
      flexible: false
    },
    {
      name: "Cross-chain Bridge",
      target: ethers.parseUnits("75000", 18), // 75,000 tokens
      duration: 90 * 24 * 3600, // 90 days
      flexible: false
    },
    {
      name: "Layer 2 Scaling Solution",
      target: ethers.parseUnits("100000", 18), // 100,000 tokens
      duration: 120 * 24 * 3600, // 120 days
      flexible: false
    }
  ];

  console.log("🎯 Creating 5 FLEXIBLE campaigns (no target)...\n");

  // Create flexible campaigns
  for (let i = 0; i < flexibleCampaigns.length; i++) {
    const campaign = flexibleCampaigns[i];
    
    try {
      console.log(`📝 Creating campaign ${i + 1}: "${campaign.name}"`);
      console.log(`   Type: Flexible (no target)`);
      console.log(`   Duration: ${campaign.duration / (24 * 3600)} days`);
      
      // Estimate gas
      const gasEstimate = await dao.createFundraiser.estimateGas(
        tokenAddress,
        campaign.target,
        campaign.duration,
        campaign.flexible
      );
      console.log(`   ⛽ Estimated gas: ${gasEstimate.toString()}`);
      
      const tx = await dao.createFundraiser(
        tokenAddress,
        campaign.target,
        campaign.duration,
        campaign.flexible,
        {
          gasLimit: gasEstimate * 120n / 100n // Add 20% buffer
        }
      );
      
      console.log(`   🔗 Transaction submitted: ${tx.hash}`);
      console.log(`   ⏳ Waiting for confirmation...`);
      
      const receipt = await tx.wait();
      const fundraiserCount = await dao.getFundraiserCount();
      
      console.log(`   ✅ Created! Fundraiser ID: ${fundraiserCount}`);
      console.log(`   ⛽ Gas used: ${receipt.gasUsed.toString()}`);
      console.log(`   💰 Gas cost: ${ethers.formatEther(receipt.gasUsed * receipt.gasPrice)} ETH`);
      console.log();
      
      // Small delay to avoid nonce issues
      await new Promise(resolve => setTimeout(resolve, 2000));
      
    } catch (error) {
      console.error(`   ❌ Failed to create campaign "${campaign.name}":`, error.message);
      if (error.reason) console.error(`   Reason: ${error.reason}`);
      console.log();
    }
  }

  console.log("🎯 Creating 5 TARGETED campaigns (with goals)...\n");

  // Create targeted campaigns
  for (let i = 0; i < targetedCampaigns.length; i++) {
    const campaign = targetedCampaigns[i];
    
    try {
      console.log(`📝 Creating campaign ${i + 6}: "${campaign.name}"`);
      console.log(`   Type: Targeted`);
      console.log(`   Target: ${ethers.formatUnits(campaign.target, 18)} tokens`);
      console.log(`   Duration: ${campaign.duration / (24 * 3600)} days`);
      
      // Estimate gas
      const gasEstimate = await dao.createFundraiser.estimateGas(
        tokenAddress,
        campaign.target,
        campaign.duration,
        campaign.flexible
      );
      console.log(`   ⛽ Estimated gas: ${gasEstimate.toString()}`);
      
      const tx = await dao.createFundraiser(
        tokenAddress,
        campaign.target,
        campaign.duration,
        campaign.flexible,
        {
          gasLimit: gasEstimate * 120n / 100n // Add 20% buffer
        }
      );
      
      console.log(`   🔗 Transaction submitted: ${tx.hash}`);
      console.log(`   ⏳ Waiting for confirmation...`);
      
      const receipt = await tx.wait();
      const fundraiserCount = await dao.getFundraiserCount();
      
      console.log(`   ✅ Created! Fundraiser ID: ${fundraiserCount}`);
      console.log(`   ⛽ Gas used: ${receipt.gasUsed.toString()}`);
      console.log(`   💰 Gas cost: ${ethers.formatEther(receipt.gasUsed * receipt.gasPrice)} ETH`);
      console.log();
      
      // Small delay to avoid nonce issues
      await new Promise(resolve => setTimeout(resolve, 2000));
      
    } catch (error) {
      console.error(`   ❌ Failed to create campaign "${campaign.name}":`, error.message);
      if (error.reason) console.error(`   Reason: ${error.reason}`);
      console.log();
    }
  }

  // Summary
  console.log("📊 FINAL SUMMARY:");
  console.log("================");
  
  try {
    const totalFundraisers = await dao.getFundraiserCount();
    console.log(`📈 Total fundraisers on contract: ${totalFundraisers}`);
    
    // Display all fundraisers
    console.log("\n📋 All Fundraisers:");
    const fundraiserIds = await dao.getAllFundraiserIds();
    
    for (let i = 0; i < fundraiserIds.length; i++) {
      const id = fundraiserIds[i];
      try {
        const summary = await dao.getFundraiserSummary(id);
        
        console.log(`\n   ID ${id}:`);
        console.log(`     Creator: ${summary.creator}`);
        console.log(`     Token: ${summary.token}`);
        console.log(`     Target: ${summary.isFlexible ? 'No target (Flexible)' : ethers.formatUnits(summary.target, 18) + ' tokens'}`);
        console.log(`     Raised: ${ethers.formatUnits(summary.raised, 18)} tokens`);
        console.log(`     Type: ${summary.isFlexible ? 'Flexible' : 'Targeted'}`);
        
        const timeLeft = await dao.timeLeftOnFundraiser(id);
        const daysLeft = timeLeft > 0 ? Math.floor(Number(timeLeft) / (24 * 3600)) : 0;
        console.log(`     Time left: ${daysLeft} days`);
        
        // Show end time
        const endDate = new Date(Number(summary.endTime) * 1000);
        console.log(`     Ends: ${endDate.toLocaleString()}`);
        
      } catch (error) {
        console.log(`     ❌ Error getting details for ID ${id}: ${error.message}`);
      }
    }
    
    console.log(`\n🎉 Campaign creation completed successfully!`);
    console.log(`✅ Contract: ${DAO_ADDRESS}`);
    console.log(`✅ Token: ${tokenAddress}`);
    console.log(`✅ Network: ${hre.network.name}`);
    
  } catch (error) {
    console.error("❌ Error getting final summary:", error.message);
  }
}

// Error handling
main()
  .then(() => {
    console.log("\n✅ Script executed successfully!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Script failed:");
    console.error("Error:", error.message);
    if (error.reason) console.error("Reason:", error.reason);
    if (error.code) console.error("Code:", error.code);
    process.exit(1);
  });