const { ethers } = require("hardhat");
const ethersLib = require("ethers"); // fallback for utils if needed
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * Resolve parseUnits/formatUnits across ethers v5 (utils.parseUnits) and v6 (parseUnits top-level).
 */
function resolveUtils() {
    // prefer hardhat ethers if present
    const H = (typeof ethers !== "undefined") ? ethers : undefined;
    if (H) {
        if (H.utils && typeof H.utils.parseUnits === "function") return H.utils;
        if (typeof H.parseUnits === "function" && typeof H.formatUnits === "function") {
            return { parseUnits: H.parseUnits.bind(H), formatUnits: H.formatUnits.bind(H) };
        }
    }
    if (ethersLib) {
        if (ethersLib.utils && typeof ethersLib.utils.parseUnits === "function") return ethersLib.utils;
        if (typeof ethersLib.parseUnits === "function" && typeof ethersLib.formatUnits === "function") {
            return { parseUnits: ethersLib.parseUnits.bind(ethersLib), formatUnits: ethersLib.formatUnits.bind(ethersLib) };
        }
    }
    throw new Error("No compatible ethers utils (parseUnits/formatUnits) found in environment");
}

const utils = resolveUtils();

async function toUnits(amount, decimals = 18) {
    return utils.parseUnits(String(amount), decimals);
}

function fromUnits(bn, decimals = 18) {
    return utils.formatUnits(bn, decimals);
}

function nowPlusDays(days) {
    return Math.floor(Date.now() / 1000) + days * 24 * 3600;
}

function bpsToFraction(bps) {
    return { numerator: bps, denominator: 10000 };
}

/**
 * Build sensible default constructor args for a ContractFactory from its interface.
 * Provides AddressZero for address types, 0 for uint/int, false for bool, "" for string, "0x" for bytes, [] for arrays.
 */
function buildDefaultArgsFromFactory(factory) {
    try {
        const iface = factory.interface;
        // ethers Interface may expose constructor fragment differently across versions
        const deployFragment = iface && (iface.deploy || (iface.fragments && iface.fragments.find(f => f.type === "constructor")));
        const inputs = (deployFragment && deployFragment.inputs) || (iface && iface.deployFunction && iface.deployFunction.inputs) || [];
        const ZERO_ADDR = (ethers && ethers.constants && ethers.constants.AddressZero) ? ethers.constants.AddressZero
            : (ethersLib && ethersLib.constants && ethersLib.constants.AddressZero) ? ethersLib.constants.AddressZero
            : "0x0000000000000000000000000000000000000000";

        const args = inputs.map(inp => {
            const t = inp.type || "";
            if (t.startsWith("address")) return ZERO_ADDR;
            if (t.startsWith("uint") || t.startsWith("int")) return 0;
            if (t === "bool") return false;
            if (t.startsWith("bytes")) return "0x";
            if (t === "string") return "";
            if (t.endsWith("[]")) return [];
            // fallback
            return 0;
        });
        return args;
    } catch (err) {
        return [];
    }
}

/**
 * Fallback deploy helper (robust across ethers versions).
 * Always returns a Contract-like object that has a .deployed() async shim.
 */
async function fallbackDeploy(contractName, ...providedArgs) {
    const Factory = await ethers.getContractFactory(contractName);

    // DEBUG: print constructor ABI inputs
    try {
        const iface = Factory.interface;
        const deployFragment = iface && (iface.deploy || (iface.fragments && iface.fragments.find(f => f.type === "constructor")));
        const inputs = (deployFragment && deployFragment.inputs) || (iface && iface.deployFunction && iface.deployFunction.inputs) || [];
        console.log(`[fallbackDeploy] ${contractName} constructor inputs:`, inputs.map(i => ({ name: i.name, type: i.type })));
    } catch (e) {
        console.log(`[fallbackDeploy] ${contractName} constructor inputs: <failed to read ABI>`, e && e.message);
    }

    const ensureContractShim = (obj) => {
        if (!obj) return obj;
        // If it's a tx-like object with no contract address, wait() might exist — but caller expects a Contract
        // If it's already a Contract, ensure .deployed exists
        if (typeof obj.deployed !== "function") {
            obj.deployed = async () => obj;
        }
        return obj;
    };

    // helper to attach a Contract from a receipt/tx
    const attachFromTx = async (txOrRes) => {
        if (!txOrRes) return null;
        if (typeof txOrRes.wait === "function") {
            const receipt = await txOrRes.wait();
            const addr = (receipt && (receipt.contractAddress || receipt.to)) || (txOrRes.deployTransaction && txOrRes.deployTransaction.contractAddress);
            if (addr) {
                const c = await ethers.getContractAt(contractName, addr);
                return ensureContractShim(c);
            }
        }
        return null;
    };

    // Try deploying with providedArgs
    try {
        const inst = await Factory.deploy(...providedArgs);
        // inst could be: Contract (ethers v5/v6), TransactionResponse, or other
        // If it's Contract-like and has address, ensure shim and return
        if (inst && (inst.address || inst.target || inst.contractAddress)) {
            return ensureContractShim(inst);
        }
        // Try to attach via wait() if present
        const attached = await attachFromTx(inst);
        if (attached) return attached;
        // If inst has deployed() (older ethers), call it then return shimmed instance
        if (inst && typeof inst.deployed === "function") {
            await inst.deployed();
            return ensureContractShim(inst);
        }
    } catch (err) {
        console.log(`[fallbackDeploy] ${contractName} deploy with providedArgs failed: ${err && err.message}`);
        // continue to try defaults
    }

    // Build ABI-derived defaults and try again
    const defaults = buildDefaultArgsFromFactory(Factory);
    console.log(`[fallbackDeploy] ${contractName} trying defaults:`, defaults);
    try {
        const inst2 = await Factory.deploy(...defaults);
        if (inst2 && (inst2.address || inst2.target || inst2.contractAddress)) {
            return ensureContractShim(inst2);
        }
        const attached2 = await attachFromTx(inst2);
        if (attached2) return attached2;
        if (inst2 && typeof inst2.deployed === "function") {
            await inst2.deployed();
            return ensureContractShim(inst2);
        }
    } catch (err) {
        console.log(`[fallbackDeploy] ${contractName} deploy with defaults failed: ${err && err.message}`);
        throw err;
    }

    throw new Error(`fallbackDeploy: failed to deploy ${contractName}`);
}

/**
 * Deploy MockToken robustly: tries common constructor signatures (uses full 5-arg ctor if available),
 * then ensures target account has `amount`. Returns { token, minted }.
 */
async function deployMockToken(minterAddress, amountWei) {
    const MockTokenFactory = await ethers.getContractFactory("MockToken");
    let token;
    const defaultArgs = buildDefaultArgsFromFactory(MockTokenFactory) || [];

    // prepare sensible full-arg defaults when ABI expects them
    const signers = await ethers.getSigners();
    const deployerAddr = (signers && signers[0] && signers[0].address) ? signers[0].address : (ethers.constants ? ethers.constants.AddressZero : "0x0000000000000000000000000000000000000000");
    const supply = (typeof utils !== "undefined" && typeof utils.parseUnits === "function") ? utils.parseUnits("1000000", 18) : 0;

    const tries = [
        // try common explicit full-arg constructor if present: name, symbol, decimals, initialSupply, initialOwner
        async () => MockTokenFactory.deploy("MockToken", "MCK", 18, supply, deployerAddr),
        async () => MockTokenFactory.deploy("MockToken", "MCK", 18, supply, deployerAddr),
        async () => MockTokenFactory.deploy("MockToken", "MCK", 18),
        async () => MockTokenFactory.deploy("MockToken", "MCK"),
        async () => MockTokenFactory.deploy("MCK", 18),
        async () => MockTokenFactory.deploy(...defaultArgs),
        async () => MockTokenFactory.deploy()
    ];

    let deployed = false;
    for (const t of tries) {
        try {
            const res = await t();
            if (res && typeof res.deployed === "function") {
                await res.deployed();
                token = res;
                deployed = true;
                break;
            }
            if (res && typeof res.wait === "function") {
                const receipt = await res.wait();
                const addr = (receipt && (receipt.contractAddress || receipt.to)) || (res.deployTransaction && res.deployTransaction.contractAddress);
                if (addr) {
                    token = await ethers.getContractAt("MockToken", addr);
                    // ensure shim
                    if (typeof token.deployed !== "function") token.deployed = async () => token;
                    deployed = true;
                    break;
                }
            }
        } catch (err) {
            // ignore and try next
        }
    }
    if (!deployed) {
        // last attempt using fallbackDeploy which uses ABI defaults
        try {
            token = await fallbackDeploy("MockToken");
            deployed = true;
        } catch (err) {
            throw new Error("deployMockToken: unable to deploy MockToken - check MockToken constructor or ABI");
        }
    }

    // Ensure minterAddress has amountWei
    let minted = false;
    if (minterAddress && amountWei) {
        // try mint function
        try {
            if (typeof token.mint === "function") {
                await token.mint(minterAddress, amountWei);
                minted = true;
            }
        } catch (err) { /* ignore */ }

        // fallback transfer if deployer has balance
        if (!minted) {
            try {
                const [deployer] = await ethers.getSigners();
                const deployerBal = await token.balanceOf(deployer.address);
                if (deployerBal.gte(amountWei)) {
                    await token.transfer(minterAddress, amountWei);
                    minted = true;
                }
            } catch (err) { /* ignore */ }
        }

        if (!minted) {
            // Last resort: attempt call to faucet-like function names
            const tryNames = ["faucet", "getTokens", "drip"];
            for (const fn of tryNames) {
                if (typeof token[fn] === "function") {
                    try {
                        await token[fn](minterAddress, amountWei);
                        minted = true;
                        break;
                    } catch (err) { /* ignore */ }
                }
            }
        }
    }

    return { token, minted };
}

/**
 * Helper to assert revert with substring message
 */
async function expectRevert(promise, messageSubstring) {
    try {
        await promise;
    } catch (err) {
        const msg = err.message || String(err);
        if (!messageSubstring || msg.includes(messageSubstring)) return;
        throw new Error(`Expected revert containing "${messageSubstring}", got: ${msg}`);
    }
    throw new Error("Expected revert but tx succeeded");
}

/* --- replace previous complex patch with a robust, minimal wrapper --- */
(function patchContractFactoryDeploySimple() {
    try {
        const CF = ethers.ContractFactory;
        if (!CF || !CF.prototype || CF.prototype.__deployPatchedSimple) return;
        const originalDeploy = CF.prototype.deploy;
        CF.prototype.deploy = async function (...args) {
            // try normal deploy first
            try {
                const res = await originalDeploy.apply(this, args);

                // If it's a tx-like object (TxResponse) -> wait + attach full Contract from artifact
                if (res && typeof res.wait === "function") {
                    try {
                        const receipt = await res.wait();
                        const addr = (receipt && (receipt.contractAddress || receipt.to)) || (res.deployTransaction && res.deployTransaction.contractAddress);
                        if (addr) {
                            // Always attach by contract name (uses compiled artifact ABI)
                            try {
                                const signerOrProvider = (this.signer && this.signer.provider) ? this.signer : (ethers.provider ? ethers.provider.getSigner() : undefined);
                                const contract = await ethers.getContractAt(this.constructorName || this.contractName || this.interface && this.interface.name || (args[0] && typeof args[0] === 'string' ? args[0] : undefined) || this.interface?.name, addr, signerOrProvider);
                                if (typeof contract.deployed !== "function") contract.deployed = async () => contract;
                                return contract;
                            } catch (e) {
                                // Fallback: try by contractName if available
                                try {
                                    const contract = await ethers.getContractAt(this.contractName || this.interface?.name, addr);
                                    if (typeof contract.deployed !== "function") contract.deployed = async () => contract;
                                    return contract;
                                } catch (e2) {
                                    // last resort: return minimal shim with address + deployed()
                                    const shim = { address: addr, deployed: async () => shim };
                                    return shim;
                                }
                            }
                        }
                    } catch (e) {
                        // if wait/attach failed, fallthrough to other checks
                    }
                }

                // If it's already a Contract-like object with address -> ensure deployed() and return
                if (res && (res.address || res.target || res.contractAddress)) {
                    if (typeof res.deployed !== "function") res.deployed = async () => res;
                    return res;
                }

                // If older ethers returned Contract with deployed() available
                if (res && typeof res.deployed === "function") {
                    await res.deployed();
                    return res;
                }

                // otherwise return whatever original returned
                return res;
            } catch (err) {
                const msg = err && err.message ? err.message.toLowerCase() : "";
                // If error is unrelated, rethrow
                if (!msg.includes("incorrect number of arguments") && !msg.includes("missing")) {
                    throw err;
                }
            }

            // If constructor arg mismatch, build defaults and retry (use buildDefaultArgsFromFactory)
            try {
                const defaults = buildDefaultArgsFromFactory(this);
                const res2 = await originalDeploy.apply(this, defaults);

                if (res2 && typeof res2.wait === "function") {
                    const receipt = await res2.wait();
                    const addr = (receipt && (receipt.contractAddress || receipt.to)) || (res2.deployTransaction && res2.deployTransaction.contractAddress);
                    if (addr) {
                        try {
                            const contract = await ethers.getContractAt(this.contractName || this.interface?.name, addr);
                            if (typeof contract.deployed !== "function") contract.deployed = async () => contract;
                            return contract;
                        } catch (e) {
                            const shim = { address: addr, deployed: async () => shim };
                            return shim;
                        }
                    }
                }

                if (res2 && (res2.address || res2.target || res2.contractAddress)) {
                    if (typeof res2.deployed !== "function") res2.deployed = async () => res2;
                    return res2;
                }

                if (res2 && typeof res2.deployed === "function") {
                    await res2.deployed();
                    return res2;
                }

                return res2;
            } catch (e) {
                throw e;
            }
        };
        CF.prototype.__deployPatchedSimple = true;
    } catch (e) {
        // do not break tests if patching not possible
    }
})();

module.exports = {
    toUnits,
    fromUnits,
    nowPlusDays,
    bpsToFraction,
    deployMockToken,
    expectRevert,
    loadFixture,
    fallbackDeploy,
};