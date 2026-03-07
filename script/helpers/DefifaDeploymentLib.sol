// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/SphinxConstants.sol";

struct DefifaDeployment {
    DefifaHook hook;
    DefifaDeployer deployer;
    DefifaGovernor governor;
    DefifaTokenUriResolver tokenUriResolver;
}

library DefifaDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);
    string constant PROJECT_NAME = "defifa-v5";

    function getDeployment(string memory path) internal returns (DefifaDeployment memory deployment) {
        // Get chainId for which we need to get the deployment.
        uint256 chainId = block.chainid;

        // Deploy to get the constants.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment(path, networks[_i].name);
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory network_name
    )
        internal
        view
        returns (DefifaDeployment memory deployment)
    {
        deployment.hook = DefifaHook(_getDeploymentAddress(path, PROJECT_NAME, network_name, "DefifaHook"));

        deployment.deployer = DefifaDeployer(_getDeploymentAddress(path, PROJECT_NAME, network_name, "DefifaDeployer"));

        deployment.governor = DefifaGovernor(_getDeploymentAddress(path, PROJECT_NAME, network_name, "DefifaGovernor"));

        deployment.tokenUriResolver =
            DefifaTokenUriResolver(_getDeploymentAddress(path, PROJECT_NAME, network_name, "DefifaTokenUriResolver"));
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param project_name The name of the project.
    /// @param network_name The name of the network.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory project_name,
        string memory network_name,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
            vm.readFile(string.concat(path, project_name, "/", network_name, "/", contractName, ".json"));
        return stdJson.readAddress(deploymentJson, ".address");
    }
}
