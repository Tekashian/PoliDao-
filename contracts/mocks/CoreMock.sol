// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStorageMinimal {
    function releaseFunds(address token, address to, uint256 amount) external;
}

contract CoreMock {
    struct Fundraiser {
        address creator;
        address token;
        uint256 goal;
        uint256 endDate;
        bool exists;
    }

    IStorageMinimal public immutable storageContract;
    uint256 public nextFundraiserId = 1;

    // lokalna whitelist, aby testy mogły wymusić zachowanie core
    mapping(address => bool) public allowedToken;

    // prosta ewidencja zbiórek (do donate(fId, amount))
    mapping(uint256 => Fundraiser) public fundraisers;

    event FundraiserCreated(uint256 indexed fundraiserId, address indexed creator, address indexed token, uint256 goal, uint256 endDate);
    event Donated(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 amount);
    event Withdrawn(uint256 indexed fundraiserId, address indexed to, address indexed token, uint256 amount);

    constructor(address storageAddr) {
        storageContract = IStorageMinimal(storageAddr);
    }

    // test helper (wywoływany z testów przy zmianie whitelist w storage)
    function allowToken(address token, bool allowed) external {
        allowedToken[token] = allowed;
    }

    function createFundraiser(address token, uint256 goal, uint256 endDate, string memory, string memory) external returns (uint256 fundraiserId) {
        require(allowedToken[token], "CoreMock: token not allowed");
        fundraiserId = nextFundraiserId++;
        fundraisers[fundraiserId] = Fundraiser({
            creator: msg.sender,
            token: token,
            goal: goal,
            endDate: endDate,
            exists: true
        });
        emit FundraiserCreated(fundraiserId, msg.sender, token, goal, endDate);
    }

    // wariant z podanym tokenem
    function donate(uint256 fundraiserId, address token, uint256 amount) external {
        require(amount > 0, "CoreMock: zero amount");
        IERC20(token).transferFrom(msg.sender, address(storageContract), amount);
        emit Donated(fundraiserId, msg.sender, token, amount);
    }

    // wariant bez tokenu (korzysta z zapisanej zbiórki)
    function donate(uint256 fundraiserId, uint256 amount) external {
        require(amount > 0, "CoreMock: zero amount");
        Fundraiser memory f = fundraisers[fundraiserId];
        require(f.exists, "CoreMock: fundraiser not found");
        IERC20(f.token).transferFrom(msg.sender, address(storageContract), amount);
        emit Donated(fundraiserId, msg.sender, f.token, amount);
    }

    // uproszczony withdraw – odbiorca to msg.sender, a token przekazywany jawnie
    function withdrawFunds(uint256 fundraiserId, address token) external {
        uint256 bal = IERC20(token).balanceOf(address(storageContract));
        require(bal > 0, "CoreMock: nothing to withdraw");
        storageContract.releaseFunds(token, msg.sender, bal);
        emit Withdrawn(fundraiserId, msg.sender, token, bal);
    }
}