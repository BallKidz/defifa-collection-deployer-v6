// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TimestampReader2 {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title GracePeriodBypass
/// @notice Regression test: grace period should extend from attestation start, not submission time.
///         When a scorecard is submitted early (before attestationStartTime), the grace period
///         must not expire before attestations begin.
contract GracePeriodBypass is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader2 private _tsReader = new TimestampReader2();

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

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Test that grace period extends from attestation start, not submission time.
    /// @dev With the fix, a scorecard submitted early should have its grace period start after
    ///      attestationsBegin, ensuring the grace period doesn't expire before attestations start.
    function test_gracePeriodExtendsFromAttestationStart() public {
        uint8 nTiers = 4;
        address[] memory _users = new address[](nTiers);

        // Set attestation start time far in the future (e.g. block.timestamp + 10 days)
        // Grace period of 1 day
        uint256 futureAttestationStart = block.timestamp + 10 days;
        uint256 gracePeriod = 1 days;

        DefifaLaunchProjectData memory defifaData =
            _getBasicLaunchDataWithAttestationTiming(nTiers, futureAttestationStart, gracePeriod);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = _createProject(defifaData);

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        for (uint256 i = 0; i < nTiers; i++) {
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            vm.deal(_users[i], 1 ether);

            uint16[] memory rawMetadata = new uint16[](1);
            // forge-lint: disable-next-line(unsafe-typecast)
            rawMetadata[0] = uint16(i + 1);
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));

            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );

            DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
            delegations[0] = DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
            vm.prank(_users[i]);
            _nft.setTierDelegatesTo(delegations);

            vm.warp(_tsReader.timestamp() + 1);
        }

        // Warp to scoring phase
        vm.warp(defifaData.start + 1);

        // Submit scorecard early (attestation start time is still in the future)
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

        uint256 submissionTime = _tsReader.timestamp();
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);

        // The scorecard should be PENDING (attestations haven't started yet)
        assertEq(
            uint256(_governor.stateOf(_gameId, _proposalId)),
            uint256(DefifaScorecardState.PENDING),
            "Scorecard should be PENDING before attestation start"
        );

        // Key assertion: warp past the old grace period end (submissionTime + gracePeriod)
        // but BEFORE attestations begin. The scorecard should still be PENDING, NOT in a post-grace state.
        vm.warp(submissionTime + gracePeriod + 1);

        // With the fix, the scorecard should still be PENDING because attestationsBegin hasn't arrived yet.
        assertEq(
            uint256(_governor.stateOf(_gameId, _proposalId)),
            uint256(DefifaScorecardState.PENDING),
            "Scorecard should still be PENDING even after old grace period would have ended"
        );

        // Now warp to after attestation start (attestation begin + 1)
        vm.warp(futureAttestationStart + 1);

        // Now the scorecard should be ACTIVE (attestations are open and grace period hasn't ended yet)
        assertEq(
            uint256(_governor.stateOf(_gameId, _proposalId)),
            uint256(DefifaScorecardState.ACTIVE),
            "Scorecard should be ACTIVE after attestation start but before grace period ends"
        );

        // Warp to after attestation start + grace period
        vm.warp(futureAttestationStart + gracePeriod + 1);

        // Now grace period has truly ended, so the state should be ACTIVE (quorum not met)
        // The key here is that it transitioned properly - grace period ran from attestation start
        assertEq(
            uint256(_governor.stateOf(_gameId, _proposalId)),
            uint256(DefifaScorecardState.ACTIVE),
            "Scorecard should be ACTIVE (no quorum) after grace period truly ends"
        );
    }

    // ----- Internal helpers ------

    function _getBasicLaunchDataWithAttestationTiming(
        uint8 nTiers,
        uint256 attestationStartTime,
        uint256 attestationGracePeriod
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
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: attestationStartTime,
            attestationGracePeriod: attestationGracePeriod,
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

    function _buildPayMetadata(bytes memory metadata) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
