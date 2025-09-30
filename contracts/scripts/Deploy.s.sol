// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import {Script} from "forge-std/Script.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefifaDelegate} from "../DefifaDelegate.sol";
import {DefifaDeployer} from "../DefifaDeployer.sol";
import {DefifaGovernor} from "../DefifaGovernor.sol";
import {DefifaProjectOwner} from "../DefifaProjectOwner.sol";
import {DefifaTokenUriResolver} from "../DefifaTokenUriResolver.sol";

contract DeployMainnet is Script {
    // V3_1 mainnet controller.
    IJBController3_1 _controller = IJBController3_1(0x97a5b9D9F0F7cD676B69f584F29048D0Ef4BB59b);

    IJBDelegatesRegistry _delegateRegistry = IJBDelegatesRegistry(0x7A53cAA1dC4d752CAD283d039501c0Ee45719FaC);
    ITypeface _typeface = ITypeface(0xA77b7D93E79f1E6B4f77FaB29d9ef85733A3D44A);

    uint256 _defifaProjectId = 369;
    uint256 _baseProtocolProjectId = 1;

    IERC20 _defifaToken = IERC20(address(_controller.tokenStore().tokenOf(_defifaProjectId)));
    IERC20 _baseProtocolToken = IERC20(address(_controller.tokenStore().tokenOf(_baseProtocolProjectId)));

    uint256 _blockTime = 12;

    function run() external {
        vm.startBroadcast();

        // Deploy the codeOrigin for the delegate.
        DefifaDelegate _defifaDelegateCodeOrigin = new DefifaDelegate(_defifaToken, _baseProtocolToken);

        // Deploy the token uri resolver.
        DefifaTokenUriResolver _defifaTokenUriResolver = new DefifaTokenUriResolver(_typeface);

        // Deploy the governor.
        DefifaGovernor _defifaGovernor = new DefifaGovernor(_controller, _blockTime);

        // Deploy the deployer.
        DefifaDeployer _defifaDeployer = new DefifaDeployer(
          address(_defifaDelegateCodeOrigin),
          _defifaTokenUriResolver,
          _defifaGovernor,
          _controller,
          _delegateRegistry,
          _defifaProjectId,
          _baseProtocolProjectId
        );

        new DefifaProjectOwner(IJBOperatable(address(_controller)).operatorStore(), _controller.projects(), _defifaDeployer);

        _defifaGovernor.transferOwnership(address(_defifaDeployer));
    }
}

contract DeployGoerli is Script {
    // V3_1 goerli controller.
    IJBController3_1 _controller = IJBController3_1(0x1d260DE91233e650F136Bf35f8A4ea1F2b68aDB6);

    IJBDelegatesRegistry _delegateRegistry = IJBDelegatesRegistry(0xCe3Ebe8A7339D1f7703bAF363d26cD2b15D23C23);
    ITypeface _typeface = ITypeface(0x8Df17136B20DA6D1E23dB2DCdA8D20Aa4ebDcda7);

    uint256 _defifaProjectId = 1068;
    uint256 _baseProtocolProjectId = 1;

    IERC20 _defifaToken = IERC20(address(_controller.tokenStore().tokenOf(_defifaProjectId)));
    IERC20 _baseProtocolToken = IERC20(address(_controller.tokenStore().tokenOf(_baseProtocolProjectId)));

    uint256 _blockTime = 12;

    function run() external {
        vm.startBroadcast();

        // Deploy the codeOrigin for the delegate
        DefifaDelegate _defifaDelegateCodeOrigin = new DefifaDelegate(_defifaToken, _baseProtocolToken);

        // Deploy the token uri resolver.
        DefifaTokenUriResolver _defifaTokenUriResolver = new DefifaTokenUriResolver(_typeface);

        // Deploy the governor.
        DefifaGovernor _defifaGovernor = new DefifaGovernor(_controller, _blockTime);

        // Deploy the deployer.
        DefifaDeployer _defifaDeployer = new DefifaDeployer(
          address(_defifaDelegateCodeOrigin),
          _defifaTokenUriResolver,
          _defifaGovernor,
          _controller,
          _delegateRegistry,
          _defifaProjectId,
          _baseProtocolProjectId
        );

        _defifaGovernor.transferOwnership(address(_defifaDeployer));

        new DefifaProjectOwner(IJBOperatable(address(_controller)).operatorStore(), _controller.projects(), _defifaDeployer);
    }
}
