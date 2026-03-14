// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @title MintCostHandler
/// @notice Stateful fuzz handler that performs pay and refund operations,
/// tracking the expected _totalMintCost alongside.
contract MintCostHandler is Test {
    DefifaHook public nft;
    IJB721TiersHookStore public store;
    uint256 public pid;
    MetadataResolverHelper public metaHelper;
    IJBMultiTerminal public terminal;
    address public hookCodeOrigin;

    uint256 public expectedMintCost;
    uint256 public tierPrice;
    uint8 public nTiers;
    uint256 public mintCount;
    uint256 public burnCount;

    struct TokenInfo {
        address holder;
        uint256 tierId;
        uint256 tokenNumber;
    }

    TokenInfo[] public liveTokens;

    constructor(
        DefifaHook _nft,
        uint256 _pid,
        MetadataResolverHelper _metaHelper,
        IJBMultiTerminal _terminal,
        address _hookCodeOrigin,
        uint256 _tierPrice,
        uint8 _nTiers
    ) {
        nft = _nft;
        pid = _pid;
        metaHelper = _metaHelper;
        terminal = _terminal;
        hookCodeOrigin = _hookCodeOrigin;
        tierPrice = _tierPrice;
        nTiers = _nTiers;
        store = _nft.store();
    }

    /// @notice Mint a new NFT for a random tier.
    function mint(uint256 tierSeed) external {
        uint256 tierId = bound(tierSeed, 1, nTiers);

        // Check remaining supply
        JB721Tier memory tier = store.tierOf(address(nft), tierId, false);
        if (tier.remainingSupply == 0) return;

        address user = _userAddr(mintCount + 1000);
        vm.deal(user, tierPrice);

        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tierId);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metaHelper.getId("pay", hookCodeOrigin);

        vm.prank(user);
        terminal.pay{value: tierPrice}(
            pid, JBConstants.NATIVE_TOKEN, tierPrice, user, 0, "", metaHelper.createMetadata(ids, data)
        );

        uint256 nb = store.numberOfBurnedFor(address(nft), tierId);
        uint256 tokenNumber = tier.initialSupply - tier.remainingSupply + 1 + nb;

        liveTokens.push(TokenInfo({holder: user, tierId: tierId, tokenNumber: tokenNumber}));

        expectedMintCost += tierPrice;
        mintCount++;
    }

    /// @notice Refund (cashout during mint phase) — burns the NFT and returns exact price.
    function refund(uint256 indexSeed) external {
        if (liveTokens.length == 0) return;
        uint256 idx = bound(indexSeed, 0, liveTokens.length - 1);

        TokenInfo memory info = liveTokens[idx];
        uint256 tokenId = (info.tierId * 1_000_000_000) + info.tokenNumber;

        uint256[] memory cid = new uint256[](1);
        cid[0] = tokenId;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory bids = new bytes4[](1);
        bids[0] = metaHelper.getId("cashOut", hookCodeOrigin);

        vm.prank(info.holder);
        JBMultiTerminal(address(terminal))
            .cashOutTokensOf({
                holder: info.holder,
                projectId: pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(info.holder),
                metadata: metaHelper.createMetadata(bids, data)
            });

        expectedMintCost -= tierPrice;
        burnCount++;

        // Swap-and-pop
        liveTokens[idx] = liveTokens[liveTokens.length - 1];
        liveTokens.pop();
    }

    function liveTokenCount() external view returns (uint256) {
        return liveTokens.length;
    }

    function _userAddr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("inv_user", i))));
    }
}

/// @title DefifaMintCostInvariantTest
/// @notice Invariant: _totalMintCost == sum of tier prices of all live (non-burned) NFTs.
contract DefifaMintCostInvariantTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    DefifaDeployer deployer;
    DefifaHook hookImpl;
    DefifaGovernor governor;
    DefifaHook nft;

    /// @dev Storage slot of _totalMintCost in DefifaHook (from `forge inspect DefifaHook storage-layout`).
    uint256 constant TOTAL_MINT_COST_SLOT = 141;

    uint8 constant N_TIERS = 4;
    uint256 constant TIER_PRICE = 1 ether;

    MintCostHandler handler;

    function setUp() public virtual override {
        super.setUp();

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
        address _nanaToken =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        address _defifaToken = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hookImpl = new DefifaHook(jbDirectory(), IERC20(_defifaToken), IERC20(_nanaToken));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hookImpl),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            _protocolFeeProjectId,
            _defifaProjectId
        );
        hookImpl.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));

        // Launch the game with a long mint period for invariant testing
        DefifaTierParams[] memory tp = new DefifaTierParams[](N_TIERS);
        for (uint256 i; i < N_TIERS; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
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
            mintPeriodDuration: 100 days,
            start: uint48(block.timestamp + 200 days),
            refundPeriodDuration: 100 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(TIER_PRICE),
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });

        uint256 pid = deployer.launchGameWith(d);

        // Get the deployed hook clone
        JBRuleset memory fc = jbRulesets().currentOf(pid);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(pid);
        nft = DefifaHook(fc.dataHook());

        // Warp to mint phase
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        handler =
            new MintCostHandler(nft, pid, metadataHelper(), jbMultiTerminal(), address(hookImpl), TIER_PRICE, N_TIERS);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MintCostHandler.mint.selector;
        selectors[1] = MintCostHandler.refund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Read _totalMintCost directly from storage.
    function _readTotalMintCost() internal view returns (uint256) {
        return uint256(vm.load(address(nft), bytes32(TOTAL_MINT_COST_SLOT)));
    }

    /// @notice INVARIANT: _totalMintCost always equals the handler's tracked expected value.
    function invariant_totalMintCostMatchesExpected() external view {
        assertEq(_readTotalMintCost(), handler.expectedMintCost(), "totalMintCost drift");
    }

    /// @notice INVARIANT: _totalMintCost == tierPrice * live token count.
    function invariant_totalMintCostEqualsPriceTimesLiveTokens() external view {
        assertEq(_readTotalMintCost(), TIER_PRICE * handler.liveTokenCount(), "totalMintCost != price * liveTokens");
    }

    /// @notice INVARIANT: mints - burns == live tokens.
    function invariant_tokenCountConsistency() external view {
        assertEq(
            handler.mintCount() - handler.burnCount(), handler.liveTokenCount(), "mintCount - burnCount != liveTokens"
        );
    }
}
