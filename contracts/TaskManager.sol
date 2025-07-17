pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract TaskManager is Ownable, ReentrancyGuard, Pausable {

    // USDC token contract on Polygon
    IERC20 public immutable usdcToken;

    // Platfrom configuration
    uint public platformFeePercentage = 250;     //2.5% (basis points)
    uint public constant BASIS_POINTS = 10000;
    uint8 public constant USDC_DECIMALS = 6;

    // Task Management
    uint public taskCounter;


    // DAO configuration (for disputes)
    address public daoContract;


    // Platform Treasury
    uint public treasuryBalance;


    // Task status enum
    enum TaskStatus {
        OPEN,
        CLAIMED,
        SUBMITTED,
        APPROVED,
        DISPUTED,
        COMPLETED,
        CANCELLED,
        PAUSED
    }


    // Main task structure
    struct Task {
        uint96 id;
        address creator;
        address worker;
        uint64 deadline;
        uint32 createdAt;
        uint128 bounty;
        uint128 stakeRequired;
        TaskStatus status;
        string ipfsHash;  // Task title and description  
    }


    struct Dispute {
        uint taskId;
        address initiator;
        uint64 votingDeadline;
        uint32 createdAt;
        uint votesFor;
        uint votesAgainst;
        bool resolved;
        bool workerWon;
        string ipfsHash;   //IPFS hash of dispute details
    }

    struct Submission {
        string ipfsHash;     //work deliverables
        uint64 submittedAt;
        string description;  //brief summary
    }

    // Storage mappings
    mapping(uint => Task) public tasks;
    mapping(uint => Submission) public submissions;
    mapping(uint => Dispute) public disputes;


    // Anti-moonlighting enforcement
    mapping(address => bool) public hasActiveTasks;
    mapping(address => uint) public activeTaskId;


    // Worker stakes - prevents spam and ensures commitment
    mapping(address => uint) public workerStakes;


    // Task dispute tracking
    mapping(uint => uint) public taskToDispute;  //taskId => disputeId
    uint public disputeCounter;


    // Events for frontend integration
    event TaskCreated(uint indexed taskId, address indexed creator, uint bounty);
    event TaskClaimed(uint indexed taskId, address indexed worker, uint stake);
    event TaskSubmitted(uint indexed taskId, string ipfsHash);
    event TaskApproved(uint indexed taskId, address creator);
    event TaskCompleted(uint indexed taskId, address indexed worker, uint payout);
    event DisputeCreated(uint indexed disputeId, uint indexed taskId, address indexed initiator);
    event DisputeResolved(uint indexed disputeId, bool workerWon, uint finalPayout);
    event StakeDeposited(address indexed user, uint amount);
    event StakeWithdrawn(address indexed user, uint amount);
    event TaskRejected(uint indexed taskId, address indexed worker,uint reason, uint stakeForfeited);
    

    // Custom errors - more gas efficient than require strings
    error InsufficientUSDCBalance();
    error TaskNotFound();
    error UnauthorizedAction();
    error TaskAlreadyClaimed();
    error TaskNotSubmitted();
    error TaskNotApproved();
    error DeadlineExceeded();
    error InvalidParameters();
    error HasActiveTasks(uint currentTaskId);
    error InvalidTaskStatus();
    error DisputeAlreadyExists();
    error DisputeNotFound();
    error VotingPeriodEnded();
    error InsufficientAllowance();


    constructor(address _usdcToken, address _daoContract) Ownable(msg.sender) {
        usdcToken = IERC20(_usdcToken);
        daoContract = _daoContract;
        taskCounter = 0;
        disputeCounter = 0;
    }

    function createTask(
        string calldata _ipfsHash,
        uint128 _bounty,
        uint64 _deadline
    ) external whenNotPaused nonReentrant {
        //Input validation
        if (_bounty == 0) revert InvalidParameters();
        if (_deadline <= block.timestamp) revert InvalidParameters();
        if (bytes(_ipfsHash).length == 0) revert InvalidParameters();

        // Escrow bounty
        usdcToken.transferFrom(msg.sender, address(this), _bounty);

        //Create task
        taskCounter++;

        
        uint128 stakeRequired = uint128( Math.mulDiv(_bounty, 5, 100) ); //5% of bounty
        if(_bounty > 3000 * (10 ** USDC_DECIMALS)) {
            stakeRequired = 300 * (10 ** USDC_DECIMALS);  //Cap stake @ $300
        }

        tasks[taskCounter] = Task({
            id: uint96(taskCounter),
            creator:msg.sender,
            worker:address(0),
            deadline: _deadline,
            createdAt: uint32(block.timestamp),
            bounty: _bounty,
            stakeRequired: stakeRequired,
            status: TaskStatus.OPEN,
            ipfsHash: _ipfsHash
        });

        emit TaskCreated(taskCounter, msg.sender, _bounty);
    }

                        

    function claimTask(uint _taskId) external whenNotPaused nonReentrant {

        Task storage task = tasks[_taskId];

        // Validation checks
        if (task.id == 0) revert TaskNotFound();
        if (task.status != TaskStatus.OPEN) revert TaskAlreadyClaimed();
        if (block.timestamp >= task.deadline) revert DeadlineExceeded();
        if (usdcToken.balanceOf(msg.sender) < task.stakeRequired) revert InsufficientUSDCBalance();
        if (usdcToken.allowance(msg.sender, address(this)) < task.stakeRequired) revert InsufficientAllowance();  // Added allowance check – Explicitly verifies USDC approval before transfer; prevents silent failures and improves error messaging.

        //Prevent multiple active tasks (moonlighting prevention)
        if (hasActiveTasks[msg.sender]) {
            revert HasActiveTasks(activeTaskId[msg.sender]);
        }

        // Update task State
        task.worker = msg.sender;
        task.status = TaskStatus.CLAIMED;

        // Escrow stake
        usdcToken.transferFrom(msg.sender, address(this), task.stakeRequired);

        // Track worker's stake
        workerStakes[msg.sender] +=task.stakeRequired;

        // Mark user as having active task (CRITICAL for moonlighting prevention!)
        hasActiveTasks[msg.sender] = true;
        activeTaskId[msg.sender] = _taskId;

        emit TaskClaimed(_taskId, msg.sender, task.stakeRequired);
    }


    function submitWork(
        uint _taskId,
        string calldata _ipfsHash,
        string calldata _description
    ) external whenNotPaused nonReentrant {
        Task storage task = tasks[_taskId];

        // Validation
        if (task.worker != msg.sender) revert UnauthorizedAction();
        if (task.status != TaskStatus.CLAIMED) revert InvalidTaskStatus();
        if (block.timestamp >= task.deadline) revert DeadlineExceeded();
        if (bytes(_ipfsHash).length == 0) revert InvalidParameters();
        if (bytes(_description).length == 0 || bytes(_description).length>500) revert InvalidParameters();

        // Check for existing submission. Avoid re-submission
        if (submissions[_taskId].submittedAt != 0) revert InvalidParameters();

        // Store submission
        submissions[_taskId] = Submission({
            ipfsHash: _ipfsHash,
            submittedAt: uint64(block.timestamp),
            description: _description
        });

        // Update task status
        task.status = TaskStatus.SUBMITTED;
        
        emit TaskSubmitted(_taskId, _ipfsHash);
    }

    function approveWork(uint _taskId) external whenNotPaused nonReentrant {
        Task storage task = tasks[_taskId];

        // Validation 
        if (task.creator != msg.sender) revert UnauthorizedAction();
        if (task.status != TaskStatus.SUBMITTED) revert TaskNotSubmitted();

        // Update status 
        task.status = TaskStatus.APPROVED;

        emit TaskApproved(_taskId, msg.sender);

        // Auto-complete and pay
        _completeTask(_taskId);
    }

    function _completeTask(uint _taskId) internal {
        Task storage task = tasks[_taskId];
        
        // Update status
        task.status = TaskStatus.COMPLETED;
        
        // Release payment to worker
        payable(task.worker).transfer(task.bounty);
        
        // Return stake to worker
        uint stake = workerStakes[task.worker];
        workerStakes[task.worker] = 0;
        payable(task.worker).transfer(stake);
        
        // FREE UP WORKER for new tasks (Critical!)
        hasActiveTasks[task.worker] = false;
        activeTaskId[task.worker] = 0;
        
        
        emit TaskCompleted(_taskId, task.worker, task.bounty);
    }



    function _rejectTask(uint _taskId, string calldata _reason) external whenNotPaused nonReentrant {
        Task storage task = tasks[_taskId];


        // Validation
        if (task.creator != msg.sender) revert UnauthorizedAction();
        if (task.status != TaskStatus.SUBMITTED) revert TaskNotSubmitted();

        // Calculate 20% penalty and 80% refund
        uint totalStake = workerStakes[task.worker];
        uint penalty = totalStake * 20/100;
        uint refund = totalStake - penalty;

        // Reset user stake
        workerStakes[task.worker] = 0;

        // Return 80% of stake to worker
        if (refund > 0){
            payable(task.worker).transfer(refund);
        }

        treasuryBalance +=penalty;

        // Return task to OPEN status 
        task.status = TaskStatus.OPEN;
        task.worker = address(0);

        // Free up worker for new tasks
        hasActiveTasks[task.worker] = false;
        activeTaskId[task.worker] = 0;
        

        emit TaskRejected(_taskId, task.worker, _reason, penalty);

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

    // Creator can cancel task before claiming
    function cancelTask(uint _taskId) external whenNotPaused nonReentrant {
        Task storage task = tasks[_taskId];

        task.status = TaskStatus.CANCELLED;
    }


    // Worker withdraws stake if Creator doesn't respond or Worker quits
    function emergencyWithdraw(uint _taskId) external payable whenNotPaused nonReentrant {

        Task storage task = tasks[_taskId];

        // Validation
        if (task.status != TaskStatus.CLAIMED) revert InvalidParameters();
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


    // Get user's current active task (0 if none)
    function getUserActiveTask(address user) external view returns (uint) {
        return activeTaskId[user];
    }

}