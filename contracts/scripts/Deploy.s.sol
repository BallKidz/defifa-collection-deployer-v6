// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import {Script} from "forge-std/Script.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefifaHook} from "../DefifaHook.sol";
import {DefifaDeployer} from "../DefifaDeployer.sol";
import {DefifaGovernor} from "../DefifaGovernor.sol";
import {DefifaProjectOwner} from "../DefifaProjectOwner.sol";
import {DefifaTokenUriResolver} from "../DefifaTokenUriResolver.sol";
import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";
import {AddressRegistryDeployment, AddressRegistryDeploymentLib} from "@bananapus/address-registry-v5/script/helpers/AddressRegistryDeploymentLib.sol";

contract DeployMainnet is Script, Sphinx {
  /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
  CoreDeployment core;
  /// @notice tracks the deployment of the address registry for the chain we are deploying to.
  AddressRegistryDeployment registry;

  // NOTE: This id is revnet, this is temporary until we have a defifa revnet.
  uint256 _defifaProjectId = 3;
  uint256 _baseProtocolProjectId = 1;

  bytes32 _salt = bytes32(keccak256('0.0.2'));

  ITypeface _typeface = ITypeface(0xA77b7D93E79f1E6B4f77FaB29d9ef85733A3D44A);

  IERC20 defifaToken;
  IERC20 baseProtocolToken;

  function configureSphinx() public override {
    sphinxConfig.projectName = 'defifa-v5';
    sphinxConfig.mainnets = ['ethereum', 'optimism', 'base', 'arbitrum'];
    sphinxConfig.testnets = [
      'ethereum_sepolia',
      'optimism_sepolia',
      'base_sepolia',
      'arbitrum_sepolia'
    ];
  }

  function run() external {
    // Get the deployment addresses for the nana CORE for this chain.
    // We want to do this outside of the `sphinx` modifier.
    core = CoreDeploymentLib.getDeployment(
      vm.envOr('NANA_CORE_DEPLOYMENT_PATH', string('node_modules/@bananapus/core-v5/deployments/'))
    );

    registry = AddressRegistryDeploymentLib.getDeployment(
      vm.envOr(
        'NANA_ADDRESS_REGISTRY_DEPLOYMENT_PATH',
        string('node_modules/@bananapus/address-registry-v5/deployments/')
      )
    );

    defifaToken = IERC20(address(core.tokens.tokenOf(_defifaProjectId)));
    baseProtocolToken = IERC20(address(core.tokens.tokenOf(_baseProtocolProjectId)));

    if (defifaToken == IERC20(address(0))) {
      revert('Defifa token is invalid, does this project id exist?');
    }

    if (baseProtocolToken == IERC20(address(0))) {
      revert('Base protocol token is invalid, does this project id exist?');
    }

    // Sepolia.
    if (block.chainid == 11_155_111) {
      _typeface = ITypeface(0x8C420d3388C882F40d263714d7A6e2c8DB93905F);

      // Optimism sepolia.
    } else if (block.chainid == 11_155_420) {
      _typeface = ITypeface(0xe160e47928907894F97a0DC025c61D64E862fEAa);

      // Base sepolia.
    } else if (block.chainid == 84_532) {
      _typeface = ITypeface(0xEb269d9F0850CEf5e3aB0F9718fb79c466720784);

      // Arb sepolia.
    } else if (block.chainid == 421_614) {
      _typeface = ITypeface(0x431C35e9fA5152A906A38390910d0Cfcba0Fb43b);
    }

    // Check that the typeface is set and that the address contains code.
    require(address(_typeface) != address(0), 'Typeface address is not configured for this chain');
    require(
      address(_typeface).code.length > 0,
      'Typeface address is not deployed to this address for this chain'
    );

    // Perform the deployment transactions.
    deploy();
  }

  function deploy() public sphinx {
    DefifaHook hook = new DefifaHook{salt: _salt}(
      core.directory,
      defifaToken,
      baseProtocolToken
    );
    DefifaTokenUriResolver tokenUriResolver = new DefifaTokenUriResolver{salt: _salt}(_typeface);
    DefifaGovernor governor = new DefifaGovernor{salt: _salt}(core.controller, safeAddress());
    DefifaDeployer deployer = new DefifaDeployer{salt: _salt}(
      address(hook),
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
