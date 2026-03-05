// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../DefifaGovernor.sol";
import "../DefifaDeployer.sol";
import "../DefifaHook.sol";
import "../DefifaTokenUriResolver.sol";
import "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";

import {JBMetadataResolver} from "@bananapus/core-v5/src/libraries/JBMetadataResolver.sol";
import {MetadataResolverHelper} from "@bananapus/core-v5/test/helpers/MetadataResolverHelper.sol";
import "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v5/test/helpers/JBTest.sol";
import "@bananapus/core-v5/src/libraries/JBRulesetMetadataResolver.sol";
import "@bananapus/721-hook-v5/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";

/// @title DefifaNoContestTest
/// @notice Tests for the NO_CONTEST safety mechanisms: minParticipation threshold and scorecardTimeout.
contract DefifaNoContestTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    // Shared test state
    uint256 _pid;
    DefifaHook _nft;
    DefifaGovernor _gov;
    address[] _users;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0, duration: 10 days, weight: 1e18, weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0, cashOutTaxRate: 0, baseCurrency: JBCurrencyIds.ETH,
                pausePay: false, pauseCreditTransfers: false, allowOwnerMinting: false,
                allowSetCustomToken: false, allowTerminalMigration: false, allowSetTerminals: false,
                allowSetController: false, allowAddAccountingContext: false, allowAddPriceFeed: false,
                ownerMustSendPayouts: false, holdFees: false, useTotalSurplusForCashOuts: false,
                useDataHookForPay: true, useDataHookForCashOut: true, dataHook: address(0), metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0), fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount = address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(jbDirectory(), IERC20(_defifaProjectTokenAccount), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook), new DefifaTokenUriResolver(ITypeface(address(0))), governor,
            jbController(), new JBAddressRegistry(), _protocolFeeProjectId, _defifaProjectId
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // MIN PARTICIPATION THRESHOLD
    // =========================================================================

    /// @notice Game with balance below minParticipation returns NO_CONTEST.
    function testMinParticipation_belowThreshold_noContest() external {
        // Set threshold to 5 ETH, but only mint 1 ETH total
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 5 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // Mint 1 token at 1 ETH — pot = 1 ETH < 5 ETH threshold
        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        // Advance to scoring phase
        _toScoring();

        // Should be NO_CONTEST, not SCORING
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "phase should be NO_CONTEST");
    }

    /// @notice Game with balance at or above minParticipation proceeds to SCORING.
    function testMinParticipation_atThreshold_scoring() external {
        // Set threshold to 4 ETH, mint exactly 4 ETH
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 4 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();

        // Balance = 4 ETH >= 4 ETH threshold → SCORING
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "phase should be SCORING");
    }

    /// @notice Cash-out during NO_CONTEST (from threshold) returns mint price after triggering.
    function testMinParticipation_cashOutReturnsMintPrice() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 10 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](2);
        _users[0] = _addr(0);
        _users[1] = _addr(1);
        _mint(_users[0], 1, 1 ether);
        _mint(_users[1], 2, 1 ether);

        _toScoring();

        // Confirm NO_CONTEST
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Trigger no-contest to queue a ruleset without payout limits (anyone can call this)
        deployer.triggerNoContestFor(_pid);

        // Still NO_CONTEST after trigger
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Cash out should return exactly 1 ETH (mint price)
        uint256 balBefore = _users[0].balance;
        _refund(_users[0], 1);
        uint256 received = _users[0].balance - balBefore;
        assertEq(received, 1 ether, "should receive exact mint price");
        assertEq(_nft.balanceOf(_users[0]), 0, "NFT should be burned");
    }

    /// @notice Refunds during REFUND phase can push balance below threshold, triggering NO_CONTEST when SCORING starts.
    function testMinParticipation_refundPushesBelow() external {
        // 4 tiers at 1 ETH, threshold 3 ETH
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 3 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        // During MINT, pot = 4 ETH > 3 ETH threshold
        // Refund 2 users during MINT phase (balance drops to 2 ETH)
        _refund(_users[2], 3);
        _refund(_users[3], 4);

        _toScoring();

        // Now balance = 2 ETH < 3 ETH threshold → NO_CONTEST
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "refunds push below threshold");
    }

    /// @notice minParticipation = 0 means the check is disabled.
    function testMinParticipation_zeroDisabled() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // Mint only 1 token (very low participation)
        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);
        _delegateSelf(_users[0], 1);

        _toScoring();

        // With threshold = 0, game proceeds to SCORING regardless
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "should be SCORING when threshold disabled");
    }

    // =========================================================================
    // SCORECARD TIMEOUT
    // =========================================================================

    /// @notice Game enters NO_CONTEST after scorecardTimeout elapses without ratification.
    function testScorecardTimeout_elapsed_noContest() external {
        // 30-day timeout
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 30 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();

        // Still within timeout → SCORING
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "should be SCORING before timeout");

        // Warp past the timeout
        vm.warp(block.timestamp + 30 days + 1);

        // Now NO_CONTEST
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "should be NO_CONTEST after timeout");
    }

    /// @notice Game at exactly the timeout boundary is still SCORING.
    function testScorecardTimeout_exactBoundary_scoring() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 30 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        // Advance exactly to scoring start
        vm.warp(d.start);

        // At exactly scoringStart + timeout, block.timestamp == start + timeout, so NOT >
        vm.warp(d.start + 30 days);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "should be SCORING at exact boundary");

        // One second later → NO_CONTEST
        vm.warp(d.start + 30 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "should be NO_CONTEST one second after");
    }

    /// @notice Cash-out during NO_CONTEST (from timeout) returns mint price after triggering.
    function testScorecardTimeout_cashOutReturnsMintPrice() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        // Warp past scoring start + timeout
        vm.warp(d.start + 7 days + 1);

        // Confirm NO_CONTEST
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Trigger no-contest to unlock refunds
        deployer.triggerNoContestFor(_pid);

        // Cash out all users — each should get 1 ETH back
        for (uint256 i; i < 4; i++) {
            uint256 balBefore = _users[i].balance;
            _refund(_users[i], i + 1);
            uint256 received = _users[i].balance - balBefore;
            assertEq(received, 1 ether, "should receive exact mint price");
            assertEq(_nft.balanceOf(_users[i]), 0, "NFT should be burned");
        }
    }

    /// @notice scorecardTimeout = 0 means the check is disabled.
    function testScorecardTimeout_zeroDisabled() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();

        // Warp very far forward (1 year) — should still be SCORING
        vm.warp(block.timestamp + 365 days);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "should be SCORING forever when timeout disabled");
    }

    // =========================================================================
    // SCORECARD BLOCKED DURING NO_CONTEST
    // =========================================================================

    /// @notice setTierCashOutWeightsTo reverts during NO_CONTEST (requires SCORING).
    function testNoContest_scorecardBlocked() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        // Submit and attest to a scorecard while still in SCORING
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 4;
        }
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);

        // Now warp past timeout → NO_CONTEST
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Attempting to ratify should revert because setTierCashOutWeightsTo checks for SCORING phase
        vm.expectRevert(DefifaHook.DefifaHook_GameIsntScoringYet.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // RATIFICATION BEFORE TIMEOUT PREVENTS NO_CONTEST
    // =========================================================================

    /// @notice If scorecard is ratified before timeout, game becomes COMPLETE (not NO_CONTEST).
    function testScorecardTimeout_ratifiedBeforeTimeout_complete() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 30 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();

        // Ratify a scorecard before timeout
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 4;
        }
        _attestAndRatify(sc);

        // Should be COMPLETE, not SCORING or NO_CONTEST
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE), "should be COMPLETE");

        // Even after timeout elapses, stays COMPLETE (cashOutWeightIsSet is checked first)
        vm.warp(d.start + 30 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE), "should stay COMPLETE after timeout");
    }

    // =========================================================================
    // BOTH MECHANISMS COMBINED
    // =========================================================================

    /// @notice When both are set, minParticipation triggers first if balance is low.
    function testBothMechanisms_thresholdTriggersFirst() external {
        // Threshold: 10 ETH, Timeout: 90 days — but only mint 1 ETH
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 10 ether, uint32(90 days));
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        _toScoring();

        // Threshold triggers NO_CONTEST immediately (no need to wait for timeout)
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "threshold should trigger NO_CONTEST");
    }

    /// @notice When both set and balance is above threshold, timeout triggers eventually.
    function testBothMechanisms_timeoutTriggersIfThresholdMet() external {
        // Threshold: 2 ETH, Timeout: 7 days — mint 4 ETH
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 2 ether, uint32(7 days));
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();

        // Balance = 4 ETH > 2 ETH threshold → SCORING
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING), "should be SCORING");

        // After timeout → NO_CONTEST
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "timeout should trigger NO_CONTEST");
    }

    // =========================================================================
    // BACKWARD COMPATIBILITY
    // =========================================================================

    /// @notice Both mechanisms disabled (0) — game functions exactly as before.
    function testBackwardCompat_noSafetyMechanisms() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // Full lifecycle: submit scorecard, attest, ratify, cash out
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 4;
        }
        _attestAndRatify(sc);

        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Cash out all users
        uint256 totalOut;
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], i + 1, 1);
            totalOut += _users[i].balance - bb;
        }
        assertGt(totalOut, 0, "should receive ETH");
    }

    // =========================================================================
    // SAFETY PARAMS VIEW
    // =========================================================================

    /// @notice safetyParamsOf returns the stored parameters.
    function testSafetyParamsOf() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 42 ether, uint32(90 days));
        (_pid, _nft, _gov) = _launch(d);

        (uint256 minP, uint32 timeout) = deployer.safetyParamsOf(_pid);
        assertEq(minP, 42 ether, "minParticipation should match");
        assertEq(timeout, uint32(90 days), "scorecardTimeout should match");
    }

    /// @notice safetyParamsOf returns 0s when not set.
    function testSafetyParamsOf_defaults() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 0);
        (_pid, _nft, _gov) = _launch(d);

        (uint256 minP, uint32 timeout) = deployer.safetyParamsOf(_pid);
        assertEq(minP, 0, "default minParticipation should be 0");
        assertEq(timeout, 0, "default scorecardTimeout should be 0");
    }

    // =========================================================================
    // FUND CONSERVATION DURING NO_CONTEST
    // =========================================================================

    /// @notice All users can refund at mint price during NO_CONTEST — no funds stuck.
    function testNoContest_allUsersCanRefund() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 2 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 2 ether);
            vm.warp(block.timestamp + 1);
        }

        // Warp past timeout
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Trigger no-contest to unlock refunds
        deployer.triggerNoContestFor(_pid);

        // All users refund
        uint256 totalRefunded;
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _refund(_users[i], i + 1);
            uint256 received = _users[i].balance - bb;
            assertEq(received, 2 ether, "each user gets exact mint price back");
            totalRefunded += received;
        }
        assertEq(totalRefunded, 8 ether, "total refunded = total minted");
    }

    // =========================================================================
    // PHASE TRANSITIONS: NO_CONTEST only during SCORING phase window
    // =========================================================================

    /// @notice During COUNTDOWN, MINT, and REFUND phases, NO_CONTEST is not returned even if threshold/timeout would trigger.
    function testNoContest_onlyDuringScoringWindow() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 100 ether, uint32(1));
        (_pid, _nft, _gov) = _launch(d);

        // COUNTDOWN
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COUNTDOWN), "should be COUNTDOWN");

        // MINT
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT), "should be MINT");

        // REFUND (warp past mint duration)
        vm.warp(d.start - d.refundPeriodDuration);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.REFUND), "should be REFUND");
    }

    // =========================================================================
    // TRIGGER NO_CONTEST MECHANISM
    // =========================================================================

    /// @notice triggerNoContestFor reverts when the game is not in NO_CONTEST phase.
    function testTriggerNoContest_revertsWhenNotNoContest() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // Should revert since the game is SCORING, not NO_CONTEST
        vm.expectRevert(DefifaDeployer.DefifaDeployer_NotNoContest.selector);
        deployer.triggerNoContestFor(_pid);
    }

    /// @notice triggerNoContestFor reverts when called twice.
    function testTriggerNoContest_revertsWhenAlreadyTriggered() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // First trigger succeeds
        deployer.triggerNoContestFor(_pid);

        // Second trigger reverts
        vm.expectRevert(DefifaDeployer.DefifaDeployer_NoContestAlreadyTriggered.selector);
        deployer.triggerNoContestFor(_pid);
    }

    /// @notice Cash-out before triggerNoContestFor reverts with NOTHING_TO_CLAIM (surplus = 0).
    function testNoContest_cashOutBeforeTrigger_reverts() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 10 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Build the cash-out metadata inline so vm.expectRevert is right before the terminal call
        uint256[] memory cid = new uint256[](1);
        JB721Tier memory tier = _nft.store().tierOf(address(_nft), 1, false);
        uint256 nb = _nft.store().numberOfBurnedFor(address(_nft), 1);
        uint256 tnum = tier.initialSupply - tier.remainingSupply + nb;
        cid[0] = (1 * 1_000_000_000) + tnum;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes memory meta = metadataHelper().createMetadata(ids, data);

        // Cash out should revert before trigger (surplus = 0 on SCORING ruleset)
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_NothingToClaim.selector);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: _users[0], projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(_users[0]), metadata: meta
        });
    }

    // =========================================================================
    // RATIFIED SCORECARD: PREVENTS NO_CONTEST FOREVER + CASH-OUTS WORK FOREVER
    // =========================================================================

    /// @notice After scorecard ratification and commitment fulfillment, cash-outs work at ratified values
    /// even long after the timeout would have elapsed. NO_CONTEST never occurs.
    function testRatifiedScorecard_cashOutsWorkForever() external {
        // Set a 7-day timeout, but we'll ratify before it
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // Ratify scorecard: equal distribution (25% each)
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 4;
        }
        _attestAndRatify(sc);

        // Should be COMPLETE
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Fulfill commitments (sends payouts and queues final ruleset)
        deployer.fulfillCommitmentsOf(_pid);

        // Warp far past the timeout (1 year) — should STILL be COMPLETE, never NO_CONTEST
        vm.warp(block.timestamp + 365 days);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE), "should stay COMPLETE forever");

        // triggerNoContestFor should revert since we're COMPLETE, not NO_CONTEST
        vm.expectRevert(DefifaDeployer.DefifaDeployer_NotNoContest.selector);
        deployer.triggerNoContestFor(_pid);

        // Cash out user 0 — should receive their share (approximately 1 ETH minus fees)
        uint256 balBefore = _users[0].balance;
        _cashOut(_users[0], 1, 1);
        uint256 received = _users[0].balance - balBefore;
        assertGt(received, 0, "should receive ETH from ratified scorecard");

        // Cash out user 3 — should also work even after a very long time
        uint256 balBefore3 = _users[3].balance;
        _cashOut(_users[3], 4, 1);
        uint256 received3 = _users[3].balance - balBefore3;
        assertGt(received3, 0, "should still receive ETH long after timeout");
    }

    // =========================================================================
    // SETUP HELPERS
    // =========================================================================

    function _launchDataWith(uint8 n, uint256 tierPrice, uint256 minParticipation, uint32 scorecardTimeout)
        internal
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001, reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0), shouldUseReservedTokenBeneficiaryAsDefault: false, name: "DEFIFA"
            });
        }
        return DefifaLaunchProjectData({
            name: "DEFIFA", projectUri: "", contractUri: "", baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days, start: uint48(block.timestamp + 3 days), refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(), splits: new JBSplit[](0),
            attestationStartTime: 0, attestationGracePeriod: 100381,
            defaultAttestationDelegate: address(0), tierPrice: uint104(tierPrice), tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)), terminal: jbMultiTerminal(),
            minParticipation: minParticipation, scorecardTimeout: scorecardTimeout
        });
    }

    function _toScoring() internal {
        vm.warp(block.timestamp + 3 days + 1);
    }

    function _launch(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n, DefifaGovernor g) {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("su", i))));
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(_pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadataHelper().createMetadata(ids, data));
    }

    function _delegateSelf(address user, uint256 tid) internal {
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: tid});
        vm.prank(user);
        _nft.setTierDelegatesTo(dd);
    }

    function _buildScorecard(uint256 n) internal pure returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
        }
    }

    function _attestAndRatify(DefifaTierCashOutWeight[] memory sc) internal {
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(block.timestamp + 1);
    }

    function _attestAllFor(uint256 pid) internal {
        vm.warp(block.timestamp + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);
    }

    function _surplus() internal view returns (uint256) {
        return jbMultiTerminal().currentSurplusOf(
            _pid, jbMultiTerminal().accountingContextsOf(_pid), 18, JBCurrencyIds.ETH
        );
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: user, projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(user), metadata: meta
        });
    }

    function _cashOutMeta(uint256 tid, uint256 tnum) internal returns (bytes memory) {
        uint256[] memory cid = new uint256[](1);
        cid[0] = (tid * 1_000_000_000) + tnum;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }

    function _refund(address user, uint256 tid) internal {
        JB721Tier memory tier = _nft.store().tierOf(address(_nft), tid, false);
        uint256 nb = _nft.store().numberOfBurnedFor(address(_nft), tid);
        uint256 tnum = tier.initialSupply - tier.remainingSupply + nb;
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: user, projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(user), metadata: meta
        });
    }
}
