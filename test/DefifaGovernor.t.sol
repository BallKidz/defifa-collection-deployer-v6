// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

// solhint-disable-next-line no-unused-import
import "forge-std/Test.sol";
// solhint-disable-next-line no-unused-import
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
contract TimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

contract DefifaGovernorTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader private _tsReader = new TimestampReader();

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address _owner = 0x1000000000000000000000000000000000000000;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

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
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        // Launch the Defifa fee project.
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

        // Transfer ownership of the hook to the deployer.
        hook.transferOwnership(address(deployer));
        // Transfer ownership of the governor to the deployer.
        governor.transferOwnership(address(deployer));
    }

    function testReceiveVotingPower(uint8 nTiers, uint8 tier) public {
        vm.assume(nTiers < 100);
        vm.assume(nTiers >= tier);
        vm.assume(tier != 0);
        address _user = address(bytes20(keccak256("user")));
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // User should have no voting power (yet)
        assertEq(_governor.getAttestationWeight(_gameId, _user, uint48(block.timestamp)), 0);
        // fund user
        vm.deal(_user, 1 ether);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        vm.assume(tier != 0);
        rawMetadata[0] = uint16(tier); // reward tier

        // Pay to the project and mint an NFT
        vm.prank(_user);
        jbMultiTerminal().pay{value: 1 ether}(
            _projectId,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            _user,
            0,
            "",
            _buildPayMetadata(abi.encode(_user, rawMetadata))
        );

        // The user should now have a balance
        assertEq(_nft.balanceOf(_user), 1);

        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.warp(block.timestamp + 1);

        assertEq(_nft.store().tierOf(address(_nft), tier, false).votingUnits, 1 ether);
        assertEq(
            _governor.MAX_ATTESTATION_POWER_TIER(),
            _governor.getAttestationWeight(_gameId, _user, uint48(block.timestamp))
        );
    }

    // cashOuts can happen after mint phase
    // function testRefund_fails_afterMintPhase() external {
    //   uint8 nTiers = 10;
    //   address[] memory _users = new address[](nTiers);
    //   DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
    //   (uint256 _projectId, , ) = createDefifaProject(defifaData);
    //   // Phase 1: Mint
    //   vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
    //   //deployer.queueNextPhaseOf(_projectId);
    //   for (uint256 i = 0; i < nTiers; i++) {
    //     // Generate a new address for each tier
    //     _users[i] = address(bytes20(keccak256(abi.encode('user', Strings.toString(i)))));
    //     // fund user
    //     vm.deal(_users[i], 1 ether);
    //     // Build metadata to buy specific NFT
    //     uint16[] memory rawMetadata = new uint16[](1);
    //     rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
    //     bytes memory metadata = abi.encode(
    //       bytes32(0),
    //       bytes32(0),
    //       type(IDefifaHook).interfaceId,
    //       _users[i],
    //       rawMetadata
    //     );
    //     // Pay to the project and mint an NFT
    //     vm.prank(_users[i]);
    //     jbMultiTerminal().pay{value: 1 ether}(
    //       _projectId,
    //       1 ether,
    //       address(0),
    //       _users[i],
    //       0,
    //       true,
    //       '',
    //       metadata
    //     );
    //   }
    //   // Phase 2: Redeem
    //   vm.warp(block.timestamp + defifaData.mintPeriodDuration);
    //   //deployer.queueNextPhaseOf(_projectId);
    //   // Phase 3: Start
    //   vm.warp(defifaData.start + 1);
    //   //deployer.queueNextPhaseOf(_projectId);
    //   // Make sure this is actually Phase 3
    //   assertEq(jbRulesets().currentOf(_projectId).number, 3);
    //   for (uint256 i = 0; i < _users.length; i++) {
    //     address _user = _users[i];
    //     // Craft the metadata: redeem the tokenId
    //     bytes memory cashOutMetadata;
    //     {
    //       uint256[] memory cashOutId = new uint256[](1);
    //       cashOutId[0] = _generateTokenId(i + 1, 1);
    //       cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId);
    //     }
    //     vm.expectRevert(abi.encodeWithSignature('FUNDING_CYCLE_REDEEM_PAUSED()'));
    //     vm.prank(_user);
    //     JBMultiTerminal(address(jbMultiTerminal())).redeemTokensOf({
    //       _holder: _user,
    //       _projectId: _projectId,
    //       _tokenCount: 0,
    //       _token: address(0),
    //       _minReturnedTokens: 0,
    //       _beneficiary: payable(_user),
    //       _memo: 'Refund plz',
    //       _metadata: cashOutMetadata
    //     });
    //   }
    //   // // Phase 4: End
    //   // vm.warp(deployer.endOf(_projectId));
    //   // Forward the amount of blocks needed to reach the end (and round up)
    //   // vm.roll(deployer.endOf(_projectId) - block.timestamp / 12 + 1);
    //   vm.warp(block.timestamp + 1 weeks);
    //   assertEq(jbRulesets().currentOf(_projectId).number, 4);
    //   for (uint256 i = 0; i < _users.length; i++) {
    //     address _user = _users[i];
    //     // Craft the metadata: redeem the tokenId
    //     bytes memory cashOutMetadata;
    //     {
    //       uint256[] memory cashOutId = new uint256[](1);
    //       cashOutId[0] = _generateTokenId(i + 1, 1);
    //       cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId);
    //     }
    //     // Here the refunds are not allowed but cashOuts are,
    //     // so it should instead revert with an error showing that there is no cashOut set for our tier
    //     vm.expectRevert(abi.encodeWithSignature('NOTHING_TO_CLAIM()'));
    //     vm.prank(_user);
    //     JBMultiTerminal(address(jbMultiTerminal())).redeemTokensOf({
    //       _holder: _user,
    //       _projectId: _projectId,
    //       _tokenCount: 0,
    //       _token: address(0),
    //       _minReturnedTokens: 0,
    //       _beneficiary: payable(_user),
    //       _memo: 'Refund plz',
    //       _metadata: cashOutMetadata
    //     });
    //   }
    // }

    function testMint_fails_afterMintPhase() external {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId,,) = createDefifaProject(defifaData);
        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Make sure this is actually Phase 2
        assertEq(jbRulesets().currentOf(_projectId).cycleNumber, 2);

        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            // Pay to the project and mint an NFT
            vm.expectRevert(JBTerminalStore.JBTerminalStore_RulesetPaymentPaused.selector);
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
        }
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            // Pay to the project and mint an NFT
            vm.expectRevert(JBTerminalStore.JBTerminalStore_RulesetPaymentPaused.selector);
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
        }
    }

    // Transfers are no longer disabled
    // function testTransfer_fails_afterTradeDeadline() external {
    //   uint8 nTiers = 10;
    //   address[] memory _users = new address[](nTiers);
    //   DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData();
    //   (uint256 _projectId, DefifaHook _nft, ) = createDefifaProject(
    //     uint256(nTiers),
    //     getBasicDefifaLaunchData()
    //   );
    //   // Phase 1: minting
    //   vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
    //   for (uint256 i = 0; i < nTiers; i++) {
    //     // Generate a new address for each tier
    //     _users[i] = address(bytes20(keccak256(abi.encode('user', Strings.toString(i)))));
    //     // fund user
    //     vm.deal(_users[i], 1 ether);
    //     // Build metadata to buy specific NFT
    //     uint16[] memory rawMetadata = new uint16[](1);
    //     rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
    //     bytes memory metadata = abi.encode(
    //       bytes32(0),
    //       bytes32(0),
    //       type(IDefifaHook).interfaceId,
    //       false,
    //       false,
    //       false,
    //       rawMetadata
    //     );
    //     // Pay to the project and mint an NFT
    //     vm.prank(_users[i]);
    //     jbMultiTerminal().pay{value: 1 ether}(
    //       _projectId,
    //       1 ether,
    //       address(0),
    //       _users[i],
    //       0,
    //       true,
    //       '',
    //       metadata
    //     );
    //   }
    //   // Phase 2: Redeem
    //   vm.warp(block.timestamp + defifaData.mintPeriodDuration);
    //   //deployer.queueNextPhaseOf(_projectId);
    //   // Make sure this is actually Phase 2
    //   assertEq(jbRulesets().currentOf(_projectId).number, 2);
    //   // Phase 3: Start
    //   vm.warp(defifaData.start + 1);
    //   //deployer.queueNextPhaseOf(_projectId);
    //   // Make sure this is actually Phase 3
    //   assertEq(jbRulesets().currentOf(_projectId).number, 3);
    //   uint256 _tokenIdToTransfer = _generateTokenId(1, 1);
    //   vm.prank(_users[0]);
    //   // trasnfers not possible in phase 3
    //   vm.expectRevert(abi.encodeWithSignature('TRANSFERS_PAUSED()'));
    //   _nft.transferFrom(_users[0], _users[1], _tokenIdToTransfer);
    // }
    function testSetCashOutRates_fails_unmetQuorum() external {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
            // Set the delegate as the user themselves
            DefifaDelegation[] memory tiered721SetDelegatesData = new DefifaDelegation[](1);
            tiered721SetDelegatesData[0] = DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
            vm.prank(_users[i]);
            _nft.setTierDelegatesTo(tiered721SetDelegatesData);
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            vm.warp(_tsReader.timestamp() + 1);
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER(),
                _governor.getAttestationWeight(_gameId, _users[i], uint48(_tsReader.timestamp()))
            );
        }
        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);
        // Generate the scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.warp(_tsReader.timestamp() + _governor.attestationStartTimeOf(_gameId) + 1);
        // We have only 40% vote on the proposal, making it still be below quorum.
        for (uint256 i = 0; i < _users.length * 4 / 10; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        // Forward the amount of blocks needed to reach the end (and round up)
        vm.warp(_tsReader.timestamp() + _governor.attestationGracePeriodOf(_gameId) + 1);
        // Execute the proposal
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function testSetCashOutRatesAndRedeem_multipleTiers(uint8 nTiers, uint8[] calldata distribution) public {
        vm.assume(nTiers > 10 && nTiers < 100);
        vm.assume(distribution.length < nTiers);

        uint256 _sumDistribution;
        for (uint256 i = 0; i < distribution.length; i++) {
            _sumDistribution += distribution[i];
        }
        vm.assume(_sumDistribution > 0);
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);

        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);

            // Build metadata to buy specific NFT
            bytes memory metadata;
            {
                uint16[] memory rawMetadata = new uint16[](1);
                rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
                metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            }

            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            vm.warp(block.timestamp + 1);
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER(),
                _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
            );
            // Have a user mint and refund the tier
            mintAndRefund(_nft, _projectId, i + 1);
        }
        // Have a user mint and refund the tier
        mintAndRefund(_nft, _projectId, 1);

        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);
        // Generate the scorecards — must sum to exactly TOTAL_CASHOUT_WEIGHT
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        uint256 assignedCashOutWeight;
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            if (distribution.length <= i) continue;
            scorecards[i].cashOutWeight = (uint256(distribution[i]) * _nft.TOTAL_CASHOUT_WEIGHT()) / _sumDistribution;
            assignedCashOutWeight += scorecards[i].cashOutWeight;
        }
        // Absorb rounding remainder into first tier with weight
        if (assignedCashOutWeight < _nft.TOTAL_CASHOUT_WEIGHT()) {
            uint256 remainder = _nft.TOTAL_CASHOUT_WEIGHT() - assignedCashOutWeight;
            for (uint256 i = 0; i < scorecards.length; i++) {
                if (scorecards[i].cashOutWeight > 0) {
                    scorecards[i].cashOutWeight += remainder;
                    break;
                }
            }
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.warp(block.timestamp + _governor.attestationStartTimeOf(_gameId) + 1);
        // No voting delay after the initial voting delay has passed in
        //assertEq(_governor.attestationStartTimeOf(_gameId), 0);
        // All the users vote
        // 0 = Against
        // 1 = For
        // 2 = Abstain
        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        // each block is of 12 secs
        vm.warp(block.timestamp + _governor.attestationGracePeriodOf(_gameId));

        _governor.ratifyScorecardFrom(_gameId, scorecards);
        // Move forward 1 block to start the new ruleset.
        vm.roll(block.number + 1);

        _verifyCashOutsAndRedeem(
            _projectId, _nft, scorecards, _users, _sumDistribution, distribution, assignedCashOutWeight
        );
    }

    function _verifyCashOutsAndRedeem(
        uint256 _projectId,
        DefifaHook _nft,
        DefifaTierCashOutWeight[] memory scorecards,
        address[] memory _users,
        uint256 _sumDistribution,
        uint8[] calldata distribution,
        uint256 assignedCashOutWeight
    )
        internal
    {
        uint256 _pot = jbMultiTerminal()
            .currentSurplusOf(_projectId, jbMultiTerminal().accountingContextsOf(_projectId), 18, JBCurrencyIds.ETH);
        // Assert that the deployer did *NOT* receive any fee tokens.
        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(deployer)), 0);
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(address(deployer)), 0);

        // Verify that the cashOutWeights actually changed
        for (uint256 i = 0; i < scorecards.length; i++) {
            _verifySingleCashOut(_projectId, _nft, scorecards[i], _users[i], _pot, _sumDistribution, distribution, i);
        }
        // All NFTs should have been redeemed, only some dust should be left
        uint256 remainingSurplus = jbMultiTerminal()
            .currentSurplusOf(_projectId, jbMultiTerminal().accountingContextsOf(_projectId), 18, JBCurrencyIds.ETH);
        uint256 _expected = _pot * (_nft.TOTAL_CASHOUT_WEIGHT() - assignedCashOutWeight) / _nft.TOTAL_CASHOUT_WEIGHT();
        assertApproxEqAbs(remainingSurplus, _expected, 10 ** 14);

        // There should be no fee tokens left in the hook.
        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(_nft)), 0);
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(address(_nft)), 0);
    }

    function _verifySingleCashOut(
        uint256 _projectId,
        DefifaHook _nft,
        DefifaTierCashOutWeight memory scorecard,
        address _user,
        uint256 _pot,
        uint256 _sumDistribution,
        uint8[] calldata distribution,
        uint256 i
    )
        internal
    {
        assertEq(_nft.tierCashOutWeights()[i], scorecard.cashOutWeight);

        bytes memory cashOutMetadata;
        uint256 _receiveDefifa;
        uint256 _receiveNana;
        {
            uint256[] memory cashOutId = new uint256[](1);
            cashOutId[0] = _generateTokenId(i + 1, 1);
            cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId));
            (_receiveDefifa, _receiveNana) = _nft.tokensClaimableFor(cashOutId);
        }
        uint256 _nanaBalance = IERC20(_protocolFeeProjectTokenAccount).balanceOf(_user);
        uint256 _defifaBalance = IERC20(_defifaProjectTokenAccount).balanceOf(_user);

        vm.prank(_user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _user,
                projectId: _projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_user),
                metadata: cashOutMetadata
            });

        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(_user), _nanaBalance + _receiveNana);
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(_user), _defifaBalance + _receiveDefifa);

        if (scorecard.cashOutWeight == 0) return;

        uint256 _expectedTierCashOut = _pot;
        if (distribution.length > i) {
            _expectedTierCashOut = (_expectedTierCashOut * distribution[i]) / _sumDistribution;
        }
        assertApproxEqRel(_expectedTierCashOut, _user.balance, 0.001 ether);
    }

    function testVotingPowerDecreasesAfterRefund() public {
        uint256 nOfOtherTiers = 31;
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaHook _hook, DefifaGovernor _governor) = createDefifaProject(defifaData);

        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        JB721Tier memory _tier = _hook.store().tierOf(address(_hook), 1, false);
        uint256 _cost = _tier.price;

        address _delegateUser = address(bytes20(keccak256("_delegateUser")));
        address _refundUser = address(bytes20(keccak256("refund_user")));
        // The user should have no balance
        assertEq(_hook.balanceOf(_refundUser), 0);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = uint16(1); // reward tier, 1 indexed
        bytes memory metadata = _buildPayMetadata(abi.encode(_refundUser, rawMetadata));
        // Pay to the project and mint an NFT
        vm.deal(_refundUser, _cost);

        vm.prank(_refundUser);
        jbMultiTerminal().pay{value: _cost}(_projectId, JBConstants.NATIVE_TOKEN, _cost, _refundUser, 0, "", metadata);

        vm.warp(block.timestamp + 1);

        assertEq(
            _governor.MAX_ATTESTATION_POWER_TIER(),
            _governor.getAttestationWeight(_gameId, _refundUser, uint48(block.timestamp))
        );

        // User should no longer have any funds
        assertEq(_refundUser.balance, 0);
        // The user should have have a token
        assertEq(_hook.balanceOf(_refundUser), 1);

        uint256 _numberBurned = _hook.store().numberOfBurnedFor(address(_hook), 1);
        // Craft the metadata: redeem the tokenId
        bytes memory cashOutMetadata;
        {
            uint256[] memory cashOutId = new uint256[](1);
            cashOutId[0] = _generateTokenId(1, _tier.initialSupply - _tier.remainingSupply + 1 + _numberBurned);
            cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId));
        }

        vm.prank(_refundUser);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _refundUser,
                projectId: _projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_refundUser),
                metadata: cashOutMetadata
            });
        vm.warp(block.timestamp + 1);

        assertEq(_refundUser.balance, _cost);
        assertEq(_hook.balanceOf(_refundUser), 0);

        assertEq(0, _governor.getAttestationWeight(_gameId, _refundUser, uint48(block.timestamp)));
    }

    function testRevertsIfDelegationisDoneAfterMintPhase(
        uint8 nUsersWithWinningTier,
        uint8 winningTierExtraWeight,
        uint8 baseCashOutWeight
    )
        public
    {
        uint256 nOfOtherTiers = 31;
        vm.assume(nUsersWithWinningTier > 1 && nUsersWithWinningTier < 100);
        uint256 totalWeight = baseCashOutWeight * (nOfOtherTiers + 1) + winningTierExtraWeight;
        vm.assume(totalWeight > 1);

        address[] memory _users = new address[](nOfOtherTiers + nUsersWithWinningTier);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        for (uint256 i = 0; i < nOfOtherTiers + nUsersWithWinningTier; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            if (i < nOfOtherTiers) {
                // Build metadata to buy specific NFT
                uint16[] memory rawMetadata = new uint16[](1);
                rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
                bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
                // Pay to the project and mint an NFT
                vm.prank(_users[i]);
                jbMultiTerminal().pay{value: 1 ether}(
                    _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
                );
                // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
                vm.warp(block.timestamp + 1);
                assertEq(
                    _governor.MAX_ATTESTATION_POWER_TIER(),
                    _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
                );
            } else {
                // Build metadata to buy specific NFT
                uint16[] memory rawMetadata = new uint16[](1);
                rawMetadata[0] = uint16(nOfOtherTiers + 1); // reward tier, 1 indexed
                bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
                // Pay to the project and mint an NFT
                vm.prank(_users[i]);
                jbMultiTerminal().pay{value: 1 ether}(
                    _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
                );
                // Forward 1 block, user should have a part of the voting power of their tier
                vm.warp(block.timestamp + 1);
                assertEq(
                    _governor.MAX_ATTESTATION_POWER_TIER() / (i - nOfOtherTiers + 1),
                    _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
                );
            }
        }
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DefifaHook_DelegateChangesUnavailableInThisPhase()"));
        _nft.setTierDelegateTo(_users[1], 1);
    }

    function testSetCashOutRatesAndRedeem_singleTier(
        uint8 nUsersWithWinningTier,
        uint8 winningTierExtraWeight,
        uint8 baseCashOutWeight
    )
        public
    {
        uint256 nOfOtherTiers = 31;
        vm.assume(nUsersWithWinningTier > 1 && nUsersWithWinningTier < 100);
        uint256 totalWeight = baseCashOutWeight * (nOfOtherTiers + 1) + winningTierExtraWeight;
        vm.assume(totalWeight > 1);

        address[] memory _users = new address[](nOfOtherTiers + nUsersWithWinningTier);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        for (uint256 i = 0; i < nOfOtherTiers + nUsersWithWinningTier; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            if (i < nOfOtherTiers) {
                // Build metadata to buy specific NFT
                uint16[] memory rawMetadata = new uint16[](1);
                rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
                bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
                // Pay to the project and mint an NFT
                vm.prank(_users[i]);
                jbMultiTerminal().pay{value: 1 ether}(
                    _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
                );
                // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
                vm.warp(block.timestamp + 1);
                assertEq(
                    _governor.MAX_ATTESTATION_POWER_TIER(),
                    _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
                );
            } else {
                // Build metadata to buy specific NFT
                uint16[] memory rawMetadata = new uint16[](1);
                rawMetadata[0] = uint16(nOfOtherTiers + 1); // reward tier, 1 indexed
                bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
                // Pay to the project and mint an NFT
                vm.prank(_users[i]);
                jbMultiTerminal().pay{value: 1 ether}(
                    _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
                );
                // Forward 1 block, user should have a part of the voting power of their tier
                vm.warp(block.timestamp + 1);
                assertEq(
                    _governor.MAX_ATTESTATION_POWER_TIER() / (i - nOfOtherTiers + 1),
                    _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
                );
            }
        }
        // Have a user mint and refund the tier
        mintAndRefund(_nft, _projectId, 1);
        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);
        // Generate the scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nOfOtherTiers + 1);

        uint256 totalCashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();

        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        uint256 assignedCashOutWeight;
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            if (baseCashOutWeight != 0) {
                scorecards[i].cashOutWeight = (totalCashOutWeight * uint256(baseCashOutWeight)) / totalWeight;
            }
            if (i == nOfOtherTiers && winningTierExtraWeight != 0) {
                scorecards[i].cashOutWeight += (totalCashOutWeight * uint256(winningTierExtraWeight)) / totalWeight;
            }
            assignedCashOutWeight += scorecards[i].cashOutWeight;
        }
        // Absorb rounding remainder into first tier with weight
        if (assignedCashOutWeight < totalCashOutWeight) {
            uint256 remainder = totalCashOutWeight - assignedCashOutWeight;
            for (uint256 i = 0; i < scorecards.length; i++) {
                if (scorecards[i].cashOutWeight > 0) {
                    scorecards[i].cashOutWeight += remainder;
                    break;
                }
            }
        }
        {
            // Forward time so proposals can be created
            uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
            // Forward time so voting becomes active
            vm.warp(block.timestamp + _governor.attestationStartTimeOf(_gameId) + 1);
            // No voting delay after the initial voting delay has passed in
            // assertEq(_governor.attestationStartTimeOf(_gameId), 0);
            // All the users vote
            // 0 = Against
            // 1 = For
            // 2 = Abstain
            for (uint256 i = 0; i < _users.length; i++) {
                vm.prank(_users[i]);
                _governor.attestToScorecardFrom(_gameId, _proposalId);
            }
        }

        // Forward the amount of blocks needed to reach the end (and round up)
        vm.warp(block.timestamp + _governor.attestationGracePeriodOf(_gameId));

        _governor.ratifyScorecardFrom(_gameId, scorecards);
        vm.warp(block.timestamp + 1);

        uint256 _pot = jbMultiTerminal()
            .currentSurplusOf(_projectId, jbMultiTerminal().accountingContextsOf(_projectId), 18, JBCurrencyIds.ETH);

        // Verify that the cashOutWeights actually changed
        for (uint256 i = 0; i < _users.length; i++) {
            address _user = _users[i];
            uint256 _tier = i <= nOfOtherTiers ? i + 1 : nOfOtherTiers + 1;
            // Craft the metadata: redeem the tokenId
            bytes memory cashOutMetadata;
            {
                uint256[] memory cashOutId = new uint256[](1);
                cashOutId[0] = _generateTokenId(_tier, _tier == nOfOtherTiers + 1 ? i - nOfOtherTiers + 1 : 1);
                cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId));
            }
            uint256 _expectedTierCashOut;
            {
                // Calculate how much weight his tier has
                uint256 _tierWeight = _tier == nOfOtherTiers + 1
                    ? uint256(baseCashOutWeight) + uint256(winningTierExtraWeight)
                    : baseCashOutWeight;

                // If the cashOut is 0 this will revert
                vm.prank(_user);
                JBMultiTerminal(address(jbMultiTerminal()))
                    .cashOutTokensOf({
                        holder: _user,
                        projectId: _projectId,
                        cashOutCount: 0,
                        tokenToReclaim: JBConstants.NATIVE_TOKEN,
                        minTokensReclaimed: 0,
                        beneficiary: payable(_user),
                        metadata: cashOutMetadata
                    });
                // We calculate the expected output based on the given distribution and how much is in the pot
                _expectedTierCashOut = (_pot * _tierWeight) / totalWeight;
            }
            {
                // If this is the winning tier then the amount is divided among the nUsersWithWinningTier
                if (_tier == nOfOtherTiers + 1) {
                    _expectedTierCashOut = _expectedTierCashOut / nUsersWithWinningTier;
                }
            }
            // Assert that our expected tier cashOut is ~equal to the actual amount
            // Allowing for some rounding errors, max allowed error is 0.000001 ether
            assertApproxEqRel(_expectedTierCashOut, _user.balance, 0.0001 ether);
        }
        // All NFTs should have been redeemed, only some dust should be left
        // Max allowed dust is 0.0001
        uint256 remainingSurplus = jbMultiTerminal()
            .currentSurplusOf(_projectId, jbMultiTerminal().accountingContextsOf(_projectId), 18, JBCurrencyIds.ETH);
        assertApproxEqAbs(
            remainingSurplus, _pot * (totalCashOutWeight - assignedCashOutWeight) / totalCashOutWeight, 10 ** 14
        );
    }

    function testPhaseTimes(
        uint16 _durationUntilProjectLaunch,
        uint16 _mintPeriodDuration,
        uint16 _inBetweenMintAndFifa,
        uint16 _fifaDuration
    )
        public
    {
        vm.assume(
            _durationUntilProjectLaunch > 2 && _mintPeriodDuration > 1 && _inBetweenMintAndFifa > 1 && _fifaDuration > 1
        );
        uint48 _launchProjectAt = uint48(block.timestamp) + _durationUntilProjectLaunch;
        uint48 _end =
            _launchProjectAt + uint48(_mintPeriodDuration) + uint48(_inBetweenMintAndFifa) + uint48(_fifaDuration);
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](1);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0), // this way we dont need more tokenUris
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "DEFIFA"
        });

        DefifaLaunchProjectData memory _launchData = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: _mintPeriodDuration,
            start: _launchProjectAt + uint48(_mintPeriodDuration) + _inBetweenMintAndFifa,
            refundPeriodDuration: _inBetweenMintAndFifa,
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
        (uint256 _projectId, DefifaHook _nft,) = createDefifaProject(_launchData);
        // Wait until the phase 1 start
        vm.warp(_launchProjectAt);
        // Get the hook
        _nft = DefifaHook(jbRulesets().currentOf(_projectId).dataHook());
        // We should be in the minting phase now
        assertEq(jbRulesets().currentOf(_projectId).cycleNumber, 1);
        // Queue Phase 2
        //deployer.queueNextPhaseOf(_projectId);
        // Go to the end of the minting phase and check if we are still in the minting phase
        vm.warp(_launchProjectAt + _mintPeriodDuration - 1);
        assertEq(jbRulesets().currentOf(_projectId).cycleNumber, 1);
        // We should now be in phase 2, minting is paused and the treasury is frozen
        vm.warp(_launchProjectAt + _mintPeriodDuration);
        assertEq(jbRulesets().currentOf(_projectId).cycleNumber, 2);
        // Queue Phase 3

        //deployer.queueNextPhaseOf(_projectId);
        // We should now be in phase 4, game has ended
        vm.warp(_launchProjectAt + _mintPeriodDuration + _inBetweenMintAndFifa + _fifaDuration);
        assertEq(jbRulesets().currentOf(_projectId).cycleNumber, 3);
    }

    function testWhenScorecardIsSubmittedWithUnmintedTier() public {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);
        // Generate the scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }

        vm.expectRevert(abi.encodeWithSignature("DefifaGovernor_UnownedProposedCashoutValue()"));
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
    }

    // function testWhenPhaseIsAlreadyQueued() public {
    //     uint8 nTiers = 10;
    //     address[] memory _users = new address[](nTiers);
    //     DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
    //     (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
    //     // Phase 1: Mint
    //     vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
    //     //deployer.queueNextPhaseOf(_projectId);
    //     for (uint256 i = 0; i < nTiers; i++) {
    //         // Generate a new address for each tier
    //         _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
    //     // fund user
    //     vm.deal(_users[i], 1 ether);
    //     // Build metadata to buy specific NFT
    //     uint16[] memory rawMetadata = new uint16[](1);
    //     rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
    //     bytes memory metadata =
    //         _buildPayMetadata(abi.encode(_users[i], rawMetadata);
    //     // Pay to the project and mint an NFT
    //     vm.prank(_users[i]);
    //     jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether,_users[i], 0, "",
    // metadata); // Set the delegate as the user themselves
    //     DefifaDelegation[] memory tiered721SetDelegatesData =
    //         new DefifaDelegation[](1);
    //     tiered721SetDelegatesData[0] =
    //         DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
    //     vm.prank(_users[i]);
    //     _nft.setTierDelegatesTo(tiered721SetDelegatesData);
    //     // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
    //     vm.roll(block.number + 1);
    //     assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i],
    // block.number - 1)); }
    //     // Phase 2: Redeem
    //     vm.warp(block.timestamp + defifaData.mintPeriodDuration);
    //     //deployer.queueNextPhaseOf(_projectId);
    //     // Right at the end of Phase 2
    //     vm.warp(defifaData.start - 1);
    //     vm.expectRevert(abi.encodeWithSignature("PHASE_ALREADY_QUEUED()"));
    //     //deployer.queueNextPhaseOf(_projectId);
    // }

    function testSettingTierCashOutWeightBeforeEndPhase() public {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
            // Set the delegate as the user themselves
            DefifaDelegation[] memory tiered721SetDelegatesData = new DefifaDelegation[](1);
            tiered721SetDelegatesData[0] = DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
            vm.prank(_users[i]);
            _nft.setTierDelegatesTo(tiered721SetDelegatesData);
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            vm.warp(_tsReader.timestamp() + 1);
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER(),
                _governor.getAttestationWeight(_gameId, _users[i], uint48(_tsReader.timestamp()))
            );
        }
        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);
        // Generate the scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.warp(_tsReader.timestamp() + _governor.attestationStartTimeOf(_gameId));
        // All the users vote
        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        // Execute the proposal — should fail because grace period hasn't ended
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function testWhenCashOutWeightisMoreThanMaxCashOutWeight(uint8 nTiers) public {
        // Anything above 10 should cause the error we are looking for.
        // As a sanity check we let it also run for less than 10 to see if it does not error in that case.
        nTiers = uint8(bound(nTiers, 2, 20));

        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);

        uint256 cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 10;

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
            // fund user
            vm.deal(_users[i], 1 ether);
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );
            // Set the delegate as the user themselves
            DefifaDelegation[] memory tiered721SetDelegatesData = new DefifaDelegation[](1);
            tiered721SetDelegatesData[0] = DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
            vm.prank(_users[i]);
            _nft.setTierDelegatesTo(tiered721SetDelegatesData);
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER(),
                _governor.getAttestationWeight(_gameId, _users[i], uint48(block.timestamp))
            );
        }
        // Warp to scoring phase (past start time)
        vm.warp(defifaData.start + 1);

        // Generate the scorecards
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);

        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].cashOutWeight = cashOutWeight;
        }

        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.warp(block.timestamp + _governor.attestationStartTimeOf(_gameId));
        // No voting delay after the initial voting delay has passed in
        // assertEq(_governor.attestationStartTimeOf(_gameId), 0);
        // All the users vote
        // 0 = Against
        // 1 = For
        // 2 = Abstain
        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }

        // Forward the amount of blocks needed to reach the end (and round up)
        vm.warp(block.timestamp + _governor.attestationGracePeriodOf(_gameId) + 1);

        // With exact-weight validation, only nTiers == 10 produces an exact sum.
        // Any other count (under or over) triggers INVALID_CASHOUT_WEIGHTS.
        if (nTiers != 10) {
            vm.expectRevert(DefifaHook.DefifaHook_InvalidCashoutWeights.selector);
        }

        // Execute the proposal
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function getBasicDefifaLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0), // this way we dont need more tokenUris
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

    // ----- internal helpers ------
    function createDefifaProject(DefifaLaunchProjectData memory defifaLaunchData)
        internal
        returns (uint256 projectId, DefifaHook nft, DefifaGovernor _governor)
    {
        _governor = governor;
        (projectId) = deployer.launchGameWith(defifaLaunchData);
        // Get a reference to the latest configured funding cycle's data hook, which should be the hook that was
        // deployed and attached to the project.
        JBRuleset memory _fc = jbRulesets().currentOf(projectId);
        if (_fc.dataHook() == address(0)) {
            (_fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaHook(_fc.dataHook());
    }

    function mintAndRefund(DefifaHook _hook, uint256 _projectId, uint256 _tierId) internal {
        JB721Tier memory _tier = _hook.store().tierOf(address(_hook), _tierId, false);
        uint256 _cost = _tier.price;
        address _refundUser = address(bytes20(keccak256("refund_user")));
        // The user should have no balance
        assertEq(_hook.balanceOf(_refundUser), 0);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = uint16(_tierId); // reward tier, 1 indexed
        bytes memory metadata = _buildPayMetadata(abi.encode(_refundUser, rawMetadata));
        // Pay to the project and mint an NFT
        vm.deal(_refundUser, _cost);
        vm.prank(_refundUser);
        jbMultiTerminal().pay{value: _cost}(_projectId, JBConstants.NATIVE_TOKEN, _cost, _refundUser, 0, "", metadata);
        // User should no longer have any funds
        assertEq(_refundUser.balance, 0);
        // The user should have have a token
        assertEq(_hook.balanceOf(_refundUser), 1);
        uint256 _numberBurned = _hook.store().numberOfBurnedFor(address(_hook), _tierId);
        // Craft the metadata: redeem the tokenId
        bytes memory cashOutMetadata;
        {
            uint256[] memory cashOutId = new uint256[](1);
            cashOutId[0] = _generateTokenId(_tierId, _tier.initialSupply - --_tier.remainingSupply);
            cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutId));
        }
        vm.prank(_refundUser);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: _refundUser,
                projectId: _projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_refundUser),
                metadata: cashOutMetadata
            });
        // User should have their original funds again
        assertEq(_refundUser.balance, _cost);
        // User should no longer have the NFT
        assertEq(_hook.balanceOf(_refundUser), 0);
    }

    // Create launchProjectFor(..) payload
    string name = "NAME";
    string symbol = "SYM";
    string baseUri = "http://www.null.com/";
    string contractUri = "ipfs://null";
    address reserveBeneficiary = address(bytes20(keccak256("reserveBeneficiary")));
    //QmWmyoMoctfbAaiEs2G46gpeUmhqFRDW6KWo64y5r581Vz
    bytes32[] tokenUris = [
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89),
        bytes32(0x7D5A99F603F231D53A4F39D1521F98D2E8BB279CF29BEBFD0687DC98458E7F89)
    ];

    function _generateTokenId(uint256 _tierId, uint256 _tokenNumber) internal pure returns (uint256) {
        return (_tierId * 1_000_000_000) + _tokenNumber;
    }

    function _buildPayMetadata(bytes memory metadata) internal returns (bytes memory) {
        // Build the metadata using the tiers to mint and the overspending flag.
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;

        // Pass the hook ID.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));

        // Generate the metadata.
        return metadataHelper().createMetadata(ids, data);
    }

    function _buildCashOutMetadata(bytes memory metadata) internal returns (bytes memory) {
        // Build the metadata using the tiers to mint and the overspending flag.
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;

        // Pass the hook ID.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));

        // Generate the metadata.
        return metadataHelper().createMetadata(ids, data);
    }
}
