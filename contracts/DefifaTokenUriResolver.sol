// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/base64/base64.sol";
import "@prb/math/src/Common.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {IDefifaTokenUriResolver} from "./interfaces/IDefifaTokenUriResolver.sol";
import {DefifaFontImporter} from "./libraries/DefifaFontImporter.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";

import {JBConstants} from '@bananapus/core-v5/src/libraries/JBConstants.sol';
import {IJB721TokenUriResolver} from '@bananapus/721-hook-v5/src/interfaces/IJB721TokenUriResolver.sol';
import {ERC721} from '@bananapus/721-hook-v5/src/abstract/ERC721.sol';
import {JB721Tier} from '@bananapus/721-hook-v5/src/structs/JB721Tier.sol';
import {JBIpfsDecoder} from '@bananapus/721-hook-v5/src/libraries/JBIpfsDecoder.sol';

/// @title DefifaTokenUriResolver
/// @notice Standard Token URIs for Defifa games.
contract DefifaTokenUriResolver is IDefifaTokenUriResolver, IJB721TokenUriResolver {
    using Strings for uint256;

    //*********************************************************************//
    // -------------------- private constant properties ------------------ //
    //*********************************************************************//

    /// @notice The fidelity of the decimal returned in the NFT image.
    uint256 private constant _IMG_DECIMAL_FIDELITY = 5;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The typeface of the SVGs.
    ITypeface public immutable override typeface;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(ITypeface _typeface) {
        typeface = _typeface;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the token's tier IPFS URI if set.
    /// @param _nft The address of the nft the token URI should be oriented to.
    /// @param _tokenId The ID of the token to get the tier URI for.
    /// @return The token URI corresponding with the tier.
    function tokenUriOf(address _nft, uint256 _tokenId) external view override returns (string memory) {
        // Keep a reference to the hook.
        IDefifaHook _hook = IDefifaHook(_nft);

        // Get the game ID.
        uint256 _gameId = _hook.PROJECT_ID();

        // Keep a reference to the game phase text.
        string memory _gamePhaseText;

        // Keep a reference to the rarity text;
        string memory _rarityText;

        // Keep a reference to the rarity text;
        string memory _valueText;

        // Keep a reference to the game's name.
        // TODO: Somehow make the `IDefifaHook` have the `name` function.
        string memory _title = ERC721(address(_hook)).name();

        // Keep a reference to the tier's name.
        string memory _team;

        // Keep a reference to the SVG parts.
        string[] memory parts = new string[](4);

        // Keep a reference to the pot.
        string memory _potText;

        {
            // Get a reference to the tier.
            JB721Tier memory _tier = _hook.store().tierOfTokenId(address(_hook), _tokenId, false);

            // Set the tier's name.
            _team = _hook.tierNameOf(_tier.id);

            // Check to see if the tier has a URI. Return it if it does.
            if (_tier.encodedIPFSUri != bytes32(0)) {
                return JBIpfsDecoder.decode(_hook.baseURI(), _tier.encodedIPFSUri);
            }

            parts[0] = string("data:application/json;base64,");

            parts[1] = string(
                abi.encodePacked(
                    '{"name":"',
                    _team,
                    '", "id": "',
                    uint256(_tier.id).toString(),
                    '","description":"Team: ',
                    _team,
                    ", ID: ",
                    uint256(_tier.id).toString(),
                    '.","image":"data:image/svg+xml;base64,'
                )
            );

            {
                // Get a reference to the game phase.
                DefifaGamePhase _gamePhase = _hook.gamePhaseReporter().currentGamePhaseOf(_gameId);

                // Keep a reference to the game pot.
                (uint256 _gamePot, address _gamePotToken, uint256 _gamePotDecimals) =
                    _hook.gamePotReporter().currentGamePotOf(_gameId, false);

                // Include the amount redeemed.
                _gamePot = _gamePot + _hook.amountRedeemed();

                // Set the pot text.
                _potText = _formatBalance(_gamePot, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);

                if (_gamePhase == DefifaGamePhase.COUNTDOWN) {
                    _gamePhaseText = "Minting starts soon.";
                } else if (_gamePhase == DefifaGamePhase.MINT) {
                    _gamePhaseText = "Minting and refunds are open.";
                } else if (_gamePhase == DefifaGamePhase.REFUND) {
                    _gamePhaseText = "Minting is over. Refunds are ending.";
                } else if (_gamePhase == DefifaGamePhase.SCORING) {
                    _gamePhaseText = "Awaiting scorecard approval.";
                } else if (_gamePhase == DefifaGamePhase.COMPLETE) {
                    _gamePhaseText = "Scorecard locked in. Burn to claim reward.";
                } else if (_gamePhase == DefifaGamePhase.NO_CONTEST) {
                    _gamePhaseText = "No contest. Refunds open.";
                }

                // Keep a reference to the number of tokens outstanding from this tier.
                uint256 _totalMinted = _hook.currentSupplyOfTier(_tier.id);

                if (_gamePhase == DefifaGamePhase.MINT) {
                    _rarityText = string(
                        abi.encodePacked(_totalMinted.toString(), _totalMinted == 1 ? " card so far" : " cards so far")
                    );
                } else {
                    _rarityText = string(
                        abi.encodePacked(
                            _totalMinted.toString(), _totalMinted == 1 ? " card in existence" : " cards in existence"
                        )
                    );
                }

                if (_gamePhase == DefifaGamePhase.SCORING || _gamePhase == DefifaGamePhase.COMPLETE) {
                    uint256 _potPortion = mulDiv(
                        _gamePot, _hook.cashOutWeightOf(_tokenId), _hook.TOTAL_CASHOUT_WEIGHT()
                    );
                    _valueText = !_hook.cashOutWeightIsSet()
                        ? "Awaiting scorecard..."
                        : _formatBalance(_potPortion, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
                } else {
                    _valueText = _formatBalance(_tier.price, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
                }
            }
        }
        parts[2] = Base64.encode(
            abi.encodePacked(
                '<svg viewBox="0 0 500 500" xmlns="http://www.w3.org/2000/svg">',
                '<style>@font-face{font-family:"Capsules-500";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getSkinnyFontSource(typeface),
                ');format("opentype");}',
                '@font-face{font-family:"Capsules-700";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getBeefyFontSource(typeface),
                ');format("opentype");}',
                "text{white-space:pre-wrap; width:100%; }</style>",
                '<rect width="100%" height="100%" fill="#181424"/>',
                '<text x="10" y="30" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">GAME: ',
                _gameId.toString(),
                " | POT: ",
                _potText,
                " | CARDS: ",
                _hook.store().totalSupplyOf(address(_hook)).toString(),
                "</text>",
                '<text x="10" y="50" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #ed017c;">',
                _gamePhaseText,
                "</text>",
                '<text x="10" y="85" style="font-size:26px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">',
                _getSubstring(_title, 0, 30),
                "</text>",
                '<text x="10" y="120" style="font-size:26px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">',
                _getSubstring(_title, 30, 60),
                "</text>",
                '<text x="10" y="205" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0 && bytes(_getSubstring(_team, 10, 20)).length != 0
                    ? _getSubstring(_team, 0, 10)
                    : "",
                "</text>",
                '<text x="10" y="295" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 10, 20)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0 ? _getSubstring(_team, 0, 10) : "",
                "</text>",
                '<text x="10" y="385" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 20, 30)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0
                        ? _getSubstring(_team, 10, 20)
                        : _getSubstring(_team, 0, 10),
                "</text>",
                '<text x="10" y="430" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">TOKEN ID: ',
                _tokenId.toString(),
                "</text>",
                '<text x="10" y="455" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">RARITY: ',
                _rarityText,
                "</text>",
                '<text x="10" y="480" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">BACKED BY: ',
                _valueText,
                "</text>",
                "</svg>"
            )
        );
        parts[3] = string('"}');
        return string.concat(parts[0], Base64.encode(abi.encodePacked(parts[1], parts[2], parts[3])));
    }

    /// @notice Gets a substring.
    /// @dev If the first character is a space, it is not included.
    /// @param _str The string to get a substring of.
    /// @param _startIndex The first index of the substring from within the string.
    /// @param _endIndex The last index of the string from within the string.
    /// @return substring The substring.
    function _getSubstring(string memory _str, uint256 _startIndex, uint256 _endIndex)
        internal
        pure
        returns (string memory substring)
    {
        bytes memory _strBytes = bytes(_str);
        if (_startIndex >= _strBytes.length) return "";
        if (_endIndex > _strBytes.length) _endIndex = _strBytes.length;
        _startIndex = _strBytes[_startIndex] == bytes1(0x20) ? _startIndex + 1 : _startIndex;
        if (_startIndex >= _endIndex) return "";
        bytes memory _result = new bytes(_endIndex-_startIndex);
        for (uint256 _i = _startIndex; _i < _endIndex;) {
            _result[_i - _startIndex] = _strBytes[_i];
            unchecked {
                ++_i;
            }
        }
        return string(_result);
    }

    /// @notice Formats a balance from a fixed point number to a string.
    /// @param _amount The fixed point amount.
    /// @param _token The token the amount is in.
    /// @param _decimals The number of decimals in the fixed point amount.
    /// @param _fidelity The number of decimals that should be returned in the formatted string.
    /// @return The formatted balance.
    function _formatBalance(uint256 _amount, address _token, uint256 _decimals, uint256 _fidelity)
        internal
        view
        returns (string memory)
    {
        bool _isEth = _token == JBConstants.NATIVE_TOKEN;

        uint256 _fixedPoint = 10 ** _decimals;

        // Convert amount to a decimal format
        string memory _integerPart = (_amount /_fixedPoint).toString();

        uint256 _remainder = _amount % _fixedPoint;
        uint256 _scaledRemainder = _remainder * (10 ** _fidelity);
        uint256 _decimalPart = _scaledRemainder / _fixedPoint;

        // Pad with zeros if necessary
        string memory _decimalPartStr = _decimalPart.toString();
        while (bytes(_decimalPartStr).length < _fidelity) {
            _decimalPartStr = string(abi.encodePacked("0", _decimalPartStr));
        }

        // Concatenate the strings
        return _isEth
            ? string(abi.encodePacked("\u039E", _integerPart, ".", _decimalPartStr))
            : string(abi.encodePacked(_integerPart, ".", _decimalPartStr, " ", IERC20Metadata(_token).symbol()));
    }
}
