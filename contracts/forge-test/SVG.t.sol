// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.16;
//
// import "forge-std/Test.sol";
//
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/proxy/Clones.sol";
// import "../DefifaHook.sol";
// import "../DefifaDeployer.sol";
// import "../DefifaTokenUriResolver.sol";
// import "../interfaces/IDefifaGamePhaseReporter.sol";
// import "../interfaces/IDefifaGamePhaseReporter.sol";
// import "../interfaces/IDefifaHook.sol";
//
// // import {CapsulesTypeface} from "../lib/capsules/contracts/CapsulesTypeface.sol";
//
// contract GamePhaseReporter is IDefifaGamePhaseReporter {
//     function currentGamePhaseOf(uint256 _gameId) external pure returns (DefifaGamePhase) {
//         _gameId;
//         return DefifaGamePhase.COUNTDOWN;
//     }
// }
//
// contract GamePotReporter is IDefifaGamePotReporter {
//     function fulfilledCommitmentsOf(uint256 _gameId) external pure returns (uint256) {
//         _gameId;
//         return 0;
//     }
//
//     function currentGamePotOf(uint256 _gameId, bool _includeCommitments)
//         external
//         pure
//         returns (uint256, address, uint256)
//     {
//         _gameId;
//         _includeCommitments;
//         return (106900000000000000, JBConstants.NATIVE_TOKEN, 18);
//     }
// }
//
// contract SVGTest is Test {
//     IJBController _controller;
//     IJBDirectory _directory;
//     IJBRulesets _fundingCycleStore;
//     IJBTiered721DelegateStore _store;
//     ITypeface _typeface;
//
//     address delegateRegistry = address(0);
//
//     function setUp() public {
//         vm.createSelectFork("https://rpc.ankr.com/eth");
//         _controller = IJBController(0xFFdD70C318915879d5192e8a0dcbFcB0285b3C98);
//         _directory = IJBDirectory(0x65572FB928b46f9aDB7cfe5A4c41226F636161ea);
//         _fundingCycleStore = IJBFundingCycleStore(0x6f18cF9173136c0B5A6eBF45f19D58d3ff2E17e6);
//         _store = IJBTiered721DelegateStore(0x67C31B9557201A341312CF78d315542b5AD83074);
//         _typeface = ITypeface(0xA77b7D93E79f1E6B4f77FaB29d9ef85733A3D44A);
//     }
//
//     event K(bytes4 k);
//
//     function testWithTierImage() public {
//         emit K(type(IDefifaHook).interfaceId);
//         IDefifaHook _hook =
//             DefifaHook(Clones.clone(address(new DefifaHook(IERC20(address(0)), IERC20(address(0))))));
//         IJB721TokenUriResolver _resolver = new DefifaTokenUriResolver(_typeface);
//         IDefifaGamePhaseReporter _gamePhaseReporter = new GamePhaseReporter();
//         IDefifaGamePotReporter _gamePotReporter = new GamePotReporter();
//
//         JB721TierParams[] memory _tiers = new JB721TierParams[](1);
//         _tiers[0] = JB721TierParams({
//             price: 1e18,
//             initialQuantity: 100,
//             votingUnits: 1,
//             reservedRate: 0,
//             reservedTokenBeneficiary: address(0),
//             encodedIPFSUri: bytes32(0xfb17901b2b08444d2bbe92ca39bdd64eab27b0481e841fcd9f14aeb56e28513b),
//             category: 0,
//             allowManualMint: false,
//             shouldUseReservedTokenBeneficiaryAsDefault: false,
//             transfersPausable: false,
//             useVotingUnits: true
//         });
//         string[] memory _tierNames = new string[](1);
//         _tierNames[0] = "lakers win. no one scores over 40pts.";
//
//         _hook.initialize({
//             gameId: 12345,
//             directory: _directory,
//             name: "Example collection",
//             symbol: "EX",
//             fundingCycleStore: _fundingCycleStore,
//             baseUri: "",
//             tokenUriResolver: _resolver,
//             contractUri: "",
//             tiers: _tiers,
//             currency: 1,
//             store: _store,
//             gamePhaseReporter: _gamePhaseReporter,
//             gamePotReporter: _gamePotReporter,
//             defaultAttestationDelegate: address(0),
//             tierNames: _tierNames
//         });
//
//         string[] memory inputs = new string[](3);
//         inputs[0] = "node";
//         inputs[1] = "./open.js";
//         inputs[2] = _resolver.tokenUriOf(address(_hook), 1000000001);
//         bytes memory res = vm.ffi(inputs);
//         res;
//         vm.ffi(inputs);
//     }
//
//     function testWithOutTierImage() public {
//         IDefifaHook _hook =
//             DefifaHook(Clones.clone(address(new DefifaHook(IERC20(address(0)), IERC20(address(0))))));
//         DefifaTokenUriResolver _resolver = new DefifaTokenUriResolver(_typeface);
//         IDefifaGamePhaseReporter _gamePhaseReporter = new GamePhaseReporter();
//         IDefifaGamePotReporter _gamePotReporter = new GamePotReporter();
//
//         JB721TierParams[] memory _tiers = new JB721TierParams[](1);
//         _tiers[0] = JB721TierParams({
//             price: 1e18,
//             initialQuantity: 100,
//             votingUnits: 0,
//             reservedRate: 0,
//             reservedTokenBeneficiary: address(0),
//             encodedIPFSUri: bytes32(""),
//             category: 0,
//             allowManualMint: false,
//             shouldUseReservedTokenBeneficiaryAsDefault: false,
//             transfersPausable: false,
//             useVotingUnits: true
//         });
//
//         string[] memory _tierNames = new string[](1);
//         _tierNames[0] = "D in 4";
//
//         _hook.initialize({
//             gameId: 123,
//             directory: _directory,
//             name: "NBA Finals (1)",
//             symbol: "DEFIFA: EXAMPLE",
//             fundingCycleStore: _fundingCycleStore,
//             baseUri: "",
//             tokenUriResolver: _resolver,
//             contractUri: "",
//             tiers: _tiers,
//             currency: 1,
//             store: _store,
//             gamePhaseReporter: _gamePhaseReporter,
//             gamePotReporter: _gamePotReporter,
//             defaultAttestationDelegate: address(0),
//             tierNames: _tierNames
//         });
//
//         string[] memory inputs = new string[](3);
//         inputs[0] = "node";
//         inputs[1] = "./open.js";
//         inputs[2] = _resolver.tokenUriOf(address(_hook), 1000000000);
//         bytes memory res = vm.ffi(inputs);
//         res;
//         vm.ffi(inputs);
//     }
// }
