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
import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";

import "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/address-registry-v5/script/helpers/AddressRegistryDeploymentLib.sol";

contract DeployMainnet is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;
    /// @notice tracks the deployment of the address registry for the chain we are deploying to.
    AddressRegistryDeployment registry;

    uint256 _defifaProjectId = 369;
    uint256 _baseProtocolProjectId = 1;

    ITypeface _typeface = ITypeface(0xA77b7D93E79f1E6B4f77FaB29d9ef85733A3D44A);
    
    IERC20 defifaToken;
    IERC20 baseProtocolToken;

    uint256 _blockTime = 12;

    function configureSphinx() public override {
        sphinxConfig.projectName = "defifa-v5";
        // TODO: We need to patch the `blockTime` logic in the governor before L2s will function as expected.
        sphinxConfig.mainnets = ["ethereum"];
        sphinxConfig.testnets = ["ethereum_sepolia"];
    }

    function run() external {
         // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v5/deployments/"))
        );

        registry = AddressRegistryDeploymentLib.getDeployment(
            vm.envOr(
                "NANA_ADDRESS_REGISTRY_DEPLOYMENT_PATH",
                string("node_modules/@bananapus/address-registry-v5/deployments/")
            )
        );

        defifaToken = IERC20(address(core.tokens.tokenOf(_defifaProjectId)));
        baseProtocolToken = IERC20(address(core.tokens.tokenOf(_baseProtocolProjectId)));

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        DefifaDelegate delegate = new DefifaDelegate(core.directory, defifaToken, baseProtocolToken);
        DefifaTokenUriResolver tokenUriResolver = new DefifaTokenUriResolver(_typeface);
        DefifaGovernor governor = new DefifaGovernor(core.controller, _blockTime);
        DefifaDeployer deployer = new DefifaDeployer(
            address(delegate),
            tokenUriResolver,
            governor,
            core.controller,
            registry.registry,
            _defifaProjectId,
            _baseProtocolProjectId
        );

        governor.transferOwnership(address(deployer));
    }
}
