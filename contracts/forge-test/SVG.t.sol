// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "lib/base64/base64.sol";

import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import {JB721Tier} from "@jbx-protocol/juice-721-delegate/contracts/structs/JB721Tier.sol";
import {
    IJBTiered721DelegateStore
} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJBTiered721DelegateStore.sol";
import {JBIpfsDecoder} from "@jbx-protocol/juice-721-delegate/contracts/libraries/JBIpfsDecoder.sol";

import "../DefifaSVGTokenUriResolver.sol";
import "../enums/DefifaGamePhase.sol";
import "../interfaces/IDefifaGamePhaseReporter.sol";
import "../interfaces/IDefifaGamePotReporter.sol";

contract SVGTest is Test {
    DefifaSVGTokenUriResolver internal resolver;
    MockStore internal store;
    MockGamePhaseReporter internal phaseReporter;
    MockGamePotReporter internal potReporter;

    function setUp() public {
        resolver = new DefifaSVGTokenUriResolver();
        store = new MockStore();
        phaseReporter = new MockGamePhaseReporter();
        potReporter = new MockGamePotReporter();
    }

    function testReturnsIpfsUriWhenTierHasEncodedUri() public {
        uint256 tokenId = 1001;
        bytes32 encodedIpfs = bytes32(0xfb17901b2b08444d2bbe92ca39bdd64eab27b0481e841fcd9f14aeb56e28513b);

        store.setTier(
            tokenId,
            JB721Tier({
                id: 1,
                price: 1e18,
                remainingQuantity: 0,
                initialQuantity: 100,
                votingUnits: 1,
                reservedRate: 0,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: encodedIpfs,
                category: 0,
                allowManualMint: false,
                transfersPausable: false,
                resolvedUri: ""
            })
        );
        store.setTotalSupply(42);

        MockDefifaDelegate delegate = new MockDefifaDelegate({
            projectId_: 123,
            name_: "Example collection",
            baseUri_: "ipfs://base/",
            store_: address(store),
            phaseReporter_: address(phaseReporter),
            potReporter_: address(potReporter),
            amountRedeemed_: 0,
            redemptionWeight_: 1,
            totalRedemptionWeight_: 100,
            redemptionWeightIsSet_: false
        });
        delegate.setTierName(1, "Example Team");

        string memory tokenUri = resolver.tokenUriOf(address(delegate), tokenId);
        string memory expected = JBIpfsDecoder.decode(delegate.baseURI(), encodedIpfs);
        assertEq(tokenUri, expected);
    }

    function testReturnsSvgMetadataWhenTierHasNoEncodedUri() public {
        uint256 tokenId = 2002;
        store.setTier(
            tokenId,
            JB721Tier({
                id: 7,
                price: 25e18,
                remainingQuantity: 90,
                initialQuantity: 100,
                votingUnits: 2,
                reservedRate: 0,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                category: 0,
                allowManualMint: false,
                transfersPausable: false,
                resolvedUri: ""
            })
        );
        store.setTotalSupply(123);

        MockDefifaDelegate delegate = new MockDefifaDelegate({
            projectId_: 456,
            name_: "Defifa Finals",
            baseUri_: "ipfs://base/",
            store_: address(store),
            phaseReporter_: address(phaseReporter),
            potReporter_: address(potReporter),
            amountRedeemed_: 4 ether,
            redemptionWeight_: 5,
            totalRedemptionWeight_: 10,
            redemptionWeightIsSet_: true
        });
        delegate.setTierName(7, "D in 4");

        phaseReporter.setPhase(DefifaGamePhase.SCORING);
        potReporter.setPot(200e18, JBTokens.ETH, 18);

        string memory tokenUri = resolver.tokenUriOf(address(delegate), tokenId);
        assertTrue(_hasBase64JsonPrefix(tokenUri));

        string memory json = string(Base64.decode(_stripPrefix(tokenUri)));
        bool hasName = _contains(json, '"name":"D in 4"');
        bool hasDescription = _contains(json, '"description":"Team: D in 4, ID: 7."');
        bool hasImage = _contains(json, '"image":"data:image/svg+xml;base64,');

        require(hasName, "name");
        require(hasDescription, "description");
        require(hasImage, "image");
    }

    function _stripPrefix(string memory tokenUri) internal pure returns (string memory) {
        bytes memory uriBytes = bytes(tokenUri);
        bytes memory prefix = bytes("data:application/json;base64,");
        require(uriBytes.length > prefix.length, "Invalid token URI");
        for (uint256 i; i < prefix.length; i++) {
            require(uriBytes[i] == prefix[i], "Missing prefix");
        }
        bytes memory data = new bytes(uriBytes.length - prefix.length);
        for (uint256 i = prefix.length; i < uriBytes.length; i++) {
            data[i - prefix.length] = uriBytes[i];
        }
        return string(data);
    }

    function _hasBase64JsonPrefix(string memory tokenUri) internal pure returns (bool) {
        bytes memory uriBytes = bytes(tokenUri);
        bytes memory prefix = bytes("data:application/json;base64,");
        if (uriBytes.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; i++) {
            if (uriBytes[i] != prefix[i]) return false;
        }
        return true;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);

        if (needleBytes.length == 0 || needleBytes.length > haystackBytes.length) {
            return false;
        }

        for (uint256 i; i <= haystackBytes.length - needleBytes.length; i++) {
            bool matchFound = true;
            for (uint256 j; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) {
                return true;
            }
        }
        return false;
    }
}

contract MockStore {
    mapping(uint256 => JB721Tier) internal _tiersByTokenId;
    uint256 internal _totalSupply;

    function setTier(uint256 _tokenId, JB721Tier memory _tier) external {
        _tiersByTokenId[_tokenId] = _tier;
    }

    function setTotalSupply(uint256 _totalSupply_) external {
        _totalSupply = _totalSupply_;
    }

    function tierOfTokenId(address, uint256 _tokenId, bool) external view returns (JB721Tier memory) {
        return _tiersByTokenId[_tokenId];
    }

    function totalSupplyOf(address) external view returns (uint256) {
        return _totalSupply;
    }
}

contract MockGamePhaseReporter is IDefifaGamePhaseReporter {
    DefifaGamePhase private _phase = DefifaGamePhase.COUNTDOWN;

    function setPhase(DefifaGamePhase phase_) external {
        _phase = phase_;
    }

    function currentGamePhaseOf(uint256) external view override returns (DefifaGamePhase) {
        return _phase;
    }
}

contract MockGamePotReporter is IDefifaGamePotReporter {
    uint256 private _pot = 106900000000000000;
    address private _token = JBTokens.ETH;
    uint256 private _decimals = 18;
    uint256 private _commitments;

    function setPot(uint256 pot_, address token_, uint256 decimals_) external {
        _pot = pot_;
        _token = token_;
        _decimals = decimals_;
    }

    function setCommitments(uint256 commitments_) external {
        _commitments = commitments_;
    }

    function fulfilledCommitmentsOf(uint256) external view override returns (uint256) {
        return _commitments;
    }

    function currentGamePotOf(uint256, bool includeCommitments)
        external
        view
        override
        returns (uint256, address, uint256)
    {
        if (includeCommitments) {
            return (_pot + _commitments, _token, _decimals);
        }
        return (_pot, _token, _decimals);
    }
}

contract MockDefifaDelegate {
    uint256 private _projectId;
    string private _name;
    string private _baseUri;
    address private _store;
    address private _phaseReporter;
    address private _potReporter;
    uint256 private _amountRedeemed;
    uint256 private _redemptionWeight;
    uint256 private _totalRedemptionWeight;
    bool private _redemptionWeightIsSet;
    mapping(uint256 => string) private _tierNames;

    constructor(
        uint256 projectId_,
        string memory name_,
        string memory baseUri_,
        address store_,
        address phaseReporter_,
        address potReporter_,
        uint256 amountRedeemed_,
        uint256 redemptionWeight_,
        uint256 totalRedemptionWeight_,
        bool redemptionWeightIsSet_
    ) {
        _projectId = projectId_;
        _name = name_;
        _baseUri = baseUri_;
        _store = store_;
        _phaseReporter = phaseReporter_;
        _potReporter = potReporter_;
        _amountRedeemed = amountRedeemed_;
        _redemptionWeight = redemptionWeight_;
        _totalRedemptionWeight = totalRedemptionWeight_;
        _redemptionWeightIsSet = redemptionWeightIsSet_;
    }

    function setTierName(uint256 tierId, string memory name_) external {
        _tierNames[tierId] = name_;
    }

    function projectId() external view returns (uint256) {
        return _projectId;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function store() external view returns (IJBTiered721DelegateStore) {
        return IJBTiered721DelegateStore(_store);
    }

    function tierNameOf(uint256 tierId) external view returns (string memory) {
        return _tierNames[tierId];
    }

    function gamePhaseReporter() external view returns (IDefifaGamePhaseReporter) {
        return IDefifaGamePhaseReporter(_phaseReporter);
    }

    function gamePotReporter() external view returns (IDefifaGamePotReporter) {
        return IDefifaGamePotReporter(_potReporter);
    }

    function amountRedeemed() external view returns (uint256) {
        return _amountRedeemed;
    }

    function setAmountRedeemed(uint256 amountRedeemed_) external {
        _amountRedeemed = amountRedeemed_;
    }

    function redemptionWeightOf(uint256) external view returns (uint256) {
        return _redemptionWeight;
    }

    function setRedemptionWeight(uint256 redemptionWeight_, uint256 totalRedemptionWeight_) external {
        _redemptionWeight = redemptionWeight_;
        _totalRedemptionWeight = totalRedemptionWeight_;
    }

    function TOTAL_REDEMPTION_WEIGHT() external view returns (uint256) {
        return _totalRedemptionWeight;
    }

    function redemptionWeightIsSet() external view returns (bool) {
        return _redemptionWeightIsSet;
    }

    function setRedemptionWeightIsSet(bool redemptionWeightIsSet_) external {
        _redemptionWeightIsSet = redemptionWeightIsSet_;
    }

    function baseURI() external view returns (string memory) {
        return _baseUri;
    }
}
