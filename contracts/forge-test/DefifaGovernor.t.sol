// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../DefifaGovernor.sol";
import "../DefifaDeployer.sol";
import "../DefifaDelegate.sol";
import "../DefifaDeployer.sol";
import "../DefifaTokenUriResolver.sol";
import "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";

import "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v5/test/helpers/JBTest.sol";
import "@bananapus/core-v5/src/libraries/JBRulesetMetadataResolver.sol";
import "@bananapus/721-hook-v5/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import '@bananapus/address-registry-v5/src/JBAddressRegistry.sol';

contract DefifaGovernorTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address _owner = 0x1000000000000000000000000000000000000000;
    uint256 blockSeconds = 12;

    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

    function setUp() public virtual override {
        super.setUp();

        // Terminal configurations.
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({
            terminal: jbMultiTerminal(),
            accountingContextsToAccept: _tokens 
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0, 
            duration: 10 days, 
            weight: 0,
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
        _protocolFeeProjectId = jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount = address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        // Launch the Defifa fee project.
        _defifaProjectId = jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        DefifaDelegate _delegate = new DefifaDelegate(jbDirectory(), IERC20(address(_defifaProjectTokenAccount)), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), blockSeconds);
        JBAddressRegistry _registry = new JBAddressRegistry();
        DefifaTokenUriResolver _tokenURIResolver = new DefifaTokenUriResolver(ITypeface(address(0)));
        deployer = new DefifaDeployer(
            address(_delegate),
            _tokenURIResolver,
            governor,
            jbController(),
            _registry,
            _protocolFeeProjectId,
            _defifaProjectId
        );

        // Transfer ownership of the delegate to the deployer.
        _delegate.transferOwnership(address(deployer));
        // Transfer ownership of the governor to the deployer.
        governor.transferOwnership(address(deployer));
    }

    function testReceiveVotingPower(uint8 nTiers, uint8 tier) public {
        vm.assume(nTiers < 100);
        vm.assume(nTiers >= tier);
        vm.assume(tier != 0);
        address _user = address(bytes20(keccak256("user")));
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);

        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // User should have no voting power (yet)
        assertEq(_governor.getAttestationWeight(_gameId, _user, block.number - 1), 0);
        // fund user
        vm.deal(_user, 1 ether);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        vm.assume(tier != 0);
        rawMetadata[0] = uint16(tier); // reward tier
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _user, rawMetadata);
        // Pay to the project and mint an NFT
        vm.prank(_user);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _user, 0, "", metadata);

        // The user should now have a balance
        assertEq(_nft.balanceOf(_user), 1);

        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.roll(block.number + 1);

        assertEq(_nft.store().tierOf(address(_nft), tier, false).votingUnits, 1);
        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _user, block.number - 1));
    }

    // redemptions can happen after mint phase
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
    //       type(IDefifaDelegate).interfaceId,
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
    //     bytes memory redemptionMetadata;
    //     {
    //       uint256[] memory redemptionId = new uint256[](1);
    //       redemptionId[0] = _generateTokenId(i + 1, 1);
    //       redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
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
    //       _metadata: redemptionMetadata
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
    //     bytes memory redemptionMetadata;
    //     {
    //       uint256[] memory redemptionId = new uint256[](1);
    //       redemptionId[0] = _generateTokenId(i + 1, 1);
    //       redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
    //     }
    //     // Here the refunds are not allowed but redemptions are,
    //     // so it should instead revert with an error showing that there is no redemption set for our tier
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
    //       _metadata: redemptionMetadata
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
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.expectRevert(JBTerminalStore.JBTerminalStore_RulesetPaymentPaused.selector);
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        }
        for (uint256 i = 0; i < nTiers; i++) {
            // Generate a new address for each tier
            _users[i] = address(bytes20(keccak256(abi.encode("user", Strings.toString(i)))));
        // fund user
        vm.deal(_users[i], 1 ether);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = uint16(i + 1); // reward tier, 1 indexed
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.expectRevert(JBTerminalStore.JBTerminalStore_RulesetPaymentPaused.selector);
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        }
    }

    // Transfers are no longer disabled
    // function testTransfer_fails_afterTradeDeadline() external {
    //   uint8 nTiers = 10;
    //   address[] memory _users = new address[](nTiers);
    //   DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData();
    //   (uint256 _projectId, DefifaDelegate _nft, ) = createDefifaProject(
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
    //       type(IDefifaDelegate).interfaceId,
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
    function testSetRedemptionRates_fails_unmetQuorum() external {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
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
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        // Set the delegate as the user themselves
        DefifaDelegation[] memory tiered721SetDelegatesData =
            new DefifaDelegation[](1);
        tiered721SetDelegatesData[0] =
            DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
        vm.prank(_users[i]);
        _nft.setTierDelegatesTo(tiered721SetDelegatesData);
        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.roll(block.number + 1);
        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        }
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].redemptionWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.roll(block.number + _governor.attestationStartTimeOf(_gameId) + 1);
        // '_governor.attestationStartTimeOf(_gameId)' internally uses the timestamp and not the block number, so we have to modify it for the next assert
        // block time is 12 secs
        vm.warp(block.timestamp + (_governor.attestationStartTimeOf(_gameId) * 12));
        // We have only 40% vote on the proposal, making it still be below quorum.
        for (uint256 i = 0; i < _users.length * 4 / 10; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        // Forward the amount of blocks needed to reach the end (and round up)
        vm.roll(block.number + _governor.attestationGracePeriodOf(_gameId) + 1);
        // each block is of 12 secs
        vm.warp(block.timestamp + (_governor.attestationGracePeriodOf(_gameId) * 12) + 1);
        // Execute the proposal
        vm.expectRevert(DefifaGovernor.NOT_ALLOWED.selector);
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function testSetRedemptionRatesAndRedeem_multipleTiers(uint8 nTiers, uint8[] calldata distribution) public {
        vm.assume(nTiers > 10 && nTiers < 100);
        vm.assume(distribution.length < nTiers);

        uint256 _sumDistribution;
        for (uint256 i = 0; i < distribution.length; i++) {
            _sumDistribution += distribution[i];
        }
        vm.assume(_sumDistribution > 0);
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        uint256 totalRedemptionWeight = _nft.TOTAL_REDEMPTION_WEIGHT();

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
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.roll(block.number + 1);
        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        // Have a user mint and refund the tier
        mintAndRefund(_nft, _projectId, i + 1);
        }
        // Have a user mint and refund the tier
        mintAndRefund(_nft, _projectId, 1);

        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](nTiers);
        uint256 assignedRedemptionWeight;
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            if (distribution.length <= i) continue;
            scorecards[i].redemptionWeight = (uint256(distribution[i]) * totalRedemptionWeight) / _sumDistribution;
            assignedRedemptionWeight += scorecards[i].redemptionWeight;
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.roll(block.number + _governor.attestationStartTimeOf(_gameId) + 1);
        // '_governor.attestationStartTimeOf(_gameId)' internally uses the timestamp and not the block number, so we have to modify it for the next assert
        // block time is 12 secs
        vm.warp(block.timestamp + (_governor.attestationStartTimeOf(_gameId) * 12));
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
        // Forward the amount of blocks needed to reach the end (and round up)
        vm.roll(block.number + _governor.attestationGracePeriodOf(_gameId) + 1);
        // each block is of 12 secs
        vm.warp(block.timestamp + (_governor.attestationGracePeriodOf(_gameId) * 12) + 1);

        _governor.ratifyScorecardFrom(_gameId, scorecards);
        vm.roll(block.number + 1);

        uint256 _pot = jbMultiTerminal().currentSurplusOf(_projectId,
             jbMultiTerminal().accountingContextsOf(_projectId),
            18,
             JBCurrencyIds.ETH
                                                         );

        // Verify that the redemptionWeights actually changed
        for (uint256 i = 0; i < scorecards.length; i++) {
            address _user = _users[i];
            // Tier's are 1 indexed and should be stored 0 indexed.
            assertEq(_nft.tierRedemptionWeights()[i], scorecards[i].redemptionWeight);
            // Craft the metadata: redeem the tokenId
            bytes memory redemptionMetadata;
            {
                uint256[] memory redemptionId = new uint256[](1);
                redemptionId[0] = _generateTokenId(i + 1, 1);
                redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
            }
            // If the redemption is 0 this will revert
            if (scorecards[i].redemptionWeight == 0) {
                vm.expectRevert(abi.encodeWithSignature("NOTHING_TO_CLAIM()"));
            }
            vm.prank(_user);
            JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
                holder: _user,
                projectId: _projectId,
                cashOutCount: 0, 
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_user),
                metadata: redemptionMetadata
            });
            if (scorecards[i].redemptionWeight == 0) continue;
            // We calculate the expected output based on the given distribution and how much is in the pot
            uint256 _expectedTierRedemption = _pot;
            _expectedTierRedemption = (_expectedTierRedemption * distribution[i]) / _sumDistribution;
            // Assert that our expected tier redemption is ~equal to the actual amount
            // Allowing for some rounding errors, max allowed error is 0.000001 ether
            assertApproxEqRel(_expectedTierRedemption, _user.balance, 0.001 ether);
            // assertLt(_expectedTierRedemption - _user.balance, 10 ** 12);
        }
        // All NFTs should have been redeemed, only some dust should be left
        // Max allowed dust is 0.0001
        uint256 remainingSurplus = jbMultiTerminal().currentSurplusOf(_projectId,
             jbMultiTerminal().accountingContextsOf(_projectId),
            18,
             JBCurrencyIds.ETH
                                                         );
        assertApproxEqAbs(remainingSurplus, _pot * (totalRedemptionWeight - assignedRedemptionWeight) / totalRedemptionWeight, 10 ** 14);
    }

    function testVotingPowerDecreasesAfterRefund() public {
        uint256 nOfOtherTiers = 31;
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaDelegate _delegate, DefifaGovernor _governor) = createDefifaProject(defifaData);

        // Phase 1: minting
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        JB721Tier memory _tier = _delegate.store().tierOf(address(_delegate), 1, false);
        uint256 _cost = _tier.price;

        address _delegateUser = address(bytes20(keccak256("_delegateUser")));
        address _refundUser = address(bytes20(keccak256("refund_user")));
        // The user should have no balance
        assertEq(_delegate.balanceOf(_refundUser), 0);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = uint16(1); // reward tier, 1 indexed
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _refundUser, rawMetadata);
        // Pay to the project and mint an NFT
        vm.deal(_refundUser, _cost);

        vm.prank(_refundUser);
        jbMultiTerminal().pay{value: _cost}(_projectId, JBConstants.NATIVE_TOKEN, _cost, _refundUser, 0, "", metadata);

        vm.roll(block.number + 1);

        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _refundUser, block.number - 1));

        // User should no longer have any funds
        assertEq(_refundUser.balance, 0);
        // The user should have have a token
        assertEq(_delegate.balanceOf(_refundUser), 1);

        uint256 _numberBurned = _delegate.store().numberOfBurnedFor(address(_delegate), 1);
        // Craft the metadata: redeem the tokenId
        bytes memory redemptionMetadata;
        {
            uint256[] memory redemptionId = new uint256[](1);
            redemptionId[0] = _generateTokenId(1, _tier.initialSupply - _tier.remainingSupply + 1 + _numberBurned);
            redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
        }

        vm.prank(_refundUser);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: _refundUser,
            projectId: _projectId,
            cashOutCount: 0, 
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_refundUser),
            metadata: redemptionMetadata
        });
        vm.roll(block.number + 1);

        assertEq(_refundUser.balance, _cost);
        assertEq(_delegate.balanceOf(_refundUser), 0);

        assertEq(0, _governor.getAttestationWeight(_gameId, _refundUser, block.number - 1));
    }

    function testRevertsIfDelegationisDoneAfterMintPhase(
        uint8 nUsersWithWinningTier,
        uint8 winningTierExtraWeight,
        uint8 baseRedemptionWeight
    ) public {
        uint256 nOfOtherTiers = 31;
        vm.assume(nUsersWithWinningTier > 1 && nUsersWithWinningTier < 100);
        uint256 totalWeight = baseRedemptionWeight * (nOfOtherTiers + 1) + winningTierExtraWeight;
        vm.assume(totalWeight > 1);

        address[] memory _users = new address[](nOfOtherTiers + nUsersWithWinningTier);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
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
            bytes memory metadata =
                abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether,_users[i], 0, "", metadata);
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            vm.roll(block.number + 1);
            assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        } else {
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(nOfOtherTiers + 1); // reward tier, 1 indexed
            bytes memory metadata =
                abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
            // Forward 1 block, user should have a part of the voting power of their tier
            vm.roll(block.number + 1);
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER() / (i - nOfOtherTiers + 1),
                _governor.getAttestationWeight(_gameId, _users[i], block.number - 1)
            );
        }
        }
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE()"));
        _nft.setTierDelegateTo(_users[1], 1);
    }

    function testSetRedemptionRatesAndRedeem_singleTier(
        uint8 nUsersWithWinningTier,
        uint8 winningTierExtraWeight,
        uint8 baseRedemptionWeight
    ) public {
        uint256 nOfOtherTiers = 31;
        vm.assume(nUsersWithWinningTier > 1 && nUsersWithWinningTier < 100);
        uint256 totalWeight = baseRedemptionWeight * (nOfOtherTiers + 1) + winningTierExtraWeight;
        vm.assume(totalWeight > 1);

        address[] memory _users = new address[](nOfOtherTiers + nUsersWithWinningTier);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(uint8(nOfOtherTiers + 1));
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
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
            bytes memory metadata =
                abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0,  "", metadata);
            // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
            vm.roll(block.number + 1);
            assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        } else {
            // Build metadata to buy specific NFT
            uint16[] memory rawMetadata = new uint16[](1);
            rawMetadata[0] = uint16(nOfOtherTiers + 1); // reward tier, 1 indexed
            bytes memory metadata =
                abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
            // Pay to the project and mint an NFT
            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0,  "", metadata);
            // Forward 1 block, user should have a part of the voting power of their tier
            vm.roll(block.number + 1);
            assertEq(
                _governor.MAX_ATTESTATION_POWER_TIER() / (i - nOfOtherTiers + 1),
                _governor.getAttestationWeight(_gameId, _users[i], block.number - 1)
            );
        }
        }
        // Have a user mint and refund the tier
        mintAndRefund(_nft, _projectId, 1);
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](
            nOfOtherTiers + 1
        );
        
        uint256 totalRedemptionWeight = _nft.TOTAL_REDEMPTION_WEIGHT();

        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        uint256 assignedRedemptionWeight;
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            if (baseRedemptionWeight != 0) {
                scorecards[i].redemptionWeight = (totalRedemptionWeight * uint256(baseRedemptionWeight)) / totalWeight;
            }
            if (i == nOfOtherTiers && winningTierExtraWeight != 0) {
                scorecards[i].redemptionWeight += (totalRedemptionWeight * uint256(winningTierExtraWeight)) / totalWeight;
            }
            assignedRedemptionWeight += scorecards[i].redemptionWeight;
        }
        {
            // Forward time so proposals can be created
            uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
            // Forward time so voting becomes active
            vm.roll(block.number + _governor.attestationStartTimeOf(_gameId) + 1);
            // '_governor.attestationStartTimeOf(_gameId)' internally uses the timestamp and not the block number, so we have to modify it for the next assert
            // block time is 12 secs
            vm.warp(block.timestamp + (_governor.attestationStartTimeOf(_gameId) * 12));
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
        vm.roll(block.number + _governor.attestationGracePeriodOf(_gameId) + 1);
        // each block is of 12 secs
        vm.warp(block.timestamp + (_governor.attestationGracePeriodOf(_gameId) * 12) + 1);

        _governor.ratifyScorecardFrom(_gameId, scorecards);
        vm.roll(block.number + 1);

        uint256 _pot = jbMultiTerminal().currentSurplusOf(_projectId,
             jbMultiTerminal().accountingContextsOf(_projectId),
            18,
             JBCurrencyIds.ETH
                                                         );

        // Verify that the redemptionWeights actually changed
        for (uint256 i = 0; i < _users.length; i++) {
            address _user = _users[i];
            uint256 _tier = i <= nOfOtherTiers ? i + 1 : nOfOtherTiers + 1;
            // Craft the metadata: redeem the tokenId
            bytes memory redemptionMetadata;
            {
                uint256[] memory redemptionId = new uint256[](1);
                redemptionId[0] = _generateTokenId(_tier, _tier == nOfOtherTiers + 1 ? i - nOfOtherTiers + 1 : 1);
                redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
            }
            uint256 _expectedTierRedemption;
            {
                // Calculate how much weight his tier has
                uint256 _tierWeight = _tier == nOfOtherTiers + 1
                    ? uint256(baseRedemptionWeight) + uint256(winningTierExtraWeight)
                    : baseRedemptionWeight;

                    // If the redemption is 0 this will revert
                    if (_tierWeight == 0) vm.expectRevert(abi.encodeWithSignature("NOTHING_TO_CLAIM()"));
                    vm.prank(_user);
                    JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
                        holder: _user,
                        projectId: _projectId,
                        cashOutCount: 0, 
                        tokenToReclaim: JBConstants.NATIVE_TOKEN,
                        minTokensReclaimed: 0,
                        beneficiary: payable(_user),
                        metadata: redemptionMetadata
                    });
                    // We calculate the expected output based on the given distribution and how much is in the pot
                    _expectedTierRedemption = (_pot * _tierWeight) / totalWeight;
            }
            {
                // If this is the winning tier then the amount is divided among the nUsersWithWinningTier
                if (_tier == nOfOtherTiers + 1) {
                    _expectedTierRedemption = _expectedTierRedemption / nUsersWithWinningTier;
                }
            }
            // Assert that our expected tier redemption is ~equal to the actual amount
            // Allowing for some rounding errors, max allowed error is 0.000001 ether
            assertApproxEqRel(_expectedTierRedemption, _user.balance, 0.0001 ether);
        }
        // All NFTs should have been redeemed, only some dust should be left
        // Max allowed dust is 0.0001
        uint256 remainingSurplus = jbMultiTerminal().currentSurplusOf(_projectId,
             jbMultiTerminal().accountingContextsOf(_projectId),
            18,
             JBCurrencyIds.ETH
                                                         );
        assertApproxEqAbs(remainingSurplus, _pot * (totalRedemptionWeight - assignedRedemptionWeight) / totalRedemptionWeight, 10 ** 14);
    }

    function testPhaseTimes(
        uint16 _durationUntilProjectLaunch,
        uint16 _mintPeriodDuration,
        uint16 _inBetweenMintAndFifa,
        uint16 _fifaDuration
    ) public {
        vm.assume(
            _durationUntilProjectLaunch > 2 && _mintPeriodDuration > 1 && _inBetweenMintAndFifa > 1 && _fifaDuration > 1
        );
        uint48 _launchProjectAt = uint48(block.timestamp) + _durationUntilProjectLaunch;
        uint48 _end = _launchProjectAt + uint48(_mintPeriodDuration) + uint48(_inBetweenMintAndFifa) + uint48(_fifaDuration);
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](1);
        tierParams[0] = DefifaTierParams({
            price: 1 ether,
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
            token: JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: JBCurrencyIds.ETH
            }) ,
            mintPeriodDuration: _mintPeriodDuration,
            start: _launchProjectAt + uint48(_mintPeriodDuration) + _inBetweenMintAndFifa,
            refundPeriodDuration: _inBetweenMintAndFifa,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100381,
            defaultAttestationDelegate: address(0),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal()
        });
        (uint256 _projectId, DefifaDelegate _nft,) = createDefifaProject(_launchData);
        // Wait until the phase 1 start
        vm.warp(_launchProjectAt);
        // Get the delegate
        _nft = DefifaDelegate(jbRulesets().currentOf(_projectId).dataHook());
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
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        // Phase 1: Mint
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].redemptionWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }

        vm.expectRevert(abi.encodeWithSignature("UNOWNED_PROPOSED_REDEMPTION_VALUE()"));
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
    }

    // function testWhenPhaseIsAlreadyQueued() public {
    //     uint8 nTiers = 10;
    //     address[] memory _users = new address[](nTiers);
    //     DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
    //     (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
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
    //         abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
    //     // Pay to the project and mint an NFT
    //     vm.prank(_users[i]);
    //     jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether,_users[i], 0, "", metadata);
    //     // Set the delegate as the user themselves
    //     DefifaDelegation[] memory tiered721SetDelegatesData =
    //         new DefifaDelegation[](1);
    //     tiered721SetDelegatesData[0] =
    //         DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
    //     vm.prank(_users[i]);
    //     _nft.setTierDelegatesTo(tiered721SetDelegatesData);
    //     // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
    //     vm.roll(block.number + 1);
    //     assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
    //     }
    //     // Phase 2: Redeem
    //     vm.warp(block.timestamp + defifaData.mintPeriodDuration);
    //     //deployer.queueNextPhaseOf(_projectId);
    //     // Right at the end of Phase 2
    //     vm.warp(defifaData.start - 1);
    //     vm.expectRevert(abi.encodeWithSignature("PHASE_ALREADY_QUEUED()"));
    //     //deployer.queueNextPhaseOf(_projectId);
    // }

    function testSettingTierRedemptionWeightBeforeEndPhase() public {
        uint8 nTiers = 10;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
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
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        // Set the delegate as the user themselves
        DefifaDelegation[] memory tiered721SetDelegatesData =
            new DefifaDelegation[](1);
        tiered721SetDelegatesData[0] =
            DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
        vm.prank(_users[i]);
        _nft.setTierDelegatesTo(tiered721SetDelegatesData);
        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.roll(block.number + 1);
        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        }
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);
        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](nTiers);
        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].redemptionWeight = i % 2 == 0 ? 1_000_000_000 / (scorecards.length / 2) : 0;
        }
        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.roll(block.number + _governor.attestationStartTimeOf(_gameId) + 1);
        // '_governor.attestationStartTimeOf(_gameId)' internally uses the timestamp and not the block number, so we have to modify it for the next assert
        // block time is 12 secs
        vm.warp(block.timestamp + (_governor.attestationStartTimeOf(_gameId) * 12));
        // All the users vote
        // 0 = Against
        // 1 = For
        // 2 = Abstain
        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            _governor.attestToScorecardFrom(_gameId, _proposalId);
        }
        // Execute the proposal
        vm.expectRevert(DefifaGovernor.NOT_ALLOWED.selector);
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function testWhenRedemptionWeightisMoreThanMaxRedemptionWeight(uint8 nTiers) public {
        // Anything above 10 should cause the error we are looking for.
        // As a sanity check we let it also run for less than 10 to see if it does not error in that case. 
        nTiers = uint8(bound(nTiers, 2, 20));

        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = getBasicDefifaLaunchData(nTiers);
        (uint256 _projectId, DefifaDelegate _nft, DefifaGovernor _governor) = createDefifaProject(defifaData);
        
        uint256 redemptionWeight = _nft.TOTAL_REDEMPTION_WEIGHT() / 10;

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
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _users[i], rawMetadata);
        // Pay to the project and mint an NFT
        vm.prank(_users[i]);
        jbMultiTerminal().pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata);
        // Set the delegate as the user themselves
        DefifaDelegation[] memory tiered721SetDelegatesData =
            new DefifaDelegation[](1);
        tiered721SetDelegatesData[0] =
            DefifaDelegation({delegatee: _users[i], tierId: uint256(i + 1)});
        vm.prank(_users[i]);
        _nft.setTierDelegatesTo(tiered721SetDelegatesData);
        // Forward 1 block, user should receive all the voting power of the tier, as its the only NFT
        vm.roll(block.number + 1);
        assertEq(_governor.MAX_ATTESTATION_POWER_TIER(), _governor.getAttestationWeight(_gameId, _users[i], block.number - 1));
        }
        // Phase 2: Redeem
        vm.warp(block.timestamp + defifaData.mintPeriodDuration);
        //deployer.queueNextPhaseOf(_projectId);

        // Generate the scorecards
        DefifaTierRedemptionWeight[] memory scorecards = new DefifaTierRedemptionWeight[](nTiers);

        // We can't have a neutral outcome, so we only give shares to tiers that are an even number (in our array)
        for (uint256 i = 0; i < scorecards.length; i++) {
            scorecards[i].id = i + 1;
            scorecards[i].redemptionWeight = redemptionWeight;
        }

        // Forward time so proposals can be created
        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        // Forward time so voting becomes active
        vm.roll(block.number + _governor.attestationStartTimeOf(_gameId) + 1);
        // '_governor.attestationStartTimeOf(_gameId)' internally uses the timestamp and not the block number, so we have to modify it for the next assert
        // block time is 12 secs
        vm.warp(block.timestamp + (_governor.attestationStartTimeOf(_gameId) * 12));
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
        vm.roll(block.number + _governor.attestationGracePeriodOf(_gameId) + 1);
        // each block is of 12 secs
        vm.warp(block.timestamp + (_governor.attestationGracePeriodOf(_gameId) * 12) + 1);
        
        // This is the error we are looking for in this test, it should only trigger when redemptionWeight is more than the max, which should happen at > 10.
        if (nTiers > 10){
            vm.expectRevert(DefifaDelegate.INVALID_REDEMPTION_WEIGHTS.selector);
        }

        // Execute the proposal
        _governor.ratifyScorecardFrom(_gameId, scorecards);
    }

    function getBasicDefifaLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            tierParams[i] = DefifaTierParams({
                price: 1 ether,
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
            token: JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: JBCurrencyIds.ETH
            }) ,
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100381,
            defaultAttestationDelegate: address(0),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal()
        });
    }

    // ----- internal helpers ------
    function createDefifaProject(DefifaLaunchProjectData memory defifaLaunchData)
    internal
    returns (uint256 projectId, DefifaDelegate nft, DefifaGovernor _governor)
    {
        _governor = governor;
        (projectId) = deployer.launchGameWith(defifaLaunchData);
        // Get a reference to the latest configured funding cycle's data source, which should be the delegate that was deployed and attached to the project.
        JBRuleset memory _fc = jbRulesets().currentOf(projectId);
        if (_fc.dataHook() == address(0)) {
            (_fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaDelegate(_fc.dataHook());
    }

    function mintAndRefund(DefifaDelegate _delegate, uint256 _projectId, uint256 _tierId) internal {
        JB721Tier memory _tier = _delegate.store().tierOf(address(_delegate), _tierId, false);
        uint256 _cost = _tier.price;
        address _refundUser = address(bytes20(keccak256("refund_user")));
        // The user should have no balance
        assertEq(_delegate.balanceOf(_refundUser), 0);
        // Build metadata to buy specific NFT
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = uint16(_tierId); // reward tier, 1 indexed
        bytes memory metadata =
            abi.encode(bytes32(0), bytes32(0), type(IDefifaDelegate).interfaceId, _refundUser, rawMetadata);
        // Pay to the project and mint an NFT
        vm.deal(_refundUser, _cost);
        vm.prank(_refundUser);
        jbMultiTerminal().pay{value: _cost}(_projectId, JBConstants.NATIVE_TOKEN, _cost,_refundUser, 0, "", metadata);
        // User should no longer have any funds
        assertEq(_refundUser.balance, 0);
        // The user should have have a token
        assertEq(_delegate.balanceOf(_refundUser), 1);
        uint256 _numberBurned = _delegate.store().numberOfBurnedFor(address(_delegate), _tierId);
        // Craft the metadata: redeem the tokenId
        bytes memory redemptionMetadata;
        {
            uint256[] memory redemptionId = new uint256[](1);
            redemptionId[0] =
                _generateTokenId(_tierId, _tier.initialSupply - --_tier.remainingSupply);
            redemptionMetadata = abi.encode(bytes32(0), type(IDefifaDelegate).interfaceId, redemptionId);
        }
        vm.prank(_refundUser);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: _refundUser,
            projectId: _projectId,
            cashOutCount: 0, 
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_refundUser),
            metadata: redemptionMetadata
        });
        // User should have their original funds again
        assertEq(_refundUser.balance, _cost);
        // User should no longer have the NFT
        assertEq(_delegate.balanceOf(_refundUser), 0);
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
}
