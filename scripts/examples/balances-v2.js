/* Przykład: pobranie sald ETH z Arbitrum(42161), Base(8453), Optimism(10) */
const { callEtherscanV2 } = require("../utils/etherscan-v2");

async function main() {
  const chains = [42161, 8453, 10];
  const address = process.env.CHECK_ADDRESS || "0xb5d85cbf7cb3ee0d56b3bb207d5fc4b82f43f511";

  for (const chainid of chains) {
    const balance = await callEtherscanV2({
      chainid,
      module: "account",
      action: "balance",
      params: {
        address,
        tag: "latest"
      }
    });
    console.log(`chain ${chainid}:`, balance);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});