// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PoliDAO
/// @notice Smart contract wspierający mechanizmy głosowania oraz zbiórek w tokenach ERC20,
///         z możliwością naliczania prowizji przy wielokrotnych refundach w miesiącu.
/// @dev    Obsługuje głosowania z ograniczonym czasem, zbiórki z opcją zwrotu, prowizje oraz whitelistę tokenów.
///         Zabezpiecza funkcje związane z tokenami przed atakami reentrancy przy użyciu ReentrancyGuard.
///         Pozwala na awaryjne wstrzymanie operacji dzięki Pausable.
contract PoliDAO is Ownable, ReentrancyGuard, Pausable {
    // ========== STRUKTURY ==========

    /// @notice Struktura przechowująca wszystkie dane pojedynczej propozycji do głosowania
    struct Proposal {
        uint256 id;                       // Unikalny identyfikator propozycji
        string question;                  // Treść pytania/propozycji
        uint256 yesVotes;                 // Liczba głosów "za"
        uint256 noVotes;                  // Liczba głosów "przeciw"
        uint256 endTime;                  // Timestamp zakończenia głosowania
        bool exists;                      // Flaga istnienia propozycji
        mapping(address => bool) hasVoted;// Mapa adresów, które już głosowały
    }

    /// @notice Skrót danych propozycji do front-endu
    struct ProposalSummary {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
    }

    /// @notice Struktura przechowująca wszystkie dane pojedynczej zbiórki
    struct Fundraiser {
        uint256 id;                          // Unikalny identyfikator zbiórki
        address creator;                     // Adres twórcy zbiórki
        address token;                       // Adres tokenu ERC20 używanego w zbiórce
        uint256 target;                      // Cel zbiórki (ilość tokenów)
        uint256 raised;                      // Aktualnie zebrana ilość netto
        uint256 endTime;                     // Timestamp zakończenia zbiórki
        bool withdrawn;                      // Flaga czy środki zostały wypłacone
        bool exists;                         // Flaga istnienia zbiórki
        bool isFlexible;                     // Flaga czy zbiórka ma tryb „elastyczny”
        uint256 reclaimDeadline;             // Timestamp granicy okresu zwrotów po zamknięciu
        bool closureInitiated;               // Flaga czy rozpoczęto okres zwrotów
        mapping(address => uint256) donations; // Mapa środków wpłaconych przez darczyńców
        mapping(address => bool) refunded;     // Mapa adresów, które już otrzymały refund
        address[] donors;                    // Lista darczyńców (dla historii wpłat)
    }

    /// @notice Skrót danych zbiórki do front-endu
    struct FundraiserSummary {
        uint256 id;
        address creator;
        address token;
        uint256 target;
        uint256 raised;
        uint256 endTime;
        bool isFlexible;
        bool closureInitiated;
    }

    // ========== ZMIENNE STANU ==========

    uint256 public proposalCount;                        // Liczba propozycji
    uint256 public fundraiserCount;                      // Liczba zbiórek

    mapping(uint256 => Proposal) private proposals;      // Propozycje
    mapping(uint256 => Fundraiser) private fundraisers;  // Zbiórki

    uint256[] private proposalIds;       // Lista wszystkich ID propozycji
    uint256[] private fundraiserIds;     // Lista wszystkich ID zbiórek

    mapping(address => bool) public isTokenWhitelisted;  // Whitelist tokenów
    address[] public whitelistedTokens;                   // Lista tokenów

    uint256 public donationCommission;  // Prowizja od wpłat (BPS)
    uint256 public successCommission;   // Prowizja od sukcesu (BPS)
    uint256 public refundCommission;    // Prowizja od kolejnych refund (BPS)

    address public commissionWallet;    // Portfel na prowizje

    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount; // Refund count na okres 30d

    uint256 public constant RECLAIM_PERIOD = 14 days;

    // ========== WYDARZENIA ==========

    event ProposalCreated(uint256 indexed id, string question, uint256 endTime);
    event Voted(address indexed voter, uint256 indexed proposalId, bool support);
    event FundraiserCreated(uint256 indexed id, address indexed creator, address token, uint256 target, uint256 endTime, bool isFlexible);
    event DonationMade(uint256 indexed id, address indexed donor, uint256 amount);
    event DonationRefunded(uint256 indexed id, address indexed donor, uint256 amountReturned, uint256 commissionTaken);
    event FundsWithdrawn(uint256 indexed id, address indexed creator, uint256 amountAfterCommission);
    event TokenWhitelisted(address indexed token);
    event TokenRemoved(address indexed token);
    event ClosureInitiated(uint256 indexed id, uint256 reclaimDeadline);
    event DonationCommissionSet(uint256 newCommission);
    event SuccessCommissionSet(uint256 newCommission);
    event RefundCommissionSet(uint256 newCommission);

    // ========== KONSTRUKTOR ==========

    /// @param initialOwner      Adres właściciela kontraktu
    /// @param _commissionWallet Portfel, na który będą trafiać prowizje
    constructor(address initialOwner, address _commissionWallet) Ownable(initialOwner) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
    }

    // ========== ADMINISTRACJA ==========

    /// @notice Pauzuje wszystkie krytyczne operacje
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Odblokowuje kontrakt
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Ustawia prowizję od wpłat
    function setDonationCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        donationCommission = bps;
        emit DonationCommissionSet(bps);
    }

    /// @notice Ustawia prowizję od sukcesu
    function setSuccessCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        successCommission = bps;
        emit SuccessCommissionSet(bps);
    }

    /// @notice Ustawia prowizję od refund
    function setRefundCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        refundCommission = bps;
        emit RefundCommissionSet(bps);
    }

    /// @notice Dodaje token do whitelisty
    function whitelistToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(!isTokenWhitelisted[token], "Already whitelisted");
        isTokenWhitelisted[token] = true;
        whitelistedTokens.push(token);
        emit TokenWhitelisted(token);
    }

    /// @notice Usuwa token z whitelisty
    function removeWhitelistToken(address token) external onlyOwner {
        require(isTokenWhitelisted[token], "Not whitelisted");
        isTokenWhitelisted[token] = false;
        // usuwamy z tablicy
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                whitelistedTokens[i] = whitelistedTokens[whitelistedTokens.length - 1];
                whitelistedTokens.pop();
                break;
            }
        }
        emit TokenRemoved(token);
    }

    // ========== GŁOSOWANIA ==========

    /// @notice Tworzy nową propozycję
    /// @param question Treść pytania
    /// @param duration Czas trwania w sekundach
    function createProposal(string calldata question, uint256 duration) external whenNotPaused {
        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.question = question;
        p.endTime = block.timestamp + duration;
        p.exists = true;

        proposalIds.push(proposalCount);

        emit ProposalCreated(p.id, question, p.endTime);
    }

    /// @notice Oddaje głos na propozycję
    /// @param proposalId ID propozycji
    /// @param support    True = za, False = przeciw
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.exists, "Not exist");
        require(block.timestamp <= p.endTime, "Ended");
        require(!p.hasVoted[msg.sender], "Already voted");

        p.hasVoted[msg.sender] = true;
        if (support) p.yesVotes++; else p.noVotes++;

        emit Voted(msg.sender, proposalId, support);
    }

    /// @notice Zwraca ile czasu zostało do końca głosowania
    function timeLeftOnProposal(uint256 proposalId) external view returns (uint256) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists || block.timestamp >= p.endTime) return 0;
        return p.endTime - block.timestamp;
    }

    /// @notice Zwraca wszystkie ID propozycji
    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }

    /// @notice Skrótowe dane propozycji (dla front-endu)
    function getProposalSummary(uint256 proposalId) public view returns (ProposalSummary memory) {
        Proposal storage p = proposals[proposalId];
        require(p.exists, "Not exist");
        return ProposalSummary({
            id: p.id,
            question: p.question,
            yesVotes: p.yesVotes,
            noVotes: p.noVotes,
            endTime: p.endTime
        });
    }

    /// @notice Pełne dane propozycji (wymagane przez testy)
    function getProposal(uint256 id) external view returns (
        uint256, string memory, uint256, uint256, uint256, bool
    ) {
        Proposal storage p = proposals[id];
        require(p.exists, "Not exist");
        return (p.id, p.question, p.yesVotes, p.noVotes, p.endTime, p.exists);
    }

    // ========== ZBIÓRKI ==========

    /// @notice Tworzy nową zbiórkę ERC20
    function createFundraiser(address token, uint256 target, uint256 duration, bool isFlexible)
        external
        whenNotPaused
    {
        require(isTokenWhitelisted[token], "Token not allowed");

        fundraiserCount++;
        Fundraiser storage f = fundraisers[fundraiserCount];
        f.id = fundraiserCount;
        f.creator = msg.sender;
        f.token = token;
        f.target = target;
        f.endTime = block.timestamp + duration;
        f.exists = true;
        f.isFlexible = isFlexible;

        fundraiserIds.push(fundraiserCount);

        emit FundraiserCreated(f.id, msg.sender, token, target, f.endTime, isFlexible);
    }

    /// @notice Dokonuje darowizny
    function donate(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not found");
        require(block.timestamp <= f.endTime, "Ended");
        require(amount > 0, "Zero amount");

        IERC20 tok = IERC20(f.token);
        require(tok.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 comm = (amount * donationCommission) / 10_000;
        uint256 net  = amount - comm;

        f.raised += net;
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += net;

        if (comm > 0) {
            require(tok.transfer(commissionWallet, comm), "Commission failed");
        }

        emit DonationMade(id, msg.sender, net);
    }

    /// @notice Zwraca refundę darczyńcy
    function refund(uint256 id) external nonReentrant whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not found");
        require(!f.refunded[msg.sender], "Already refunded");

        uint256 donated = f.donations[msg.sender];
        require(donated > 0, "None donated");

        if (!f.isFlexible) {
            require(block.timestamp > f.endTime, "Too early");
            require(f.raised < f.target || f.closureInitiated, "No refunds");
            if (f.closureInitiated) {
                require(block.timestamp <= f.reclaimDeadline, "Reclaim over");
            }
        }

        uint256 period = block.timestamp / 30 days;
        monthlyRefundCount[msg.sender][period]++;

        uint256 commAmt = 0;
        if (monthlyRefundCount[msg.sender][period] > 1 && refundCommission > 0) {
            commAmt = (donated * refundCommission) / 10_000;
        }

        f.refunded[msg.sender]    = true;
        f.raised                 -= donated;
        f.donations[msg.sender]   = 0;

        IERC20 tok = IERC20(f.token);
        if (commAmt > 0) {
            require(tok.transfer(commissionWallet, commAmt), "Commission failed");
        }
        require(tok.transfer(msg.sender, donated - commAmt), "Refund failed");

        emit DonationRefunded(id, msg.sender, donated - commAmt, commAmt);
    }

    /// @notice Wypłaca środki twórcy
    function withdraw(uint256 id) external nonReentrant whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not found");
        require(msg.sender == f.creator, "Not creator");
        // natychmiastowy check wypłacono?
        require(!f.withdrawn || f.isFlexible, "Already withdrawn");

        IERC20 tok = IERC20(f.token);

        // elastyczna – zawsze pozwalamy
        if (f.isFlexible) {
            uint256 amt = f.raised;
            require(amt > 0, "Zero");
            f.raised = 0;
            require(tok.transfer(f.creator, amt), "Transfer failed");
            emit FundsWithdrawn(id, f.creator, amt);
            return;
        }

        // docelowa: przed pierwszą wypłatą
        if (f.raised >= f.target) {
            require(!f.withdrawn, "Already withdrawn");
            f.withdrawn = true;
        } else {
            // zbiórka zakończona i refund window
            require(block.timestamp > f.endTime, "Too early");
            require(f.closureInitiated && block.timestamp >= f.reclaimDeadline, "Not ready");
            f.withdrawn = true;
        }

        uint256 comm = (f.raised * successCommission) / 10_000;
        uint256 net  = f.raised - comm;
        f.raised = 0;

        if (comm > 0) {
            require(tok.transfer(commissionWallet, comm), "Commission failed");
        }
        require(tok.transfer(f.creator, net), "Transfer failed");

        emit FundsWithdrawn(id, f.creator, net);
    }

    /// @notice Inicjuje okres refundów po zakończeniu zbiórki (docelowa, nieelastyczna)
    function initiateClosure(uint256 id) external whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(msg.sender == f.creator, "Not creator");
        require(!f.isFlexible, "Flexible only");
        require(block.timestamp > f.endTime, "Too early");
        require(!f.closureInitiated, "Already initiated");

        f.closureInitiated = true;
        f.reclaimDeadline   = block.timestamp + RECLAIM_PERIOD;

        emit ClosureInitiated(id, f.reclaimDeadline);
    }

    /// @notice Ile czasu zostało do końca zbiórki
    function timeLeftOnFundraiser(uint256 id) external view returns (uint256) {
        Fundraiser storage f = fundraisers[id];
        if (!f.exists || block.timestamp >= f.endTime) return 0;
        return f.endTime - block.timestamp;
    }

    /// @notice Wszystkie ID zbiórek
    function getAllFundraiserIds() external view returns (uint256[] memory) {
        return fundraiserIds;
    }

    /// @notice Lista darczyńców danej zbiórki
    function getDonors(uint256 id) external view returns (address[] memory) {
        return fundraisers[id].donors;
    }

    // ========== GETTERY ==========

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

    function donationOf(uint256 id, address donor) external view returns (uint256) {
        return fundraisers[id].donations[donor];
    }

    function hasRefunded(uint256 id, address donor) external view returns (bool) {
        return fundraisers[id].refunded[donor];
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }

    /// @notice Pełne dane zbiórki (wymagane przez testy)
    function getFundraiser(uint256 id) external view returns (
        uint256, address, address, uint256, uint256,
        uint256, bool, bool, uint256, bool
    ) {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not exist");
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

    /// @notice Skrótowe dane propozycji (publiczny wrapper)
    function getProposalSummaryPublic(uint256 id) external view returns (ProposalSummary memory) {
        return getProposalSummary(id);
    }

    /// @notice Skrótowe dane zbiórki (publiczny wrapper)
    function getFundraiserSummary(uint256 id) external view returns (FundraiserSummary memory) {
        Fundraiser storage f = fundraisers[id];
        require(f.exists, "Not exist");
        return FundraiserSummary({
            id: f.id,
            creator: f.creator,
            token: f.token,
            target: f.target,
            raised: f.raised,
            endTime: f.endTime,
            isFlexible: f.isFlexible,
            closureInitiated: f.closureInitiated
        });
    }
}
