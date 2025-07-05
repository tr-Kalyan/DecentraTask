pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TaskManager is Ownable, ReentrancyGuard {

    uint public maxVerifiersPerTask = 5;
    uint public minVerifiersPerTask = 3; 

    function setVerificationLimits(uint _max, uint _min) external onlyOwner {
        maxVerifiersPerTask = _max;
        minVerifiersPerTask = _min;
    }


    //Task status enum

    enum TaskStatus {
        OPEN,
        CLAIMED,
        SUBMITTED,
        COMPLETED,
        DISPUTED
    }

    //Main task structure
    struct Task {
        uint id;
        address creator;
        address worker;
        string title;
        string ipfsHash;  //Task description/requirements
        uint bounty;
        uint stakeRequired;
        uint deadline;
        TaskStatus status;
        uint createdAt;
    }

    struct Submission {
        string ipfsHash;     //work deliverables
        uint submittedAt;
        string description;  //brief summary
    }


    struct Dispute {
        uint taskId;
        address initiator;
        string ipfsHash;   //IPFS hash of dispute details
        uint createdAt;
        bool resolved;
    }


    //Phase 1: Basic Verification 

    struct TaskVerification {
        mapping(address => bool) hasVerified;
        mapping(address => string) feedback;    //Verifier comments
        uint approvalCount;
        bool isVerified;                        //Final verification status
    }


    //Phase 2: Creator feedback
    struct CreatorFeedback {
        mapping(address => uint8) verifierRating;  // Creator rates verifiers 1-5
          bool hasRated;                           // Has creator provided feedback?
          uint256 averageRating;                   // Calculated average
    }

    // Phase 3: Reputation Weighting (commented for now)
    struct ReputationData {
        mapping(address => uint256) verifierReputation;  // Snapshot when verified
        uint256 totalWeightedVotes;                      // Reputation-weighted total
        uint256 weightedApprovals;                       // Weighted approvals
    }
    
}