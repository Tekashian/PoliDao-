/* Ethers v6 <-> v5 compatibility shim for tests */

const { Contract, ethers } = require("ethers");

// 1) Alias .address -> .target (ethers v6)
try {
  if (!Object.getOwnPropertyDescriptor(Contract.prototype, "address")) {
    Object.defineProperty(Contract.prototype, "address", {
      get: function () {
        return this.target || this._address || undefined;
      },
      configurable: true,
    });
  }
} catch (_) {}

// 2) BigInt helpers, by test calls like x.sub(y)
function toBigInt(x) {
  if (typeof x === "bigint") return x;
  if (x == null) throw new TypeError("Cannot convert null/undefined to bigint");
  return BigInt(x.toString());
}
function addBigIntMethod(name, fn) {
  const proto = BigInt.prototype;
  if (!Object.prototype.hasOwnProperty.call(proto, name)) {
    Object.defineProperty(proto, name, {
      value: fn,
      writable: false,
      enumerable: false,
      configurable: true,
    });
  }
}
addBigIntMethod("add", function (x) { return this + toBigInt(x); });
addBigIntMethod("sub", function (x) { return this - toBigInt(x); });
addBigIntMethod("mul", function (x) { return this * toBigInt(x); });
addBigIntMethod("div", function (x) { return this / toBigInt(x); });
addBigIntMethod("mod", function (x) { return this % toBigInt(x); });

addBigIntMethod("eq", function (x) { return this === toBigInt(x); });
addBigIntMethod("lt", function (x) { return this < toBigInt(x); });
addBigIntMethod("lte", function (x) { return this <= toBigInt(x); });
addBigIntMethod("gt", function (x) { return this > toBigInt(x); });
addBigIntMethod("gte", function (x) { return this >= toBigInt(x); });

addBigIntMethod("toHexString", function () {
  const hex = this.toString(16);
  return "0x" + (hex.length % 2 === 1 ? "0" + hex : hex);
});

/**
 * Ethers v6 compatibility helpers
 * Provides backward compatibility and v6-specific utilities
 */

/**
 * Safe contract deployment with proper waiting
 */
async function deployContract(contractFactory, ...args) {
    const contract = await contractFactory.deploy(...args);
    await contract.waitForDeployment();
    return contract;
}

/**
 * Get contract address (v6 compatible)
 */
async function getContractAddress(contract) {
    return await contract.getAddress();
}

/**
 * Safe transaction execution with wait
 */
async function executeTransaction(transaction) {
    const tx = await transaction;
    return await tx.wait();
}

/**
 * Convert legacy BigNumber to BigInt
 */
function toBigInt(value) {
    if (typeof value === 'bigint') return value;
    if (typeof value === 'string') return BigInt(value);
    if (value && value.toString) return BigInt(value.toString());
    return BigInt(value);
}

/**
 * Format ether amount (v6 compatible)
 */
function formatEther(wei) {
    return ethers.formatEther(wei);
}

/**
 * Parse ether amount (v6 compatible)
 */
function parseEther(ether) {
    return ethers.parseEther(ether.toString());
}

/**
 * Parse units with custom decimals (v6 compatible)
 */
function parseUnits(value, decimals = 18) {
    return ethers.parseUnits(value.toString(), decimals);
}

/**
 * Format units with custom decimals (v6 compatible)
 */
function formatUnits(value, decimals = 18) {
    return ethers.formatUnits(value, decimals);
}

/**
 * Check if address is valid (v6 compatible)
 */
function isAddress(address) {
    return ethers.isAddress(address);
}

/**
 * Get checksum address (v6 compatible)
 */
function getAddress(address) {
    return ethers.getAddress(address);
}

/**
 * Create random wallet (v6 compatible)
 */
function createRandomWallet() {
    return ethers.Wallet.createRandom();
}

/**
 * Connect contract to signer (v6 compatible)
 */
function connectContract(contract, signer) {
    return contract.connect(signer);
}

/**
 * Get transaction receipt (v6 compatible)
 */
async function getTransactionReceipt(txHash) {
    return await ethers.provider.getTransactionReceipt(txHash);
}

/**
 * Get block (v6 compatible)
 */
async function getBlock(blockNumber = 'latest') {
    return await ethers.provider.getBlock(blockNumber);
}

/**
 * Get balance (v6 compatible)
 */
async function getBalance(address) {
    return await ethers.provider.getBalance(address);
}

/**
 * Send transaction (v6 compatible)
 */
async function sendTransaction(transaction) {
    return await ethers.provider.sendTransaction(transaction);
}

/**
 * Estimate gas (v6 compatible)
 */
async function estimateGas(transaction) {
    return await ethers.provider.estimateGas(transaction);
}

/**
 * Get gas price (v6 compatible)
 */
async function getGasPrice() {
    const feeData = await ethers.provider.getFeeData();
    return feeData.gasPrice;
}

/**
 * Wait for transaction confirmation
 */
async function waitForTransaction(txHash, confirmations = 1) {
    return await ethers.provider.waitForTransaction(txHash, confirmations);
}

/**
 * Create contract interface (v6 compatible)
 */
function createInterface(abi) {
    return new ethers.Interface(abi);
}

/**
 * Encode function data (v6 compatible)
 */
function encodeFunctionData(contractInterface, functionName, args = []) {
    return contractInterface.encodeFunctionData(functionName, args);
}

/**
 * Decode function result (v6 compatible)
 */
function decodeFunctionResult(contractInterface, functionName, data) {
    return contractInterface.decodeFunctionResult(functionName, data);
}

/**
 * Hash message (v6 compatible)
 */
function hashMessage(message) {
    return ethers.hashMessage(message);
}

/**
 * Sign message (v6 compatible)
 */
async function signMessage(signer, message) {
    return await signer.signMessage(message);
}

/**
 * Verify message signature (v6 compatible)
 */
function verifyMessage(message, signature) {
    return ethers.verifyMessage(message, signature);
}

module.exports = {
    deployContract,
    getContractAddress,
    executeTransaction,
    toBigInt,
    formatEther,
    parseEther,
    parseUnits,
    formatUnits,
    isAddress,
    getAddress,
    createRandomWallet,
    connectContract,
    getTransactionReceipt,
    getBlock,
    getBalance,
    sendTransaction,
    estimateGas,
    getGasPrice,
    waitForTransaction,
    createInterface,
    encodeFunctionData,
    decodeFunctionResult,
    hashMessage,
    signMessage,
    verifyMessage
};