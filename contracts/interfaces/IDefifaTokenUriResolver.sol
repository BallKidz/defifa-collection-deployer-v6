// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IDefifaHook} from "./IDefifaHook.sol";
import {IDefifaGamePhaseReporter} from "./IDefifaGamePhaseReporter.sol";

interface IDefifaTokenUriResolver {
    function typeface() external view returns (ITypeface);
}
