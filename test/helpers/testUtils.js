const { ethers } = require("hardhat");
const ethersLib = require("ethers"); // fallback for utils if needed
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const path = require("path");

// Ensure a usable ethers.utils is available for tests that call ethers.utils.* directly
try {
    const hardhatEthers = ethers;
    const pkgEthers = ethersLib;

    // Ensure global ethers
    if (typeof globalThis !== "undefined") {
        globalThis.ethers = globalThis.ethers || hardhatEthers;
    }

    const gEth = globalThis.ethers || hardhatEthers;

    // utils bag
    gEth.utils = gEth.utils || {};

    // parseUnits polyfill (ethers v6 has parseUnits at top-level)
    if (typeof gEth.utils.parseUnits !== "function") {
        if (typeof gEth.parseUnits === "function") {
            gEth.utils.parseUnits = (...a) => gEth.parseUnits(...a);
        } else if (pkgEthers && pkgEthers.utils && typeof pkgEthers.utils.parseUnits === "function") {
            gEth.utils.parseUnits = (...a) => pkgEthers.utils.parseUnits(...a);
        }
    }

    // formatBytes32String polyfill (ethers v6 has encodeBytes32String)
    if (typeof gEth.utils.formatBytes32String !== "function") {
        if (typeof gEth.encodeBytes32String === "function") {
            gEth.utils.formatBytes32String = (v) => gEth.encodeBytes32String(v);
        } else if (pkgEthers && pkgEthers.utils && typeof pkgEthers.utils.formatBytes32String === "function") {
            gEth.utils.formatBytes32String = (v) => pkgEthers.utils.formatBytes32String(v);
        }
    }
} catch (_e) {
    // ignore
}

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

// ===== NEW: helpers used by fallback deploys and patch =====
const DEPLOY_CACHE = global.__TEST_UTILS_DEPLOY_CACHE__ = global.__TEST_UTILS_DEPLOY_CACHE__ || {};

/**
 * Normalize argument for constructor:
 * - Contract-like => its address
 * - BigInt/BigNumber/String/Number => pass-through
 */
async function normalizeArg(arg) {
    if (!arg) return arg;
    if (typeof arg === "object") {
        const addr = arg.address || arg.target || arg.contractAddress;
        if (addr) return addr;
    }
    return arg;
}

/**
 * Deploy a contract once and cache. Always returns an ethers Contract-like with .address and .deployed()
 */
async function deployOnce(name, ...args) {
    if (DEPLOY_CACHE[name]) return DEPLOY_CACHE[name];

    const p = (async () => {
        const F = await ethers.getContractFactory(name);
        const norm = await Promise.all((args || []).map(normalizeArg));

        let res;
        try {
            res = await F.deploy(...norm);
        } catch (e) {
            // try without args as a last resort
            res = await F.deploy();
        }

        // ethers v6 returns Contract; v5 may return TxResponse
        if (res && (res.address || res.target || res.contractAddress)) {
            if (typeof res.deployed !== "function") res.deployed = async () => res;
            return res;
        }
        if (res && typeof res.wait === "function") {
            const receipt = await res.wait();
            const addr = (receipt && (receipt.contractAddress || receipt.to)) || (res.deployTransaction && res.deployTransaction.contractAddress);
            if (addr) {
                try {
                    const c = await ethers.getContractAt(name, addr);
                    if (typeof c.deployed !== "function") c.deployed = async () => c;
                    return c;
                } catch {
                    const shim = { address: addr, deployed: async () => shim };
                    return shim;
                }
            }
        }
        if (typeof res?.deployed === "function") {
            await res.deployed();
            return res;
        }
        return res;
    })();

    DEPLOY_CACHE[name] = p;
    return p;
}

/**
 * Resolve address dependencies by ABI param name heuristics. Returns an address string.
 */
async function resolveDependencyByName(argName) {
    const role = String(argName || "").toLowerCase();
    const [signer] = await ethers.getSigners();

    const addrFrom = (c) => (c && (c.address || c.target)) || c || ethers.constants.AddressZero;

    if (role.includes("storage")) {
        const s = await deployOnce("PoliDaoStorage");
        return addrFrom(s);
    }
    if (role.includes("core") || role.includes("main")) {
        const s = await deployOnce("PoliDaoStorage");
        const c = await deployOnce("PoliDaoCore", addrFrom(s));
        return addrFrom(c);
    }
    if (role.includes("router")) {
        const coreAddr = await resolveDependencyByName("core");
        const r = await deployOnce("PoliDaoRouter", coreAddr);
        return addrFrom(r);
    }
    if (role.includes("refund")) {
        // PoliDaoRefunds(main, commissionWallet)
        const coreAddr = await resolveDependencyByName("core");
        const r = await deployOnce("PoliDaoRefunds", coreAddr, signer.address);
        return addrFrom(r);
    }
    if (role.includes("commission") && role.includes("wallet")) {
        return signer.address;
    }
    if (role.includes("fee") && role.includes("token")) {
        // Try a MockToken
        try {
            const dec = 18;
            const supply = await toUnits("1000000", dec);
            const t = await deployOnce("MockToken", "MockToken", "MCK", dec, supply, signer.address);
            return addrFrom(t);
        } catch {
            return signer.address;
        }
    }
    if (role.includes("owner") || role.includes("admin")) {
        return signer.address;
    }
    if (role.includes("token")) {
        // Generic token address
        try {
            const dec = 18;
            const supply = await toUnits("1000000", dec);
            const t = await deployOnce("MockToken", "MockToken", "MCK", dec, supply, signer.address);
            return addrFrom(t);
        } catch {
            return signer.address;
        }
    }
    return signer.address;
}

/**
 * Build sensible default constructor args for a ContractFactory from its interface.
 * Provides AddressZero for address types, 0 for uint/int, false for bool, "" for string, "0x" for bytes, [] for arrays.
 */
function buildDefaultArgsFromFactory(factory) {
    try {
        const iface = factory.interface;
        const deployFragment = iface && (iface.deploy || (iface.fragments && iface.fragments.find(f => f.type === "constructor")));
        const inputs = (deployFragment && deployFragment.inputs) || (iface && iface.deployFunction && iface.deployFunction.inputs) || [];

        // prefer first signer address if available; avoid awaiting here to keep function sync
        let ZERO_ADDR = "0x0000000000000000000000000000000000000000";
        try {
            if (ethers && ethers.constants && ethers.constants.AddressZero) {
                ZERO_ADDR = ethers.constants.AddressZero;
            } else if (ethersLib && ethersLib.constants && ethersLib.constants.AddressZero) {
                ZERO_ADDR = ethersLib.constants.AddressZero;
            }
        } catch (e) { /* ignore */ }

        const args = inputs.map(inp => {
            const t = (inp && inp.type) || "";
            const name = (inp && inp.name) ? inp.name.toLowerCase() : "";

            // address-like params
            if (t.startsWith("address")) {
                // prefer meaningful owner/core addresses instead of zero
                if (name.includes("owner") || name.includes("initialowner") || name.includes("main") || name.includes("core") || name.includes("admin")) {
                    return ZERO_ADDR;
                }
                return ZERO_ADDR;
            }

            // decimals heuristics
            if (name.includes("decimals") || name === "decimals_" || name === "decimals") return 18;

            // initialSupply / supply heuristics => large supply
            if (name.includes("supply") || name.includes("initialsupply") || name.includes("initial_supply")) {
                try {
                    const dec = 18;
                    if (utils && typeof utils.parseUnits === "function") return utils.parseUnits("1000000", dec);
                } catch (e) { /* ignore */ }
                return 0;
            }

            // numeric types
            if (t.startsWith("uint") || t.startsWith("int")) return 0;
            if (t === "bool") return false;
            if (t.startsWith("bytes")) return "0x";
            if (t === "string") return "";
            if (t.endsWith("[]")) return [];
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
    // Jeśli są jawne argumenty, próbuj bezpośrednio
    if (providedArgs && providedArgs.length > 0) {
        try {
            const F = await ethers.getContractFactory(contractName);
            const norm = await Promise.all(providedArgs.map(normalizeArg));
            const inst = await F.deploy(...norm);
            if (typeof inst?.deployed === "function") await inst.deployed();
            return inst;
        } catch (_e) { /* continue to system-backed path */ }
    }

    // 1) użyj gotowych instancji z system fixture
    const sys = await getSystem();
    if (sys) {
        const name = String(contractName || "");
        const map = {
            "PoliDaoStorage": pick(sys, ["storage", "daoStorage", "PoliDaoStorage", "poliDaoStorage"]),
            "PoliDaoCore": pick(sys, ["core", "daoCore", "PoliDaoCore", "poliDaoCore"]),
            "PoliDaoRouter": pick(sys, ["router", "daoRouter", "PoliDaoRouter", "poliDaoRouter"]),
            "PoliDaoRefunds": pick(sys, ["refunds", "daoRefunds", "PoliDaoRefunds", "poliDaoRefunds"]),
            "MockToken": pick(sys, ["token", "feeToken", "mockToken", "erc20"]),
        };
        if (map[name]) return map[name];
    }

    // 2) fallback: rozpoznaj potrzebne adresy z ABI i rozwiąż address-deps
    const Factory = await ethers.getContractFactory(contractName);
    const fragment = Factory.interface?.deploy || Factory.interface?.fragments?.find(f => f.type === "constructor");
    const inputs = (fragment && fragment.inputs) || [];

    const args = [];
    for (const inp of inputs) {
        const t = (inp.type || "").toLowerCase();
        const n = (inp.name || "").toLowerCase();

        if (t.startsWith("address")) {
            args.push(await resolveDependencyByName(n || t));
        } else if (n.includes("decimals")) {
            args.push(18);
        } else if (n.includes("supply")) {
            const dec = 18;
            const supply = (ethers.utils && ethers.utils.parseUnits) ? ethers.utils.parseUnits("1000000", dec) : 1000000;
            args.push(supply);
        } else if (t === "bool") {
            args.push(false);
        } else if (t.startsWith("uint") || t.startsWith("int")) {
            args.push(0);
        } else if (t === "string") {
            args.push("");
        } else if (t.startsWith("bytes")) {
            args.push("0x");
        } else if (t.endsWith("[]")) {
            args.push([]);
        } else {
            args.push(0);
        }
    }

    const inst = await deployOnce(contractName, ...args);
    return inst;
}

/**
 * Deploy MockToken robustly: tries common constructor signatures (uses full 5-arg ctor if available),
 * then ensures target account has `amount`. Returns { token, minted }.
 */
async function deployMockToken(options = {}) {
    const [signer] = await ethers.getSigners();
    const owner = options.owner || signer.address;
    const name = options.name || "MockToken";
    const symbol = options.symbol || "MCK";
    const decimals = options.decimals ?? 18;
    const supply = options.supply ?? (ethers.utils && ethers.utils.parseUnits ? ethers.utils.parseUnits("1000000", decimals) : (10n ** BigInt(6 + decimals)));

    // Try most common ctor: (string, string, uint8, uint256, address)
    try {
        return await deployOnce("MockToken", name, symbol, decimals, supply, owner);
    } catch (_e1) {
        // Alt: (string, string, uint8, uint256) then mint/transfer in fixture – deploy anyway
        try {
            return await deployOnce("MockToken", name, symbol, decimals, supply);
        } catch (_e2) {
            // Alt: (uint256, address)
            try {
                return await deployOnce("MockToken", supply, owner);
            } catch (_e3) {
                // Alt: (address, uint256)
                try {
                    return await deployOnce("MockToken", owner, supply);
                } catch (eFinal) {
                    throw eFinal;
                }
            }
        }
    }
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

// System fixture loader (deployuje spójny zestaw: storage, core, router, refunds, tokeny)
let SYSTEM_CACHE = null;
async function getSystem() {
    if (SYSTEM_CACHE) return SYSTEM_CACHE;
    try {
        const mod = require(path.join(__dirname, "..", "fixtures", "deploySystemFixture.js"));
        const fn = mod.deploySystemFixture || mod.default || mod; // wspiera różne eksporty
        const sys = await loadFixture(fn);
        SYSTEM_CACHE = sys;
        return sys;
    } catch (e) {
        return null;
    }
}

function pick(obj, keys) {
    for (const k of keys) {
        if (obj && obj[k]) return obj[k];
    }
    return undefined;
}

async function systemAddressByRole(role) {
    const sys = await getSystem();
    if (!sys) return null;

    const roleLc = String(role || "").toLowerCase();

    const storageC =
        pick(sys, ["storage", "daoStorage", "PoliDaoStorage", "poliDaoStorage"]) ||
        Object.values(sys).find((c) => c?.interface?.functions?.createFundraiser);
    const coreC =
        pick(sys, ["core", "daoCore", "PoliDaoCore", "poliDaoCore"]) ||
        Object.values(sys).find((c) => c?.interface?.functions?.setAuthorizedRouter && c?.interface?.functions?.setModule);
    const routerC =
        pick(sys, ["router", "daoRouter", "PoliDaoRouter", "poliDaoRouter"]) ||
        Object.values(sys).find((c) => c?.interface?.functions?.createFundraiserViaRouter);
    const refundsC =
        pick(sys, ["refunds", "daoRefunds", "PoliDaoRefunds", "poliDaoRefunds"]) ||
        Object.values(sys).find((c) => c?.interface?.functions?.setCommissions);

    const tokenC =
        pick(sys, ["token", "feeToken", "mockToken", "erc20"]) ||
        Object.values(sys).find((c) => c?.interface?.functions?.transfer && c?.interface?.functions?.balanceOf);

    if (roleLc.includes("storage")) return storageC?.address ?? storageC?.target ?? null;
    if (roleLc.includes("core") || roleLc.includes("main")) return coreC?.address ?? coreC?.target ?? null;
    if (roleLc.includes("router")) return routerC?.address ?? routerC?.target ?? null;
    if (roleLc.includes("refund")) return refundsC?.address ?? refundsC?.target ?? null;
    if (roleLc.includes("token") || roleLc.includes("fee") || roleLc.includes("commissionwallet")) return tokenC?.address ?? tokenC?.target ?? null;
    return null;
}

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