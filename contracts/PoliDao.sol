// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PoliDAO
 * @notice Smart kontrakt wspierający mechanizmy głosowania oraz zbiórek w tokenach ERC20.
 * @dev Obsługuje głosowania z ograniczonym czasem, zbiórki z opcją zwrotu, prowizje oraz whitelistę tokenów.
 */
contract PoliDAO is Ownable {
    // ========== STRUKTURY ==========

    /// @notice Struktura pojedynczej propozycji do głosowania
    struct Proposal {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        bool exists;
        mapping(address => bool) hasVoted;
    }

    /// @notice Struktura pojedynczej zbiórki
    struct Fundraiser {
        uint256 id;
        address creator;
        address token;
        uint256 target;
        uint256 raised;
        uint256 endTime;
        bool withdrawn;
        bool exists;
        bool isFlexible;
        uint256 reclaimDeadline;
        bool closureInitiated;
        mapping(address => uint256) donations;
        mapping(address => bool) refunded;
    }

    // ========== ZMIENNE STANU ==========

    uint256 public proposalCount;
    uint256 public fundraiserCount;

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Fundraiser) private fundraisers;

    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;

    uint256 public donationCommission;
    uint256 public successCommission;
    address public commissionWallet;

    uint256 public constant RECLAIM_PERIOD = 14 days;

    // ========== WYDARZENIA ==========

    event ProposalCreated(uint256 id, string question, uint256 endTime);
    event Voted(address voter, uint256 proposalId, bool support);

    event FundraiserCreated(uint256 id, address creator, address token, uint256 target, uint256 endTime, bool isFlexible);
    event DonationMade(uint256 id, address donor, uint256 amount);
    event DonationRefunded(uint256 id, address donor, uint256 amount);
    event FundsWithdrawn(uint256 id, address creator, uint256 amountAfterCommission);
    event TokenWhitelisted(address token);
    event ClosureInitiated(uint256 id, uint256 reclaimDeadline);

    // ========== KONSTRUKTOR ==========

    /**
     * @notice Inicjalizacja kontraktu z właścicielem i portfelem prowizji
     * @param initialOwner Adres właściciela kontraktu
     * @param _commissionWallet Adres do którego trafiają prowizje
     */
    constructor(address initialOwner, address _commissionWallet) Ownable(initialOwner) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
        donationCommission = 0;
        successCommission = 0;
    }

    // ========== GŁOSOWANIA ==========

    /**
     * @notice Tworzy nową propozycję do głosowania
     * @param _question Treść pytania
     * @param _durationSeconds Czas trwania głosowania w sekundach
     */
    function createProposal(string memory _question, uint256 _durationSeconds) external {
        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.question = _question;
        p.endTime = block.timestamp + _durationSeconds;
        p.exists = true;

        emit ProposalCreated(p.id, _question, p.endTime);
    }

    /**
     * @notice Oddaje głos w propozycji
     * @param _proposalId ID propozycji
     * @param _support Czy głos za (true) czy przeciw (false)
     */
    function vote(uint256 _proposalId, bool _support) external {
        Proposal storage p = proposals[_proposalId];
        require(p.exists, "Proposal does not exist");
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!p.hasVoted[msg.sender], "Already voted");

        p.hasVoted[msg.sender] = true;

        if (_support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }

        emit Voted(msg.sender, _proposalId, _support);
    }

    // ========== ZBIÓRKI ==========

    /**
     * @notice Dodaje nowy adres tokenu do whitelisty
     * @param _token Adres tokenu ERC20
     */
    function whitelistToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        isTokenWhitelisted[_token] = true;
        whitelistedTokens.push(_token);
        emit TokenWhitelisted(_token);
    }

    /**
     * @notice Ustawia prowizję od dotacji (w BPS)
     * @param _bps Wartość w punktach bazowych (max 10000)
     */
    function setDonationCommission(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 100%");
        donationCommission = _bps;
    }

    /**
     * @notice Ustawia prowizję od wypłat (w BPS)
     * @param _bps Wartość w punktach bazowych (max 10000)
     */
    function setSuccessCommission(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 100%");
        successCommission = _bps;
    }

    /**
     * @notice Tworzy nową zbiórkę
     * @param _token Token ERC20 akceptowany w zbiórce
     * @param _target Cel zbiórki
     * @param _durationSeconds Czas trwania
     * @param _isFlexible Czy zbiórka jest elastyczna (możliwa wypłata bez celu)
     */
    function createFundraiser(address _token, uint256 _target, uint256 _durationSeconds, bool _isFlexible) external {
        require(isTokenWhitelisted[_token], "Token not allowed");

        fundraiserCount++;
        Fundraiser storage f = fundraisers[fundraiserCount];
        f.id = fundraiserCount;
        f.creator = msg.sender;
        f.token = _token;
        f.target = _target;
        f.endTime = block.timestamp + _durationSeconds;
        f.exists = true;
        f.isFlexible = _isFlexible;

        emit FundraiserCreated(f.id, msg.sender, _token, _target, f.endTime, _isFlexible);
    }

    /**
     * @notice Wpłaca środki na zbiórkę
     * @param _id ID zbiórki
     * @param _amount Kwota do wpłaty
     */
    function donate(uint256 _id, uint256 _amount) external {
        Fundraiser storage f = fundraisers[_id];
        require(f.exists, "Not found");
        require(block.timestamp <= f.endTime, "Ended");
        require(_amount > 0, "Amount = 0");

        IERC20 token = IERC20(f.token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        uint256 commission = (_amount * donationCommission) / 10000;
        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission failed");
        }

        uint256 net = _amount - commission;
        f.raised += net;
        f.donations[msg.sender] += net;

        emit DonationMade(_id, msg.sender, net);
    }

    /**
     * @notice Pozwala użytkownikowi odzyskać środki jeśli zbiórka nie zakończyła się sukcesem
     * @param _id ID zbiórki
     */
    function refund(uint256 _id) external {
        Fundraiser storage f = fundraisers[_id];
        require(f.exists, "Not found");
        require(!f.refunded[msg.sender], "Already refunded");

        uint256 donated = f.donations[msg.sender];
        require(donated > 0, "Nothing donated");

        if (!f.isFlexible) {
            require(block.timestamp > f.endTime, "Too early");
            require(f.raised < f.target || f.closureInitiated, "No refunds now");
            if (f.closureInitiated) {
                require(block.timestamp <= f.reclaimDeadline, "Reclaim period over");
            }
        }

        f.refunded[msg.sender] = true;
        f.donations[msg.sender] = 0;

        require(IERC20(f.token).transfer(msg.sender, donated), "Refund failed");

        emit DonationRefunded(_id, msg.sender, donated);
    }

    /**
     * @notice Pozwala twórcy wypłacić środki z zakończonej zbiórki
     * @param _id ID zbiórki
     */
    function withdraw(uint256 _id) external {
        Fundraiser storage f = fundraisers[_id];
        require(f.exists, "Not found");
        require(msg.sender == f.creator, "Not creator");
        require(!f.withdrawn || f.isFlexible, "Already withdrawn");

        if (f.isFlexible) {
            uint256 available = f.raised;
            f.raised = 0;
            require(available > 0, "Nothing to withdraw");

            require(IERC20(f.token).transfer(f.creator, available), "Withdraw failed");
            emit FundsWithdrawn(_id, f.creator, available);
            return;
        }

        if (f.raised >= f.target) {
            f.withdrawn = true;
        } else {
            require(block.timestamp > f.endTime, "Too early");
            require(f.closureInitiated && block.timestamp >= f.reclaimDeadline, "Not ready");
            f.withdrawn = true;
        }

        uint256 commission = (f.raised * successCommission) / 10000;
        uint256 net = f.raised - commission;

        if (commission > 0) {
            require(IERC20(f.token).transfer(commissionWallet, commission), "Commission fail");
        }
        require(IERC20(f.token).transfer(f.creator, net), "Withdraw fail");

        emit FundsWithdrawn(_id, f.creator, net);
    }

    /**
     * @notice Inicjuje okres zwrotów w zakończonej zbiórce
     * @param _id ID zbiórki
     */
    function initiateClosure(uint256 _id) external {
        Fundraiser storage f = fundraisers[_id];
        require(msg.sender == f.creator, "Not creator");
        require(!f.isFlexible, "Flexible can't initiate closure");
        require(block.timestamp > f.endTime, "Too early");
        require(!f.closureInitiated, "Already initiated");
        f.closureInitiated = true;
        f.reclaimDeadline = block.timestamp + RECLAIM_PERIOD;
        emit ClosureInitiated(_id, f.reclaimDeadline);
    }

    // ========== GETTERY: PUBLICZNE DANE DLA FRONTU ==========

    function getFundraiser(uint256 id) external view returns (
        uint256, address, address, uint256, uint256,
        uint256, bool, bool, uint256, bool
    ) {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not found");
        return (
            f.id,
            f.creator,
            f.token,
            f.target,
            f.raised,
            f.endTime,
            f.withdrawn,
            f.isFlexible,
            f.reclaimDeadline,
            f.closureInitiated
        );
    }

    function donationOf(uint256 id, address donor) external view returns (uint256) {
        return fundraisers[id].donations[donor];
    }

    function hasRefunded(uint256 id, address donor) external view returns (bool) {
        return fundraisers[id].refunded[donor];
    }

    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

    function getProposal(uint256 id) external view returns (
        uint256, string memory, uint256, uint256, uint256, bool
    ) {
        Proposal storage p = proposals[id];
        require(p.exists, "Not found");
        return (
            p.id,
            p.question,
            p.yesVotes,
            p.noVotes,
            p.endTime,
            p.exists
        );
    }

    function hasVoted(uint256 id, address voter) external view returns (bool) {
        return proposals[id].hasVoted[voter];
    }

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }
}
