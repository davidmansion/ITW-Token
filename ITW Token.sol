// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";

contract ITWToken is Ownable {

    string public constant name = "InterWorld Token";

    string public constant symbol = "ITW";

    uint8 public constant decimals = 18;

    uint public totalSupply;
    uint public constant MaxSupply = 100000000*1e18;    // 100 million
    uint public constant FirstSupply = 1;   // 30 million

    mapping (address => mapping (address => uint96)) internal allowances;

    mapping (address => uint96) internal balances;

    // delegator => delegatee
    mapping (address => address) public delegates;

    mapping(address => bool) public minters;

    struct Checkpoint {
        uint32 fromBlock;
        uint96 votes;
    }

    // delegatee => index => Checkpoint
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    // delegatee => Checkpoints length
    mapping (address => uint32) public numCheckpoints;

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    event AddMinter(address indexed minter);

    event RemoveMinter(address indexed minter);

    modifier onlyMinter() {
        require(minters[msg.sender], "ITWToken: NOT_MINTER");
        _;
    }

    constructor(address account)  {
        _mint(account, uint96(FirstSupply));
    }

    function addMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "ITWToken: ZERO_ADDRESS");

        minters[_minter] = true;
        emit AddMinter(_minter);
    }

    function removeMinter(address _minter) external  onlyOwner {
        require(_minter != address(0), "ITWToken: ZERO_ADDRESS");

        minters[_minter] = false;
        emit RemoveMinter(_minter);
    }

    function mint(address account, uint96 amount) public onlyMinter {
        require(totalSupply + uint(amount) <= MaxSupply, "ITWToken: EXCEED_THE_MAXIMUM");
        _mint(account, amount);
    }

    function allowance(address account, address spender) external view returns (uint) {
        return allowances[account][spender];
    }

    function approve(address spender, uint rawAmount) external returns (bool) {
        uint96 amount;
        if (rawAmount == type(uint256).max) {
            amount = type(uint96).max;
        } else {
            amount = safe96(rawAmount, "ITWToken: AMOUNT_EXCEED_96_BITS");
        }

        allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function balanceOf(address account) external view returns (uint) {
        return balances[account];
    }

    function transfer(address dst, uint rawAmount) external returns (bool) {
        uint96 amount = safe96(rawAmount, "ITWToken: AMOUNT_EXCEED_96_BITS");
        _transferTokens(msg.sender, dst, amount);
        return true;
    }

    function transferFrom(address src, address dst, uint rawAmount) external returns (bool) {
        address spender = msg.sender;
        uint96 spenderAllowance = allowances[src][spender];
        uint96 amount = safe96(rawAmount, "ITWToken: AMOUNT_EXCEED_96_BITS");

        if (spender != src && spenderAllowance != type(uint96).max) {
            uint96 newAllowance = sub96(spenderAllowance, amount, "ITWToken: TRANSFER_AMOUNT_EXCEED_SPENDER_ALLOWANCE");
            allowances[src][spender] = newAllowance;

            emit Approval(src, spender, newAllowance);
        }

        _transferTokens(src, dst, amount);
        return true;
    }

    function delegate(address delegatee) public {
        return _delegate(msg.sender, delegatee);
    }

    function getCurrentVotes(address account) external view returns (uint96) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPriorVotes(address account, uint blockNumber) public view returns (uint96) {
        require(blockNumber < block.number, "ITWToken: NOT_YET_DETERMINED");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _mint(address _account, uint96 _amount) internal {
        balances[_account] = add96(balances[_account], _amount, "ITWToken: MINT_AMOUNT_OVERFLOW");
        totalSupply += _amount;

        emit Transfer(address(0), _account, _amount);
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates[delegator];
        uint96 delegatorBalance = balances[delegator];
        delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _transferTokens(address src, address dst, uint96 amount) internal {
        require(src != address(0), "ITWToken: CANNOT_TRANSFER_FROM_THE_ZERO_ADDRESS");
        require(dst != address(0), "ITWToken: CANNOT_TRANSFER_TO_THE_ZERO_ADDRESS");

        balances[src] = sub96(balances[src], amount, "ITWToken: TRANSFER_AMOUNT_EXCEED_BALANCE");
        balances[dst] = add96(balances[dst], amount, "ITWToken: TRANSFER_AMOUNT_OVERFLOW");
        emit Transfer(src, dst, amount);

        _moveDelegates(delegates[src], delegates[dst], amount);
    }

    function _moveDelegates(address srcRep, address dstRep, uint96 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint96 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint96 srcRepNew = sub96(srcRepOld, amount, "ITWToken: VOTE_AMOUNT_UNDERFLOW");
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint96 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint96 dstRepNew = add96(dstRepOld, amount, "ITWToken: VOTE_AMOUNT_OVERFLOW");
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint32 nCheckpoints, uint96 oldVotes, uint96 newVotes) internal {
        uint32 blockNumber = safe32(block.number, "ITWToken: BLOCK_NUMBER_EXCEED_32_BITS");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function safe96(uint n, string memory errorMessage) internal pure returns (uint96) {
        require(n < 2**96, errorMessage);
        return uint96(n);
    }

    function add96(uint96 a, uint96 b, string memory errorMessage) internal pure returns (uint96) {
        uint96 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub96(uint96 a, uint96 b, string memory errorMessage) internal pure returns (uint96) {
        require(b <= a, errorMessage);
        return a - b;
    }
}
