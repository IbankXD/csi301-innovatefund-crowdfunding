// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title InnovateFund
 * @notice โจทย์ที่ 5: ระบบบริหารโครงการระดมทุนและจ่ายเงินตามความสำเร็จ
 * (Blockchain Crowdfunding & Milestone Fund Management)
 * บริษัท InnovateFund
 */
contract InnovateFund {
    // 4 & 5. โครงสร้างข้อมูลแต่ละระยะงาน (Milestone)
    struct Milestone {
        string description;       // คำอธิบายระยะงาน
        uint256 targetAmount;     // ยอดเงินที่จะเบิกใน Milestone นี้ (Wei)
        string evidence;          // หลักฐานความสำเร็จของงาน (URL หรือ Hash)
        uint256 approvalCount;    // จำนวนเสียงที่โหวตเห็นชอบ
        bool isRequested;         // ขอเบิกเงินแล้วหรือยัง
        bool isPaid;              // จ่ายเงินให้เจ้าของโครงการแล้วหรือยัง
        uint256 paidAt;           // เวลาที่จ่ายเงิน
    }

    // 1. โครงสร้างข้อมูลโครงการระดมทุน (Campaign)
    struct Campaign {
        uint256 id;
        string title;             // ชื่อโครงการ
        address payable creator;  // เจ้าของโครงการ
        uint256 targetGoal;       // เป้าหมายเงินทุน (Wei)
        uint256 deadline;         // เวลาสิ้นสุดการระดมทุน (Timestamp)
        uint256 raisedAmount;     // ยอดเงินสะสมที่ระดมได้
        uint256 totalContributors;// จำนวนผู้สนับสนุนทั้งหมด
        uint256 currentMilestone; // ลำดับ Milestone ปัจจุบัน
        uint256 milestoneCount;   // จำนวน Milestone ทั้งหมด
        bool exists;
    }

    uint256 public nextCampaignId;
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => Milestone[]) private campaignMilestones;

    // campaignId => (contributorAddress => contributedAmount)
    mapping(uint256 => mapping(address => uint256)) public contributions;

    // campaignId => (contributorAddress => hasContributed)
    mapping(uint256 => mapping(address => bool)) public hasContributed;

    // campaignId => (milestoneIndex => (contributorAddress => hasVoted))
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public milestoneVotes;

    // 7. ประวัติธุรกรรมความโปร่งใสทางการเงิน (Funding Transparency Log)
    struct FinancialLog {
        string logType;           // "CONTRIBUTE", "REFUND", "RELEASE"
        address actor;            // ผู้ทำรายการ
        uint256 amount;           // จำนวนเงิน (Wei)
        uint256 milestoneIndex;   // ดัชนี Milestone (ถ้ามี)
        uint256 timestamp;
    }
    mapping(uint256 => FinancialLog[]) private campaignFinancialLogs;

    // Events
    event CampaignCreated(uint256 indexed campaignId, string title, address indexed creator, uint256 targetGoal, uint256 deadline);
    event ContributionReceived(uint256 indexed campaignId, address indexed contributor, uint256 amount, uint256 totalRaised);
    event MilestoneReleaseRequested(uint256 indexed campaignId, uint256 indexed milestoneIndex, string evidence);
    event MilestoneApproved(uint256 indexed campaignId, uint256 indexed milestoneIndex, address indexed voter, uint256 currentVotes);
    event MilestoneFundsReleased(uint256 indexed campaignId, uint256 indexed milestoneIndex, uint256 amount, address indexed creator);
    event RefundClaimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);

    // =========================================================================
    // 1. สร้างโครงการระดมทุน (Create Campaign)
    // =========================================================================
    function createCampaign(
        string memory _title,
        uint256 _targetGoal,
        uint256 _durationInSeconds,
        string[] memory _milestoneDescs,
        uint256[] memory _milestoneAmounts
    ) external returns (uint256) {
        require(bytes(_title).length > 0, "Title is required");
        require(_targetGoal > 0, "Target goal must be greater than 0");
        require(_durationInSeconds >= 60, "Duration must be at least 60 seconds");
        require(_milestoneDescs.length > 0, "At least 1 milestone is required");
        require(_milestoneDescs.length == _milestoneAmounts.length, "Milestone counts mismatch");

        // กฎทางธุรกิจสำคัญ: ยอดเงินของทุก Milestone รวมกันต้องเท่ากับเป้าหมายเงินทุนที่จัดสรรไว้
        uint256 totalMilestoneSum = 0;
        for (uint256 i = 0; i < _milestoneAmounts.length; i++) {
            require(_milestoneAmounts[i] > 0, "Milestone amount must be > 0");
            totalMilestoneSum += _milestoneAmounts[i];
        }
        require(totalMilestoneSum == _targetGoal, "Sum of milestone funds must equal target goal");

        uint256 campId = nextCampaignId++;
        uint256 deadlineTime = block.timestamp + _durationInSeconds;

        campaigns[campId] = Campaign({
            id: campId,
            title: _title,
            creator: payable(msg.sender),
            targetGoal: _targetGoal,
            deadline: deadlineTime,
            raisedAmount: 0,
            totalContributors: 0,
            currentMilestone: 0,
            milestoneCount: _milestoneDescs.length,
            exists: true
        });

        for (uint256 i = 0; i < _milestoneDescs.length; i++) {
            campaignMilestones[campId].push(Milestone({
                description: _milestoneDescs[i],
                targetAmount: _milestoneAmounts[i],
                evidence: "",
                approvalCount: 0,
                isRequested: false,
                isPaid: false,
                paidAt: 0
            }));
        }

        emit CampaignCreated(campId, _title, msg.sender, _targetGoal, deadlineTime);
        return campId;
    }

    // =========================================================================
    // 2. สนับสนุนเงินทุน (Contribute Funds)
    // =========================================================================
    function contribute(uint256 _campaignId) external payable {
        Campaign storage camp = campaigns[_campaignId];
        require(camp.exists, "Campaign does not exist");
        require(block.timestamp < camp.deadline, "Funding deadline has passed");
        require(msg.value > 0, "Contribution must be greater than 0");

        if (!hasContributed[_campaignId][msg.sender]) {
            hasContributed[_campaignId][msg.sender] = true;
            camp.totalContributors++;
        }

        contributions[_campaignId][msg.sender] += msg.value;
        camp.raisedAmount += msg.value;

        campaignFinancialLogs[_campaignId].push(FinancialLog({
            logType: "CONTRIBUTE",
            actor: msg.sender,
            amount: msg.value,
            milestoneIndex: 0,
            timestamp: block.timestamp
        }));

        emit ContributionReceived(_campaignId, msg.sender, msg.value, camp.raisedAmount);
    }

    // =========================================================================
    // 3. ตรวจสอบยอดระดมทุน (Track Funding Progress)
    // =========================================================================
    function getCampaignProgress(uint256 _campaignId)
        external
        view
        returns (
            string memory title,
            address creator,
            uint256 targetGoal,
            uint256 deadline,
            uint256 raisedAmount,
            uint256 totalContributors,
            uint256 currentMilestone,
            uint256 milestoneCount,
            bool isGoalReached,
            bool isExpired
        )
    {
        Campaign storage camp = campaigns[_campaignId];
        require(camp.exists, "Campaign does not exist");

        return (
            camp.title,
            camp.creator,
            camp.targetGoal,
            camp.deadline,
            camp.raisedAmount,
            camp.totalContributors,
            camp.currentMilestone,
            camp.milestoneCount,
            camp.raisedAmount >= camp.targetGoal,
            block.timestamp >= camp.deadline
        );
    }

    // =========================================================================
    // 4. ขอเบิกเงินตาม Milestone (Request Fund Release)
    // =========================================================================
    function requestMilestoneRelease(
        uint256 _campaignId,
        uint256 _milestoneIndex,
        string memory _evidence
    ) external {
        Campaign storage camp = campaigns[_campaignId];
        require(camp.exists, "Campaign does not exist");
        require(msg.sender == camp.creator, "Only campaign creator can request release");
        require(camp.raisedAmount >= camp.targetGoal, "Funding goal not reached");
        require(_milestoneIndex < camp.milestoneCount, "Invalid milestone index");
        require(_milestoneIndex == camp.currentMilestone, "Must complete milestones in sequence");

        Milestone storage m = campaignMilestones[_campaignId][_milestoneIndex];
        require(!m.isPaid, "Milestone funds already released");
        require(!m.isRequested, "Milestone release already requested");
        require(bytes(_evidence).length > 0, "Evidence of completion is required");

        m.evidence = _evidence;
        m.isRequested = true;

        emit MilestoneReleaseRequested(_campaignId, _milestoneIndex, _evidence);
    }

    // =========================================================================
    // 5. อนุมัติการจ่ายเงิน (Approve Milestone)
    // =========================================================================
    function approveMilestone(uint256 _campaignId, uint256 _milestoneIndex) external {
        Campaign storage camp = campaigns[_campaignId];
        require(camp.exists, "Campaign does not exist");
        require(hasContributed[_campaignId][msg.sender], "Only contributors can approve milestone");
        require(_milestoneIndex < camp.milestoneCount, "Invalid milestone index");

        Milestone storage m = campaignMilestones[_campaignId][_milestoneIndex];
        require(m.isRequested, "Milestone release has not been requested yet");
        require(!m.isPaid, "Milestone funds already paid");
        require(!milestoneVotes[_campaignId][_milestoneIndex][msg.sender], "You have already voted on this milestone");

        milestoneVotes[_campaignId][_milestoneIndex][msg.sender] = true;
        m.approvalCount++;

        emit MilestoneApproved(_campaignId, _milestoneIndex, msg.sender, m.approvalCount);

        // เกณฑ์อนุมัติ: คะแนนเห็นชอบเกิน 50% ของผู้สนับสนุนทั้งหมด (> totalContributors / 2)
        if (m.approvalCount > (camp.totalContributors / 2)) {
            m.isPaid = true;
            m.paidAt = block.timestamp;
            camp.currentMilestone++;

            // โอนเงินของ Milestone ให้เจ้าของโครงการ
            camp.creator.transfer(m.targetAmount);

            campaignFinancialLogs[_campaignId].push(FinancialLog({
                logType: "RELEASE",
                actor: camp.creator,
                amount: m.targetAmount,
                milestoneIndex: _milestoneIndex + 1,
                timestamp: block.timestamp
            }));

            emit MilestoneFundsReleased(_campaignId, _milestoneIndex, m.targetAmount, camp.creator);
        }
    }

    // =========================================================================
    // 6. คืนเงินกรณีไม่สำเร็จ (Refund Contribution)
    // =========================================================================
    function claimRefund(uint256 _campaignId) external {
        Campaign storage camp = campaigns[_campaignId];
        require(camp.exists, "Campaign does not exist");
        require(block.timestamp >= camp.deadline, "Funding period has not ended yet");
        require(camp.raisedAmount < camp.targetGoal, "Funding goal reached, refund not available");

        uint256 contributedAmount = contributions[_campaignId][msg.sender];
        require(contributedAmount > 0, "No funds to refund");

        contributions[_campaignId][msg.sender] = 0;

        payable(msg.sender).transfer(contributedAmount);

        campaignFinancialLogs[_campaignId].push(FinancialLog({
            logType: "REFUND",
            actor: msg.sender,
            amount: contributedAmount,
            milestoneIndex: 0,
            timestamp: block.timestamp
        }));

        emit RefundClaimed(_campaignId, msg.sender, contributedAmount);
    }

    // =========================================================================
    // 7. ความโปร่งใสทางการเงิน (Funding Transparency Dashboard & Helpers)
    // =========================================================================
    function getMilestones(uint256 _campaignId)
        external
        view
        returns (
            string[] memory descriptions,
            uint256[] memory targetAmounts,
            string[] memory evidences,
            uint256[] memory approvalCounts,
            bool[] memory isRequesteds,
            bool[] memory isPaids
        )
    {
        Milestone[] storage list = campaignMilestones[_campaignId];
        uint256 len = list.length;

        descriptions = new string[](len);
        targetAmounts = new uint256[](len);
        evidences = new string[](len);
        approvalCounts = new uint256[](len);
        isRequesteds = new bool[](len);
        isPaids = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            descriptions[i] = list[i].description;
            targetAmounts[i] = list[i].targetAmount;
            evidences[i] = list[i].evidence;
            approvalCounts[i] = list[i].approvalCount;
            isRequesteds[i] = list[i].isRequested;
            isPaids[i] = list[i].isPaid;
        }
    }

    function getFinancialLogs(uint256 _campaignId)
        external
        view
        returns (
            string[] memory types,
            address[] memory actors,
            uint256[] memory amounts,
            uint256[] memory milestoneIndexes,
            uint256[] memory timestamps
        )
    {
        FinancialLog[] storage logs = campaignFinancialLogs[_campaignId];
        uint256 len = logs.length;

        types = new string[](len);
        actors = new address[](len);
        amounts = new uint256[](len);
        milestoneIndexes = new uint256[](len);
        timestamps = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            types[i] = logs[i].logType;
            actors[i] = logs[i].actor;
            amounts[i] = logs[i].amount;
            milestoneIndexes[i] = logs[i].milestoneIndex;
            timestamps[i] = logs[i].timestamp;
        }
    }

    function hasVotedOnMilestone(uint256 _campaignId, uint256 _milestoneIndex, address _voter)
        external
        view
        returns (bool)
    {
        return milestoneVotes[_campaignId][_milestoneIndex][_voter];
    }
}
