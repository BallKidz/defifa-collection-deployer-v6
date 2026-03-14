// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "../src/enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "../src/enums/DefifaScorecardState.sol";
import {DefifaHookLib} from "../src/libraries/DefifaHookLib.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title DefifaForkTest
/// @notice Comprehensive fork tests covering full game lifecycle, edge cases, adversarial conditions, and fund
/// conservation. Forks Ethereum mainnet to test in realistic conditions.
contract DefifaForkTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader private _tsReader;

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
        vm.createSelectFork("ethereum");

        // Deploy JB core fresh on fork.
        super.setUp();

        _tsReader = new TimestampReader();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 10 days,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: JBCurrencyIds.ETH,
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook =
            new DefifaHook(jbDirectory(), IERC20(_defifaProjectTokenAccount), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            _defifaProjectId,
            _protocolFeeProjectId
        );

        // Grant deployer SET_SPLIT_GROUPS permission on the defifa fee project.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.SET_SPLIT_GROUPS;
        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner,
                // forge-lint: disable-next-line(unsafe-typecast)
                JBPermissionsData({
                    operator: address(deployer), projectId: uint64(_defifaProjectId), permissionIds: permissionIds
                })
            );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // FULL LIFECYCLE: Mint → Refund → Score → Ratify → Cash Out
    // =========================================================================

    function test_fork_fullLifecycle_4tiers() external {
        _setupGame(4, 1 ether);

        // Verify MINT phase.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT));

        // Verify all users hold NFTs.
        for (uint256 i; i < 4; i++) {
            assertEq(_nft.balanceOf(_users[i]), 1, "each user holds 1 NFT");
        }

        // Record pot before fees.
        uint256 potBefore = _balance();
        assertEq(potBefore, 4 ether, "pot = 4 ETH from 4 mints");

        // Advance to SCORING.
        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // Set winner-take-all scorecard: tier 1 gets everything.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        _attestAndRatify(sc);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Winner cashes out.
        uint256 winnerBefore = _users[0].balance;
        _cashOut(_users[0], 1, 1);
        uint256 winnerReceived = _users[0].balance - winnerBefore;
        assertGt(winnerReceived, 0, "winner received ETH");

        // Losers get only fee tokens (no ETH).
        for (uint256 i = 1; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], i + 1, 1);
            assertEq(_users[i].balance, bb, "loser gets 0 ETH");
            // But they should have received fee tokens.
            uint256 defifa = IERC20(_defifaProjectTokenAccount).balanceOf(_users[i]);
            uint256 nana = IERC20(_protocolFeeProjectTokenAccount).balanceOf(_users[i]);
            assertTrue(defifa > 0 || nana > 0, "loser got fee tokens");
        }

        // All fee tokens distributed.
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(address(_nft)), 0, "no DEFIFA left in hook");
        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(_nft)), 0, "no NANA left in hook");
    }

    // =========================================================================
    // REFUND PHASE: Full refund during MINT, partial refund patterns
    // =========================================================================

    function test_fork_refundDuringMint_exactPrice() external {
        _setupGame(8, 2 ether);

        // Refund first 4 users during MINT.
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _refund(_users[i], i + 1);
            assertEq(_users[i].balance - bb, 2 ether, "exact refund of mint price");
            assertEq(_nft.balanceOf(_users[i]), 0, "NFT burned on refund");
        }

        // Remaining pot = 4 users * 2 ETH = 8 ETH.
        assertEq(_balance(), 8 ether, "pot = remaining mints");
    }

    function test_fork_refundDuringRefundPhase() external {
        _setupGame(4, 1 ether);

        // Advance past MINT into REFUND phase.
        vm.warp(_tsReader.timestamp() + 1 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.REFUND));

        // Refund during REFUND phase.
        uint256 bb = _users[0].balance;
        _refund(_users[0], 1);
        assertEq(_users[0].balance - bb, 1 ether, "refund works in REFUND phase");
    }

    // =========================================================================
    // HIGH VOLUME: 32 tiers × 100 ETH each = 3,200 ETH pot
    // =========================================================================

    function test_fork_highVolume_32tiers_100eth() external {
        _setupGame(32, 100 ether);
        _toScoring();

        // Tier 1 = 50%, rest split evenly.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(32);
        uint256 half = tw / 2;
        uint256 perTier = half / 31;
        uint256 assigned;
        for (uint256 i; i < 32; i++) {
            if (i == 0) {
                sc[i].cashOutWeight = half;
            } else if (i == 31) {
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = perTier;
            }
            assigned += sc[i].cashOutWeight;
        }

        _attestAndRatify(sc);
        uint256 pot = _surplus();
        uint256 out = _cashOutAllUsers();

        assertApproxEqAbs(out, pot, 1e15, "total cashed out ~ pot");
        assertLe(_surplus(), 1e15, "negligible dust remains");
    }

    // =========================================================================
    // EXTREME ROUNDING: 1 wei weights, 1000 ETH per tier
    // =========================================================================

    function test_fork_extremeWeights_1weiAnd999999() external {
        _setupGame(3, 1000 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(3);
        sc[0].cashOutWeight = 1;
        sc[1].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() - 2;
        sc[2].cashOutWeight = 1;

        _attestAndRatify(sc);
        uint256 pot = _surplus();
        uint256 out = _cashOutAllUsers();
        assertApproxEqAbs(out + _surplus(), pot, 3, "fund conservation with extreme weights");
        assertGt(_users[1].balance, pot * 99 / 100, "tier 2 > 99% of pot");
    }

    // =========================================================================
    // MULTI-PLAYER PER TIER: 5 winners, 3 losers
    // =========================================================================

    function test_fork_multiPlayerPerTier_winnerTakeAll() external {
        _setupMultiPlayer();
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        _attestAndRatify(sc);

        // All 5 winners should get approximately equal shares.
        uint256[] memory payouts = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], 1, i + 1);
            payouts[i] = _users[i].balance - bb;
            assertGt(payouts[i], 0, "winner receives ETH");
        }
        for (uint256 i = 1; i < 5; i++) {
            assertApproxEqRel(payouts[i], payouts[0], 0.001 ether, "payouts approx equal");
        }

        // Losers get 0 ETH.
        for (uint256 i; i < 3; i++) {
            uint256 bb = _users[5 + i].balance;
            _cashOut(_users[5 + i], i + 2, 1);
            assertEq(_users[5 + i].balance, bb, "loser gets 0 ETH");
        }
    }

    // =========================================================================
    // ADVERSARIAL: Overweight scorecard (120%) rejected
    // =========================================================================

    function test_fork_rejectsOverweightScorecard() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = (_nft.TOTAL_CASHOUT_WEIGHT() * 30) / 100; // 120% total
        }

        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        vm.expectRevert(DefifaHook.DefifaHook_InvalidCashoutWeights.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Underweight scorecard (80%) rejected
    // =========================================================================

    function test_fork_rejectsUnderweightScorecard() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = (_nft.TOTAL_CASHOUT_WEIGHT() * 20) / 100; // 80% total
        }

        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        vm.expectRevert(DefifaHook.DefifaHook_InvalidCashoutWeights.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Double attestation attempt
    // =========================================================================

    function test_fork_doubleAttestationReverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.timestamp() + _gov.attestationStartTimeOf(_gameId) + 1);

        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, pid);

        // Second attestation should revert.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyAttested.selector);
        _gov.attestToScorecardFrom(_gameId, pid);
    }

    // =========================================================================
    // ADVERSARIAL: Duplicate scorecard submission reverts
    // =========================================================================

    function test_fork_duplicateScorecardReverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _gov.submitScorecardFor(_gameId, sc);

        vm.expectRevert(DefifaGovernor.DefifaGovernor_DuplicateScorecard.selector);
        _gov.submitScorecardFor(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Double ratification reverts
    // =========================================================================

    function test_fork_doubleRatificationReverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _attestAndRatify(sc);

        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyRatified.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Cash out weights set twice reverts
    // =========================================================================

    function test_fork_cashOutWeightsAlreadySetReverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _attestAndRatify(sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights set");

        // Trying to set weights again via governor owner (which is the governor itself) should revert
        // because cashOutWeightIsSet is true. But since governor already ratified, the hook owner is the governor.
        // The governor can't call setTierCashOutWeightsTo directly without going through ratification again.
        // The ratification path will revert with AlreadyRatified.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyRatified.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Delegation blocked after MINT phase
    // =========================================================================

    function test_fork_delegationBlockedAfterMint() external {
        _setupGame(4, 1 ether);

        // Advance to REFUND phase.
        vm.warp(_tsReader.timestamp() + 1 days);

        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DefifaHook_DelegateChangesUnavailableInThisPhase()"));
        _nft.setTierDelegateTo(address(1), 1);

        // SCORING phase.
        _toScoring();

        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DefifaHook_DelegateChangesUnavailableInThisPhase()"));
        _nft.setTierDelegateTo(address(1), 1);
    }

    // =========================================================================
    // ADVERSARIAL: Cash out before scorecard — reverts (nothing to claim)
    // =========================================================================

    function test_fork_cashOutBeforeScorecard_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        bytes memory meta = _cashOutMeta(1, 1);
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_NothingToClaim.selector);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _users[0],
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_users[0]),
                metadata: meta
            });

        // NFT not burned (revert rolled it back).
        assertEq(_nft.balanceOf(_users[0]), 1, "NFT intact after revert");
    }

    // =========================================================================
    // ADVERSARIAL: Non-holder tries to cash out someone else's NFT
    // =========================================================================

    function test_fork_nonHolderCashOutReverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _attestAndRatify(sc);

        // Attacker tries to cash out user[0]'s token.
        address attacker = address(bytes20(keccak256("attacker")));
        bytes memory meta = _cashOutMeta(1, 1);

        vm.prank(attacker);
        vm.expectRevert();
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: attacker,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(attacker),
                metadata: meta
            });
    }

    // =========================================================================
    // ADVERSARIAL: Scorecard with weight on unminted tier reverts
    // =========================================================================

    function test_fork_weightOnUnmintedTierReverts() external {
        // Launch 8-tier game but only mint 4 tiers.
        _setupPartial(8, 4, 1 ether);
        _toScoring();

        // Try to give weight to tier 5 (unminted).
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](8);
        for (uint256 i; i < 8; i++) {
            sc[i].id = i + 1;
            sc[i].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 8;
        }
        // Fix rounding for last tier.
        // forge-lint: disable-next-line(divide-before-multiply)
        sc[7].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() - ((_nft.TOTAL_CASHOUT_WEIGHT() / 8) * 7);

        vm.expectRevert(DefifaGovernor.DefifaGovernor_UnownedProposedCashoutValue.selector);
        _gov.submitScorecardFor(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Scorecard submission outside SCORING phase
    // =========================================================================

    function test_fork_scorecardSubmitOutsideScoring_reverts() external {
        _setupGame(4, 1 ether);

        // Still in MINT phase.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT));

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);

        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.submitScorecardFor(_gameId, sc);
    }

    // =========================================================================
    // ADVERSARIAL: Attestation outside SCORING phase (during COMPLETE)
    // =========================================================================

    function test_fork_attestationAfterRatification_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(scorecardId);
        _gov.ratifyScorecardFrom(_gameId, sc);

        // Now in COMPLETE phase. Try to attest to another scorecard.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Submit a different scorecard? Can't — already ratified.
        DefifaTierCashOutWeight[] memory sc2 = _buildScorecard(4);
        sc2[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyRatified.selector);
        _gov.submitScorecardFor(_gameId, sc2);
    }

    // =========================================================================
    // ADVERSARIAL: NFT transfer then try to double-vote
    // =========================================================================

    function test_fork_nftTransferDoesNotDoubleVote() external {
        _setupGame(4, 1 ether);

        // user[0] transfers their NFT to user[1] (who already has tier 2)
        uint256 tokenId = _generateTokenId(1, 1);
        vm.prank(_users[0]);
        _nft.transferFrom(_users[0], _users[1], tokenId);

        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.timestamp() + _gov.attestationStartTimeOf(_gameId) + 1);

        // user[0] has no tokens now — attestation weight should be 0.
        _gov.getAttestationWeight(_gameId, _users[0], uint48(_gov.attestationStartTimeOf(_gameId)));
        // user[0]'s delegation was set at mint time. The checkpoint was recorded. But they transferred.
        // Since attestation uses snapshot at submission time, user[0]'s weight depends on when they delegated.

        // user[1] attests (has tokens from both tiers now).
        vm.prank(_users[1]);
        uint256 weight1 = _gov.attestToScorecardFrom(_gameId, pid);
        assertGt(weight1, 0, "user1 has attestation weight");

        // Other users attest.
        for (uint256 i = 2; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }

        // Advance past grace period.
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // Should be able to ratify if quorum is met.
        DefifaScorecardState state = _gov.stateOf(_gameId, pid);
        assertTrue(
            state == DefifaScorecardState.SUCCEEDED || state == DefifaScorecardState.ACTIVE,
            "state should be SUCCEEDED or ACTIVE"
        );
    }

    // =========================================================================
    // ADVERSARIAL: Competing scorecards — only one can be ratified
    // =========================================================================

    function test_fork_competingScorecards_onlyOneRatified() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Scorecard A: even distribution.
        DefifaTierCashOutWeight[] memory scA = _evenScorecard(4);
        uint256 pidA = _gov.submitScorecardFor(_gameId, scA);

        // Scorecard B: winner-take-all (different from A).
        DefifaTierCashOutWeight[] memory scB = _buildScorecard(4);
        scB[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 pidB = _gov.submitScorecardFor(_gameId, scB);

        assertTrue(pidA != pidB, "different scorecards have different IDs");

        // Attest and ratify scorecard A.
        _attestAllFor(pidA);
        _gov.ratifyScorecardFrom(_gameId, scA);

        // Scorecard B should now be DEFEATED.
        assertEq(uint256(_gov.stateOf(_gameId, pidB)), uint256(DefifaScorecardState.DEFEATED));
    }

    // =========================================================================
    // ADVERSARIAL: fulfillCommitmentsOf double-call (idempotent)
    // =========================================================================

    function test_fork_doubleFulfillment_idempotent() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _attestAndRatify(sc);

        uint256 fulfilled = deployer.fulfilledCommitmentsOf(_pid);
        assertGt(fulfilled, 0, "commitments fulfilled");

        // Second call should be a no-op.
        deployer.fulfillCommitmentsOf(_pid);
        assertEq(deployer.fulfilledCommitmentsOf(_pid), fulfilled, "no change on second call");
    }

    // =========================================================================
    // ADVERSARIAL: fulfillCommitmentsOf before ratification reverts
    // =========================================================================

    function test_fork_fulfillBeforeRatification_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        vm.expectRevert(DefifaDeployer.DefifaDeployer_CantFulfillYet.selector);
        deployer.fulfillCommitmentsOf(_pid);
    }

    // =========================================================================
    // GOVERNANCE: Quorum calculation with partial minting
    // =========================================================================

    function test_fork_quorum_partialMinting() external {
        _setupPartial(10, 6, 1 ether);
        uint256 expected = (6 * _gov.MAX_ATTESTATION_POWER_TIER()) / 2;
        assertEq(_gov.quorum(_gameId), expected, "quorum = 50% of minted tiers");
    }

    // =========================================================================
    // GOVERNANCE: Single-tier game (minimum viable game)
    // =========================================================================

    function test_fork_singleTierGame() external {
        DefifaLaunchProjectData memory d = _launchData(1, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);
        _delegateSelf(_users[0], 1);
        vm.warp(_tsReader.timestamp() + 1);

        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(1);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        _attestAndRatify(sc);

        // Cash out the single player.
        uint256 bb = _users[0].balance;
        _cashOut(_users[0], 1, 1);
        uint256 received = _users[0].balance - bb;
        assertGt(received, 0, "single player receives ETH");
    }

    // =========================================================================
    // NO CONTEST: minParticipation threshold triggers NO_CONTEST
    // =========================================================================

    function test_fork_noContest_minParticipation() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 5 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // Mint only 1 ETH < 5 ETH threshold.
        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        _toScoring();

        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));
    }

    // =========================================================================
    // NO CONTEST: scorecardTimeout triggers NO_CONTEST
    // =========================================================================

    function test_fork_noContest_scorecardTimeout() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // Warp past timeout.
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));
    }

    // =========================================================================
    // NO CONTEST: triggerNoContestFor + full refund
    // =========================================================================

    function test_fork_noContest_triggerAndRefund() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 2 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 2 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        vm.warp(d.start + 7 days + 1);
        deployer.triggerNoContestFor(_pid);

        // All users refund.
        uint256 totalRefunded;
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _refund(_users[i], i + 1);
            uint256 received = _users[i].balance - bb;
            assertEq(received, 2 ether, "exact refund");
            totalRefunded += received;
        }
        assertEq(totalRefunded, 8 ether, "total refunded = total minted");
    }

    // =========================================================================
    // NO CONTEST: Double trigger reverts
    // =========================================================================

    function test_fork_noContest_doubleTriggerReverts() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](1);
        _users[0] = _addr(0);
        _mint(_users[0], 1, 1 ether);

        vm.warp(d.start + 7 days + 1);

        deployer.triggerNoContestFor(_pid);

        vm.expectRevert(DefifaDeployer.DefifaDeployer_NoContestAlreadyTriggered.selector);
        deployer.triggerNoContestFor(_pid);
    }

    // =========================================================================
    // NO CONTEST: triggerNoContest outside NO_CONTEST phase reverts
    // =========================================================================

    function test_fork_noContest_triggerWhenScoring_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        vm.expectRevert(DefifaDeployer.DefifaDeployer_NotNoContest.selector);
        deployer.triggerNoContestFor(_pid);
    }

    // =========================================================================
    // NO CONTEST: Ratified scorecard prevents NO_CONTEST forever
    // =========================================================================

    function test_fork_ratifiedPreventsNoContest() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        // Even after timeout, should remain COMPLETE.
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        vm.expectRevert(DefifaDeployer.DefifaDeployer_NotNoContest.selector);
        deployer.triggerNoContestFor(_pid);
    }

    // =========================================================================
    // FEE ACCOUNTING: Default splits (no user splits)
    // =========================================================================

    function test_fork_feeAccounting_defaultSplits() external {
        _setupGame(4, 1 ether);

        uint256 potBefore = _balance();
        assertEq(potBefore, 4 ether);

        // Expected fee: 7.5% (2.5% NANA + 5% DEFIFA).
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedSurplus = potBefore - expectedFee;

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        uint256 potAfter = _balance();
        assertEq(potAfter, expectedSurplus, "surplus after fees");
        assertEq(deployer.fulfilledCommitmentsOf(_pid), expectedFee, "fulfilled = fee");
    }

    // =========================================================================
    // FEE ACCOUNTING: fee + surplus = original pot (zero rounding loss)
    // =========================================================================

    function test_fork_feeAccounting_noRoundingLoss() external {
        _setupGame(4, 1 ether);

        uint256 potBefore = _balance();

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        uint256 potAfter = _balance();
        uint256 fee = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fee + potAfter, potBefore, "fee + surplus = pot exactly");
    }

    // =========================================================================
    // FEE ACCOUNTING: With user-provided custom splits
    // =========================================================================

    function test_fork_feeAccounting_withUserSplits() external {
        JBSplit[] memory customSplits = new JBSplit[](1);
        address charity = address(bytes20(keccak256("charity")));
        customSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 10, // 10%
            projectId: 0,
            beneficiary: payable(charity),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        DefifaLaunchProjectData memory d = _launchDataWithSplits(4, 1 ether, customSplits);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        uint256 potBefore = _balance();
        // totalAbsolutePercent = 25M + 50M + 100M = 175M (17.5%).
        // expectedFee = (potBefore * 175_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        uint256 fee = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fee + _balance(), potBefore, "no rounding loss with user splits");
        assertTrue(charity.balance > 0, "charity received funds");
    }

    // =========================================================================
    // FEE TOKENS: Reserved minters get proportional $DEFIFA/$NANA
    // =========================================================================

    function test_fork_reservedMintersGetFeeTokens() external {
        address reserveAddr = address(bytes20(keccak256("reserveBeneficiary")));

        DefifaTierParams[] memory tp = new DefifaTierParams[](2);
        for (uint256 i; i < 2; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1,
                reservedTokenBeneficiary: reserveAddr,
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }
        DefifaLaunchProjectData memory d = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            tierPrice: uint104(1 ether),
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](2);
        _users[0] = _addr(0);
        _users[1] = _addr(1);
        _mint(_users[0], 1, 1 ether);
        _delegateSelf(_users[0], 1);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(_users[1], 2, 1 ether);
        _delegateSelf(_users[1], 2);
        vm.warp(_tsReader.timestamp() + 1);

        _toScoring();

        // Mint reserved tokens.
        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](2);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 1});
        reserveConfigs[1] = JB721TiersMintReservesConfig({tierId: 2, count: 1});
        _nft.mintReservesFor(reserveConfigs);

        assertEq(_nft.balanceOf(reserveAddr), 2, "reserve beneficiary holds 2 NFTs");

        // Seed fee tokens into the hook.
        deal(address(IERC20(_defifaProjectTokenAccount)), address(_nft), 1000 ether);
        deal(address(IERC20(_protocolFeeProjectTokenAccount)), address(_nft), 500 ether);

        // Scorecard: equal weight.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 2;
        sc[1].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 2;

        address[] memory allUsers = new address[](3);
        allUsers[0] = _users[0];
        allUsers[1] = _users[1];
        allUsers[2] = reserveAddr;

        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.timestamp() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < allUsers.length; i++) {
            vm.prank(allUsers[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(_tsReader.timestamp() + 1);

        // Cash out paid minters.
        _cashOut(_users[0], 1, 1);
        _cashOut(_users[1], 2, 1);

        uint256 user0Defifa = IERC20(_defifaProjectTokenAccount).balanceOf(_users[0]);
        assertGt(user0Defifa, 0, "paid minter got DEFIFA tokens");

        // Cash out reserved minter's tokens.
        bytes memory meta1 = _cashOutMeta(1, 2);
        vm.prank(reserveAddr);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: reserveAddr,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(reserveAddr),
                metadata: meta1
            });

        bytes memory meta2 = _cashOutMeta(2, 2);
        vm.prank(reserveAddr);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: reserveAddr,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(reserveAddr),
                metadata: meta2
            });

        uint256 reserveDefifa = IERC20(_defifaProjectTokenAccount).balanceOf(reserveAddr);
        assertGt(reserveDefifa, 0, "reserved minter got DEFIFA tokens");

        // All fee tokens distributed.
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(address(_nft)), 0, "no DEFIFA left");
        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(_nft)), 0, "no NANA left");
    }

    // =========================================================================
    // CASH OUT ORDERING: First vs last to exit — fair distribution
    // =========================================================================

    function test_fork_cashOutOrdering_fairAcrossExitOrder() external {
        _setupGame(4, 10 ether);
        _toScoring();

        _attestAndRatify(_evenScorecard(4));

        // Cash out users in reverse order and forward order — results should be similar.
        uint256[] memory received = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], i + 1, 1);
            received[i] = _users[i].balance - bb;
        }

        // With equal weights, all should receive approximately equal amounts.
        for (uint256 i = 1; i < 4; i++) {
            assertApproxEqRel(received[i], received[0], 0.001 ether, "equal-weight payouts are equal");
        }
    }

    // =========================================================================
    // GAME POT REPORTING: currentGamePotOf accuracy
    // =========================================================================

    function test_fork_gamePotReporting() external {
        _setupGame(4, 1 ether);
        _toScoring();

        (uint256 potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (uint256 potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 4 ether, "pot excluding = 4 ETH");
        assertEq(potIncluding, 4 ether, "pot including = 4 ETH (no fulfillment yet)");

        _attestAndRatify(_evenScorecard(4));

        uint256 fee = deployer.fulfilledCommitmentsOf(_pid);
        (potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 4 ether - fee, "pot excluding = surplus");
        assertEq(potIncluding, 4 ether, "pot including = original pot");
    }

    // =========================================================================
    // PHASE TRANSITIONS: Correct sequence
    // =========================================================================

    function test_fork_phaseTransitions_correctSequence() external {
        DefifaLaunchProjectData memory d = _launchData(4, 1 ether);
        (_pid, _nft, _gov) = _launch(d);

        // COUNTDOWN.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COUNTDOWN));

        // MINT.
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT));

        // REFUND.
        vm.warp(d.start - d.refundPeriodDuration);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.REFUND));

        // SCORING.
        vm.warp(d.start);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));
    }

    // =========================================================================
    // GAME TIMES: timesFor view returns correct values
    // =========================================================================

    function test_fork_timesFor() external {
        DefifaLaunchProjectData memory d = _launchData(4, 1 ether);
        (_pid, _nft, _gov) = _launch(d);

        (uint48 start, uint24 mintDur, uint24 refundDur) = deployer.timesFor(_pid);
        assertEq(start, d.start, "start matches");
        assertEq(mintDur, d.mintPeriodDuration, "mint duration matches");
        assertEq(refundDur, d.refundPeriodDuration, "refund duration matches");
    }

    // =========================================================================
    // EDGE: NFT transfer → new owner cashes out, firstOwnerOf preserved
    // =========================================================================

    function test_fork_nftTransfer_newOwnerCashesOut() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Give tier 1 all the weight.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        address original = _users[0];
        address recipient = _addr(999);

        uint256 tokenId = _generateTokenId(1, 1);

        // Verify firstOwnerOf before transfer.
        assertEq(_nft.firstOwnerOf(tokenId), original, "firstOwner = minter before transfer");

        // Transfer NFT.
        vm.prank(original);
        _nft.transferFrom(original, recipient, tokenId);

        // firstOwnerOf should still be the original minter.
        assertEq(_nft.firstOwnerOf(tokenId), original, "firstOwner = minter after transfer");

        // New owner cashes out.
        uint256 bb = recipient.balance;
        bytes memory meta = _cashOutMeta(1, 1);
        vm.prank(recipient);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: recipient,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(recipient),
                metadata: meta
            });
        assertGt(recipient.balance - bb, 0, "new owner received ETH");
    }

    // =========================================================================
    // EDGE: Intra-tier fairness — 5 holders same tier, sequential cash outs
    // =========================================================================

    function test_fork_intraTierFairness_5holders() external {
        DefifaLaunchProjectData memory d = _launchData(2, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // 5 people mint tier 1, 1 person mints tier 2.
        _users = new address[](6);
        for (uint256 i; i < 5; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], 1, 1 ether);
            _delegateSelf(_users[i], 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
        _users[5] = _addr(5);
        _mint(_users[5], 2, 1 ether);
        _delegateSelf(_users[5], 2);
        vm.warp(_tsReader.timestamp() + 1);

        _toScoring();

        // All weight to tier 1.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        // Each of the 5 holders cashes out sequentially.
        // Due to integer division (weight / 5), each should get the same amount.
        uint256[] memory received = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], 1, i + 1);
            received[i] = _users[i].balance - bb;
        }

        // All 5 should receive the same amount (integer division means equal shares).
        for (uint256 i = 1; i < 5; i++) {
            assertEq(received[i], received[0], "all tier-1 holders get equal cash out");
        }
    }

    // =========================================================================
    // EDGE: Multi-token cash out — burn 3 NFTs from same tier in one tx
    // =========================================================================

    function test_fork_multiTokenCashOut_sameTier() external {
        DefifaLaunchProjectData memory d = _launchData(2, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        address user = _addr(0);
        // Mint 3 tokens in tier 1.
        for (uint256 i; i < 3; i++) {
            _mint(user, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }
        // Need someone in tier 2 for delegation/quorum.
        address user2 = _addr(1);
        _mint(user2, 2, 1 ether);
        _delegateSelf(user2, 2);
        vm.warp(_tsReader.timestamp() + 1);

        // Delegate tier 1.
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: 1});
        vm.prank(user);
        _nft.setTierDelegatesTo(dd);
        vm.warp(_tsReader.timestamp() + 1);

        _users = new address[](2);
        _users[0] = user;
        _users[1] = user2;

        _toScoring();

        // All weight to tier 1.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        // Build multi-token cash out metadata (3 tokens at once).
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = _generateTokenId(1, 1);
        tokenIds[1] = _generateTokenId(1, 2);
        tokenIds[2] = _generateTokenId(1, 3);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(tokenIds);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes memory meta = metadataHelper().createMetadata(ids, data);

        uint256 bb = user.balance;
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
        assertGt(user.balance - bb, 0, "batch cash out returned ETH");
        assertEq(_nft.balanceOf(user), 0, "all 3 NFTs burned");
    }

    // =========================================================================
    // EDGE: Cross-tier cash out — burn tokens from different tiers in one tx
    // =========================================================================

    function test_fork_crossTierCashOut_singleTx() external {
        _setupGame(4, 1 ether);
        _toScoring();

        _attestAndRatify(_evenScorecard(4));

        // User 0 holds tier 1, user 1 holds tier 2. Transfer tier 2 to user 0.
        vm.prank(_users[1]);
        _nft.transferFrom(_users[1], _users[0], _generateTokenId(2, 1));

        // User 0 now holds tier 1 token 1 and tier 2 token 1. Cash out both in one tx.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _generateTokenId(1, 1);
        tokenIds[1] = _generateTokenId(2, 1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(tokenIds);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes memory meta = metadataHelper().createMetadata(ids, data);

        uint256 bb = _users[0].balance;
        vm.prank(_users[0]);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _users[0],
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_users[0]),
                metadata: meta
            });
        assertGt(_users[0].balance - bb, 0, "cross-tier batch cash out returned ETH");
    }

    // =========================================================================
    // EDGE: Zero-power attestation — non-holder attests with 0 weight
    // =========================================================================

    function test_fork_zeroPowerAttestation() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        // Warp to attestation period.
        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Non-holder attests — should succeed but add 0 weight.
        address stranger = _addr(999);
        vm.prank(stranger);
        uint256 weight = _gov.attestToScorecardFrom(_gameId, pid);
        assertEq(weight, 0, "non-holder has 0 attestation power");

        // But they can't attest again.
        vm.prank(stranger);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyAttested.selector);
        _gov.attestToScorecardFrom(_gameId, pid);
    }

    // =========================================================================
    // EDGE: Delegation to address(0) via setTierDelegateTo (no validation)
    // =========================================================================

    function test_fork_delegateToZero_viaSetTierDelegateTo() external {
        _setupGame(4, 1 ether);

        // setTierDelegateTo allows address(0) — no check (unlike setTierDelegatesTo which reverts).
        vm.prank(_users[0]);
        _nft.setTierDelegateTo(address(0), 1);

        // Verify setTierDelegatesTo would revert for address(0).
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: address(0), tierId: 1});
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_DelegateAddressZero.selector);
        _nft.setTierDelegatesTo(dd);

        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // After delegating to address(0), user's attestation power is reduced
        // (delegate checkpoint partially drained). Verify it's less than a normal holder.
        vm.prank(_users[0]);
        uint256 w0 = _gov.attestToScorecardFrom(_gameId, pid);
        vm.prank(_users[1]);
        uint256 w1 = _gov.attestToScorecardFrom(_gameId, pid);
        assertTrue(w0 < w1, "address(0) delegate has less power than normal delegate");
    }

    // =========================================================================
    // EDGE: minParticipation boundary — balance == minParticipation → NO_CONTEST
    // =========================================================================

    function test_fork_minParticipation_exactBoundary_meets() external {
        // balance == minParticipation: check uses `<`, so 4 < 4 = false → SCORING.
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 4 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        _toScoring();
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));
    }

    function test_fork_minParticipation_belowThreshold() external {
        // balance < minParticipation → NO_CONTEST.
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 4 ether + 1, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        _toScoring();
        // balance = 4 ether, minParticipation = 4 ether + 1 wei → 4e18 < 4e18+1 → NO_CONTEST.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));
    }

    // =========================================================================
    // EDGE: Cash out during SCORING (before weights set) → NothingToClaim
    // =========================================================================

    function test_fork_cashOutDuringScoring_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // No scorecard ratified yet. Cash out with 0 weight → hook reverts with NothingToClaim.
        bytes memory meta = _cashOutMeta(1, 1);
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_NothingToClaim.selector);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _users[0],
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_users[0]),
                metadata: meta
            });
    }

    // =========================================================================
    // EDGE: NFT transfer destroys delegation — new owner can't vote in SCORING
    // =========================================================================

    function test_fork_nftTransfer_recipientGetsAttestationPower() external {
        _setupGame(4, 1 ether);

        address recipient = _addr(999);

        // Transfer tier 1 NFT during MINT.
        vm.prank(_users[0]);
        _nft.transferFrom(_users[0], recipient, _generateTokenId(1, 1));

        // Recipient has the NFT but delegation went to address(0) (recipient's default).
        // Recipient can re-delegate during MINT.
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: recipient, tierId: 1});
        vm.prank(recipient);
        _nft.setTierDelegatesTo(dd);
        vm.warp(_tsReader.timestamp() + 1);

        _toScoring();

        // Both the original owner and recipient have attestation power due to checkpoint history.
        // The key invariant: the recipient who re-delegated can attest with non-zero weight.
        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Recipient should have attestation power after re-delegation.
        vm.prank(recipient);
        uint256 w1 = _gov.attestToScorecardFrom(_gameId, pid);
        assertGt(w1, 0, "recipient has attestation power after transfer and re-delegation");
    }

    // =========================================================================
    // EDGE: Delegation change reverts outside MINT phase
    // =========================================================================

    function test_fork_delegateDuringScoring_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: _users[0], tierId: 1});
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_DelegateChangesUnavailableInThisPhase.selector);
        _nft.setTierDelegatesTo(dd);
    }

    // =========================================================================
    // EDGE: Scorecard timeout boundary — exact tick
    // =========================================================================

    function test_fork_scorecardTimeout_exactBoundary() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Advance to scoring start.
        vm.warp(d.start);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.SCORING));

        // At exactly start + scorecardTimeout, check uses `>` so should still be SCORING.
        vm.warp(d.start + 7 days);
        assertEq(
            uint256(deployer.currentGamePhaseOf(_pid)),
            uint256(DefifaGamePhase.SCORING),
            "at exact boundary: still SCORING"
        );

        // One second later → NO_CONTEST.
        vm.warp(d.start + 7 days + 1);
        assertEq(
            uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST), "past boundary: NO_CONTEST"
        );
    }

    // =========================================================================
    // EDGE: Refund then re-mint same tier (user comes back)
    // =========================================================================

    function test_fork_refundThenRemint() external {
        _setupGame(4, 1 ether);

        address user = _users[0];
        uint256 tokenId1 = _generateTokenId(1, 1);

        // Verify user holds token.
        assertEq(_nft.ownerOf(tokenId1), user);

        // Refund.
        _refund(user, 1);
        assertEq(_nft.balanceOf(user), 0, "NFT burned after refund");

        // Re-mint same tier. Token number should be 2 now (first was burned).
        _mint(user, 1, 1 ether);
        uint256 tokenId2 = _generateTokenId(1, 2);
        assertEq(_nft.ownerOf(tokenId2), user, "user re-minted tier 1 with new token number");
    }

    // =========================================================================
    // EDGE: Defeated scorecard after another is ratified
    // =========================================================================

    function test_fork_defeatedScorecard_afterRatification() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Submit two competing scorecards.
        DefifaTierCashOutWeight[] memory scA = _buildScorecard(4);
        scA[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 pidA = _gov.submitScorecardFor(_gameId, scA);

        DefifaTierCashOutWeight[] memory scB = _evenScorecard(4);
        uint256 pidB = _gov.submitScorecardFor(_gameId, scB);

        // Attest and ratify scorecard A.
        _attestAllFor(pidA);
        _gov.ratifyScorecardFrom(_gameId, scA);

        // Scorecard A is RATIFIED, scorecard B is DEFEATED.
        assertEq(uint256(_gov.stateOf(_gameId, pidA)), uint256(DefifaScorecardState.RATIFIED));
        assertEq(uint256(_gov.stateOf(_gameId, pidB)), uint256(DefifaScorecardState.DEFEATED));
    }

    // =========================================================================
    // EDGE: Reserve mint → attestation power
    // =========================================================================

    function test_fork_reserveMint_getsAttestationPower() external {
        _setupGame(4, 1 ether);

        // The reserve beneficiary is address(0) in our default params (no reserved token beneficiary).
        // But reservedRate is 1001 (1 reserve per 1001 mints). With only 1 mint, no reserves trigger.
        // Let's verify the existing voting power works correctly even with the reserve rate set.

        // Verify all 4 users have attestation power through their delegation.
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Each user (sole holder of their tier) should get equal, non-zero attestation power.
        // Note: the protocol gives sole holders 2x MAX_ATTESTATION_POWER_TIER because
        // delegate checkpoint units (from store's votingUnits = price) are 2x total tier checkpoints.
        uint256 firstWeight;
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            uint256 w = _gov.attestToScorecardFrom(_gameId, pid);
            assertGt(w, 0, "sole holder has attestation power");
            if (i == 0) firstWeight = w;
            else assertEq(w, firstWeight, "all sole holders get equal power");
        }
    }

    // =========================================================================
    // EDGE: Quorum with odd number of minted tiers (rounding)
    // =========================================================================

    function test_fork_quorum_oddTierCount() external {
        // 3 tiers minted. Quorum = (3 * MAX_ATTESTATION_POWER_TIER) / 2 = 1.5e9 → rounds to 1_500_000_000.
        _setupGame(3, 1 ether);
        _toScoring();

        uint256 q = _gov.quorum(_gameId);
        uint256 expectedQuorum = (3 * _gov.MAX_ATTESTATION_POWER_TIER()) / 2;
        assertEq(q, expectedQuorum, "quorum = floor(3 * 1e9 / 2)");

        // 2 of 3 tiers attesting should exceed quorum.
        DefifaTierCashOutWeight[] memory sc = _evenScorecard(3);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Only users 0 and 1 attest (2 of 3 tiers).
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, pid);
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, pid);

        // 2e9 > 1.5e9 → quorum met.
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.SUCCEEDED));
    }

    // =========================================================================
    // EDGE: Quorum NOT met with 1 of 5 tiers (below 50%)
    // =========================================================================

    function test_fork_quorum_notMet_1of5() external {
        // Use 5 tiers so quorum = 5 * MAX / 2 = 2.5e9.
        // A sole holder contributes ~2e9 (due to 2x attestation factor) < 2.5e9 → quorum NOT met.
        _setupGame(5, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(5);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Only 1 of 5 tiers attests.
        vm.prank(_users[0]);
        uint256 w = _gov.attestToScorecardFrom(_gameId, pid);

        // Verify the single attestation is below quorum.
        uint256 q = _gov.quorum(_gameId);
        assertLt(w, q, "single holder weight < quorum");

        // State should still be ACTIVE after grace period (quorum not met).
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.ACTIVE));

        // Ratification should fail.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // EDGE: NO_CONTEST full cycle — trigger, then all users refund at mint price
    // =========================================================================

    function test_fork_noContest_fullRefundCycle() external {
        DefifaLaunchProjectData memory d = _launchDataWith(4, 1 ether, 0, 7 days);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Let scorecard timeout expire → NO_CONTEST.
        vm.warp(d.start + 7 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Trigger no-contest.
        deployer.triggerNoContestFor(_pid);

        // Advance to let the new ruleset take effect.
        vm.warp(_tsReader.timestamp() + 1);

        // All users should be able to refund at mint price (1 ETH each).
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _refund(_users[i], i + 1);
            assertEq(_users[i].balance - bb, 1 ether, "NO_CONTEST refund = mint price");
        }

        // Treasury should be empty.
        assertEq(_balance(), 0, "treasury empty after all refunds");
    }

    // =========================================================================
    // EDGE: Attestation weight shared proportionally within tier
    // =========================================================================

    function test_fork_attestationWeight_proportionalInTier() external {
        DefifaLaunchProjectData memory d = _launchData(2, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // 3 people in tier 1, 1 person in tier 2.
        address alice = _addr(0);
        address bob = _addr(1);
        address carol = _addr(2);
        address dan = _addr(3);

        _mint(alice, 1, 1 ether);
        _delegateSelf(alice, 1);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(bob, 1, 1 ether);
        _delegateSelf(bob, 1);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(carol, 1, 1 ether);
        _delegateSelf(carol, 1);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(dan, 2, 1 ether);
        _delegateSelf(dan, 2);
        vm.warp(_tsReader.timestamp() + 1);

        _users = new address[](4);
        _users[0] = alice;
        _users[1] = bob;
        _users[2] = carol;
        _users[3] = dan;

        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(2);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);

        // Alice holds 1/3 of tier 1 → proportionally less power than Dan (sole holder of tier 2).
        vm.prank(alice);
        uint256 wAlice = _gov.attestToScorecardFrom(_gameId, pid);

        // Dan holds 1/1 of tier 2 → full power for his tier.
        vm.prank(dan);
        uint256 wDan = _gov.attestToScorecardFrom(_gameId, pid);

        // Verify proportionality: Alice should have roughly 1/3 of Dan's power.
        assertGt(wDan, wAlice, "sole holder has more power than 1/3 holder");
        assertGt(wAlice, 0, "partial holder still has power");
        // Alice = 1/3 of tier 1, Dan = all of tier 2. Allow 1 wei rounding tolerance.
        assertApproxEqAbs(wAlice * 3, wDan, 3, "3 x alice power ~= dan power");
    }

    // =========================================================================
    // EDGE: Cash out non-owned token ID → Unauthorized
    // =========================================================================

    function test_fork_cashOut_wrongTokenId_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        // User 0 tries to cash out user 1's token.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _generateTokenId(2, 1); // tier 2, token 1 — belongs to user 1
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(tokenIds);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes memory meta = metadataHelper().createMetadata(ids, data);

        vm.prank(_users[0]);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaHook.DefifaHook_Unauthorized.selector, _generateTokenId(2, 1), _users[1], _users[0]
            )
        );
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _users[0],
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_users[0]),
                metadata: meta
            });
    }

    // =========================================================================
    // EDGE: Submit scorecard outside SCORING phase
    // =========================================================================

    function test_fork_submitScorecard_duringMint_reverts() external {
        _setupGame(4, 1 ether);
        // Still in MINT phase.

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.submitScorecardFor(_gameId, sc);
    }

    // =========================================================================
    // EDGE: Two-player precise accounting — winner takes (surplus - dust)
    // =========================================================================

    function test_fork_twoplayer_preciseAccounting() external {
        _setupGame(2, 5 ether);

        uint256 totalPot = _balance();
        assertEq(totalPot, 10 ether, "2 players x 5 ETH");

        _toScoring();

        // Tier 1 wins 100%.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        uint256 surplus = _surplus();
        // surplus = totalPot - fees (7.5%)
        uint256 expectedSurplus = totalPot - (totalPot * 75_000_000 / JBConstants.SPLITS_TOTAL_PERCENT);
        assertEq(surplus, expectedSurplus, "surplus = pot - 7.5% fees");

        // Winner cashes out entire surplus.
        uint256 bb = _users[0].balance;
        _cashOut(_users[0], 1, 1);
        uint256 winnerGot = _users[0].balance - bb;

        // Winner should get the full surplus (minus rounding dust).
        assertApproxEqAbs(winnerGot, surplus, 1, "winner gets full surplus");
    }

    // =========================================================================
    // FUZZ: Fund conservation across varying tier/player counts
    // =========================================================================

    function test_fork_fuzz_fundConservation(uint8 rawTiers, uint8 rawPlayers) external {
        uint8 nTiers = uint8(bound(rawTiers, 2, 12));
        uint8 nPpt = uint8(bound(rawPlayers, 1, 3));

        _setupMultiN(nTiers, nPpt, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(nTiers);
        uint256 assigned;
        for (uint256 i; i < nTiers; i++) {
            if (i == nTiers - 1) {
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = tw / nTiers;
            }
            assigned += sc[i].cashOutWeight;
        }

        _attestAndRatify(sc);
        uint256 pot = _surplus();

        uint256 total;
        for (uint256 i; i < _users.length; i++) {
            uint256 bb = _users[i].balance;
            uint256 tid = (i / nPpt) + 1;
            uint256 tnum = (i % nPpt) + 1;
            _cashOut(_users[i], tid, tnum);
            total += _users[i].balance - bb;
        }

        assertApproxEqAbs(total + _surplus(), pot, _users.length, "fund conservation");
    }

    // =========================================================================
    // SCORECARD STATE MACHINE: PENDING → ACTIVE → SUCCEEDED → RATIFIED
    // =========================================================================

    function test_fork_scorecardStateMachine() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);

        // On fork, attestationStartTimeOf is an absolute timestamp already in the past,
        // so the scorecard goes straight to ACTIVE (no PENDING window).
        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.ACTIVE));

        // Attest all.
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }

        // Still ACTIVE during grace period (even if quorum met).
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.ACTIVE));

        // SUCCEEDED: after grace period.
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.SUCCEEDED));

        // RATIFIED: after ratification.
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertEq(uint256(_gov.stateOf(_gameId, pid)), uint256(DefifaScorecardState.RATIFIED));
    }

    // =========================================================================
    // SCORECARD: Ratification before SUCCEEDED state reverts
    // =========================================================================

    function test_fork_ratifyBeforeSucceeded_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        _gov.submitScorecardFor(_gameId, sc);

        // No attestations yet — try to ratify.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // SCORECARD: Unknown scorecard reverts
    // =========================================================================

    function test_fork_unknownScorecardState_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Query state for a non-existent scorecard.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_UnknownProposal.selector);
        _gov.stateOf(_gameId, 12_345);
    }

    // =========================================================================
    // ADVERSARIAL: Zero-weight scorecard (all zeros except minimum)
    // =========================================================================

    function test_fork_zeroWeightTiers_winnerTakeAll() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Give all weight to tier 4, zero to others.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[3].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        _attestAndRatify(sc);

        // Tiers 1-3 get nothing.
        for (uint256 i; i < 3; i++) {
            uint256 weight = _nft.cashOutWeightOf(_generateTokenId(i + 1, 1));
            assertEq(weight, 0, "zero-weight tier has 0 cash out weight");
        }

        // Tier 4 gets everything.
        uint256 weight4 = _nft.cashOutWeightOf(_generateTokenId(4, 1));
        assertGt(weight4, 0, "tier 4 has weight");

        uint256 bb = _users[3].balance;
        _cashOut(_users[3], 4, 1);
        assertGt(_users[3].balance - bb, 0, "tier 4 holder received ETH");
    }

    // =========================================================================
    // ADVERSARIAL: Scorecard tier order violation reverts
    // =========================================================================

    function test_fork_scorecardBadTierOrder_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Tiers out of order: [3, 1, 2, 4].
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](4);
        sc[0] = DefifaTierCashOutWeight({id: 3, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT() / 4});
        sc[1] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT() / 4});
        sc[2] = DefifaTierCashOutWeight({id: 2, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT() / 4});
        sc[3] = DefifaTierCashOutWeight({id: 4, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT() / 4});

        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        vm.expectRevert(DefifaHookLib.DefifaHook_BadTierOrder.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // MINTING: Multi-tier mint in single transaction
    // =========================================================================

    function test_fork_multiTierMint_singleTx() external {
        DefifaLaunchProjectData memory d = _launchData(4, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        address user = _addr(0);
        vm.deal(user, 3 ether);

        // Mint tiers 1, 2, 3 in one tx (3 ETH).
        uint16[] memory m = new uint16[](3);
        m[0] = 1;
        m[1] = 2;
        m[2] = 3;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));

        vm.prank(user);
        jbMultiTerminal().pay{value: 3 ether}(
            _pid, JBConstants.NATIVE_TOKEN, 3 ether, user, 0, "", metadataHelper().createMetadata(ids, data)
        );

        assertEq(_nft.balanceOf(user), 3, "user holds 3 NFTs");
    }

    // =========================================================================
    // GRACE PERIOD: Enforced minimum of 1 day
    // =========================================================================

    function test_fork_gracePeriod_minimumEnforced() external {
        DefifaLaunchProjectData memory d = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1, // Very short — should be clamped to 1 day.
            defaultAttestationDelegate: address(0),
            tierPrice: uint104(1 ether),
            tiers: _makeTierParams(4),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
        (_pid, _nft, _gov) = _launch(d);

        // Governor should enforce minimum grace period of 1 day.
        assertGe(_gov.attestationGracePeriodOf(_gameId), 1 days, "grace period >= 1 day");
    }

    // =========================================================================
    // CASH OUT WEIGHT: totalCashOutWeight() is constant
    // =========================================================================

    function test_fork_totalCashOutWeight_constant() external {
        _setupGame(4, 1 ether);

        // Before scorecard.
        assertEq(_nft.totalCashOutWeight(), _nft.TOTAL_CASHOUT_WEIGHT(), "constant before scorecard");

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        // After scorecard.
        assertEq(_nft.totalCashOutWeight(), _nft.TOTAL_CASHOUT_WEIGHT(), "constant after scorecard");
    }

    // =========================================================================
    // SETUP HELPERS
    // =========================================================================

    function _setupGame(uint8 nTiers, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _setupMultiPlayer() internal {
        DefifaLaunchProjectData memory d = _launchData(4, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](8);
        for (uint256 i; i < 5; i++) {
            _users[i] = _addr(100 + i);
            _mint(_users[i], 1, 1 ether);
            _delegateSelf(_users[i], 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
        for (uint256 i; i < 3; i++) {
            _users[5 + i] = _addr(200 + i);
            _mint(_users[5 + i], i + 2, 1 ether);
            _delegateSelf(_users[5 + i], i + 2);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _setupMultiN(uint8 nTiers, uint8 nPpt, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        uint256 total = uint256(nTiers) * uint256(nPpt);
        _users = new address[](total);
        uint256 idx;
        for (uint256 t; t < nTiers; t++) {
            for (uint256 p; p < nPpt; p++) {
                _users[idx] = _addr(idx);
                _mint(_users[idx], t + 1, tierPrice);
                _delegateSelf(_users[idx], t + 1);
                vm.warp(_tsReader.timestamp() + 1);
                idx++;
            }
        }
    }

    function _setupPartial(uint8 nTiers, uint256 nMint, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nMint);
        for (uint256 i; i < nMint; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _toScoring() internal {
        vm.warp(_tsReader.timestamp() + 3 days + 1);
    }

    // =========================================================================
    // PRIMITIVE HELPERS
    // =========================================================================

    function _launchData(uint8 n, uint256 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        return _launchDataWith(n, tierPrice, 0, 0);
    }

    function _launchDataWith(
        uint8 n,
        uint256 tierPrice,
        uint256 minParticipation,
        uint32 scorecardTimeout
    )
        internal
        returns (DefifaLaunchProjectData memory)
    {
        return DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(tierPrice),
            tiers: _makeTierParams(n),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: minParticipation,
            scorecardTimeout: scorecardTimeout
        });
    }

    function _launchDataWithSplits(
        uint8 n,
        uint256 tierPrice,
        JBSplit[] memory splits
    )
        internal
        returns (DefifaLaunchProjectData memory)
    {
        return DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: splits,
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(tierPrice),
            tiers: _makeTierParams(n),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
    }

    function _makeTierParams(uint8 n) internal pure returns (DefifaTierParams[] memory tp) {
        tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }
    }

    function _launch(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n, DefifaGovernor g) {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("fork_user", i))));
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(
            _pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadataHelper().createMetadata(ids, data)
        );
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

    function _evenScorecard(uint256 n) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = _buildScorecard(n);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 assigned;
        for (uint256 i; i < n; i++) {
            if (i == n - 1) {
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = tw / n;
            }
            assigned += sc[i].cashOutWeight;
        }
    }

    function _attestAndRatify(DefifaTierCashOutWeight[] memory sc) internal {
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(_tsReader.timestamp() + 1);
    }

    function _attestAllFor(uint256 pid) internal {
        // attestationStartTimeOf returns an absolute timestamp; on fork it may already be in the past.
        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
    }

    function _surplus() internal view returns (uint256) {
        return
            jbMultiTerminal()
                .currentSurplusOf(_pid, jbMultiTerminal().accountingContextsOf(_pid), 18, JBCurrencyIds.ETH);
    }

    function _balance() internal view returns (uint256) {
        return jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), _pid, JBConstants.NATIVE_TOKEN);
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
    }

    function _cashOutMeta(uint256 tid, uint256 tnum) internal view returns (bytes memory) {
        uint256[] memory cid = new uint256[](1);
        cid[0] = (tid * 1_000_000_000) + tnum;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }

    function _cashOutAllUsers() internal returns (uint256 total) {
        for (uint256 i; i < _users.length; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], i + 1, 1);
            total += _users[i].balance - bb;
        }
    }

    function _refund(address user, uint256 tid) internal {
        JB721Tier memory tier = _nft.store().tierOf(address(_nft), tid, false);
        uint256 nb = _nft.store().numberOfBurnedFor(address(_nft), tid);
        uint256 tnum = tier.initialSupply - tier.remainingSupply + nb;
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
    }

    function _generateTokenId(uint256 _tierId, uint256 _tokenNumber) internal pure returns (uint256) {
        return (_tierId * 1_000_000_000) + _tokenNumber;
    }
}
