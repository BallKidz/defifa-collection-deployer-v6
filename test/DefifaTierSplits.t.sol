// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/DefifaGovernor.sol";
import "../src/DefifaDeployer.sol";
import "../src/DefifaHook.sol";
import "../src/DefifaTokenUriResolver.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBSplits} from "@bananapus/core-v6/src/interfaces/IJBSplits.sol";

/// @title DefifaTierSplitsTest
/// @notice Integration tests for the per-tier splits feature: verifies that on-mint split forwarding,
/// refund reduction, and zero-split backward compatibility all work correctly.
contract DefifaTierSplitsTest is JBTest, TestBaseWorkflow {
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

    // -----------------------------------------------------------------------
    // Test 1: Split beneficiary receives 20% of tierPrice on mint,
    //         treasury retains 80%.
    // -----------------------------------------------------------------------
    function testSplitForwardedOnMint() external {
        address splitBeneficiary1 = address(bytes20(keccak256("splitBen1")));
        address splitBeneficiary2 = address(bytes20(keccak256("splitBen2")));
        uint256 tierPrice = 1 ether;
        uint32 splitPercent = 200_000_000; // 20%

        // Build tier params with per-tier splits.
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](2);

        JBSplit[] memory splits1 = new JBSplit[](1);
        splits1[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT), // 100% of the split amount goes to this beneficiary
            projectId: 0,
            beneficiary: payable(splitBeneficiary1),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplit[] memory splits2 = new JBSplit[](1);
        splits2[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(splitBeneficiary2),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        tierParams[0] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier1",
            splits: splits1
        });
        tierParams[1] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier2",
            splits: splits2
        });

        DefifaLaunchProjectData memory defifaData = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tierPrice: uint104(tierPrice),
            tierSplitPercent: splitPercent,
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

        (uint256 projectId, DefifaHook _nft,) = _createDefifaProject(defifaData);

        // Register per-tier splits in JBSplits.
        // The hook address forms the first 160 bits of the split group ID, so the hook itself
        // is authorized to call setSplitGroupsOf for these groups.
        _registerTierSplits(projectId, _nft, 1, splits1);
        _registerTierSplits(projectId, _nft, 2, splits2);

        // Mint phase.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);

        // Record beneficiary balance before mint.
        uint256 benBalBefore = splitBeneficiary1.balance;

        // Mint 1 NFT from tier 1.
        address minter = address(bytes20(keccak256("minter1")));
        vm.deal(minter, tierPrice);
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = 1; // tier 1
        bytes memory payMetadata = _buildPayMetadata(abi.encode(minter, rawMetadata));
        vm.prank(minter);
        jbMultiTerminal().pay{value: tierPrice}(
            projectId, JBConstants.NATIVE_TOKEN, tierPrice, minter, 0, "", payMetadata
        );

        // The split beneficiary should have received 20% of tierPrice.
        uint256 expectedSplitAmount = (tierPrice * splitPercent) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 benBalAfter = splitBeneficiary1.balance;
        assertEq(benBalAfter - benBalBefore, expectedSplitAmount, "split beneficiary should receive 20% of tierPrice");

        // Treasury should hold 80% of tierPrice.
        uint256 treasuryBalance =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        uint256 expectedTreasury = tierPrice - expectedSplitAmount;
        assertEq(treasuryBalance, expectedTreasury, "treasury should hold 80% of tierPrice");
    }

    // -----------------------------------------------------------------------
    // Test 2: Refund during refund phase returns only the retained amount
    //         (tierPrice minus the split amount that was already forwarded).
    // -----------------------------------------------------------------------
    function testRefundExcludesSplitAmount() external {
        address splitBeneficiary = address(bytes20(keccak256("splitBenRefund")));
        uint256 tierPrice = 1 ether;
        uint32 splitPercent = 200_000_000; // 20%

        JBSplit[] memory splits1 = new JBSplit[](1);
        splits1[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        DefifaTierParams[] memory tierParams = new DefifaTierParams[](2);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier1",
            splits: splits1
        });
        tierParams[1] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier2",
            splits: new JBSplit[](0)
        });

        DefifaLaunchProjectData memory defifaData = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tierPrice: uint104(tierPrice),
            tierSplitPercent: splitPercent,
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

        (uint256 projectId, DefifaHook _nft,) = _createDefifaProject(defifaData);

        // Register per-tier splits in JBSplits so the split amount is forwarded to the beneficiary.
        _registerTierSplits(projectId, _nft, 1, splits1);

        // Mint phase.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);

        // Mint 1 NFT from tier 1.
        address minter = address(bytes20(keccak256("refundMinter")));
        vm.deal(minter, tierPrice);
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = 1;
        bytes memory payMetadata = _buildPayMetadata(abi.encode(minter, rawMetadata));
        vm.prank(minter);
        jbMultiTerminal().pay{value: tierPrice}(
            projectId, JBConstants.NATIVE_TOKEN, tierPrice, minter, 0, "", payMetadata
        );

        // Verify NFT was minted.
        assertEq(_nft.balanceOf(minter), 1, "minter should hold 1 NFT");

        // Advance to refund phase.
        vm.warp(defifaData.start - defifaData.refundPeriodDuration);

        // Record minter balance before refund.
        uint256 minterBalBefore = minter.balance;

        // Cash out (refund) the NFT.
        uint256[] memory cashOutIds = new uint256[](1);
        cashOutIds[0] = _generateTokenId(1, 1);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

        vm.prank(minter);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: minter,
                projectId: projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(minter),
                metadata: cashOutMetadata
            });

        // Minter should receive approximately 80% of tierPrice (the 20% was already forwarded to splits).
        uint256 expectedSplitAmount = (tierPrice * splitPercent) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedRefund = tierPrice - expectedSplitAmount;
        uint256 actualRefund = minter.balance - minterBalBefore;

        assertEq(actualRefund, expectedRefund, "refund should be 80% of tierPrice (split amount excluded)");
        assertEq(_nft.balanceOf(minter), 0, "NFT should be burned after refund");
    }

    // -----------------------------------------------------------------------
    // Test 3: With tierSplitPercent=0, full price is refunded (backward compat).
    // -----------------------------------------------------------------------
    function testZeroSplitPercentUnchanged() external {
        uint256 tierPrice = 1 ether;

        DefifaTierParams[] memory tierParams = new DefifaTierParams[](2);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier1",
            splits: new JBSplit[](0)
        });
        tierParams[1] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "Tier2",
            splits: new JBSplit[](0)
        });

        DefifaLaunchProjectData memory defifaData = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tierPrice: uint104(tierPrice),
            tierSplitPercent: 0, // No splits!
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

        (uint256 projectId, DefifaHook _nft,) = _createDefifaProject(defifaData);

        // Mint phase.
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);

        // Mint 1 NFT from tier 1.
        address minter = address(bytes20(keccak256("zeroSplitMinter")));
        vm.deal(minter, tierPrice);
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = 1;
        bytes memory payMetadata = _buildPayMetadata(abi.encode(minter, rawMetadata));
        vm.prank(minter);
        jbMultiTerminal().pay{value: tierPrice}(
            projectId, JBConstants.NATIVE_TOKEN, tierPrice, minter, 0, "", payMetadata
        );

        // Treasury should hold the full tierPrice.
        uint256 treasuryBalance =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        assertEq(treasuryBalance, tierPrice, "treasury should hold full tierPrice when splitPercent=0");

        // Advance to refund phase.
        vm.warp(defifaData.start - defifaData.refundPeriodDuration);

        // Record minter balance before refund.
        uint256 minterBalBefore = minter.balance;

        // Cash out (refund) the NFT.
        uint256[] memory cashOutIds = new uint256[](1);
        cashOutIds[0] = _generateTokenId(1, 1);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

        vm.prank(minter);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: minter,
                projectId: projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(minter),
                metadata: cashOutMetadata
            });

        // Minter should receive the full tierPrice.
        uint256 actualRefund = minter.balance - minterBalBefore;
        assertEq(actualRefund, tierPrice, "full tierPrice should be refunded when splitPercent=0");
        assertEq(_nft.balanceOf(minter), 0, "NFT should be burned after refund");
    }

    // ========================== Helpers ==========================

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

    /// @notice Registers per-tier splits in the JBSplits contract for a given tier.
    /// @dev The hook address forms the first 160 bits of the split group ID, so the hook is
    /// authorized to call setSplitGroupsOf for its own tier groups. We use vm.prank to simulate
    /// the hook setting its own splits.
    function _registerTierSplits(
        uint256 projectId,
        DefifaHook _nft,
        uint256 tierId,
        JBSplit[] memory splits
    )
        internal
    {
        uint256 groupId = uint256(uint160(address(_nft))) | (tierId << 160);
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: groupId, splits: splits});
        // Cache the splits contract reference before pranking, since vm.prank only applies to the
        // next external call.
        IJBSplits splitsContract = jbController().SPLITS();
        vm.prank(address(_nft));
        splitsContract.setSplitGroupsOf(projectId, 0, splitGroups);
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

    function _buildCashOutMetadata(bytes memory metadata) internal returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
