// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
import {IDefifaGovernor} from "../../src/interfaces/IDefifaGovernor.sol";
import {IDefifaDeployer} from "../../src/interfaces/IDefifaDeployer.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {
    JB721TiersRulesetMetadataResolver
} from "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TimestampReader3 {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title M36_FulfillmentBlocksRatification
/// @notice Regression test: ratification should succeed even when fulfillCommitmentsOf reverts.
/// @dev Tests the try-catch wrapper around fulfillCommitmentsOf in ratifyScorecardFrom.
///      The test verifies that the FulfillmentFailed event is emitted and ratification completes.
contract M36_FulfillmentBlocksRatification is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader3 private _tsReader = new TimestampReader3();

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

    function setUp() public virtual override {
        super.setUp();

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

        _protocolFeeProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(
            jbDirectory(), IERC20(address(_defifaProjectTokenAccount)), IERC20(_protocolFeeProjectTokenAccount)
        );
        governor = new DefifaGovernor(jbController(), address(this));
        JBAddressRegistry _registry = new JBAddressRegistry();
        DefifaTokenUriResolver _tokenURIResolver = new DefifaTokenUriResolver(ITypeface(address(0)));
        deployer = new DefifaDeployer(
            address(hook),
            _tokenURIResolver,
            governor,
            jbController(),
            _registry,
            _defifaProjectId,
            _protocolFeeProjectId
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Test that ratification emits FulfillmentFailed when fulfillment reverts,
    ///         but the scorecard is still ratified.
    /// @dev We mock fulfillCommitmentsOf to revert, then verify the ratification still succeeds.
    function test_ratificationSucceedsWhenFulfillmentReverts() public {
        uint8 nTiers = 4;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = _getBasicLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = _createProject(defifaData);

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        for (uint256 i = 0; i < nTiers; i++) {
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            vm.deal(_users[i], 1 ether);
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1);
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Warp to scoring phase
        vm.warp(defifaData.start + 1);

        // Build scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        uint256 weightPerTier = _nft.TOTAL_CASHOUT_WEIGHT() / nTiers;
        uint256 assigned;
        for (uint256 i = 0; i < nTiers; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = weightPerTier;
            assigned += weightPerTier;
        }
        if (assigned < _nft.TOTAL_CASHOUT_WEIGHT()) {
            scorecards[0].cashOutWeight += _nft.TOTAL_CASHOUT_WEIGHT() - assigned;
        }

        // Submit and attest
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        vm.warp(_tsReader.timestamp() + _governor.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        vm.warp(_tsReader.timestamp() + _governor.attestationGracePeriodOf(_gameId) + 1);

        // Mock fulfillCommitmentsOf to revert
        address _deployer = jbController().PROJECTS().ownerOf(_gameId);
        vm.mockCallRevert(
            _deployer,
            abi.encodeWithSelector(IDefifaDeployer.fulfillCommitmentsOf.selector, _gameId),
            abi.encodeWithSignature("Error(string)", "simulated fulfillment failure")
        );

        // Ratification should succeed even though fulfillment will revert.
        // We expect the FulfillmentFailed event to be emitted.
        vm.expectEmit(true, false, false, false);
        emit IDefifaGovernor.FulfillmentFailed(_gameId, "");

        _governor.ratifyScorecardFrom(_gameId, scorecards);

        // Verify the scorecard was ratified
        assertEq(
            _governor.ratifiedScorecardIdOf(_gameId),
            _proposalId,
            "Scorecard should be ratified despite fulfillment failure"
        );

        // Verify the state is RATIFIED
        assertEq(
            uint256(_governor.stateOf(_gameId, _proposalId)),
            uint256(DefifaScorecardState.RATIFIED),
            "Scorecard state should be RATIFIED"
        );
    }

    // ----- Internal helpers ------

    function _getBasicLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
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
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
    }

    function _createProject(DefifaLaunchProjectData memory defifaLaunchData)
        internal
        returns (uint256 projectId, DefifaHook nft, DefifaGovernor _governor)
    {
        _governor = governor;
        (projectId) = deployer.launchGameWith(defifaLaunchData);
        JBRuleset memory _fc = jbRulesets().currentOf(projectId);
        if (_fc.dataHook() == address(0)) {
            (_fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaHook(_fc.dataHook());
    }

    function _buildPayMetadata(bytes memory metadata) internal returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
