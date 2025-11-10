// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "lib/base64/base64.sol";
import {PRBMath} from "@paulrberg/contracts/math/PRBMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import {IJB721TokenUriResolver} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJB721TokenUriResolver.sol";
import {JBIpfsDecoder} from "@jbx-protocol/juice-721-delegate/contracts/libraries/JBIpfsDecoder.sol";
import {JB721Tier} from "@jbx-protocol/juice-721-delegate/contracts/structs/JB721Tier.sol";
import {
    IJBTiered721DelegateStore
} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJBTiered721DelegateStore.sol";
import {IDefifaDelegate} from "./interfaces/IDefifaDelegate.sol";
import {IDefifaTokenUriResolver} from "./interfaces/IDefifaTokenUriResolver.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @title DefifaSVGTokenUriResolver
/// @notice Token URI resolver that renders SVG metadata without relying on external typeface contracts.
contract DefifaSVGTokenUriResolver is Ownable, IDefifaTokenUriResolver, IJB721TokenUriResolver {
    using Strings for uint256;
    using SafeMath for uint256;

    uint256 private constant _IMG_DECIMAL_FIDELITY = 3;

    mapping(address => uint256) private _gameIdOverride;
    mapping(address => bool) private _gameIdOverrideSet;

    event GameIdOverrideSet(address indexed delegate, uint256 indexed gameId);

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the tier IPFS URI if set, otherwise build an SVG-based JSON document.
    function tokenUriOf(address _nft, uint256 _tokenId) external view override returns (string memory) {
        IDefifaDelegate _delegate = IDefifaDelegate(_nft);

        IJBTiered721DelegateStore _store;
        try _delegate.store() returns (IJBTiered721DelegateStore store_) {
            _store = store_;
        } catch {
            return _placeholderTokenUri(_tokenId);
        }

        if (address(_store) == address(0)) {
            return _placeholderTokenUri(_tokenId);
        }

        JB721Tier memory _tier;
        try _store.tierOfTokenId(address(_delegate), _tokenId, false) returns (JB721Tier memory tier_) {
            _tier = tier_;
        } catch {
            return _placeholderTokenUri(_tokenId);
        }

        if (_tier.encodedIPFSUri != bytes32(0)) {
            try _delegate.baseURI() returns (string memory baseUri) {
                return JBIpfsDecoder.decode(baseUri, _tier.encodedIPFSUri);
            } catch {
                return _placeholderTokenUri(_tokenId);
            }
        }

        string memory _team;
        try _delegate.tierNameOf(_tier.id) returns (string memory tierName) {
            _team = tierName;
        } catch {}

        if (bytes(_team).length == 0) {
            _team = string(abi.encodePacked("Tier ", uint256(_tier.id).toString()));
        }

        string memory _title;
        try _delegate.name() returns (string memory name_) {
            _title = name_;
        } catch {
            _title = "Defifa";
        }

        uint256 _gameId;
        bool _hasGameId;
        try _delegate.PROJECT_ID() returns (uint256 gameId_) {
            if (gameId_ != 0) {
                _gameId = gameId_;
                _hasGameId = true;
            }
        } catch {}

        if (!_hasGameId && _gameIdOverrideSet[_nft]) {
            _gameId = _gameIdOverride[_nft];
            _hasGameId = true;
        }

        IDefifaGamePhaseReporter _phaseReporter;
        try _delegate.gamePhaseReporter() returns (IDefifaGamePhaseReporter reporter_) {
            _phaseReporter = reporter_;
        } catch {}

        IDefifaGamePotReporter _potReporter;
        try _delegate.gamePotReporter() returns (IDefifaGamePotReporter reporter_) {
            _potReporter = reporter_;
        } catch {}

        (bool _potFetched, uint256 _gamePot, address _gamePotToken, uint256 _gamePotDecimals) =
            _safeGamePot(_potReporter, _hasGameId ? _gameId : 0);

        uint256 _amountRedeemed;
        try _delegate.amountRedeemed() returns (uint256 amount) {
            _amountRedeemed = amount;
        } catch {}

        uint256 _effectivePot = _gamePot + _amountRedeemed;
        string memory _potText;
        if (_potFetched) {
            _potText = _formatBalance(_effectivePot, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
        } else if (_amountRedeemed != 0) {
            _potText = _formatBalance(_amountRedeemed, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
        } else {
            _potText = "Unknown";
        }

        (bool _phaseFetched, DefifaGamePhase _gamePhase) = _safeGamePhase(_phaseReporter, _hasGameId ? _gameId : 0);
        string memory _gamePhaseText = "Phase data unavailable.";

        if (_phaseFetched) {
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
        }

        uint256 _totalMinted = _tier.initialQuantity - _tier.remainingQuantity;
        string memory _rarityText;
        if (_phaseFetched && _gamePhase == DefifaGamePhase.MINT) {
            _rarityText =
                string(abi.encodePacked(_totalMinted.toString(), _totalMinted == 1 ? " card so far" : " cards so far"));
        } else {
            _rarityText = string(
                abi.encodePacked(
                    _totalMinted.toString(), _totalMinted == 1 ? " card in existence" : " cards in existence"
                )
            );
        }

        uint256 _redemptionWeight;
        try _delegate.redemptionWeightOf(_tokenId) returns (uint256 weight) {
            _redemptionWeight = weight;
        } catch {}

        bool _redemptionSet;
        try _delegate.redemptionWeightIsSet() returns (bool isSet) {
            _redemptionSet = isSet;
        } catch {}

        uint256 _totalRedemptionWeight;
        try _delegate.TOTAL_REDEMPTION_WEIGHT() returns (uint256 total) {
            _totalRedemptionWeight = total;
        } catch {}

        string memory _valueText;
        if (
            _phaseFetched && (_gamePhase == DefifaGamePhase.SCORING || _gamePhase == DefifaGamePhase.COMPLETE)
                && _totalRedemptionWeight != 0
        ) {
            uint256 _potPortion = PRBMath.mulDiv(_effectivePot, _redemptionWeight, _totalRedemptionWeight);
            _valueText = !_redemptionSet
                ? "Awaiting scorecard..."
                : _formatBalance(_potPortion, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
        } else {
            _valueText = _formatBalance(_tier.price, _gamePotToken, _gamePotDecimals, _IMG_DECIMAL_FIDELITY);
        }

        uint256 _totalSupply;
        try _store.totalSupplyOf(address(_delegate)) returns (uint256 supply) {
            _totalSupply = supply;
        } catch {}

        string[] memory parts = new string[](4);
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

        parts[2] = Base64.encode(
            abi.encodePacked(
                '<svg viewBox="0 0 500 500" xmlns="http://www.w3.org/2000/svg">',
                "<style>",
                "text{white-space:pre-wrap;width:100%;font-family:\"Courier New\", monospace;}",
                ".thin{font-weight:500;font-family:\"Courier New\", monospace;}",
                ".bold{font-weight:700;font-family:\"Courier New\", monospace;}",
                "</style>",
                '<rect width="100%" height="100%" fill="#181424"/>',
                '<text x="10" y="30" class="thin" style="font-size:16px;fill:#c0b3f1;">GAME: ',
                _gameId == 0 ? "-" : _gameId.toString(),
                " | POT: ",
                _potText,
                " | CARDS: ",
                _totalSupply.toString(),
                "</text>",
                '<text x="10" y="50" class="thin" style="font-size:16px;fill:#ed017c;">',
                _gamePhaseText,
                "</text>",
                '<text x="10" y="85" class="thin" style="font-size:26px;fill:#c0b3f1;">',
                _getSubstring(_title, 0, 30),
                "</text>",
                '<text x="10" y="120" class="thin" style="font-size:26px;fill:#c0b3f1;">',
                _getSubstring(_title, 30, 60),
                "</text>",
                '<text x="10" y="205" class="bold" style="font-size:80px;fill:#fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0 && bytes(_getSubstring(_team, 10, 20)).length != 0
                    ? _getSubstring(_team, 0, 10)
                    : "",
                "</text>",
                '<text x="10" y="295" class="bold" style="font-size:80px;fill:#fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 10, 20)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0 ? _getSubstring(_team, 0, 10) : "",
                "</text>",
                '<text x="10" y="385" class="bold" style="font-size:80px;fill:#fea282;">',
                bytes(_getSubstring(_team, 20, 30)).length != 0
                    ? _getSubstring(_team, 20, 30)
                    : bytes(_getSubstring(_team, 10, 20)).length != 0
                        ? _getSubstring(_team, 10, 20)
                        : _getSubstring(_team, 0, 10),
                "</text>",
                '<text x="10" y="430" class="thin" style="font-size:16px;fill:#c0b3f1;">TOKEN ID: ',
                _tokenId.toString(),
                "</text>",
                '<text x="10" y="455" class="thin" style="font-size:16px;fill:#c0b3f1;">RARITY: ',
                _rarityText,
                "</text>",
                '<text x="10" y="480" class="thin" style="font-size:16px;fill:#c0b3f1;">BACKED BY: ',
                _valueText,
                "</text>",
                "</svg>"
            )
        );
        parts[3] = string('"}');

        return string.concat(parts[0], Base64.encode(abi.encodePacked(parts[1], parts[2], parts[3])));
    }

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

    function _placeholderTokenUri(uint256 _tokenId) private pure returns (string memory) {
        string memory json = string(
            abi.encodePacked(
                '{"name":"Defifa Game NFT #', _tokenId.toString(), '","description":"Metadata unavailable","image":""}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

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
        bytes memory _result = new bytes(_endIndex - _startIndex);
        for (uint256 _i = _startIndex; _i < _endIndex;) {
            _result[_i - _startIndex] = _strBytes[_i];
            unchecked {
                ++_i;
            }
        }
        return string(_result);
    }

    function _formatBalance(uint256 _amount, address _token, uint256 _decimals, uint256 _fidelity)
        internal
        view
        returns (string memory)
    {
        bool _isEth = _token == JBTokens.ETH;

        uint256 _fixedPoint = 10 ** _decimals;

        string memory _integerPart = _amount.div(_fixedPoint).toString();

        uint256 _remainder = _amount.mod(_fixedPoint);
        uint256 _scaledRemainder = _remainder.mul(10 ** _fidelity);
        uint256 _decimalPart = _scaledRemainder.div(_fixedPoint);

        string memory _decimalPartStr = _decimalPart.toString();
        while (bytes(_decimalPartStr).length < _fidelity) {
            _decimalPartStr = string(abi.encodePacked("0", _decimalPartStr));
        }

        return _isEth
            ? string(abi.encodePacked("\u039E", _integerPart, ".", _decimalPartStr))
            : string(abi.encodePacked(_integerPart, ".", _decimalPartStr, " ", IERC20Metadata(_token).symbol()));
    }

    function typeface() external pure returns (ITypeface) {
        return ITypeface(address(0));
    }

    function setGameIdOverride(address _delegate, uint256 _gameId) external onlyOwner {
        _gameIdOverride[_delegate] = _gameId;
        _gameIdOverrideSet[_delegate] = true;
        emit GameIdOverrideSet(_delegate, _gameId);
    }

    function clearGameIdOverride(address _delegate) external onlyOwner {
        delete _gameIdOverride[_delegate];
        delete _gameIdOverrideSet[_delegate];
        emit GameIdOverrideSet(_delegate, 0);
    }

    function gameIdOverrideOf(address _delegate) external view returns (uint256 gameId, bool isSet) {
        return (_gameIdOverride[_delegate], _gameIdOverrideSet[_delegate]);
    }
}

