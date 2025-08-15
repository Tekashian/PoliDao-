// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Minimal abstract storage contract placeholder.
 * This file provides the `PoliDaoStorage` symbol used across the codebase
 * by declaring an abstract contract that implements the storage interface.
 * The actual concrete storage implementation can replace this later.
 */
contract PoliDaoStorage is IPoliDaoStorage {
	// Minimal in-memory storage to satisfy compilation. NOT for production.
	mapping(uint256 => PackedFundraiserData) internal _fundraisers;
	mapping(uint256 => mapping(address => uint256)) internal _donations;
	mapping(bytes32 => address) internal _modules;
	mapping(address => bool) internal _authorizedContracts;
	address[] internal _whitelistedTokens;
	uint256 internal _counter;
	address internal _commissionWallet;
	address internal _feeToken;
	address internal _authorizedRouter;

	// Events
	function createFundraiser(
		PackedFundraiserData memory data,
		string memory /*title*/,
		string memory /*description*/,
		string memory /*location*/,
		address /*creator*/,
		address token
	) external returns (uint256 fundraiserId) {
		_counter++;
		data.id = uint32(_counter);
		_fundraisers[_counter] = data;
		_whitelistedTokens.push(token);
		return _counter;
	}

	using SafeERC20 for IERC20;

	// simple owner implementation to satisfy the interface without conflicting with OpenZeppelin Ownable
	address private _owner;

	modifier onlyOwner() {
		require(msg.sender == _owner, "Only owner");
		_;
	}

	constructor(address _commissionWalletArg, address _feeTokenArg, address _initialTokenArg) {
		_owner = msg.sender;
		_commissionWallet = _commissionWalletArg;
		_feeToken = _feeTokenArg;
		if (_initialTokenArg != address(0)) {
			_whitelistedTokens.push(_initialTokenArg);
		}
		// authorize deployer by default (owner)
		_authorizedContracts[msg.sender] = true;
	}

	function addDonation(uint256 fundraiserId, address donor, uint256 amount) external {
		_donations[fundraiserId][donor] += amount;
	}

	function updateFundraiser(uint256, PackedFundraiserData memory) external {}
	function updateFundraiserLocation(uint256, string memory) external {}
	function updateDonationAmount(uint256, address, uint256) external {}
	function updateRaisedAmount(uint256, uint256) external {}
	function updateFundraiserStatus(uint256, uint8) external {}

	function addWhitelistedToken(address token) external onlyOwner { _whitelistedTokens.push(token); }
	function removeWhitelistedToken(address) external onlyOwner {}

	function setCommissions(uint256, uint256, uint256) external onlyOwner {}
	function setExtensionFee(uint256) external onlyOwner {}
	function setCommissionWallet(address) external onlyOwner {}
	function setFeeToken(address) external onlyOwner {}

	function setModule(bytes32 moduleKey, address moduleAddress) external onlyOwner { _modules[moduleKey] = moduleAddress; }
	function setModules(address governance, address media, address updates, address refunds, address security, address web3, address analytics) external onlyOwner {
		_modules[keccak256(bytes("ANALYTICS"))] = analytics;
		_modules[keccak256(bytes("GOVERNANCE"))] = governance;
		_modules[keccak256(bytes("MEDIA"))] = media;
		_modules[keccak256(bytes("REFUNDS"))] = refunds;
		_modules[keccak256(bytes("SECURITY"))] = security;
		_modules[keccak256(bytes("UPDATES"))] = updates;
		_modules[keccak256(bytes("WEB3"))] = web3;
	}

	function setAuthorizedRouter(address _router) external onlyOwner { _authorizedRouter = _router; }

	function authorizeContract(address contractAddr) external onlyOwner { _authorizedContracts[contractAddr] = true; emit ContractAuthorized(contractAddr); }

	function deauthorizeContract(address contractAddr) external onlyOwner { _authorizedContracts[contractAddr] = false; emit ContractDeauthorized(contractAddr); }

	function getFundraiserDonors(uint256 /*fundraiserId*/) external pure returns (address[] memory donors) { return new address[](0); }
	function getWhitelistedTokens() external view returns (address[] memory) { return _whitelistedTokens; }
	function getFeeInfo() external view returns (uint256, uint256, uint256, uint256, address, address) { return (0,0,0,0,_feeToken,_commissionWallet); }
	function isContractAuthorized(address contractAddr) external view returns (bool) { return _authorizedContracts[contractAddr]; }

	/**
	 * @notice Release funds from storage to a recipient; only authorized contracts/modules may call
	 */
	function releaseFunds(address token, address to, uint256 amount) external {
		require(_authorizedContracts[msg.sender] || _modules[keccak256(bytes("REFUNDS"))] == msg.sender, "Not authorized to release funds");
		require(to != address(0), "Invalid recipient");
		require(amount > 0, "Amount must be > 0");
		// Check balance
		uint256 bal = IERC20(token).balanceOf(address(this));
		require(bal >= amount, "Insufficient balance in storage");
		// Use SafeERC20 via the IERC20 wrapper
		IERC20(token).safeTransfer(to, amount);
		emit FundsReleased(token, to, amount, msg.sender);
	}

	function fundraiserCounter() external view returns (uint256) { return _counter; }
	function fundraisers(uint256 fundraiserId) external view returns (PackedFundraiserData memory) { return _fundraisers[fundraiserId]; }
	function fundraiserTitles(uint256) external pure returns (string memory) { return ""; }
	function fundraiserDescriptions(uint256) external pure returns (string memory) { return ""; }
	function fundraiserLocations(uint256) external pure returns (string memory) { return ""; }
	function fundraiserCreators(uint256) external pure returns (address) { return address(0); }
	function fundraiserTokens(uint256) external pure returns (address) { return address(0); }
	function donations(uint256 fundraiserId, address donor) external view returns (uint256) { return _donations[fundraiserId][donor]; }
	function isTokenWhitelisted(address /*token*/) external pure returns (bool) { return true; }
	function modules(bytes32 moduleKey) external view returns (address) { return _modules[moduleKey]; }
	function authorizedRouter() external view returns (address) { return _authorizedRouter; }
	function donationCommission() external pure returns (uint256) { return 0; }
	function successCommission() external pure returns (uint256) { return 0; }
	function refundCommission() external pure returns (uint256) { return 0; }
	function extensionFee() external pure returns (uint256) { return 0; }
	function feeToken() external view returns (address) { return _feeToken; }
	function commissionWallet() external view returns (address) { return _commissionWallet; }
	function MAX_EXTENSION_FEE() external pure returns (uint256) { return 0; }
	function MAX_COMMISSION_RATE() external pure returns (uint256) { return 0; }
	function MAX_LOCATION_LENGTH() external pure returns (uint256) { return 200; }
	function MAX_TITLE_LENGTH() external pure returns (uint256) { return 200; }
	function MAX_DESCRIPTION_LENGTH() external pure returns (uint256) { return 1000; }
	function MAX_FUTURE_DATE() external view returns (uint256) { return block.timestamp + 365 days; }
	function MAX_EXTENSIONS() external pure returns (uint256) { return 90; }
	function MIN_EXTENSION_NOTICE() external pure returns (uint256) { return 7 days; }
	function MAX_EXTENSION_DAYS() external pure returns (uint256) { return 90; }

	// Ownership helpers to satisfy IPoliDaoStorage
	function transferOwnership(address newOwner) external onlyOwner {
		require(newOwner != address(0), "Invalid new owner");
		emit OwnershipTransferred(_owner, newOwner);
		_owner = newOwner;
	}

	function owner() external view returns (address) { return _owner; }
}
