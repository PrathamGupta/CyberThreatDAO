// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CyberInsuranceDAO {
    // Define roles and claim statuses
    enum MemberRole { None, Member, Expert, Underwriter, Admin }
    enum ClaimStatus { Pending, Approved, Rejected, Disputed }

    // Structure for claims
    struct Claim {
        uint id;
        address claimant;
        string description;
        uint amount;
        uint votesFor;
        uint votesAgainst;
        uint startTime;  // Voting period start time
        bool executed;
        ClaimStatus status;
    }

    uint public claimCount;
    mapping(uint => Claim) public claims;
    mapping(address => MemberRole) public roles;

    // ERC-20 token used for staking and voting power
    IERC20 public token;
    // Staking balances: tokens staked by each member
    mapping(address => uint) public stakingBalance;

    // Voting and staking parameters
    uint public votingPeriod = 86400;    // Voting period in seconds (24 hours)
    uint public challengePeriod = 3600;    // Challenge period after execution (1 hour)
    uint public minStake = 1 * 10**18;     // Minimum stake (in tokens, assuming 18 decimals)

    // ---------------- On-Chain Analytics Variables ----------------
    uint public totalClaimValue;      // Sum of all submitted claim amounts
    uint public totalVotesFor;        // Sum of all votes in favor across claims
    uint public totalVotesAgainst;    // Sum of all votes against across claims
    uint public approvedClaims;       // Count of approved claims
    uint public rejectedClaims;       // Count of rejected claims
    uint public disputedClaims;       // Count of disputed claims

    // ---------------- Automated Premium Adjustments ----------------
    uint public premiumRate; // Premium rate in percentage (e.g., 10 means 10%)

    // ---------------- Events ----------------
    event ClaimSubmitted(uint indexed claimId, address indexed claimant, uint amount);
    event VoteCast(uint indexed claimId, address indexed voter, bool vote, uint votingPower);
    event ClaimExecuted(uint indexed claimId, ClaimStatus status);
    event ClaimChallenged(uint indexed claimId, address indexed challenger);
    event StakeDeposited(address indexed staker, uint amount);
    event StakeWithdrawn(address indexed staker, uint amount);
    event IncidentDataVerified(bool verified);

    // ---------------- Modifiers ----------------
    modifier onlyMember() {
        require(roles[msg.sender] != MemberRole.None, "Not a DAO member");
        _;
    }

    modifier onlyAdmin() {
        require(roles[msg.sender] == MemberRole.Admin, "Only admin allowed");
        _;
    }

    // ---------------- Constructor ----------------
    // Set the deployer as Admin, initialize the premium rate, and store the ERC-20 token address.
    constructor(address _tokenAddress) {
        token = IERC20(_tokenAddress);  // *REPLACE THIS WITH YOUR ERC-20 TOKEN ADDRESS*
        roles[msg.sender] = MemberRole.Admin;
        premiumRate = 10; // Initialize premium rate to 10%
    }

    // ---------------- Member and Admin Functions ----------------
    
    // Admin can add new members with a specific role.
    function addMember(address _member, MemberRole _role) external onlyAdmin {
        require(_role != MemberRole.None, "Invalid role");
        roles[_member] = _role;
    }
    
    // Members deposit tokens for staking.
    // They must first approve this contract to transfer tokens on their behalf.
    function depositStake(uint256 _amount) external onlyMember {
        require(_amount >= minStake, "Amount less than minimum stake required");
        require(token.transferFrom(msg.sender, address(this), _amount), "Token transfer failed");
        stakingBalance[msg.sender] += _amount;
        emit StakeDeposited(msg.sender, _amount);
    }
    
    // Members withdraw their staked tokens.
    function withdrawStake(uint256 _amount) external onlyMember {
        require(stakingBalance[msg.sender] >= _amount, "Insufficient stake");
        stakingBalance[msg.sender] -= _amount;
        require(token.transfer(msg.sender, _amount), "Token transfer failed");
        emit StakeWithdrawn(msg.sender, _amount);
    }
    
    // Submit a new cyber insurance claim.
    // Increases the total claim value for analytics.
    function submitClaim(string calldata _description, uint _amount) external returns (uint) {
        claimCount++;
        totalClaimValue += _amount;
        claims[claimCount] = Claim({
            id: claimCount,
            claimant: msg.sender,
            description: _description,
            amount: _amount,
            votesFor: 0,
            votesAgainst: 0,
            startTime: block.timestamp,
            executed: false,
            status: ClaimStatus.Pending
        });
        emit ClaimSubmitted(claimCount, msg.sender, _amount);
        return claimCount;
    }
    
    // Members vote on a claim.
    // Their voting power is determined by their staked tokens.
    // Global totals for votes are updated for analytics.
    function voteOnClaim(uint _claimId, bool _approve) external onlyMember {
        Claim storage claim = claims[_claimId];
        require(block.timestamp <= claim.startTime + votingPeriod, "Voting period is over");
        require(!claim.executed, "Claim already executed");
        require(stakingBalance[msg.sender] >= minStake, "Insufficient stake to vote");
        
        uint votingPower = stakingBalance[msg.sender];
        if (_approve) {
            claim.votesFor += votingPower;
            totalVotesFor += votingPower;
        } else {
            claim.votesAgainst += votingPower;
            totalVotesAgainst += votingPower;
        }
        emit VoteCast(_claimId, msg.sender, _approve, votingPower);
    }
    
    // Admin executes a claim after the voting period.
    // Updates claim status and analytics counters, then adjusts the premium rate.
    function executeClaim(uint _claimId) external onlyAdmin {
        Claim storage claim = claims[_claimId];
        require(block.timestamp > claim.startTime + votingPeriod, "Voting period not finished");
        require(!claim.executed, "Claim already executed");
        
        if (claim.votesFor > claim.votesAgainst) {
            claim.status = ClaimStatus.Approved;
            approvedClaims++;
        } else {
            claim.status = ClaimStatus.Rejected;
            rejectedClaims++;
        }
        claim.executed = true;
        emit ClaimExecuted(_claimId, claim.status);
        
        // Update premium rate based on claim outcomes.
        updatePremiumRate();
    }
    
    // Members can challenge an executed claim within the challenge period.
    // This marks the claim as disputed and updates analytics.
    function challengeClaim(uint _claimId) external onlyMember {
        Claim storage claim = claims[_claimId];
        require(claim.executed, "Claim has not been executed");
        require(block.timestamp <= claim.startTime + votingPeriod + challengePeriod, "Challenge period is over");
        claim.status = ClaimStatus.Disputed;
        disputedClaims++;
        emit ClaimChallenged(_claimId, msg.sender);
        
        // Optionally update premium rate after a dispute.
        updatePremiumRate();
    }
    
    // ---------------- Automated Premium Adjustments ----------------
    // Automatically adjust the premium rate based on claim outcomes.
    // For example, if more than 50% of executed claims are approved, increase the rate;
    // if fewer than 30% are approved, decrease it. Premium rate is bounded between 5% and 20%.
    function updatePremiumRate() internal {
        uint totalExecuted = approvedClaims + rejectedClaims + disputedClaims;
        if (totalExecuted > 0) {
            uint approvedRatio = (approvedClaims * 100) / totalExecuted;
            if (approvedRatio > 50 && premiumRate < 20) {
                premiumRate += 1; // Increase premium by 1%
            } else if (approvedRatio < 30 && premiumRate > 5) {
                premiumRate -= 1; // Decrease premium by 1%
            }
        }
    }
    
    // Helper function to calculate the premium for a given insured value.
    function calculatePremium(uint insuredValue) public view returns (uint) {
        return (insuredValue * premiumRate) / 100;
    }
    
    // ---------------- Simple On-Chain Analytics ----------------
    // Retrieve key metrics about the DAO’s performance and claim history.
    function getAnalytics() public view returns (
        uint _totalClaims,
        uint _totalClaimValue,
        uint _approvedClaims,
        uint _rejectedClaims,
        uint _disputedClaims,
        uint _totalVotesFor,
        uint _totalVotesAgainst,
        uint _premiumRate
    ) {
        _totalClaims = claimCount;
        _totalClaimValue = totalClaimValue;
        _approvedClaims = approvedClaims;
        _rejectedClaims = rejectedClaims;
        _disputedClaims = disputedClaims;
        _totalVotesFor = totalVotesFor;
        _totalVotesAgainst = totalVotesAgainst;
        _premiumRate = premiumRate;
    }
}
