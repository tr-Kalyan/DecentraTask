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


    // Task status enum

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


    // Phase 1: Basic Verification 

    struct TaskVerification {
        //address[] verifiers;
        mapping(address => bool) hasVerified;
        mapping(address => string) feedback;    //Verifier comments
        uint approvalCount;
        uint rejectionCount;
        bool isVerified;                        //Final verification status
    }


    struct CreatorFeedback {
        mapping(address => uint8) verifierRating;  // Creator rates verifiers 1-5
        bool hasRated;                             // Has creator provided feedback?
        uint averageRating;                     // Calculated average
    }



    // Phase 2: Reputation Weighting (commented for now)
    struct ReputationData {
        mapping(address => uint256) verifierReputation;  // Snapshot when verified
        uint256 totalWeightedVotes;                      // Reputation-weighted total
        uint256 weightedApprovals;                       // Weighted approvals
    }

    // State variables
    uint public taskCounter;
    uint public platformFeePercentage = 250; //2.5% (basis points)
    uint public constant BASIS_POINTS = 10000;

    // Storage mappings
    mapping(uint => Task) public tasks;
    mapping(uint => Submission) public submissions;
    mapping(uint => Dispute) public disputes;
    mapping(uint => TaskVerification) public verifications;
    mapping(uint => CreatorFeedback) public creatorFeedbacks;
    mapping(uint => ReputationData) public reputationData;
    mapping(address => bool) public hasActiveTasks;
    mapping(address => uint) public activeTaskId;
    

    // User stakes - prevents spam and ensures commitment
    mapping(address => uint) public userStakes;

    // Treasury from penalties
    uint public treasuryFund;



    // Reviewer rating score from creator feedback
    mapping(address => uint) public reviewerRatingReceived;  // total points received
    mapping(address => uint) public reviewerRatingPossible;  // total possible points


    // Events for frontend integration
    event TaskCreated(uint indexed taskId, address indexed creator, uint bounty);
    event TaskClaimed(uint indexed taskId, address indexed worker);
    event TaskSubmitted(uint indexed taskId, string ipfsHash);
    event TaskCompleted(uint indexed taskId, address indexed worker, uint payout);
    event TaskDisputed(uint indexed taskId, address indexed initiator);
    event TaskVerified(uint indexed taskId, address indexed verifier, bool approved);
    event StakeDeposited(address indexed user, uint amount);
    event StakeWithdrawn(address indexed user, uint amount);
    event TaskRejected(uint indexed taskId, address indexed worker, uint stakeForfeited);
    event ReviewRated(address indexed creator, address indexed verifier, uint8 rating, uint taskId);

    // Custom errors - more gas efficient than require strings
    error InsufficientStake();
    error TaskNotFound();
    error UnauthorizedAction();
    error TaskAlreadyClaimed();
    error TaskNotSubmitted();
    error DeadlineExceeded();
    error InvalidParameters();
    error HasActiveTasks(uint currentTaskId);
    error InvalidTaskStatus();
    error AlreadyVerified();

    constructor() Ownable(msg.sender) {
        taskCounter = 0;
    }

    function createTask(
        string calldata _title,
        string calldata _ipfsHash,
        uint _stakeRequired,
        uint _deadline
    ) external payable nonReentrant {
        //Input validation
        if (msg.value == 0) revert InvalidParameters();
        if (_deadline <= block.timestamp) revert InvalidParameters();
        if (bytes(_title).length == 0) revert InvalidParameters();

        //Create task
        taskCounter++;

        tasks[taskCounter] = Task({
            id:taskCounter,
            creator:msg.sender,
            worker:address(0),
            title: _title,
            ipfsHash: _ipfsHash,
            bounty: msg.value,
            stakeRequired: _stakeRequired,
            deadline: _deadline,
            status: TaskStatus.OPEN,
            createdAt: block.timestamp
        });

        emit TaskCreated(taskCounter, msg.sender, msg.value);
    }


    function claimTask(uint _taskId) external payable nonReentrant {

        Task storage task = tasks[_taskId];

        //Validation checks
        if (task.id == 0) revert TaskNotFound();
        if (task.status != TaskStatus.OPEN) revert TaskAlreadyClaimed();
        if (block.timestamp > task.deadline) revert DeadlineExceeded();
        if (msg.value < task.stakeRequired) revert InsufficientStake();

        //Prevent multiple active tasks (moonlighting prevention)
        if (hasActiveTasks[msg.sender]) {
            revert HasActiveTasks(activeTaskId[msg.sender]);
        }

        // Update task State
        task.worker = msg.sender;
        task.status = TaskStatus.CLAIMED;

        // Track User's stake
        userStakes[msg.sender] += msg.value;

        // Mark user as having active task (CRITICAL for moonlighting prevention!)
        hasActiveTasks[msg.sender] = true;
        activeTaskId[msg.sender] = _taskId;

        emit TaskClaimed(_taskId, msg.sender);
    }

    function submitWork(
        uint _taskId,
        string calldata _ipfsHash,
        string calldata _description
    ) external nonReentrant {

        Task storage task = tasks[_taskId];


        //Validation
        if (task.worker != msg.sender) revert UnauthorizedAction();
        if (task.status != TaskStatus.CLAIMED) revert InvalidTaskStatus();
        if (block.timestamp > task.deadline) revert DeadlineExceeded();

        //Store submissions
        submissions[_taskId] = Submission({
            ipfsHash: _ipfsHash,
            submittedAt: block.timestamp,
            description: _description
        });

        // Update task status
        task.status = TaskStatus.SUBMITTED;
    
        emit TaskSubmitted(_taskId, _ipfsHash);
        
    }

    function verifyTask(uint _taskId, bool _approved, string calldata _feedback) external nonReentrant {

        Task storage task = tasks[_taskId];

        //Validation
        if (task.status != TaskStatus.SUBMITTED) revert TaskNotSubmitted();
        if (task.worker == msg.sender || task.creator == msg.sender ) {
            revert UnauthorizedAction();
        }
        if (verifications[_taskId].hasVerified[msg.sender]) {
            revert("Already Verified");
        }

        //Record verification
        verifications[_taskId].hasVerified[msg.sender] = true;
        verifications[_taskId].feedback[msg.sender] = _feedback;

        if (_approved) {
            verifications[_taskId].approvalCount++;
        }else{
            verifications[_taskId].rejectionCount++;
        }

        emit TaskVerified(_taskId,msg.sender, _approved);

        // Check if verification complete
        _checkVerificationComplete(_taskId);
    }

    function _checkVerificationComplete(uint _taskId) internal {
        TaskVerification storage verification = verifications[_taskId];
        
        if (verification.approvalCount >= minVerifiersPerTask) {
            // Task approved - release payment
            _completeTask(_taskId);
        } else if (verification.rejectionCount >= minVerifiersPerTask) {
            _rejectTask(_taskId);
        }
    }

    function _completeTask(uint _taskId) internal {
        Task storage task = tasks[_taskId];
        
        // Update status
        task.status = TaskStatus.COMPLETED;
        
        // Release payment to worker
        payable(task.worker).transfer(task.bounty);
        
        // Return stake to worker
        uint stake = userStakes[task.worker];
        userStakes[task.worker] = 0;
        payable(task.worker).transfer(stake);
        
        // FREE UP WORKER for new tasks (Critical!)
        hasActiveTasks[task.worker] = false;
        activeTaskId[task.worker] = 0;
        
        
        emit TaskCompleted(_taskId, task.worker, task.bounty);

    }

    function _rejectTask(uint _taskId) internal {
        Task storage task = tasks[_taskId];

        // Calculate 20% penalty and 80% refund
        uint totalStake = userStakes[task.worker];
        uint penalty = totalStake * 20/100;
        uint refund = totalStake - penalty;

        // Reset user stake
        userStakes[task.worker] = 0;

        // Return 80% of stake to worker
        if (refund > 0){
            payable(task.worker).transfer(refund);
        }

        treasuryFund +=penalty;

        // Return task to OPEN status 
        task.status = TaskStatus.OPEN;
        task.worker = address(0);

        // Free up worker for new tasks
        hasActiveTasks[task.worker] = false;
        activeTaskId[task.worker] = 0;
        

        emit TaskRejected(_taskId,task.worker,penalty);

    }

    // Worker state cleanup function
    function _clearWorkerState(address worker) internal {
        hasActiveTasks[worker] = false;
        activeTaskId[worker] = 0;
    }

    // Get available tasks for claiming
    function getAvailableTasks() external view returns (uint[] memory) {
        
        // Count available tasks first
        uint availableCount = 0;
        for (uint i = 1; i <= taskCounter; i++) {
            if (tasks[i].status == TaskStatus.OPEN && block.timestamp <= tasks[i].deadline) {
                availableCount++;  
            }
        }
        
        // Create array of available task IDs
        uint[] memory availableTasks = new uint[](availableCount);
        uint index = 0;
        
        for (uint i = 1; i <= taskCounter; i++) {
            if (tasks[i].status == TaskStatus.OPEN && block.timestamp <= tasks[i].deadline) {
                availableTasks[index] = i;
                index++;
            }
        }
        
        return availableTasks;
    }

    // Check if user can claim tasks
    function canUserClaimTasks(address user) external view returns (bool) {
        return !hasActiveTasks[user];
    }

    // Get specific task details
    function getTask(uint _taskId) external view returns (Task memory) {
        if (tasks[_taskId].id == 0) revert TaskNotFound();
        return tasks[_taskId];
    }

    // Get task submission details  
    function getSubmission(uint _taskId) external view returns (Submission memory) {
        if (tasks[_taskId].id == 0) revert TaskNotFound();
        return submissions[_taskId];
    }

    // Get verification status
    function getVerificationStatus(uint _taskId) external view returns (
        uint approvalCount,
        bool isComplete,
        bool userHasVerified
    ) {
        TaskVerification storage verification = verifications[_taskId];
        return (
            verification.approvalCount,
            verification.approvalCount >= minVerifiersPerTask,
            verification.hasVerified[msg.sender]
        );
    }

    // Get user's current active task (0 if none)
    function getUserActiveTask(address user) external view returns (uint) {
        return activeTaskId[user];
    }


    function rateReviewers(uint _taskId, address[] calldata verifiers, uint8[] calldata ratings) external {
        Task storage task = tasks[_taskId];

        // Validate: only task creator can rate
        if (task.creator != msg.sender) revert UnauthorizedAction();

        // Already rated check (optional)
        if (creatorFeedbacks[_taskId].hasRated) revert("Already rated");

        // Validation
        if (verifiers.length != ratings.length || verifiers.length == 0) revert InvalidParameters();

        for (uint i = 0; i < verifiers.length; i++) {
            address verifier = verifiers[i];
            uint8 rating = ratings[i];

            if (rating > 5) revert InvalidParameters();

            // Rating for the specific task
            creatorFeedbacks[_taskId].verifierRating[verifier] = rating;

            // Global reviewer stats
            reviewerRatingReceived[verifier] += rating;
            reviewerRatingPossible[verifier] += 5;

            // Emit event for frontend and transparency
            emit ReviewRated(msg.sender, verifier, rating, _taskId);
        }

        creatorFeedbacks[_taskId].hasRated = true;
    }

    function getReviewerRating(address reviewer) public view returns (uint ratingPercent, uint received, uint possible) {
        received = reviewerRatingReceived[reviewer];
        possible = reviewerRatingPossible[reviewer];

        if (possible == 0) return (0, 0, 0); // No ratings yet

        ratingPercent = (received * 100) / possible;  
        return (ratingPercent, received, possible);
    }

    function getReviewerStats(address reviewer) external view returns (
        uint ratingPercent,
        uint received,
        uint possible
    ) {
        return getReviewerRating(reviewer);
    }

    function getCreatorRatingForTask(uint _taskId, address verifier) external view returns (uint8) {
        return creatorFeedbacks[_taskId].verifierRating[verifier];
    }
}