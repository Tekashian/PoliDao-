// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPoliDaoStructs.sol";

contract PoliDaoStorage is Ownable {
    using SafeERC20 for IERC20;

    // OZ v5 Ownable requires initialOwner in constructor
    constructor() Ownable(msg.sender) {}

    // ===================== Constants (libraries expect public getters) =====================
    // Extension/creation constraints
    uint256 public constant MAX_EXTENSION_DAYS = 365;
    uint256 public constant MAX_EXTENSIONS = 3;
    uint256 public constant MIN_EXTENSION_NOTICE = 1 days;
    uint256 public constant SECONDS_PER_DAY = 1 days;
    uint256 public constant MAX_FUTURE_DATE = 365 days;

    // Text limits
    uint256 public constant MAX_LOCATION_LENGTH = 256;
    uint256 public constant MAX_TITLE_LENGTH = 128;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1024;

    // Fees/commission caps (basis points and absolute fee caps)
    uint256 public constant MAX_COMMISSION_RATE = 10_000; // 100% in bps
    uint256 public constant MAX_EXTENSION_FEE = type(uint256).max;

    // ===================== Router and access =====================
    address private _authorizedRouter;
    mapping(address => bool) private _authorizedContracts;

    event ContractAuthorized(address indexed contractAddress);
    event ContractDeauthorized(address indexed contractAddress);
    event AuthorizedRouterUpdated(address indexed previous, address indexed current, address indexed caller);

    // Commission / fees events
    event RefundCommissionUpdated(uint256 previous, uint256 current, address indexed caller);
    event CommissionRatesUpdated(
        uint256 prevDonation,
        uint256 prevSuccess,
        uint256 prevRefund,
        uint256 newDonation,
        uint256 newSuccess,
        uint256 newRefund,
        address indexed caller
    );
    event ExtensionFeeUpdated(uint256 previous, uint256 current, address indexed caller);

    // NEW optional events
    event CommissionWalletUpdated(address indexed previous, address indexed current, address indexed caller);
    event FeeTokenUpdated(address indexed previous, address indexed current, address indexed caller);
    // (UWAGA: usunięto wcześniejszą zduplikowaną deklarację FundsReleased)

    function setAuthorizedRouter(address router) external onlyOwner {
        // Slither: add zero address validation + event
        require(router != address(0), "Zero router");
        address prev = _authorizedRouter;
        require(prev != router, "No change");
        _authorizedRouter = router;
        emit AuthorizedRouterUpdated(prev, router, msg.sender);
    }

    function authorizedRouter() external view returns (address) {
        return _authorizedRouter;
    }

    function authorizeContract(address contractAddress) external onlyOwner {
        _authorizedContracts[contractAddress] = true;
        emit ContractAuthorized(contractAddress);
    }

    function deauthorizeContract(address contractAddress) external onlyOwner {
        _authorizedContracts[contractAddress] = false;
        emit ContractDeauthorized(contractAddress);
    }

    function isContractAuthorized(address contractAddress) public view returns (bool) {
        return _authorizedContracts[contractAddress];
    }

    // ===================== Whitelist (MOVED UP BEFORE FUNDRAISERS) =====================
    address[] internal _whitelistedTokens;
    mapping(address => bool) internal _isWhitelisted;

    function addWhitelistedToken(address token) external onlyOwner {
        if (!_isWhitelisted[token]) {
            _isWhitelisted[token] = true;
            _whitelistedTokens.push(token);
        }
    }

    function removeWhitelistedToken(address token) external onlyOwner {
        if (_isWhitelisted[token]) {
            _isWhitelisted[token] = false;
            // keep array for history; tests don't require pruning
        }
    }

    function isTokenWhitelisted(address token) public view returns (bool) {
        return _isWhitelisted[token];
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return _whitelistedTokens;
    }

    // ===================== Fundraisers =====================
    uint256 public fundraiserCounter;

    // Packed struct storage
    mapping(uint256 => IPoliDaoStructs.PackedFundraiserData) private _fundraisers;

    // Additional fields accessed by libs
    mapping(uint256 => address) public fundraiserCreators;
    mapping(uint256 => address) public fundraiserTokens;
    mapping(uint256 => string) public fundraiserTitles;
    mapping(uint256 => string) public fundraiserDescriptions;
    mapping(uint256 => string) public fundraiserLocations;

    // Donor tracking
    mapping(uint256 => mapping(address => uint256)) public donations;
    mapping(uint256 => address[]) private _fundraiserDonors;
    mapping(uint256 => mapping(address => bool)) private _isDonorInList;

    // Events
    event FundraiserCreatedInStorage(uint256 indexed fundraiserId, address indexed creator);
    event DonationAddedToStorage(uint256 indexed fundraiserId, address indexed donor, uint256 amount);
    event FundsReleased(address indexed token, address indexed to, uint256 amount, address indexed caller);

    // Getter returning the packed struct as expected by libraries
    function fundraisers(uint256 fundraiserId) external view returns (IPoliDaoStructs.PackedFundraiserData memory) {
        return _fundraisers[fundraiserId];
    }

    // Internal creation helper to unify all overloads
    function _createFundraiserInternal(
        IPoliDaoStructs.PackedFundraiserData memory data,
        string memory title,
        string memory description,
        string memory location,
        address creator,
        address token
    ) internal returns (uint256 fundraiserId) {
        // Start IDs from 1 (id==0 means not exists in libs)
        fundraiserId = ++fundraiserCounter;
        data.id = uint32(fundraiserId);
        _fundraisers[fundraiserId] = data;
        fundraiserCreators[fundraiserId] = creator;
        fundraiserTokens[fundraiserId] = token;
        fundraiserTitles[fundraiserId] = title;
        fundraiserDescriptions[fundraiserId] = description;
        fundraiserLocations[fundraiserId] = location;
        emit FundraiserCreatedInStorage(fundraiserId, creator);
    }

    // Pełny wariant (używany przez FundraiserLogic)
    function createFundraiser(
        IPoliDaoStructs.PackedFundraiserData memory data,
        string memory title,
        string memory description,
        string memory location,
        address creator,
        address token
    ) external returns (uint256 fundraiserId) {
        require(creator != address(0), "Invalid creator");
        require(token != address(0), "Invalid token");
        require(isTokenWhitelisted(token), "Token not whitelisted");
        fundraiserId = _createFundraiserInternal(
            data, title, description, location, creator, token
        );
    }

    // Starter: prosty wariant używany w testach/demach
    function createFundraiser(address token) external returns (uint256 fundraiserId) {
        require(token != address(0), "Invalid token");
        require(isTokenWhitelisted(token), "Token not whitelisted");
        IPoliDaoStructs.PackedFundraiserData memory data = IPoliDaoStructs.PackedFundraiserData({
            goalAmount: 0,
            raisedAmount: 0,
            endDate: uint64(block.timestamp + 30 days),
            originalEndDate: uint64(block.timestamp + 30 days),
            id: 0,
            suspensionTime: 0,
            extensionCount: 0,
            fundraiserType: uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL),
            status: uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            isFlexible: false
        });
        fundraiserId = _createFundraiserInternal(
            data, "Starter Campaign", "Created via starter", "N/A", msg.sender, token
        );
    }

    // Update packed struct (used by ExtensionLogic and others)
    function updateFundraiser(uint256 fundraiserId, IPoliDaoStructs.PackedFundraiserData memory data) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        require(fundraiserId != 0, "Invalid id");
        data.id = uint32(fundraiserId); // keep id consistent
        _fundraisers[fundraiserId] = data;
    }

    // Update status (used by modules)
    function updateFundraiserStatus(uint256 fundraiserId, uint8 newStatus) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        _fundraisers[fundraiserId].status = newStatus;
    }

    // Update raised amount (used by donation/withdraw/refund flows)
    function updateRaisedAmount(uint256 fundraiserId, uint256 newAmount) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        require(newAmount <= type(uint128).max, "Overflow");
        _fundraisers[fundraiserId].raisedAmount = uint128(newAmount);
    }

    // Location/title/description updates (wrappers expected by LocationLogic)
    function updateFundraiserLocation(uint256 fundraiserId, string memory newLocation) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        fundraiserLocations[fundraiserId] = newLocation;
    }

    // Optional helpers (not strictly required by libs, but useful)
    function setFundraiserTitle(uint256 fundraiserId, string memory newTitle) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        fundraiserTitles[fundraiserId] = newTitle;
    }

    function setFundraiserDescription(uint256 fundraiserId, string memory newDescription) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        fundraiserDescriptions[fundraiserId] = newDescription;
    }

    // === ADDED: authorization modifier (uses existing vars) ===
    modifier onlyAuthorized() {
        // _authorizedContracts and _authorizedRouter already exist in this contract
        require(
            _authorizedContracts[msg.sender] || msg.sender == owner() || msg.sender == _authorizedRouter,
            "PoliDaoStorage: Not authorized"
        );
        _;
    }

    // Helper: public-auth check for libraries/modules without exposing internal mappings
    function isAuthorized(address a) external view returns (bool) {
        return _authorizedContracts[a] || a == owner() || a == _authorizedRouter;
    }

    /**
     * @notice Records a donation (no token transfer; tokens should be moved before)
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param amount The donated amount
     */
    function addDonation(
        uint256 fundraiserId,
        address donor,
        uint256 amount
    ) external {
        require(amount > 0, "Amount must be greater than zero");
        require(fundraiserId <= fundraiserCounter, "Invalid fundraiser ID");
        require(fundraiserId > 0, "Fundraiser does not exist");
        
        // Get fundraiser data
        IPoliDaoStructs.PackedFundraiserData storage fundraiser = _fundraisers[fundraiserId];
        require(fundraiser.status == uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE), "Fundraiser not active");
        require(block.timestamp < fundraiser.endDate, "Fundraiser ended");
        
        // Get the fundraiser's token
        address tokenAddress = fundraiserTokens[fundraiserId];
        require(tokenAddress != address(0), "No token set for fundraiser");
        require(isTokenWhitelisted(tokenAddress), "Token not whitelisted");
        
        // Record amount per donor
        donations[fundraiserId][donor] += amount;

        // Update fundraiser totals (use internal storage mapping)
        // If struct/type differs, adjust to your exact struct name imported from IPoiDaoStructs
        IPoliDaoStructs.PackedFundraiserData storage f = _fundraisers[fundraiserId];
        // ensure fundraiser exists if not already validated above
        // require(f.id != 0, "PoliDaoStorage: Fundraiser not found");
        unchecked {
            f.raisedAmount = uint128(uint256(f.raisedAmount) + amount);
        }

        // Note: no token transfer and no non-existent events here
    }
    
    // Donor-related
    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        require(donor != address(0), "Invalid donor");
        donations[fundraiserId][donor] = newAmount;
        if (newAmount > 0 && !_isDonorInList[fundraiserId][donor]) {
            _isDonorInList[fundraiserId][donor] = true;
            _fundraiserDonors[fundraiserId].push(donor);
        }
    }

    function getFundraiserDonors(uint256 fundraiserId) external view returns (address[] memory donors) {
        return _fundraiserDonors[fundraiserId];
    }

    // ===================== Fees and commissions =====================
    // Public vars create getters matching interface names
    uint256 public donationCommission;   // bps
    uint256 public successCommission;    // bps
    uint256 public refundCommission;     // bps
    uint256 public extensionFee;         // absolute amount
    address public feeToken;             // ERC20 for fees
    address public commissionWallet;     // receiver

    // Overload: some tests call setCommissions(uint256) to set refund only
    function setCommissions(uint256 _refundCommission) external onlyOwner {
        uint256 prev = refundCommission;
        require(_refundCommission <= MAX_COMMISSION_RATE, "Too high");
        require(prev != _refundCommission, "No change");
        refundCommission = _refundCommission;
        emit RefundCommissionUpdated(prev, _refundCommission, msg.sender);
    }

    function setCommissions(
        uint256 _donationCommission,
        uint256 _successCommission,
        uint256 _refundCommission
    ) external onlyOwner {
        uint256 prevDonation = donationCommission;
        uint256 prevSuccess = successCommission;
        uint256 prevRefund = refundCommission;
        require(_donationCommission <= MAX_COMMISSION_RATE, "Donation too high");
        require(_successCommission <= MAX_COMMISSION_RATE, "Success too high");
        require(_refundCommission <= MAX_COMMISSION_RATE, "Refund too high");
        bool changed = _donationCommission != prevDonation
            || _successCommission != prevSuccess
            || _refundCommission != prevRefund;
        require(changed, "No change");
        donationCommission = _donationCommission;
        successCommission = _successCommission;
        refundCommission = _refundCommission;
        emit CommissionRatesUpdated(
            prevDonation,
            prevSuccess,
            prevRefund,
            _donationCommission,
            _successCommission,
            _refundCommission,
            msg.sender
        );
    }

    function setExtensionFee(uint256 _extensionFee) external onlyOwner {
        uint256 prev = extensionFee;
        require(_extensionFee <= MAX_EXTENSION_FEE, "Too high");
        require(prev != _extensionFee, "No change");
        extensionFee = _extensionFee;
        emit ExtensionFeeUpdated(prev, _extensionFee, msg.sender);
    }

    function setCommissionWallet(address _commissionWallet) external onlyOwner {
        require(_commissionWallet != address(0), "zero wallet");
        address prev = commissionWallet;
        require(prev != _commissionWallet, "No change");
        commissionWallet = _commissionWallet;
        emit CommissionWalletUpdated(prev, _commissionWallet, msg.sender);
    }

    function setFeeToken(address _feeToken) external onlyOwner {
        require(_feeToken != address(0), "zero token");
        address prev = feeToken;
        require(prev != _feeToken, "No change");
        feeToken = _feeToken;
        emit FeeTokenUpdated(prev, _feeToken, msg.sender);
    }

    function getFeeInfo()
        external
        view
        returns (
            uint256 donationCommissionRate,
            uint256 successCommissionRate,
            uint256 refundCommissionRate,
            uint256 extensionFeeAmount,
            address feeTokenAddress,
            address commissionWalletAddress
        )
    {
        return (
            donationCommission,
            successCommission,
            refundCommission,
            extensionFee,
            feeToken,
            commissionWallet
        );
    }

    // ===================== MODULE REGISTRY
    mapping(bytes32 => address) public modules;

    event ModuleMappingUpdated(bytes32 indexed key, address indexed oldModule, address indexed newModule);

    /**
     * @notice Set or clear a module implementation.
     * Owner: może ustawić dowolny nie‑zerowy lub wyczyścić.
     * Autoryzowany kontrakt: może tylko czyścić (moduleAddr == 0).
     */
    function setModule(bytes32 key, address moduleAddr) external {
        if (msg.sender != owner()) {
            require(moduleAddr == address(0) && _authorizedContracts[msg.sender], "PoliDaoStorage: not owner");
        }
        address old = modules[key];
        if (old == moduleAddr) return;
        modules[key] = moduleAddr;
        emit ModuleMappingUpdated(key, old, moduleAddr);
    }

    // Convenience bulk setter to satisfy interface
    function setModules(
        address governance,
        address media,
        address updates,
        address refunds,
        address security,
        address web3,
        address analytics
    ) external onlyOwner {
        modules[keccak256("GOVERNANCE")] = governance;
        modules[keccak256("MEDIA")] = media;
        modules[keccak256("UPDATES")] = updates;
        modules[keccak256("REFUNDS")] = refunds;
        modules[keccak256("SECURITY")] = security;
        modules[keccak256("WEB3")] = web3;
        modules[keccak256("ANALYTICS")] = analytics;
    }

    // ===================== Funds release =====================
    function releaseFunds(address token, address to, uint256 amount) external {
        require(msg.sender == owner() || isContractAuthorized(msg.sender), "Not authorized");
        require(to != address(0) && amount > 0, "Invalid");
        IERC20(token).safeTransfer(to, amount);
        emit FundsReleased(token, to, amount, msg.sender);
    }
}
