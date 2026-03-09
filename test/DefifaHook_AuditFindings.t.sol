// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
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
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TimestampReaderAudit {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title DefifaHook_AuditFindings
/// @notice Regression tests for audit findings in DefifaHook.
contract DefifaHook_AuditFindings is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReaderAudit private _tsReader = new TimestampReaderAudit();

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

    /// @notice M-5: Attestation units must be preserved when transferring an NFT to an undelegated recipient.
    /// @dev Before the fix, transferring to a recipient with no delegate set would cause attestation units to vanish:
    ///      the sender's delegate lost units but no delegate gained them (because address(0) was skipped).
    ///      After the fix, the recipient auto-delegates to themselves, preserving total attestation power.
    function test_M5_attestationUnitsPreservedOnTransferToUndelegatedRecipient() public {
        uint8 nTiers = 4;
        address playerA = address(bytes20(keccak256("playerA")));
        address playerB = address(bytes20(keccak256("playerB")));

        DefifaLaunchProjectData memory defifaData = _getBasicLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft,) = _createProject(defifaData);

        // Phase 1: Mint — both players buy tier 1 NFTs.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);

        // Player A mints tier 1.
        vm.deal(playerA, 1 ether);
        {
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = 1;
            bytes memory metadata = _buildPayMetadata(abi.encode(playerA, rawMetadata));
            vm.prank(playerA);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, playerA, 0, "", metadata
            );
        }
        assertEq(_nft.balanceOf(playerA), 1, "Player A should own 1 NFT");

        // Player A explicitly sets delegation to self.
        {
            DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
            delegations[0] = DefifaDelegation({delegatee: playerA, tierId: 1});
            vm.prank(playerA);
            _nft.setTierDelegatesTo(delegations);
        }

        // Player B mints tier 1 — uses self as attestation delegate (via pay metadata).
        vm.deal(playerB, 1 ether);
        {
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = 1;
            bytes memory metadata = _buildPayMetadata(abi.encode(playerB, rawMetadata));
            vm.prank(playerB);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, playerB, 0, "", metadata
            );
        }
        assertEq(_nft.balanceOf(playerB), 1, "Player B should own 1 NFT");

        // Advance 1 second so checkpoints are recorded.
        vm.warp(_tsReader.timestamp() + 1);

        // Get the tier's voting units per NFT.
        uint256 votingUnitsPerNft = _nft.store().tierOf(address(_nft), 1, false).votingUnits;
        assertTrue(votingUnitsPerNft > 0, "Voting units should be non-zero");

        // Capture the total tier attestation supply before transfer.
        uint256 totalBefore = _nft.getTierTotalAttestationUnitsOf(1);
        assertEq(totalBefore, votingUnitsPerNft * 2, "Total should be 2 NFTs worth of voting units");

        // Verify Player A's delegate has attestation units.
        uint256 playerADelegateUnitsBefore = _nft.getTierAttestationUnitsOf(playerA, 1);
        assertEq(playerADelegateUnitsBefore, votingUnitsPerNft, "Player A delegate should have 1 NFT of voting units");

        // Now create a NEW recipient (playerC) who has NEVER set delegation.
        address playerC = address(bytes20(keccak256("playerC")));

        // Warp to REFUND phase — delegation changes are locked (only MINT phase allows setTierDelegatesTo).
        vm.warp(defifaData.start - defifaData.refundPeriodDuration);
        // Confirm we are in REFUND phase by verifying setTierDelegatesTo reverts.
        {
            DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
            delegations[0] = DefifaDelegation({delegatee: playerC, tierId: 1});
            vm.prank(playerC);
            vm.expectRevert(DefifaHook.DefifaHook_DelegateChangesUnavailableInThisPhase.selector);
            _nft.setTierDelegatesTo(delegations);
        }

        // Player A transfers their NFT to playerC (who has no delegate set).
        uint256 tokenId = _generateTokenId(1, 1); // Tier 1, token #1
        vm.prank(playerA);
        _nft.transferFrom(playerA, playerC, tokenId);

        // Advance 1 second so checkpoints are recorded.
        vm.warp(_tsReader.timestamp() + 1);

        // After fix: playerC should be auto-delegated to themselves.
        address playerCDelegate = _nft.getTierDelegateOf(playerC, 1);
        assertEq(playerCDelegate, playerC, "Player C should be auto-delegated to self after receiving NFT");

        // Player A's delegate should have lost the voting units.
        uint256 playerADelegateUnitsAfter = _nft.getTierAttestationUnitsOf(playerA, 1);
        assertEq(playerADelegateUnitsAfter, 0, "Player A delegate should have 0 voting units after transfer");

        // Player C (auto-delegated to self) should have gained the voting units.
        uint256 playerCDelegateUnits = _nft.getTierAttestationUnitsOf(playerC, 1);
        assertEq(playerCDelegateUnits, votingUnitsPerNft, "Player C should have gained the transferred voting units");

        // The total attestation supply should be unchanged — no units lost.
        uint256 totalAfter = _nft.getTierTotalAttestationUnitsOf(1);
        assertEq(totalAfter, totalBefore, "Total attestation units must be conserved across the transfer");

        // Verify conservation: sum of all delegate attestation units for tier 1 == total.
        uint256 sumOfDelegates = _nft.getTierAttestationUnitsOf(playerA, 1) + _nft.getTierAttestationUnitsOf(playerB, 1)
            + _nft.getTierAttestationUnitsOf(playerC, 1);
        assertEq(sumOfDelegates, totalAfter, "Sum of all delegate attestation units must equal total supply");
    }

    /// @notice M-5 additional: multiple sequential transfers to undelegated recipients should all preserve units.
    function test_M5_multipleTransfersToUndelegatedRecipientsPreserveUnits() public {
        uint8 nTiers = 2;
        address playerA = address(bytes20(keccak256("playerA")));

        DefifaLaunchProjectData memory defifaData = _getBasicLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft,) = _createProject(defifaData);

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);

        // Player A mints tier 1.
        vm.deal(playerA, 1 ether);
        {
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = 1;
            bytes memory metadata = _buildPayMetadata(abi.encode(playerA, rawMetadata));
            vm.prank(playerA);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, playerA, 0, "", metadata
            );
        }

        // Player A sets delegation.
        {
            DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
            delegations[0] = DefifaDelegation({delegatee: playerA, tierId: 1});
            vm.prank(playerA);
            _nft.setTierDelegatesTo(delegations);
        }

        vm.warp(_tsReader.timestamp() + 1);

        uint256 votingUnitsPerNft = _nft.store().tierOf(address(_nft), 1, false).votingUnits;
        uint256 totalBefore = _nft.getTierTotalAttestationUnitsOf(1);
        assertEq(totalBefore, votingUnitsPerNft, "Total should be 1 NFT worth of voting units");

        // Warp to REFUND phase.
        vm.warp(defifaData.start - defifaData.refundPeriodDuration);

        uint256 tokenId = _generateTokenId(1, 1);

        // Transfer through 3 undelegated recipients sequentially.
        address currentHolder = playerA;
        for (uint256 i = 0; i < 3; i++) {
            address nextRecipient = address(uint160(0xBEEF0000 + i));

            vm.prank(currentHolder);
            _nft.transferFrom(currentHolder, nextRecipient, tokenId);
            vm.warp(_tsReader.timestamp() + 1);

            // Verify the recipient auto-delegated to self.
            assertEq(
                _nft.getTierDelegateOf(nextRecipient, 1), nextRecipient, "Each recipient should auto-delegate to self"
            );

            // Verify the recipient has the voting units.
            assertEq(
                _nft.getTierAttestationUnitsOf(nextRecipient, 1),
                votingUnitsPerNft,
                "Each recipient should hold the voting units"
            );

            // Verify total is conserved.
            assertEq(
                _nft.getTierTotalAttestationUnitsOf(1),
                totalBefore,
                "Total attestation units must remain constant across chain of transfers"
            );

            currentHolder = nextRecipient;
        }
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

    function _generateTokenId(uint256 _tierId, uint256 _tokenNumber) internal pure returns (uint256) {
        return (_tierId * 1_000_000_000) + _tokenNumber;
    }

    function _buildPayMetadata(bytes memory metadata) internal returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
