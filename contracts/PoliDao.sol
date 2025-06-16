// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PoliDAO
/// @notice Smart contract wspierający mechanizmy głosowania oraz zbiórek w tokenach ERC20,
///         z możliwością naliczania prowizji przy wielokrotnych refundach w miesiącu.
/// @dev    Obsługuje głosowania z ograniczonym czasem, zbiórki z opcją zwrotu, prowizje oraz whitelistę tokenów.
///         Zabezpiecza funkcje związane z tokenami przed atakami reentrancy przy użyciu ReentrancyGuard.
contract PoliDAO is Ownable, ReentrancyGuard {
    // ========== STRUKTURY ==========

    /// @notice Struktura przechowująca wszystkie dane pojedynczej propozycji do głosowania
    struct Proposal {
        uint256 id;                       // @notice Unikalny identyfikator propozycji
        string question;                  // @notice Treść pytania/propozycji
        uint256 yesVotes;                 // @notice Liczba głosów "za"
        uint256 noVotes;                  // @notice Liczba głosów "przeciw"
        uint256 endTime;                  // @notice Timestamp zakończenia głosowania
        bool exists;                      // @notice Flaga istnienia propozycji
        mapping(address => bool) hasVoted;// @notice Mapa adresów, które już głosowały
    }

    /// @notice Struktura przechowująca wszystkie dane pojedynczej zbiórki
    struct Fundraiser {
        uint256 id;                          // @notice Unikalny identyfikator zbiórki
        address creator;                     // @notice Adres twórcy zbiórki
        address token;                       // @notice Adres tokenu ERC20 używanego w zbiórce
        uint256 target;                      // @notice Cel zbiórki (ilość tokenów)
        uint256 raised;                      // @notice Aktualnie zebrana ilość netto
        uint256 endTime;                     // @notice Timestamp zakończenia zbiórki
        bool withdrawn;                      // @notice Flaga czy środki zostały wypłacone
        bool exists;                         // @notice Flaga istnienia zbiórki
        bool isFlexible;                     // @notice Flaga czy zbiórka ma tryb „elastyczny”
        uint256 reclaimDeadline;             // @notice Timestamp granicy okresu zwrotów po zamknięciu
        bool closureInitiated;               // @notice Flaga czy rozpoczęto okres zwrotów
        mapping(address => uint256) donations; // @notice Mapa środków wpłaconych przez darczyńców
        mapping(address => bool) refunded;     // @notice Mapa adresów, które już otrzymały refund
    }

    // ========== ZMIENNE STANU ==========

    /// @notice Liczba utworzonych propozycji
    uint256 public proposalCount;

    /// @notice Liczba utworzonych zbiórek
    uint256 public fundraiserCount;

    /// @notice Mapa propozycji (id => Proposal)
    mapping(uint256 => Proposal) private proposals;

    /// @notice Mapa zbiórek (id => Fundraiser)
    mapping(uint256 => Fundraiser) private fundraisers;

    /// @notice Flaga czy dany token jest dozwolony do zbiórek
    mapping(address => bool) public isTokenWhitelisted;

    /// @notice Lista adresów tokenów na whitelist
    address[] public whitelistedTokens;

    /// @notice Prowizja (w BPS) pobierana od każdej wpłaty dotacji
    uint256 public donationCommission;

    /// @notice Prowizja (w BPS) pobierana przy wypłatach środków przez twórcę
    uint256 public successCommission;

    /// @notice Prowizja (w BPS) pobierana przy kolejnych refundach w miesiącu
    uint256 public refundCommission;

    /// @notice Portfel, na który trafiają wszystkie pobrane prowizje
    address public commissionWallet;

    /// @notice Śledzenie liczby refundów adresu w danym 30-dniowym okresie
    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount;

    /// @notice Stały okres (w sekundach) dostępny na zwrot po inicjacji closure
    uint256 public constant RECLAIM_PERIOD = 14 days;

    // ========== WYDARZENIA ==========

    /// @notice Emitowane przy utworzeniu nowej propozycji do głosowania
    /// @param id          Unikalny identyfikator propozycji
    /// @param question    Treść pytania
    /// @param endTime     Timestamp zakończenia głosowania
    event ProposalCreated(uint256 indexed id, string question, uint256 endTime);

    /// @notice Emitowane przy oddaniu głosu
    /// @param voter       Adres głosującego
    /// @param proposalId  ID propozycji
    /// @param support     True = głos za, False = głos przeciw
    event Voted(address indexed voter, uint256 indexed proposalId, bool support);

    /// @notice Emitowane przy utworzeniu nowej zbiórki
    /// @param id          Unikalny identyfikator zbiórki
    /// @param creator     Adres twórcy zbiórki
    /// @param token       Adres tokenu ERC20
    /// @param target      Cel zbiórki
    /// @param endTime     Timestamp zakończenia zbiórki
    /// @param isFlexible  Flaga elastyczności zbiórki
    event FundraiserCreated(
        uint256 indexed id,
        address indexed creator,
        address token,
        uint256 target,
        uint256 endTime,
        bool isFlexible
    );

    /// @notice Emitowane przy wpłacie darowizny
    /// @param id       ID zbiórki
    /// @param donor    Adres darczyńcy
    /// @param amount   Ilość tokenów netto po odjęciu prowizji
    event DonationMade(uint256 indexed id, address indexed donor, uint256 amount);

    /// @notice Emitowane przy wypłacie refundu
    /// @param id              ID zbiórki
    /// @param donor           Adres darczyńcy
    /// @param amountReturned  Ilość tokenów zwrócona darczyńcy
    /// @param commissionTaken Pobrana prowizja od zwrotu
    event DonationRefunded(
        uint256 indexed id,
        address indexed donor,
        uint256 amountReturned,
        uint256 commissionTaken
    );

    /// @notice Emitowane przy wypłacie środków do twórcy zbiórki
    /// @param id               ID zbiórki
    /// @param creator          Adres twórcy
    /// @param amountAfterCommission Ilość tokenów przekazana po odjęciu prowizji
    event FundsWithdrawn(uint256 indexed id, address indexed creator, uint256 amountAfterCommission);

    /// @notice Emitowane przy dodaniu tokenu do whitelisty
    /// @param token   Adres tokenu
    event TokenWhitelisted(address indexed token);

    /// @notice Emitowane przy inicjacji okresu zwrotu (closure) dla nieelastycznej zbiórki
    /// @param id              ID zbiórki
    /// @param reclaimDeadline Timestamp zakończenia okresu zwrotów
    event ClosureInitiated(uint256 indexed id, uint256 reclaimDeadline);

    // ========== KONSTRUKTOR ==========

    /// @param initialOwner       Adres właściciela kontraktu (Ownable)
    /// @param _commissionWallet  Portfel, na który będą trafiać prowizje
    constructor(address initialOwner, address _commissionWallet) Ownable(initialOwner) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
        donationCommission = 0;
        successCommission = 0;
        refundCommission = 0;
    }

    // ========== ADMIN: USTAWIENIA PROWIZJI ==========

    /// @notice Ustawia prowizję od każdej wpłaty dotacji
    /// @param _bps  Prowizja w punktach bazowych (0–10000)
    function setDonationCommission(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 100%");
        donationCommission = _bps;
    }

    /// @notice Ustawia prowizję przy wypłacie środków przez twórcę
    /// @param _bps  Prowizja w punktach bazowych (0–10000)
    function setSuccessCommission(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 100%");
        successCommission = _bps;
    }

    /// @notice Ustawia prowizję przy kolejnych refundach w tym samym miesiącu
    /// @param _bps  Prowizja w punktach bazowych (0–10000)
    function setRefundCommission(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 100%");
        refundCommission = _bps;
    }

    // ========== GŁOSOWANIA ==========

    /// @notice Tworzy nową propozycję do głosowania
    /// @param _question         Treść pytania
    /// @param _durationSeconds  Czas trwania głosowania w sekundach
    function createProposal(string memory _question, uint256 _durationSeconds) external {
        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.question = _question;
        p.endTime = block.timestamp + _durationSeconds;
        p.exists = true;
        emit ProposalCreated(p.id, _question, p.endTime);
    }

    /// @notice Oddaje głos w istniejącej propozycji
    /// @param _proposalId  ID propozycji
    /// @param _support     True = głos za, False = głos przeciw
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

    /// @notice Dodaje token do whitelisty
    /// @param _token  Adres tokenu ERC20 dozwolonego w zbiórkach
    function whitelistToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        isTokenWhitelisted[_token] = true;
        whitelistedTokens.push(_token);
        emit TokenWhitelisted(_token);
    }

    /// @notice Tworzy nową zbiórkę ERC20
    /// @param _token            Adres tokenu ERC20
    /// @param _target           Cel zbiórki (ilość tokenów)
    /// @param _durationSeconds  Czas trwania zbiórki w sekundach
    /// @param _isFlexible       True = tryb elastyczny (wypłaty w trakcie)
    function createFundraiser(
        address _token,
        uint256 _target,
        uint256 _durationSeconds,
        bool _isFlexible
    ) external {
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

    /// @notice Wpłaca darowiznę na zbiórkę
    /// @param _id      ID zbiórki
    /// @param _amount  Kwota do wpłaty (tokeny ERC20)
    function donate(uint256 _id, uint256 _amount) external nonReentrant {
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

    /// @notice Oddaje refundę darczyńcy; nalicza prowizję przy drugim i kolejnych zwrotach w miesiącu
    /// @param _id  ID zbiórki
    function refund(uint256 _id) external nonReentrant {
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

        uint256 period = block.timestamp / 30 days;
        monthlyRefundCount[msg.sender][period]++;

        uint256 commissionAmt = 0;
        if (monthlyRefundCount[msg.sender][period] > 1 && refundCommission > 0) {
            commissionAmt = (donated * refundCommission) / 10000;
        }

        f.refunded[msg.sender] = true;
        f.donations[msg.sender] = 0;

        IERC20 token = IERC20(f.token);

        if (commissionAmt > 0) {
            require(token.transfer(commissionWallet, commissionAmt), "Refund commission failed");
        }

        uint256 toReturn = donated - commissionAmt;
        require(token.transfer(msg.sender, toReturn), "Refund failed");

        emit DonationRefunded(_id, msg.sender, toReturn, commissionAmt);
    }

    /// @notice Wypłaca zebrane środki twórcy zbiórki
    /// @param _id  ID zbiórki
    function withdraw(uint256 _id) external nonReentrant {
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

    /// @notice Inicjuje okres zwrotów (closure) dla nieelastycznej zbiórki
    /// @param _id  ID zbiórki
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

    // ========== GETTERY ==========

    /// @notice Zwraca dane zbiórki (bez mappingów wewnętrznych)
    /// @param id  ID zbiórki
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

    /// @notice Pobiera wpłaconą kwotę przez darczyńcę dla danej zbiórki
    /// @param id     ID zbiórki
    /// @param donor  Adres darczyńcy
    function donationOf(uint256 id, address donor) external view returns (uint256) {
        return fundraisers[id].donations[donor];
    }

    /// @notice Sprawdza, czy darczyńca otrzymał refundę w danej zbiórce
    /// @param id     ID zbiórki
    /// @param donor  Adres darczyńcy
    function hasRefunded(uint256 id, address donor) external view returns (bool) {
        return fundraisers[id].refunded[donor];
    }

    /// @notice Zwraca liczbę utworzonych zbiórek
    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

    /// @notice Zwraca dane propozycji (bez mappingów wewnętrznych)
    /// @param id  ID propozycji
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

    /// @notice Sprawdza, czy adres już głosował w danej propozycji
    /// @param id     ID propozycji
    /// @param voter  Adres głosującego
    function hasVoted(uint256 id, address voter) external view returns (bool) {
        return proposals[id].hasVoted[voter];
    }

    /// @notice Zwraca liczbę utworzonych propozycji
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }
}
