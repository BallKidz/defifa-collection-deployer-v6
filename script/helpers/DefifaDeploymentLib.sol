// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

struct DefifaDeployment {
    DefifaHook hook;
    DefifaDeployer deployer;
    DefifaGovernor governor;
    DefifaTokenUriResolver tokenUriResolver;
}

library DefifaDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant VM = Vm(VM_ADDRESS);
    string constant PROJECT_NAME = "defifa-v5";

    function getDeployment(string memory path) internal returns (DefifaDeployment memory deployment) {
        // Get chainId for which we need to get the deployment.
        uint256 chainId = block.chainid;

        // Deploy to get the constants.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment({path: path, networkName: networks[_i].name});
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        view
        returns (DefifaDeployment memory deployment)
    {
        deployment.hook = DefifaHook(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "DefifaHook"
            })
        );

        deployment.deployer = DefifaDeployer(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "DefifaDeployer"
            })
        );

        deployment.governor = DefifaGovernor(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "DefifaGovernor"
            })
        );

        deployment.tokenUriResolver = DefifaTokenUriResolver(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "DefifaTokenUriResolver"
            })
        );
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param projectName The name of the project.
    /// @param networkName The name of the network.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        VM.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));
        return stdJson.readAddress({json: deploymentJson, key: ".address"});
    }
}
