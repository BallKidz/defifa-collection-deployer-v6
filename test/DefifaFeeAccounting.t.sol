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
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @notice Tests for PR #22 (M-D8): fee accounting after removing duplicate nana fee.
/// Verifies that only the fee portion of the pot is sent as payouts during fulfillment,
/// and the remaining balance stays as surplus for cash-outs.
contract DefifaFeeAccountingTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    uint256 _gameId = 3;

    function setUp() public virtual override {
        super.setUp();

        // Terminal configurations.
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
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

        // Launch the NANA fee project.
        _protocolFeeProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0));

        // Launch the Defifa fee project.
        _defifaProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        address _defifaToken = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        // Look up NANA token.
        address _nanaToken = address(jbTokens().tokenOf(_protocolFeeProjectId));

        hook = new DefifaHook(jbDirectory(), IERC20(_defifaToken), IERC20(_nanaToken));
        governor = new DefifaGovernor(jbController(), address(this));
        JBAddressRegistry _registry = new JBAddressRegistry();
        DefifaTokenUriResolver _tokenUriResolver = new DefifaTokenUriResolver(ITypeface(address(0)));
        deployer = new DefifaDeployer(
            address(hook),
            _tokenUriResolver,
            governor,
            jbController(),
            _registry,
            _defifaProjectId,
            _protocolFeeProjectId
        );

        // Grant the deployer SET_SPLIT_GROUPS permission on the defifa fee project.
        // This is needed so the deployer can set custom splits via controller.setSplitGroupsOf().
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

    // -----------------------------------------------------------------------
    // Test 1: Fee accounting with default splits (no user splits)
    // defifa = 5%, nana = 2.5%, total commitment = 7.5%
    // -----------------------------------------------------------------------
    function testFeeAccounting_defaultSplits() external {
        uint8 nTiers = 4;
        DefifaLaunchProjectData memory defifaData = _getBasicDefifaLaunchData(nTiers);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        // Mint phase: each user buys 1 NFT for 1 ETH.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        // Record pot before fulfillment.
        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        assertEq(potBefore, nTiers * 1 ether, "pot should be nTiers ETH");

        // Expected fee: pot * (5% + 2.5%) = pot * 7.5%
        // DEFIFA_FEE_DIVISOR = 20 -> 1_000_000_000 / 20 = 50_000_000 (5%)
        // BASE_PROTOCOL_FEE_DIVISOR = 40 -> 1_000_000_000 / 40 = 25_000_000 (2.5%)
        // totalAbsolutePercent = 75_000_000
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedSurplus = potBefore - expectedFee;

        // Advance through lifecycle and ratify scorecard.
        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);

        // Check balance after fulfillment (ratification triggers fulfillment).
        uint256 potAfter =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        assertEq(potAfter, expectedSurplus, "surplus after fees should be pot - feeAmount");
        assertEq(
            deployer.fulfilledCommitmentsOf(projectId), expectedFee, "fulfilledCommitmentsOf should equal fee amount"
        );

        // Verify currentGamePotOf reporting.
        (uint256 potExcluding,,) = deployer.currentGamePotOf(projectId, false);
        (uint256 potIncluding,,) = deployer.currentGamePotOf(projectId, true);
        assertEq(potExcluding, expectedSurplus, "pot excluding commitments = surplus");
        assertEq(potIncluding, expectedSurplus + expectedFee, "pot including commitments = original pot");
    }

    // -----------------------------------------------------------------------
    // Test 2: Cash-out amounts are correct after fee deduction
    // With 4 tiers, even scorecard, each player should get ~(pot - fees) / 4
    // -----------------------------------------------------------------------
    function testCashOutAfterFees() external {
        uint8 nTiers = 4;
        DefifaLaunchProjectData memory defifaData = _getBasicDefifaLaunchData(nTiers);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        // Mint phase.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        // Ratify scorecard (triggers fulfillment).
        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);
        vm.warp(block.timestamp + 1);

        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 surplus = potBefore - expectedFee;

        // Each user cashes out their NFT.
        uint256 totalCashedOut;
        for (uint256 i = 0; i < nTiers; i++) {
            uint256 balBefore = users[i].balance;

            uint256[] memory cashOutIds = new uint256[](1);
            cashOutIds[0] = _generateTokenId(i + 1, 1);
            bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

            vm.prank(users[i]);
            JBMultiTerminal(address(jbMultiTerminal()))
                .cashOutTokensOf({
                    holder: users[i],
                    projectId: projectId,
                    cashOutCount: 0,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(users[i]),
                    metadata: cashOutMetadata
                });

            totalCashedOut += users[i].balance - balBefore;
        }

        // Total cashed out should approximately equal the post-fee surplus.
        assertApproxEqRel(totalCashedOut, surplus, 0.001 ether, "total cash-out should equal surplus");
    }

    // -----------------------------------------------------------------------
    // Test 3: Fee + remaining balance = original pot (no dust lost)
    // -----------------------------------------------------------------------
    function testFeeAccounting_noRoundingLoss() external {
        uint8 nTiers = 4;
        DefifaLaunchProjectData memory defifaData = _getBasicDefifaLaunchData(nTiers);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);

        uint256 potAfter =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        uint256 feeAmount = deployer.fulfilledCommitmentsOf(projectId);
        assertEq(feeAmount + potAfter, potBefore, "fee + surplus should equal original pot exactly");
    }

    // -----------------------------------------------------------------------
    // Test 4: Fee accounting with user-provided custom splits
    // User adds a 10% split -> total commitment = 5% + 5% + 10% = 20%
    // -----------------------------------------------------------------------
    function testFeeAccounting_withUserSplits() external {
        uint8 nTiers = 4;

        JBSplit[] memory customSplits = new JBSplit[](1);
        address splitBeneficiary = address(bytes20(keccak256("charity")));
        customSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 10, // 10% = 100_000_000
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        DefifaLaunchProjectData memory defifaData = _getDefifaLaunchDataWithSplits(nTiers, customSplits);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        // Mint phase.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        // totalAbsolutePercent = 25_000_000 + 50_000_000 + 100_000_000 = 175_000_000 (17.5%)
        uint256 expectedFee = (potBefore * 175_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedSurplus = potBefore - expectedFee;

        // Ratify scorecard (triggers fulfillment).
        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);

        uint256 potAfter =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        assertEq(potAfter, expectedSurplus, "surplus with user splits should be pot - 20%");
        assertEq(deployer.fulfilledCommitmentsOf(projectId), expectedFee, "fulfilled = fee amount with user splits");

        // Verify beneficiary received funds.
        assertTrue(splitBeneficiary.balance > 0, "split beneficiary should have received funds");
    }

    // -----------------------------------------------------------------------
    // Test 5: Cash-out with user splits — surplus is reduced by user split portion
    // -----------------------------------------------------------------------
    function testCashOutAfterFees_withUserSplits() external {
        uint8 nTiers = 4;

        JBSplit[] memory customSplits = new JBSplit[](1);
        customSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 10, // 10%
            projectId: 0,
            beneficiary: payable(address(bytes20(keccak256("charity")))),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        DefifaLaunchProjectData memory defifaData = _getDefifaLaunchDataWithSplits(nTiers, customSplits);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);
        vm.warp(block.timestamp + 1);

        // 17.5% fee (2.5% nana + 5% defifa + 10% user)
        uint256 expectedFee = (potBefore * 175_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 surplus = potBefore - expectedFee;

        // Cash out all tiers.
        uint256 totalCashedOut;
        for (uint256 i = 0; i < nTiers; i++) {
            uint256 balBefore = users[i].balance;

            uint256[] memory cashOutIds = new uint256[](1);
            cashOutIds[0] = _generateTokenId(i + 1, 1);
            bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

            vm.prank(users[i]);
            JBMultiTerminal(address(jbMultiTerminal()))
                .cashOutTokensOf({
                    holder: users[i],
                    projectId: projectId,
                    cashOutCount: 0,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(users[i]),
                    metadata: cashOutMetadata
                });

            totalCashedOut += users[i].balance - balBefore;
        }

        assertApproxEqRel(
            totalCashedOut, surplus, 0.001 ether, "cash-out with user splits should equal surplus after 20% fee"
        );

        // Verify that surplus is meaningfully less than with no user splits.
        uint256 surplusWithoutUserSplits = potBefore - (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        assertTrue(surplus < surplusWithoutUserSplits, "user splits should reduce available surplus");
    }

    // -----------------------------------------------------------------------
    // Test 6: Splits normalization with awkward percentages
    // -----------------------------------------------------------------------
    function testSplitNormalization_noRoundingLoss() external {
        uint8 nTiers = 4;

        JBSplit[] memory customSplits = new JBSplit[](3);
        customSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: 33_333_333, // ~3.33%
            projectId: 0,
            beneficiary: payable(address(0x1111)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        customSplits[1] = JBSplit({
            preferAddToBalance: false,
            percent: 66_666_666, // ~6.67%
            projectId: 0,
            beneficiary: payable(address(0x2222)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        customSplits[2] = JBSplit({
            preferAddToBalance: false,
            percent: 11_111_111, // ~1.11%
            projectId: 0,
            beneficiary: payable(address(0x3333)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        DefifaLaunchProjectData memory defifaData = _getDefifaLaunchDataWithSplits(nTiers, customSplits);
        (uint256 projectId, DefifaHook _nft, DefifaGovernor _governor) = _createDefifaProject(defifaData);

        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(_nft, _governor, projectId, nTiers);

        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        // Ratification should succeed (proves splits normalization works).
        _ratifyEvenScorecard(users, _nft, _governor, projectId, nTiers);

        uint256 potAfter =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        // fee + remaining = original (no dust lost).
        uint256 feeAmount = deployer.fulfilledCommitmentsOf(projectId);
        assertEq(feeAmount + potAfter, potBefore, "fee + surplus should equal original pot exactly");
    }

    // ========================== Helpers ==========================

    function _getBasicDefifaLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
        return _getDefifaLaunchDataWithSplits(nTiers, new JBSplit[](0));
    }

    function _getDefifaLaunchDataWithSplits(
        uint8 nTiers,
        JBSplit[] memory splits
    )
        internal
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

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
            tierPrice: uint104(1 ether),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
    }

    function _createDefifaProject(DefifaLaunchProjectData memory defifaLaunchData)
        internal
        returns (uint256 projectId, DefifaHook nft, DefifaGovernor _governor)
    {
        _governor = governor;
        projectId = deployer.launchGameWith(defifaLaunchData);
        JBRuleset memory _fc = jbRulesets().currentOf(projectId);
        if (_fc.dataHook() == address(0)) {
            (_fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaHook(_fc.dataHook());
    }

    /// @notice Mint 1 NFT per tier, set delegation, return array of user addresses.
    function _mintAllTiers(
        DefifaHook _nft,
        DefifaGovernor,
        uint256 projectId,
        uint8 nTiers
    )
        internal
        returns (address[] memory users)
    {
        users = new address[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            users[i] = address(bytes20(keccak256(abi.encode("feeUser", i))));
            vm.deal(users[i], 1 ether);

            uint16[] memory rawMetadata = new uint16[](1);
            // forge-lint: disable-next-line(unsafe-typecast)
            rawMetadata[0] = uint16(i + 1);
            bytes memory metadata = _buildPayMetadata(abi.encode(users[i], rawMetadata));

            vm.prank(users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                projectId, JBConstants.NATIVE_TOKEN, 1 ether, users[i], 0, "", metadata
            );

            // Set delegation.
            DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
            delegations[0] = DefifaDelegation({delegatee: users[i], tierId: i + 1});
            vm.prank(users[i]);
            _nft.setTierDelegatesTo(delegations);

            vm.warp(block.timestamp + 1);
        }
    }

    /// @notice Submit and ratify an even scorecard (equal weight per tier).
    function _ratifyEvenScorecard(
        address[] memory users,
        DefifaHook _nft,
        DefifaGovernor _governor,
        uint256,
        uint8 nTiers
    )
        internal
    {
        // Advance to SCORING phase.
        vm.warp(block.timestamp + 2 days);

        uint256 totalCashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        // Build even scorecard.
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        uint256 assigned;
        for (uint256 i = 0; i < nTiers; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = totalCashOutWeight / nTiers;
            assigned += scorecards[i].cashOutWeight;
        }
        // Absorb rounding remainder into last tier.
        scorecards[nTiers - 1].cashOutWeight += totalCashOutWeight - assigned;

        // Submit scorecard.
        uint256 proposalId = _governor.submitScorecardFor(_gameId, scorecards);

        // Advance to attestation period and vote.
        vm.warp(block.timestamp + _governor.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            _governor.attestToScorecardFrom(_gameId, proposalId);
        }

        // Advance past grace period.
        vm.warp(block.timestamp + _governor.attestationGracePeriodOf(_gameId) + 1);

        // Ratify (this calls fulfillCommitmentsOf internally).
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function _generateTokenId(uint256 _tierId, uint256 _tokenNumber) internal pure returns (uint256) {
        return (_tierId * 1_000_000_000) + _tokenNumber;
    }

    function _buildPayMetadata(bytes memory metadata) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }

    function _buildCashOutMetadata(bytes memory metadata) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
