# PoliDAO Contracts (UUPS Upgradeable)

Production-grade smart contract suite for PoliDAO. The system centers on a UUPS-upgradeable Core behind an ERC1967 proxy, wired to a single Storage contract, a Router entrypoint, and pluggable feature Modules.

## Architecture at a glance

- Core (PoliDaoCoreUpgradeable)
  - Thin orchestrator; stateless logic in libraries; state lives in Storage
  - UUPS upgradeability (ERC1967 proxy) via OpenZeppelin
  - Access control: owner (admin + upgrades), onlyRouter for mediated flows, Storage ACL for contracts
- Storage (PoliDaoStorage)
  - Single source of truth: fundraisers, donations, totals, mappings
  - Exposes helpers and module registry
- Router (PoliDaoRouter)
  - The canonical entrypoint for FE clients; enforces security checks and calls Core
- Modules (governance, media, updates, security, web3, analytics)
  - Optional feature surfaces, registered in Storage; Core can call them dynamically

## Upgradeability and storage safety

- Pattern: UUPS (ERC1967 proxy). The proxy address is the stable address used by the frontend.
- Initialization: only via initialize() on the implementation during proxy deployment; never use constructors.
- Storage layout: never reorder or remove variables. Only append, and preserve the __gap to keep layout compatibility.
- Authorization: _authorizeUpgrade restricted to owner(). Consider multisig ownership for production.

## Deploy and verify

Preferred path uses the provided deployment script and verification helpers.

- Environment variables
  - SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY
- Deploy (UUPS Core)
  - USE_UUPS_CORE=1 (default in script) ensures Core is deployed behind ERC1967Proxy
- Verification is automated for fresh deployments; re-run with FORCE_REVERIFY=1 to force verify

The script writes addresses and constructor/init args to deployments/<network>.json for reproducible verify.

## Frontend ABI

- Build ABIs for frontend consumption:

```powershell
node scripts/build-abi.js
```

- Outputs in frontend-abi/:
  - PoliDaoCore.abi.json (from upgradeable core)
  - Router/Modules/Storage ABIs
  - CombinedABI.json (de-duplicated)

Always point the FE to the proxy address for Core and use the upgradeable ABI.

## Testing

- Run full test suite:

```powershell
npx hardhat test
```

- Suite includes unit, integration, security, performance scaffolding, and UUPS upgrade flow checks.
- Some suites use mocks when a component is intentionally not deployed in that scenario (messages are informational).

## Security notes

- Reentrancy protected where state changes occur; SafeERC20 for token transfers
- Router-enforced flows (onlyRouter) mediate user actions
- Refunds are blocked once withdrawals start for a fundraiser
- Owner-only admin setters affect router/extensions/modules/fees; consider staging via multisig

## Versioning

- Core exposes version() for FE cache invalidation and diagnostics (e.g., "1.0.0-upgradeable").
- Update this on implementation changes that affect behavior or ABI.

## Repository hygiene

- Example contracts/tests removed
- Legacy non-upgradeable Core removed. The codebase is UUPS-only for clarity and safety.

## License

SPDX-License-Identifier: MIT
