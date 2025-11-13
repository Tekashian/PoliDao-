// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "./../interfaces/IPoliDaoStructs.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../libraries/FundraiserLogic.sol";
import "../libraries/WithdrawLogic.sol";
import "../libraries/RefundLogic.sol";
import "../storage/PoliDaoStorage.sol";

/**
 * @title PoliDaoCoreUpgradeable
 * @notice The production Core for PoliDAO, deployed behind an ERC1967 proxy (UUPS pattern).
 * @dev
 *  Design overview
 *  - This Core is a thin orchestrator that coordinates between Storage (authoritative state),
 *    stateless libraries (Fundraiser/Withdraw/Refund), the Router (user entry), and feature Modules.
 *  - Upgradeability: UUPS via OpenZeppelin. The proxy delegates to an implementation that can be
 *    upgraded by the owner. The initialize() function replaces constructors.
 *  - Storage layout: DO NOT re-order or delete existing state variables. Only append new ones and
 *    adjust the __gap accordingly to preserve storage compatibility across upgrades.
 *  - Authorization model:
 *      owner()         — upgrade and admin setters
 *      onlyRouter      — enforced entry for certain flows (createFor/donateFrom/withdrawFor/...)
 *      Storage ACL     — storageContract.isContractAuthorized(address)
 *  - Security:
 *      ReentrancyGuard is used for mutating flows; SafeERC20 protects ERC20 transfers;
 *      onlyRouter prevents unmediated actions; refunds are blocked once withdrawals started.
 *  - Fees:
 *      Donation fee (BPS) is applied on inbound donations. Withdraw fees (success/flexible) are
 *      applied in WithdrawLogic and accounted in Storage.
 *
 *  Frontend integration
 *  - The stable address your FE talks to is the PROXY. Always use the upgradeable ABI.
 *  - version() is exposed for easy cache busting on ABI/impl updates.
 *  - Typical FE flow goes through the Router; direct Core calls remain available when appropriate.
 *
 *  Upgrade notes and hazards
 *  - Never introduce constructors; initialization logic must live in initialize().
 *  - Keep modifiers and auth semantics stable; changing onlyRouter/onlyAuthorized can break Router/Modules.
 *  - Consider emitting explicit upgrade events in owner-controlled flows if future analytics need them.
 *
 * @custom:version 1.0.0-upgradeable
 */
contract PoliDaoCoreUpgradeable is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using Address for address;
    using SafeERC20 for IERC20;

    // ========== ERRORS ==========
    error InvalidAmount();
    error InvalidInput();
    error NotImplemented();
    error DonationsClosed();
    error RefundNotAllowed();

    // ========== FEES / COMMISSIONS ==========
    address public feeRecipient;
    uint16  public donationFeeBps;            // 0..10000 (default 0)
    uint16  public successWithdrawFeeBps;     // fee on successful withdraw
    uint16  public flexibleWithdrawFeeBps;    // fee on flexible/failed withdraw

    // ========== WITHDRAW FLAGS ==========
    mapping(uint256 => bool) public withdrawalsStarted;

    // ========== DEPENDENCIES ==========
    IPoliDaoStorage public storageContract;
    address public extensionsContract;
    address public routerContract;

    // ========== MODULE ADDRESSES ==========
    address public governanceModule;
    address public mediaModule;
    address public updatesModule;
    address public securityModule;
    address public web3Module;
    address public analyticsModule;

    // ========== MODULE UPGRADE LOCK ==========
    bool private _moduleUpgradesLocked;

    // ========== EVENTS ==========
    event FundraiserCreated(
        uint256 indexed fundraiserId,
        address indexed creator,
        address indexed token,
        string title,
        uint8 fundraiserType,
        uint256 goalAmount,
        uint256 endDate,
        string location
    );
    event DonationMade(
        uint256 indexed fundraiserId,
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 newRaised
    );
    event FundsWithdrawn(uint256 indexed fundraiserId, address indexed creator, address indexed token, uint256 amount);
    event RefundPeriodEntered(uint256 indexed fundraiserId, address indexed caller);
    event RefundClaimed(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 netAmount, uint256 commission);
    event FundraiserSuspended(uint256 indexed fundraiserId, address indexed by, string reason, uint256 timestamp);
    event ModuleUpgraded(string label, address oldAddr, address newAddr);
    event ModuleDisabled(string label, address oldAddr);
    event RouterContractUpdated(address indexed oldRouter, address indexed newRouter);
    event ExtensionsContractUpdated(address indexed oldExtensions, address indexed newExtensions);
    event ModuleUpgradesLocked(address indexed locker);

    // ========== INITIALIZER ==========
    /**
     * @notice Initializes the Core implementation behind the proxy.
     * @param _storageContract Deployed Storage contract address that holds campaign state.
     * @param initialOwner Address that will own upgrade authority and admin setters.
     * @dev Must be called exactly once through the proxy. Subsequent calls revert by OZ initializer.
     */
    function initialize(address _storageContract, address initialOwner) public initializer {
        require(_storageContract != address(0), "PoliDaoCore: Invalid storage contract");
        require(initialOwner != address(0), "PoliDaoCore: Invalid owner");

        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        storageContract = IPoliDaoStorage(_storageContract);
        // routerContract will be set via setRouterContract later
    }

    // ========== UUPS AUTH ==========
    /**
     * @dev UUPS authorization hook — only the owner can upgrade the implementation.
     */
    function _authorizeUpgrade(address /*newImplementation*/ ) internal override onlyOwner {}

    // Public version for FE cache invalidation
    /**
     * @notice Human-readable implementation version for tooling and cache invalidation.
     */
    function version() external pure returns (string memory) {
        return "1.0.0-upgradeable";
    }

    // ========== MODIFIERS ==========
    modifier onlyRouter() {
        require(msg.sender == routerContract, "PoliDaoCore: only router");
        _;
    }
    modifier onlyAuthorized() {
        require(
            msg.sender == extensionsContract ||
            msg.sender == routerContract ||
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoCore: Not authorized"
        );
        _;
    }
    modifier onlyAuthorizedOrOwner() {
        require(
            msg.sender == owner() ||
            msg.sender == extensionsContract ||
            msg.sender == routerContract ||
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoCore: Not authorized"
        );
        _;
    }

    // ========== ADMIN / CONFIG ==========
    /**
     * @notice Sets the optional Extensions contract used by some router flows.
     * @param _extensionsContract Address of the extensions contract (must be a contract).
     */
    function setExtensionsContract(address _extensionsContract) external onlyOwner {
        require(_extensionsContract != address(0), "PoliDaoCore: Invalid extensions contract");
        require(_hasCode(_extensionsContract), "PoliDaoCore: Extensions must be a contract");
        address old = extensionsContract;
        extensionsContract = _extensionsContract;
        emit ExtensionsContractUpdated(old, _extensionsContract);
    }

    /**
     * @notice Sets the Router contract allowed to call router-only methods.
     * @param _router Router address.
     */
    function setRouterContract(address _router) external onlyOwner {
        require(_router != address(0), "PoliDaoCore: invalid router");
        address old = routerContract;
        routerContract = _router;
        emit RouterContractUpdated(old, _router);
    }

    // ========== CORE BUSINESS LOGIC ==========
    /**
     * @notice Creates a fundraiser for msg.sender.
     * @param data Structured fundraiser parameters.
     * @return fundraiserId Newly created fundraiser ID.
     */
    function createFundraiser(IPoliDaoStructs.FundraiserCreationData memory data)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 fundraiserId)
    {
        require(bytes(data.title).length > 0, "PoliDaoCore: Title required");
        require(data.endDate > block.timestamp, "PoliDaoCore: Invalid end date");
        require(storageContract.isTokenWhitelisted(data.token), "PoliDaoCore: Token not whitelisted");
        if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "PoliDaoCore: Goal amount required");
        }
        fundraiserId = FundraiserLogic.createFundraiserLogic(
            PoliDaoStorage(address(storageContract)), data, msg.sender
        );
        emit FundraiserCreated(
            fundraiserId, msg.sender, data.token, data.title,
            uint8(data.fundraiserType), data.goalAmount, data.endDate, data.location
        );
        return fundraiserId;
    }

    /**
     * @notice Router-only variant to create a fundraiser on behalf of a creator.
     * @param creator Beneficiary/creator address.
     * @param data Structured fundraiser parameters.
     * @return fundraiserId Newly created fundraiser ID.
     */
    function createFundraiserFor(
        address creator,
        IPoliDaoStructs.FundraiserCreationData memory data
    )
        external
        whenNotPaused
        nonReentrant
        onlyRouter
        returns (uint256 fundraiserId)
    {
        require(creator != address(0), "PoliDaoCore: Creator required");
        require(bytes(data.title).length > 0, "PoliDaoCore: Title required");
        require(data.endDate > block.timestamp, "PoliDaoCore: Invalid end date");
        require(storageContract.isTokenWhitelisted(data.token), "PoliDaoCore: Token not whitelisted");
        if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "PoliDaoCore: Goal amount required");
        }
        fundraiserId = FundraiserLogic.createFundraiserLogic(
            PoliDaoStorage(address(storageContract)), data, creator
        );
        return fundraiserId;
    }

    /**
     * @notice Extends a fundraiser’s endDate by additional days.
     * @param fundraiserId Target fundraiser ID.
     * @param additionalDays Number of days to add.
     */
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays)
        external
        whenNotPaused
        nonReentrant
        onlyAuthorizedOrOwner
    {
        require(storageContract.fundraisers(fundraiserId).id != 0, "PoliDaoCore: Fundraiser not found");
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        f.endDate = f.endDate + uint64(additionalDays * 1 days);
        storageContract.updateFundraiser(fundraiserId, f);
    }

    /**
     * @notice Donates tokens to a fundraiser using msg.sender’s allowance.
     * @param fundraiserId Target fundraiser ID.
     * @param amount Amount to donate (token units).
     * @dev Applies donationFeeBps if configured; forwards net to Storage and records donation.
     */
    function donate(uint256 fundraiserId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "PoliDaoCore: amount=0");
        address token = storageContract.fundraiserTokens(fundraiserId);
        require(token != address(0), "PoliDaoCore: token");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 fee = 0;
        if (feeRecipient != address(0) && donationFeeBps > 0) {
            fee = (amount * donationFeeBps) / 10_000;
            if (fee > 0) {
                IERC20(token).safeTransfer(feeRecipient, fee);
            }
        }
        uint256 net = amount - fee;
        IERC20(token).safeTransfer(address(storageContract), net);
        storageContract.addDonation(fundraiserId, msg.sender, net);
        IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserId);
        emit DonationMade(fundraiserId, msg.sender, token, net, fr.raisedAmount);
    }

    /**
     * @notice Router-only donation using donor’s allowance (e.g., after permit).
     * @param fundraiserId Target fundraiser ID.
     * @param donor Donor address whose funds are transferred via SafeERC20.
     * @param amount Amount to donate.
     */
    function donateFrom(uint256 fundraiserId, address donor, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(amount > 0, "PoliDaoCore: amount=0");
        address token = storageContract.fundraiserTokens(fundraiserId);
        require(token != address(0), "PoliDaoCore: token");
        IERC20(token).safeTransferFrom(donor, address(this), amount);
        uint256 fee = 0;
        if (feeRecipient != address(0) && donationFeeBps > 0) {
            fee = (amount * donationFeeBps) / 10_000;
            if (fee > 0) IERC20(token).safeTransfer(feeRecipient, fee);
        }
        uint256 net = amount - fee;
        IERC20(token).safeTransfer(address(storageContract), net);
        storageContract.addDonation(fundraiserId, donor, net);
        IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserId);
        emit DonationMade(fundraiserId, donor, token, net, fr.raisedAmount);
    }

    /**
     * @notice Router-only batch donation helper.
     * @param donor Donor address.
     * @param fundraiserIds Parallel array of fundraiser IDs.
     * @param amounts Parallel array of donation amounts.
     */
    function batchDonateFrom(address donor, uint256[] calldata fundraiserIds, uint256[] calldata amounts)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(fundraiserIds.length == amounts.length && fundraiserIds.length > 0, "PoliDaoCore: arrays mismatch");
        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            address token = storageContract.fundraiserTokens(fundraiserIds[i]);
            require(token != address(0), "PoliDaoCore: token");
            IERC20(token).safeTransferFrom(donor, address(this), amt);
            uint256 fee = 0;
            if (feeRecipient != address(0) && donationFeeBps > 0) {
                fee = (amt * donationFeeBps) / 10_000;
                if (fee > 0) IERC20(token).safeTransfer(feeRecipient, fee);
            }
            uint256 net = amt - fee;
            IERC20(token).safeTransfer(address(storageContract), net);
            storageContract.addDonation(fundraiserIds[i], donor, net);
            IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserIds[i]);
            emit DonationMade(fundraiserIds[i], donor, token, net, fr.raisedAmount);
        }
    }

    // ========== EXTENSIONS / MODULES ==========
    /**
     * @notice Router-only opaque delegate to the Extensions contract.
     * @param data Encoded function selector and args for Extensions.
     * @return result Raw return data.
     */
    function delegateToExtensions(bytes calldata data) external onlyRouter returns (bytes memory result) {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        bytes memory returnData = extensionsContract.functionCall(data);
        return returnData;
    }

    /**
     * @notice Router-only opaque call into a mapped Module.
     * @param moduleKey keccak256 label of the Module (e.g., keccak256("GOVERNANCE")).
     * @param data Encoded function selector and args for the Module.
     * @return result Raw return data.
     */
    function callModule(bytes32 moduleKey, bytes calldata data) external onlyRouter returns (bytes memory result) {
        address module = storageContract.modules(moduleKey);
        require(module != address(0), "PoliDaoCore: Module not set");
        bytes memory returnData = module.functionCall(data);
        return returnData;
    }

    /**
     * @notice Read-only static call into a mapped Module.
     * @param moduleKey Module key.
     * @param data Encoded selector and args.
     * @return result Raw return data.
     */
    function staticCallModule(bytes32 moduleKey, bytes calldata data) external view returns (bytes memory result) {
        address module = storageContract.modules(moduleKey);
        require(module != address(0), "PoliDaoCore: Module not set");
    bytes memory returnData = Address.functionStaticCall(module, data);
        return returnData;
    }

    // ========== VIEWS ==========
    /**
     * @notice Backward compatible basic fundraiser info accessor.
     */
    function getFundraiserBasicInfo(uint256 fundraiserId)
        external
        view
        returns (
            address creator,
            address token,
            uint256 raised,
            uint256 goal,
            uint256 endDate,
            uint8 status
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory data = storageContract.fundraisers(fundraiserId);
        require(data.id != 0, "PoliDaoCore: Fundraiser not found");
        return (
            storageContract.fundraiserCreators(fundraiserId),
            storageContract.fundraiserTokens(fundraiserId),
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status
        );
    }

    /**
     * @notice Total number of created fundraisers.
     */
    function getFundraiserCount() external view returns (uint256) {
        return storageContract.fundraiserCounter();
    }

    /**
     * @notice Backward compatible detailed fundraiser metadata accessor.
     */
    function getFundraiserDetails(uint256 fundraiserId)
        external
        view
        returns (
            string memory title,
            string memory description,
            string memory location,
            uint256 endDate,
            uint8 fundraiserType,
            uint8 status,
            address token,
            uint256 goalAmount,
            uint256 raisedAmount,
            address creator,
            uint256 extensionCount,
            bool isSuspended,
            string memory suspensionReason
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        title = storageContract.fundraiserTitles(fundraiserId);
        description = storageContract.fundraiserDescriptions(fundraiserId);
        location = storageContract.fundraiserLocations(fundraiserId);
        endDate = f.endDate;
        fundraiserType = f.fundraiserType;
        status = f.status;
        token = storageContract.fundraiserTokens(fundraiserId);
        goalAmount = f.goalAmount;
        raisedAmount = f.raisedAmount;
        creator = storageContract.fundraiserCreators(fundraiserId);
        extensionCount = f.extensionCount;
        isSuspended = f.isSuspended;
        suspensionReason = "";
    }

    /**
     * @notice Suspends a fundraiser (authorized actors only), emitting an audit event.
     */
    function suspendFundraiser(uint256 fundraiserId, string calldata reason)
        external
        whenNotPaused
        nonReentrant
        onlyAuthorizedOrOwner
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        if (!f.isSuspended) {
            f.isSuspended = true;
            f.suspensionTime = uint32(block.timestamp);
            storageContract.updateFundraiser(fundraiserId, f);
        }
        emit FundraiserSuspended(fundraiserId, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Returns the donation amount recorded for a donor in a fundraiser.
     */
    function getDonationAmount(uint256 fundraiserId, address donor) external view returns (uint256) {
        return storageContract.donations(fundraiserId, donor);
    }

    /**
     * @notice Router-only: delegates an extension operation to Extensions.
     */
    function extendFundraiserFor(uint256 fundraiserId, address requester, uint256 additionalDays)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        extensionsContract.functionCall(
            abi.encodeWithSignature("extendFundraiser(uint256,address,uint256)", fundraiserId, requester, additionalDays)
        );
    }

    /**
     * @notice Router-only: delegates location update to Extensions.
     */
    function updateLocationFor(uint256 fundraiserId, address requester, string calldata newLocation)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        extensionsContract.functionCall(
            abi.encodeWithSignature("updateLocation(uint256,address,string)", fundraiserId, requester, newLocation)
        );
    }

    // ========== WITHDRAW / REFUND ==========
    /**
     * @notice Creator-initiated withdrawal. Applies fees and records in Storage.
     * @param fundraiserId Target fundraiser.
     */
    function withdrawFunds(uint256 fundraiserId) external whenNotPaused nonReentrant {
        (
            address creator,
            address token,
            uint256 paidNet,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        ) = WithdrawLogic.executeWithdraw(
                storageContract,
                fundraiserId,
                msg.sender,
                owner(),
                feeRecipient,
                successWithdrawFeeBps,
                flexibleWithdrawFeeBps
            );
        if ((isWithGoal && !goalReached && timeEnded) || (!isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }
        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
    }

    /**
     * @notice Router-only withdrawal on behalf of requester.
     */
    function withdrawFundsFor(uint256 fundraiserId, address requester)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        (
            address creator,
            address token,
            uint256 paidNet,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        ) = WithdrawLogic.executeWithdraw(
                storageContract,
                fundraiserId,
                requester,
                owner(),
                feeRecipient,
                successWithdrawFeeBps,
                flexibleWithdrawFeeBps
            );
        if ((isWithGoal && !goalReached && timeEnded) || (!isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }
        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
    }

    /**
     * @notice Deprecated no-op. Refunds are managed per-donor via refundFor().
     */
    function refund(uint256) external whenNotPaused nonReentrant onlyAuthorizedOrOwner {
        revert RefundNotAllowed();
    }

    /**
     * @notice Router-only donor refund. Blocks if withdrawals already started.
     */
    function refundFor(uint256 fundraiserId, address donor)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(!withdrawalsStarted[fundraiserId], "PoliDaoCore: withdrawals started");
        (uint256 netAmount, uint256 commission, address token) =
            RefundLogic.claimRefund(storageContract, fundraiserId, donor, withdrawalsStarted[fundraiserId]);
        emit RefundClaimed(fundraiserId, donor, token, netAmount, commission);
    }

    // ========== MODULE MGMT ==========
    /**
     * @notice One-time bulk set of core module addresses.
     */
    function setModules(
        address _governance,
        address _media,
        address _updates,
        address /*_refunds*/,
        address _security,
        address _web3,
        address _analytics
    ) external onlyOwner {
        require(governanceModule == address(0) && mediaModule == address(0), "Already initialized");
        require(
            _governance != address(0) &&
            _media != address(0) &&
            _updates != address(0) &&
            _security != address(0) &&
            _web3 != address(0) &&
            _analytics != address(0),
            "PoliDaoCore: zero module addr"
        );
        governanceModule = _governance;
        mediaModule = _media;
        updatesModule = _updates;
        securityModule = _security;
        web3Module = _web3;
        analyticsModule = _analytics;
    }

    /**
     * @notice Upgrades or disables a single Module by label. Also attempts to mirror Storage mapping and ACL.
     * @param label Human-readable label (e.g., "GOVERNANCE").
     * @param newAddr New implementation address or zero to disable.
     */
    function upgradeModule(string calldata label, address newAddr) external onlyOwner nonReentrant {
        require(!_moduleUpgradesLocked, "PoliDaoCore: module upgrades locked");
        if (bytes(label).length == 0) revert InvalidInput();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule(label);
        if (newAddr == address(0)) {
            emit ModuleDisabled(label, oldEffective);
        } else {
            emit ModuleUpgraded(label, oldEffective, newAddr);
        }
        bytes32 h = keccak256(bytes(label));
        if (h == keccak256("GOVERNANCE")) governanceModule = newAddr;
        else if (h == keccak256("MEDIA")) mediaModule = newAddr;
        else if (h == keccak256("UPDATES")) updatesModule = newAddr;
        else if (h == keccak256("SECURITY")) securityModule = newAddr;
        else if (h == keccak256("WEB3")) web3Module = newAddr;
        else if (h == keccak256("ANALYTICS")) analyticsModule = newAddr;
        // best-effort sync
        try storageContract.setModule(h, newAddr) {} catch {}
        if (newAddr != address(0) && !storageContract.isContractAuthorized(newAddr)) {
            try storageContract.authorizeContract(newAddr) {} catch {}
        }
    }

    /**
     * @notice Permanently locks further module upgrades.
     */
    function lockModuleUpgrades() external onlyOwner nonReentrant {
        require(!_moduleUpgradesLocked, "PoliDaoCore: already locked");
        _moduleUpgradesLocked = true;
        emit ModuleUpgradesLocked(msg.sender);
    }

    // ========== STATUS / CONFIG ==========
    /**
     * @notice Returns current wiring status for basic health checks.
     */
    function getContractStatus()
        external
        view
        returns (
            address storageAddress,
            address extensionsAddress,
            address routerAddress,
            bool isConfigured
        )
    {
        return (
            address(storageContract),
            extensionsContract,
            routerContract,
            extensionsContract != address(0) && routerContract != address(0)
        );
    }

    /**
     * @notice Validates that required components are configured and Core is authorized in Storage.
     */
    function validateConfiguration() external view returns (bool isValid, string memory missingComponent) {
        if (extensionsContract == address(0)) return (false, "Extensions contract not set");
        if (routerContract == address(0)) return (false, "Router contract not set");
        if (!storageContract.isContractAuthorized(address(this))) return (false, "Core not authorized in storage");
        return (true, "");
    }

    // ========== HELPERS / SETTERS ==========
    /**
     * @dev Resolves a module address prioritizing local overrides, falling back to Storage mapping.
     */
    function _resolveModule(string memory moduleKey) internal view returns (address) {
        bytes32 h = keccak256(bytes(moduleKey));
        if (h == keccak256("GOVERNANCE") && governanceModule != address(0)) return governanceModule;
        if (h == keccak256("MEDIA") && mediaModule != address(0)) return mediaModule;
        if (h == keccak256("UPDATES") && updatesModule != address(0)) return updatesModule;
        if (h == keccak256("SECURITY") && securityModule != address(0)) return securityModule;
        if (h == keccak256("WEB3") && web3Module != address(0)) return web3Module;
        if (h == keccak256("ANALYTICS") && analyticsModule != address(0)) return analyticsModule;
        return storageContract.modules(h);
    }

    /**
     * @dev Cheap contract code existence check.
     */
    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    /**
     * @notice Returns the address that must be approved for token transfers (this Core/proxy).
     */
    function spenderAddress() external view returns (address) { return address(this); }

    /**
     * @notice Sets fee recipient for donation and withdraw commissions.
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner { feeRecipient = _feeRecipient; }

    /**
     * @notice Sets donation fee in BPS (0..10000).
     */
    function setDonationFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= 10_000, "bps>100%");
        donationFeeBps = _bps;
    }

    /**
     * @notice Sets withdraw fees (success and flexible) in BPS (each 0..10000).
     */
    function setWithdrawFeesBps(uint16 _successBps, uint16 _flexibleBps) external onlyOwner {
        require(_successBps <= 10_000 && _flexibleBps <= 10_000, "bps>100%");
        successWithdrawFeeBps = _successBps;
        flexibleWithdrawFeeBps = _flexibleBps;
    }

    // ========== STORAGE GAPS ==========
    // Storage gap to allow adding variables in future upgrades without shifting the storage layout.
    uint256[45] private __gap; // adjust down when you append new variables above
}
