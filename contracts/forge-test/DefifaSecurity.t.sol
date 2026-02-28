// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../DefifaGovernor.sol";
import "../DefifaDeployer.sol";
import "../DefifaHook.sol";
import "../DefifaTokenUriResolver.sol";
import "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";

import {JBMetadataResolver} from "@bananapus/core-v5/src/libraries/JBMetadataResolver.sol";
import {MetadataResolverHelper} from "@bananapus/core-v5/test/helpers/MetadataResolverHelper.sol";
import "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v5/test/helpers/JBTest.sol";
import "@bananapus/core-v5/src/libraries/JBRulesetMetadataResolver.sol";
import "@bananapus/721-hook-v5/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";

/// @title DefifaSecurityTest
/// @notice High-volume game integrity, fund conservation, scorecard validation, and governance tests.
contract DefifaSecurityTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    // Shared test state (set by _setupGame helpers)
    uint256 _pid;
    DefifaHook _nft;
    DefifaGovernor _gov;
    address[] _users;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0, duration: 10 days, weight: 1e18, weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0, cashOutTaxRate: 0, baseCurrency: JBCurrencyIds.ETH,
                pausePay: false, pauseCreditTransfers: false, allowOwnerMinting: false,
                allowSetCustomToken: false, allowTerminalMigration: false, allowSetTerminals: false,
                allowSetController: false, allowAddAccountingContext: false, allowAddPriceFeed: false,
                ownerMustSendPayouts: false, holdFees: false, useTotalSurplusForCashOuts: false,
                useDataHookForPay: true, useDataHookForCashOut: true, dataHook: address(0), metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0), fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount = address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(jbDirectory(), IERC20(_defifaProjectTokenAccount), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook), new DefifaTokenUriResolver(ITypeface(address(0))), governor,
            jbController(), new JBAddressRegistry(), _protocolFeeProjectId, _defifaProjectId
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // HIGH-VOLUME: 32 tiers at 100 ETH each = 3,200 ETH pot
    // =========================================================================
    function testHighVolume_32tiers() external {
        _setupGame(32, 100 ether);
        _toScoring();

        // Tier 1 gets 50%, rest split 50% — must sum to exactly TOTAL_CASHOUT_WEIGHT
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(32);
        uint256 half = tw / 2;
        uint256 perTier = half / 31;
        uint256 assigned;
        for (uint256 i; i < 32; i++) {
            if (i == 0) {
                sc[i].cashOutWeight = half;
            } else if (i == 31) {
                // Last tier absorbs rounding remainder
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = perTier;
            }
            assigned += sc[i].cashOutWeight;
        }

        _attestAndRatify(sc);
        uint256 pot = _surplus();
        uint256 out = _cashOutAllUsers();

        assertApproxEqAbs(out, pot, 1e15, "cashed out vs pot");
        assertLe(_surplus(), 1e15, "remaining dust");
        // No fee tokens left in hook
        assertEq(IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(_nft)), 0, "no NANA left");
        assertEq(IERC20(_defifaProjectTokenAccount).balanceOf(address(_nft)), 0, "no DEFIFA left");
    }

    // =========================================================================
    // MULTI-PLAYER: 5 users in winning tier, 1 each in losing tiers
    // =========================================================================
    function testMultiPlayer_winnerTakesAll() external {
        _setupMultiPlayer();
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        // tiers 2-4 get 0

        _attestAndRatify(sc);

        // All winners should get approximately equal shares
        uint256[] memory winnerPayouts = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            uint256 bb = _users[i].balance;
            _cashOut(_users[i], 1, i + 1);
            winnerPayouts[i] = _users[i].balance - bb;
            assertGt(winnerPayouts[i], 0, "winner should receive ETH");
        }

        // All winners should get approximately equal amounts (within 0.1%)
        for (uint256 i = 1; i < 5; i++) {
            assertApproxEqRel(winnerPayouts[i], winnerPayouts[0], 0.001 ether, "winner payouts should be equal");
        }

        // Losers get 0 ETH (but still receive fee tokens, so no NOTHING_TO_CLAIM revert)
        for (uint256 i; i < 3; i++) {
            uint256 bb = _users[5 + i].balance;
            _cashOut(_users[5 + i], i + 2, 1);
            assertEq(_users[5 + i].balance, bb, "loser should receive 0 ETH");
            assertEq(_nft.balanceOf(_users[5 + i]), 0, "loser NFT burned");
        }
    }

    // =========================================================================
    // REFUND: exact price returned during MINT phase
    // =========================================================================
    function testRefundIntegrity() external {
        _setupGame(8, 50 ether);

        // Refund first 4 during MINT phase
        for (uint256 i; i < 4; i++) {
            uint256 bb = _users[i].balance;
            _refund(_users[i], i + 1);
            assertEq(_users[i].balance - bb, 50 ether, "exact refund");
            assertEq(_nft.balanceOf(_users[i]), 0, "NFT burned");
        }
        assertEq(_surplus(), 50 ether * 4, "pot = remaining mints");
    }

    // =========================================================================
    // ROUNDING: extreme weights at 1000 ETH per tier
    // =========================================================================
    function testRounding_extremeWeights() external {
        _setupGame(3, 1000 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(3);
        sc[0].cashOutWeight = 1;
        sc[1].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT() - 2;
        sc[2].cashOutWeight = 1;

        _attestAndRatify(sc);
        uint256 pot = _surplus();
        uint256 out = _cashOutAllUsers();
        assertApproxEqAbs(out + _surplus(), pot, 3, "fund conservation");
        assertGt(_users[1].balance, pot * 99 / 100, "tier 2 > 99%");
    }

    // =========================================================================
    // C-D2: overweight scorecard rejected
    // =========================================================================
    function testC_D2_rejectsOverweight() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = (_nft.TOTAL_CASHOUT_WEIGHT() * 30) / 100; // 120% total
        }

        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        vm.expectRevert(DefifaHook.INVALID_CASHOUT_WEIGHTS.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // M-D6: delegation blocked after MINT phase
    // =========================================================================
    function testM_D6_delegationBlocked() external {
        _setupGame(4, 1 ether);

        // REFUND phase
        vm.warp(block.timestamp + 1 days);
        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE()"));
        _nft.setTierDelegateTo(address(1), 1);

        // SCORING phase
        vm.warp(block.timestamp + 2 days);
        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE()"));
        _nft.setTierDelegateTo(address(1), 1);
    }

    // =========================================================================
    // QUORUM: 50% of minted tiers
    // =========================================================================
    function testQuorum_50pctMintedTiers() external {
        // Launch game with 10 tiers but only mint 6
        _setupPartial(10, 6, 1 ether);
        uint256 expected = (6 * _gov.MAX_ATTESTATION_POWER_TIER()) / 2;
        assertEq(_gov.quorum(_gameId), expected, "quorum = 50% of minted tiers");
    }

    // =========================================================================
    // FUZZ: fund conservation across varying tier/player counts
    // =========================================================================
    function testFuzz_fundConservation(uint8 rawTiers, uint8 rawPlayers) external {
        uint8 nTiers = uint8(bound(rawTiers, 2, 12));
        uint8 nPPT = uint8(bound(rawPlayers, 1, 3));

        _setupMultiN(nTiers, nPPT, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 wpt = tw / nTiers;
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(nTiers);
        uint256 assigned;
        for (uint256 i; i < nTiers; i++) {
            if (i == nTiers - 1) {
                // Last tier absorbs rounding remainder to satisfy exact weight requirement
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = wpt;
            }
            assigned += sc[i].cashOutWeight;
        }

        _attestAndRatify(sc);
        uint256 pot = _surplus();

        uint256 total;
        for (uint256 i; i < _users.length; i++) {
            uint256 bb = _users[i].balance;
            uint256 tid = (i / nPPT) + 1;
            uint256 tnum = (i % nPPT) + 1;
            _cashOut(_users[i], tid, tnum);
            total += _users[i].balance - bb;
        }

        assertApproxEqAbs(total + _surplus(), pot, _users.length, "fund conservation");
    }

    // =========================================================================
    // SCORECARD: valid equal-weight scorecard passes
    // =========================================================================
    function testScorecard_equalWeight_passes() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = tw / 4;
        }

        // Should succeed without reverting
        _attestAndRatify(sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights should be set");
    }

    // =========================================================================
    // GAME LIFECYCLE: cash-out before scorecard gives 0 ETH (weights = 0)
    // =========================================================================
    function testNoCashOut_beforeScorecard() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Cash out during scoring before scorecard — weight=0 means NOTHING_TO_CLAIM revert
        bytes memory meta = _cashOutMeta(1, 1);
        vm.expectRevert(DefifaHook.NOTHING_TO_CLAIM.selector);
        vm.prank(_users[0]);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: _users[0], projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(_users[0]), metadata: meta
        });
        // NFT should NOT have been burned (revert rolled it back)
        assertEq(_nft.balanceOf(_users[0]), 1, "NFT not burned on revert");
    }

    // =========================================================================
    // SETUP HELPERS
    // =========================================================================

    function _setupGame(uint8 nTiers, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launch_data(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
    }

    function _setupMultiPlayer() internal {
        DefifaLaunchProjectData memory d = _launch_data(4, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](8);
        for (uint256 i; i < 5; i++) {
            _users[i] = _addr(100 + i);
            _mint(_users[i], 1, 1 ether);
            _delegateSelf(_users[i], 1);
            vm.warp(block.timestamp + 1);
        }
        for (uint256 i; i < 3; i++) {
            _users[5 + i] = _addr(200 + i);
            _mint(_users[5 + i], i + 2, 1 ether);
            _delegateSelf(_users[5 + i], i + 2);
            vm.warp(block.timestamp + 1);
        }
    }

    function _setupMultiN(uint8 nTiers, uint8 nPPT, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launch_data(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        uint256 total = uint256(nTiers) * uint256(nPPT);
        _users = new address[](total);
        uint256 idx;
        for (uint256 t; t < nTiers; t++) {
            for (uint256 p; p < nPPT; p++) {
                _users[idx] = _addr(idx);
                _mint(_users[idx], t + 1, tierPrice);
                _delegateSelf(_users[idx], t + 1);
                vm.warp(block.timestamp + 1);
                idx++;
            }
        }
    }

    function _setupPartial(uint8 nTiers, uint256 nMint, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launch_data(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nMint);
        for (uint256 i; i < nMint; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
        }
    }

    function _toScoring() internal {
        // Warp 3 days forward (past mint + refund) into scoring
        vm.warp(block.timestamp + 3 days + 1);
    }

    // =========================================================================
    // PRIMITIVE HELPERS
    // =========================================================================

    function _launch_data(uint8 n, uint256 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
                price: uint80(tierPrice), reservedRate: 1001, reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0), shouldUseReservedTokenBeneficiaryAsDefault: false, name: "DEFIFA"
            });
        }
        return DefifaLaunchProjectData({
            name: "DEFIFA", projectUri: "", contractUri: "", baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days, start: uint48(block.timestamp + 3 days), refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(), splits: new JBSplit[](0),
            attestationStartTime: 0, attestationGracePeriod: 100381,
            defaultAttestationDelegate: address(0), tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)), terminal: jbMultiTerminal()
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
        return address(bytes20(keccak256(abi.encode("su", i))));
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(_pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadataHelper().createMetadata(ids, data));
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

    function _attestAndRatify(DefifaTierCashOutWeight[] memory sc) internal {
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        _attestAllFor(pid);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(block.timestamp + 1);
    }

    function _attestAllFor(uint256 pid) internal {
        vm.warp(block.timestamp + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);
    }

    function _surplus() internal view returns (uint256) {
        return jbMultiTerminal().currentSurplusOf(
            _pid, jbMultiTerminal().accountingContextsOf(_pid), 18, JBCurrencyIds.ETH
        );
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: user, projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(user), metadata: meta
        });
    }

    function _cashOutMeta(uint256 tid, uint256 tnum) internal returns (bytes memory) {
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
        // Tier fetched AFTER mint: remainingSupply already decremented, so no +1
        uint256 tnum = tier.initialSupply - tier.remainingSupply + nb;
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal())).cashOutTokensOf({
            holder: user, projectId: _pid, cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN, minTokensReclaimed: 0,
            beneficiary: payable(user), metadata: meta
        });
    }
}
