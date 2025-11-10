// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "lib/base64/base64.sol";
import {PRBMath} from "@paulrberg/contracts/math/PRBMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import {IJB721TokenUriResolver} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJB721TokenUriResolver.sol";
import {JBIpfsDecoder} from "@jbx-protocol/juice-721-delegate/contracts/libraries/JBIpfsDecoder.sol";
import {JB721Tier} from "@jbx-protocol/juice-721-delegate/contracts/structs/JB721Tier.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IDefifaDelegate} from "./interfaces/IDefifaDelegate.sol";
import {IDefifaTokenUriResolver} from "./interfaces/IDefifaTokenUriResolver.sol";
import {DefifaFontImporter} from "./libraries/DefifaFontImporter.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";

/// @title DefifaTokenUriResolver
/// @notice Standard Token URIs for Defifa games.
contract DefifaTokenUriResolver is IDefifaTokenUriResolver, IJB721TokenUriResolver {
    using Strings for uint256;
    using SafeMath for uint256;

    //*********************************************************************//
    // -------------------- private constant properties ------------------ //
    //*********************************************************************//

    /// @notice The fidelity of the decimal returned in the NFT image.
    uint256 private constant _IMG_DECIMAL_FIDELITY = 4;

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
        // Keep a reference to the delegate.
        IDefifaDelegate _delegate = IDefifaDelegate(_nft);

        // Get the game ID.
        uint256 _gameId = _delegate.PROJECT_ID();

        // Keep a reference to the game phase text.
        string memory _gamePhaseText;

        // Keep a reference to the rarity text;
        string memory _rarityText;

        // Keep a reference to the rarity text;
        string memory _valueText;

        // Keep a reference to the game's name.
        string memory _title = _delegate.name();

        // Keep a reference to the tier's name.
        string memory _team;

        // Keep a reference to the SVG parts.
        string[] memory parts = new string[](4);

        // Keep a reference to the pot.
        string memory _potText;

        {
            // Get a reference to the tier.
            JB721Tier memory _tier = _delegate.store().tierOfTokenId(address(_delegate), _tokenId, false);

            // Set the tier's name.
            _team = _delegate.tierNameOf(_tier.id);

            // Check to see if the tier has a URI. Return it if it does.
            if (_tier.encodedIPFSUri != bytes32(0)) {
                return JBIpfsDecoder.decode(_delegate.baseURI(), _tier.encodedIPFSUri);
            }

            parts[0] = string("data:application/json;base64,");

            parts[1] = string(
                abi.encodePacked(
                    '{"name":"',
                    _team,
                    '", "id": "',
                    _tier.id.toString(),
                    '","description":"Team: ',
                    _team,
                    ", ID: ",
                    _tier.id.toString(),
                    '.","image":"data:image/svg+xml;base64,'
                )
            );

            {
                // Get a reference to the game phase (tolerant to reporter issues).
                (, DefifaGamePhase _gamePhase) =
                    _safeGamePhase(_delegate.gamePhaseReporter(), _gameId);

                // Keep a reference to the game pot (tolerant to reporter issues).
                (, uint256 _gamePot, address _gamePotToken, uint256 _gamePotDecimals) =
                    _safeGamePot(_delegate.gamePotReporter(), _gameId);

                // Include the amount redeemed.
                _gamePot = _gamePot + _delegate.amountRedeemed();

                // Set the pot text.
                _potText = _formatBalance(_gamePot, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);

                if (_gamePhase == DefifaGamePhase.NO_CONTEST) {
                    _gamePhaseText = "No contest. Refunds open.";
                } else if (_gamePhase == DefifaGamePhase.NO_CONTEST_INEVITABLE) {
                    _gamePhaseText = "No contest inevitable. Refunds open.";
                } else if (_gamePhase == DefifaGamePhase.COUNTDOWN) {
                    _gamePhaseText = "Minting starts soon.";
                } else if (_gamePhase == DefifaGamePhase.MINT) {
                    _gamePhaseText = "Minting and refunds are open.";
                } else if (_gamePhase == DefifaGamePhase.REFUND) {
                    _gamePhaseText = "Minting is over. Refunds are ending.";
                } else if (_gamePhase == DefifaGamePhase.SCORING) {
                    _gamePhaseText = "Awaiting scorecard approval.";
                } else if (_gamePhase == DefifaGamePhase.COMPLETE) {
                    _gamePhaseText = "Scorecard locked in. Burn to claim reward.";
                }

                // Keep a reference to the number of tokens outstanding from this tier.
                uint256 _totalMinted = _tier.initialQuantity - _tier.remainingQuantity;

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
                    uint256 _potPortion = PRBMath.mulDiv(
                        _gamePot, _delegate.redemptionWeightOf(_tokenId), _delegate.TOTAL_REDEMPTION_WEIGHT()
                    );
                    _valueText = !_delegate.redemptionWeightIsSet()
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
                '<style>@font-face{font-family:"Capsules-300";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getSkinnyFontSource(typeface),
                ');format("opentype");}',
                '@font-face{font-family:"Capsules-400";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getBeefyFontSource(typeface),
                ');format("opentype");}',
                "text{white-space:pre-wrap; width:100%; }</style>",
                '<rect width="100%" height="100%" fill="#181424"/>',
                '<text x="10" y="30" style="font-size:16px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">GAME: ',
                _gameId.toString(),
                " | POT: ",
                _potText,
                " | CARDS: ",
                _delegate.store().totalSupplyOf(address(_delegate)).toString(),
                "</text>",
                '<text x="10" y="50" style="font-size:16px; font-family: Capsules-300; font-weight:300; fill: #ed017c;">',
                _gamePhaseText,
                "</text>",
                '<text x="10" y="85" style="font-size:26px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">',
                _getSubstring(_title, 0, 30),
                "</text>",
                '<text x="10" y="120" style="font-size:26px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">',
                _getSubstring(_title, 30, 60),
                "</text>",
                '<text x="10" y="205" style="font-size:80px; font-family: Capsules-400; font-weight:400; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0 && bytes(_getSubstring(_team, 10, 20)).length != 0
                    ? _getSubstring(_team, 0, 10)
                    : "",
                "</text>",
                '<text x="10" y="295" style="font-size:80px; font-family: Capsules-400; font-weight:400; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 10, 20)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0 ? _getSubstring(_team, 0, 10) : "",
                "</text>",
                '<text x="10" y="385" style="font-size:80px; font-family: Capsules-400; font-weight:400; fill: #fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 20, 30)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0
                        ? _getSubstring(_team, 10, 20)
                        : _getSubstring(_team, 0, 10),
                "</text>",
                '<text x="10" y="430" style="font-size:16px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">TOKEN ID: ',
                _tokenId.toString(),
                "</text>",
                '<text x="10" y="455" style="font-size:16px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">RARITY: ',
                _rarityText,
                "</text>",
                '<text x="10" y="480" style="font-size:16px; font-family: Capsules-300; font-weight:300; fill: #c0b3f1;">BACKED BY: ',
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

    /// @notice Safely fetch the current game phase, tolerating reporter reverts.
    function _safeGamePhase(IDefifaGamePhaseReporter _reporter, uint256 _gameId)
        private
        view
        returns (bool success, DefifaGamePhase phase)
    {
        if (address(_reporter) == address(0)) return (false, DefifaGamePhase.COUNTDOWN);
        try _reporter.currentGamePhaseOf(_gameId) returns (DefifaGamePhase phase_) {
            return (true, phase_);
        } catch {
            if (_gameId != 0) {
                try _reporter.currentGamePhaseOf(0) returns (DefifaGamePhase fallbackPhase) {
                    return (true, fallbackPhase);
                } catch {}
            }
        }
        return (false, DefifaGamePhase.COUNTDOWN);
    }

    /// @notice Safely fetch the current game pot, tolerating reporter reverts.
    function _safeGamePot(IDefifaGamePotReporter _reporter, uint256 _gameId)
        private
        view
        returns (bool success, uint256 pot, address token, uint256 decimals)
    {
        if (address(_reporter) == address(0)) return (false, 0, JBTokens.ETH, 18);
        try _reporter.currentGamePotOf(_gameId, false) returns (uint256 pot_, address token_, uint256 decimals_) {
            return (true, pot_, token_, decimals_);
        } catch {
            if (_gameId != 0) {
                try _reporter.currentGamePotOf(0, false) returns (uint256 pot_, address token_, uint256 decimals_) {
                    return (true, pot_, token_, decimals_);
                } catch {}
            }
        }
        return (false, 0, JBTokens.ETH, 18);
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
        bool _isEth = _token == JBTokens.ETH;

        uint256 _fixedPoint = 10 ** _decimals;

        // Convert amount to a decimal format
        string memory _integerPart = _amount.div(_fixedPoint).toString();

        uint256 _remainder = _amount.mod(_fixedPoint);
        uint256 _scaledRemainder = _remainder.mul(10 ** _fidelity);
        uint256 _decimalPart = _scaledRemainder.div(_fixedPoint);

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
