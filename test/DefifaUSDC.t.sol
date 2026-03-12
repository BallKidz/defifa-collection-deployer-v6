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
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "../src/enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "../src/enums/DefifaScorecardState.sol";

/// @notice Mock USDC token with 6 decimals.
contract DefifaMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract USDCTimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title DefifaUSDCTest
/// @notice Tests Defifa game lifecycle with USDC (6-decimal ERC-20) instead of native ETH.
/// Exercises 6-decimal accounting, fee calculations, and cash-out flows.
contract DefifaUSDCTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    USDCTimestampReader private _tsReader;
    DefifaMockUSDC usdc;

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

        _tsReader = new USDCTimestampReader();
        usdc = new DefifaMockUSDC();

        // Terminal configurations using USDC.
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: address(usdc), decimals: 6, currency: uint32(uint160(address(usdc)))});
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
                baseCurrency: uint32(uint160(address(usdc))),
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

        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.SET_SPLIT_GROUPS;
        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner,
                JBPermissionsData({
                    operator: address(deployer), projectId: uint64(_defifaProjectId), permissionIds: permissionIds
                })
            );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // USDC LAUNCH DATA HELPERS
    // =========================================================================

    function _launchDataUSDC(uint8 n, uint104 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        return _launchDataUSDCWith(n, tierPrice, 0, 0);
    }

    function _launchDataUSDCWith(
        uint8 n,
        uint104 tierPrice,
        uint256 minParticipation,
        uint32 scorecardTimeout
    )
        internal
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        return DefifaLaunchProjectData({
            name: "DEFIFA_USDC",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: address(usdc), decimals: 6, currency: uint32(uint160(address(usdc)))}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            tierPrice: tierPrice,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: minParticipation,
            scorecardTimeout: scorecardTimeout
        });
    }

    function _launch(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n, DefifaGovernor g) {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("usdc_user", i))));
    }

    function _mintUSDC(address user, uint256 tid, uint104 amt) internal {
        usdc.mint(user, amt);
        uint16[] memory m = new uint16[](1);
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.startPrank(user);
        usdc.approve(address(jbMultiTerminal()), amt);
        jbMultiTerminal().pay(_pid, address(usdc), amt, user, 0, "", metadataHelper().createMetadata(ids, data));
        vm.stopPrank();
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
        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(_tsReader.timestamp() + 1);
    }

    function _toScoring() internal {
        vm.warp(_tsReader.timestamp() + 3 days + 1);
    }

    function _setupGameUSDC(uint8 nTiers, uint104 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchDataUSDC(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mintUSDC(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _balance() internal view returns (uint256) {
        return jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), _pid, address(usdc));
    }

    function _surplus() internal view returns (uint256) {
        return jbMultiTerminal()
            .currentSurplusOf(_pid, jbMultiTerminal().accountingContextsOf(_pid), 6, uint32(uint160(address(usdc))));
    }

    function _generateTokenId(uint256 tierId, uint256 tokenNumber) internal pure returns (uint256) {
        return (tierId * 1_000_000_000) + tokenNumber;
    }

    function _buildCashOutMetadata(bytes memory decodedData) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes[] memory datas = new bytes[](1);
        datas[0] = decodedData;
        return metadataHelper().createMetadata(ids, datas);
    }

    function _cashOutUSDC(address user, uint256 tid, uint256 tnum) internal {
        uint256[] memory cashOutIds = new uint256[](1);
        cashOutIds[0] = _generateTokenId(tid, tnum);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: address(usdc),
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: cashOutMetadata
            });
    }

    function _refundUSDC(address user, uint256 tid) internal {
        uint256[] memory cashOutIds = new uint256[](1);
        cashOutIds[0] = _generateTokenId(tid, 1);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: address(usdc),
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: cashOutMetadata
            });
    }

    // =========================================================================
    // TESTS
    // =========================================================================

    /// @notice Test 1: Mint and refund with USDC.
    function test_defifa_usdc_mintAndRefund() external {
        uint104 tierPrice = 100e6; // 100 USDC
        _setupGameUSDC(4, tierPrice);

        // Verify MINT phase.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT));

        // Verify all 4 users hold NFTs.
        for (uint256 i; i < 4; i++) {
            assertEq(_nft.balanceOf(_users[i]), 1, "each user holds 1 NFT");
        }

        // Terminal should have 400 USDC.
        assertEq(_balance(), 400e6, "terminal balance = 400 USDC");

        // Refund user 0 during MINT phase.
        uint256 balBefore = usdc.balanceOf(_users[0]);
        _refundUSDC(_users[0], 1);
        assertEq(usdc.balanceOf(_users[0]) - balBefore, 100e6, "refund = 100 USDC");
        assertEq(_nft.balanceOf(_users[0]), 0, "NFT burned on refund");

        // Remaining balance = 300 USDC.
        assertEq(_balance(), 300e6, "terminal balance = 300 USDC after refund");
    }

    /// @notice Test 2: Scorecard and distribute with USDC.
    function test_defifa_usdc_scorecardAndDistribute() external {
        uint104 tierPrice = 100e6;
        _setupGameUSDC(4, tierPrice);

        _toScoring();

        // Tier 1 = 100% weight.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Winner cashes out -> receives USDC.
        uint256 winnerBalBefore = usdc.balanceOf(_users[0]);
        _cashOutUSDC(_users[0], 1, 1);
        uint256 winnerReceived = usdc.balanceOf(_users[0]) - winnerBalBefore;
        assertGt(winnerReceived, 0, "winner received USDC");

        // Losers get 0 USDC.
        for (uint256 i = 1; i < 4; i++) {
            uint256 bb = usdc.balanceOf(_users[i]);
            _cashOutUSDC(_users[i], i + 1, 1);
            assertEq(usdc.balanceOf(_users[i]), bb, "loser gets 0 USDC");
        }
    }

    /// @notice Test 3: Fee accounting with USDC (6-decimal precision).
    function test_defifa_usdc_feeAccounting() external {
        uint104 tierPrice = 100e6;
        _setupGameUSDC(4, tierPrice);

        uint256 potBefore = _balance();
        assertEq(potBefore, 400e6, "pot = 400 USDC");

        // Expected fee: 7.5% (2.5% NANA + 5% DEFIFA).
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedSurplus = potBefore - expectedFee;

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        uint256 potAfter = _balance();
        assertEq(potAfter, expectedSurplus, "surplus after fees = pot - 7.5%");

        uint256 fulfilled = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fulfilled, expectedFee, "fulfilled = fee amount");
        assertEq(fulfilled + potAfter, potBefore, "fee + surplus = original pot exactly (no rounding loss)");
    }

    /// @notice Test 4: No-contest with USDC (minParticipation threshold).
    function test_defifa_usdc_noContest() external {
        uint104 tierPrice = 100e6;
        DefifaLaunchProjectData memory d = _launchDataUSDCWith(4, tierPrice, 500e6, 0); // 500 USDC min
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // Mint only 1 tier = 100 USDC < 500 USDC threshold.
        _users = new address[](1);
        _users[0] = _addr(0);
        _mintUSDC(_users[0], 1, tierPrice);

        _toScoring();

        // balance = 100 USDC < 500 USDC → NO_CONTEST.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));
    }

    /// @notice Test 5: Game pot reporting with USDC.
    function test_defifa_usdc_potCalculation() external {
        uint104 tierPrice = 100e6;
        _setupGameUSDC(4, tierPrice);

        _toScoring();

        (uint256 potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (uint256 potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 400e6, "pot excluding = 400 USDC");
        assertEq(potIncluding, 400e6, "pot including = 400 USDC (no fulfillment yet)");

        _attestAndRatify(_evenScorecard(4));

        uint256 fee = deployer.fulfilledCommitmentsOf(_pid);
        (potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 400e6 - fee, "pot excluding = surplus");
        assertEq(potIncluding, 400e6, "pot including = original pot");
    }
}
