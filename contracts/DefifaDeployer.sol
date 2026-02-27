// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@prb/math/src/Common.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {IDefifaGovernor} from "./interfaces/IDefifaGovernor.sol";
import {DefifaLaunchProjectData} from "./structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "./structs/DefifaTierParams.sol";
import {DefifaOpsData} from "./structs/DefifaOpsData.sol";
import {DefifaHook} from "./DefifaHook.sol";
import {DefifaTokenUriResolver} from "./DefifaTokenUriResolver.sol";

import {IJBToken} from '@bananapus/core-v5/src/interfaces/IJBToken.sol';
import {IJB721TokenUriResolver} from '@bananapus/721-hook-v5/src/interfaces/IJB721TokenUriResolver.sol';
import {IJBController, JBRulesetConfig, JBTerminalConfig} from '@bananapus/core-v5/src/interfaces/IJBController.sol';
import {IJBAddressRegistry} from '@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol';
import {IJBTerminal} from '@bananapus/core-v5/src/interfaces/IJBTerminal.sol';
import {IJBMultiTerminal} from '@bananapus/core-v5/src/interfaces/IJBMultiTerminal.sol';
import {JBAccountingContext} from '@bananapus/core-v5/src/structs/JBAccountingContext.sol';
import {JBRulesetMetadata} from '@bananapus/core-v5/src/structs/JBRulesetMetadata.sol';
import {JBSplit} from '@bananapus/core-v5/src/structs/JBSplit.sol';
import {JBCurrencyAmount} from '@bananapus/core-v5/src/structs/JBCurrencyAmount.sol';
import {JBConstants} from '@bananapus/core-v5/src/libraries/JBConstants.sol';
import {JBSplitGroup} from "@bananapus/core-v5/src/structs/JBSplitGroup.sol";
import {IJBSplitHook} from '@bananapus/core-v5/src/interfaces/IJBSplitHook.sol';
import {JB721Tier} from '@bananapus/721-hook-v5/src/structs/JB721Tier.sol';
import {JB721TierConfig} from '@bananapus/721-hook-v5/src/structs/JB721TierConfig.sol';
import {IJBDirectory} from '@bananapus/core-v5/src/interfaces/IJBDirectory.sol';
import {JBSplitHookContext} from '@bananapus/core-v5/src/structs/JBSplitHookContext.sol';
import {JBFundAccessLimitGroup} from '@bananapus/core-v5/src/structs/JBFundAccessLimitGroup.sol';
import {JB721TiersRulesetMetadata, JB721TiersRulesetMetadataResolver} from '@bananapus/721-hook-v5/src/libraries/JB721TiersRulesetMetadataResolver.sol';
import "@bananapus/core-v5/src/interfaces/IJBRulesets.sol";


/// @title DefifaDeployer
/// @notice Deploys and manages Defifa games.
contract DefifaDeployer is IDefifaDeployer, IDefifaGamePhaseReporter, IDefifaGamePotReporter, IERC721Receiver {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error CANT_FULFILL_YET();
    error GAME_OVER();
    error INVALID_FEE_PERCENT();
    error INVALID_GAME_CONFIGURATION();
    error INCORRECT_DECIMAL_AMOUNT();
    error TERMINAL_NOT_FOUND();
    error PHASE_ALREADY_QUEUED();
    error SPLITS_DONT_ADD_UP();
    error UNEXPECTED_TERMINAL_CURRENCY();

    //*********************************************************************//
    // ----------------------- internal properties ----------------------- //
    //*********************************************************************//

    /// @notice The game's ops.
    mapping(uint256 => DefifaOpsData) internal _opsOf;

    /// @notice This contract current nonce, used for the registry initialized at 1 since the first contract deployed is the hook
    uint256 internal _nonce;

    /// @notice If each game has been set to no contest.
    mapping(uint256 => bool) internal _noContestIsSet;

    //*********************************************************************//
    // ------------------ public immutable properties -------------------- //
    //*********************************************************************//

    /// @notice The group relative to which splits are stored.
    /// @dev This could be any fixed number.
    uint256 public immutable override splitGroup;

    /// @notice The project ID that'll receive game fees, and relative to which splits are stored.
    /// @dev The owner of this project ID must give this contract operator permissions over the SET_SPLITS operation.
    uint256 public immutable override defifaProjectId;

    /// @notice The project ID that'll receive protocol fees as commitments are fulfilled.
    uint256 public immutable override baseProtocolProjectId;

    /// @notice The original code for the Defifa hook to base subsequent instances on.
    address public immutable override hookCodeOrigin;

    /// @notice The default Defifa token URI resolver.
    IJB721TokenUriResolver public immutable override tokenUriResolver;

    /// @notice The Defifa governor.
    IDefifaGovernor public immutable override governor;

    /// @notice The controller with which new projects should be deployed.
    IJBController public immutable override controller;

    /// @notice The hooks registry.
    IJBAddressRegistry public immutable registry;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The divisor that describes the fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent.
    uint256 public override baseProtocolFeeDivisor = 20;

    /// @notice The divisor that describes the fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent.
    uint256 public override defifaFeeDivisor = 20;

    /// @notice The amount of commitments a game has fulfilled.
    /// @dev The ID of the game to check.
    mapping(uint256 => uint256) public override fulfilledCommitmentsOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The game times.
    /// @param _gameId The ID of the game for which the game times apply.
    /// @return The game's start time, as a unix timestamp.
    /// @return The game's minting period duration, in seconds.
    /// @return The game's refund period duration, in seconds.
    function timesFor(uint256 _gameId) external view override returns (uint48, uint24, uint24) {
        DefifaOpsData memory _ops = _opsOf[_gameId];
        return (_ops.start, _ops.mintPeriodDuration, _ops.refundPeriodDuration);
    }

    /// @notice The token of a gmae.
    /// @param _gameId The ID of the game to get the token of.
    /// @return The game's token.
    function tokenOf(uint256 _gameId) external view override returns (address) {
        return _opsOf[_gameId].token;
    }

    /// @notice The current pot the game is being played with.
    /// @param _gameId The ID of the game for which the pot apply.
    /// @param _includeCommitments A flag indicating if the portion of the pot committed to fulfill preprogrammed obligations should be included.
    /// @return The game's pot amount, as a fixed point number.
    /// @return The token address the game's pot is measured in.
    /// @return The number of decimals included in the amount.
    function currentGamePotOf(uint256 _gameId, bool _includeCommitments)
        external
        view
        returns (uint256, address, uint256)
    {
        // Get a reference to the token being used by the project.
        address _token = _opsOf[_gameId].token;

        // Get a reference to the terminal.
        IJBTerminal _terminal = controller.DIRECTORY().primaryTerminalOf(_gameId, _token);

        // Get the accounting context for the project.
        JBAccountingContext memory _context = _terminal.accountingContextForTokenOf(_gameId, _token);

        // Get the current balance.
        uint256 _pot = IJBMultiTerminal(address(_terminal)).STORE().balanceOf(
            // TODO: Should we only check native token here?
            address(_terminal), _gameId, JBConstants.NATIVE_TOKEN
        );

        // Add any fulfilled commitments.
        if (_includeCommitments) _pot += fulfilledCommitmentsOf[_gameId];

        return (_pot, _token, _context.decimals);
    }

    /// @notice Whether or not the next phase still needs queuing.
    /// @param _gameId The ID of the game to get the queue status of.
    /// @return Whether or not the next phase still needs queuing.
    function nextPhaseNeedsQueueing(uint256 _gameId) external view override returns (bool) {
        // Get the game's current funding cycle along with its metadata.
        JBRuleset memory _currentRuleset = controller.RULESETS().currentOf(_gameId);
        // Get the game's queued funding cycle along with its metadata.
        (JBRuleset memory _queuedRuleset,) = controller.RULESETS().latestQueuedOf(_gameId);

        // If the configurations are the same and the game hasn't ended, queueing is still needed.
        return _currentRuleset.duration != 0
            && _currentRuleset.id == _queuedRuleset.id;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the number of the game phase.
    /// @dev The game phase corresponds to the game's current funding cycle number.
    /// @param _gameId The ID of the game to get the phase number of.
    /// @return The game phase.
    function currentGamePhaseOf(uint256 _gameId) public view override returns (DefifaGamePhase) {
        // Get the game's current funding cycle along with its metadata.
        (JBRuleset memory _currentRuleset, JBRulesetMetadata memory _metadata) =
            controller.currentRulesetOf(_gameId);

        if (_currentRuleset.cycleNumber == 0) return DefifaGamePhase.COUNTDOWN;
        if (_currentRuleset.cycleNumber == 1) return DefifaGamePhase.MINT;
        if (_currentRuleset.cycleNumber == 2 && _opsOf[_gameId].refundPeriodDuration != 0) {
            return DefifaGamePhase.REFUND;
        }
        if (IDefifaHook(_metadata.dataHook).cashOutWeightIsSet()) return DefifaGamePhase.COMPLETE;
        return DefifaGamePhase.SCORING;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param _hookCodeOrigin The code of the Defifa hook.
    /// @param _tokenUriResolver The standard default token URI resolver.
    /// @param _governor The Defifa governor.
    /// @param _controller The controller to use to launch the game from.
    /// @param _registry The contract storing references to the deployer of each hook.
    /// @param _defifaProjectId The ID of the project that should take the fee from the games.
    /// @param _baseProtocolProjectId The ID of the protocol project that'll receive fees from fulfilling commitments.
    constructor(
        address _hookCodeOrigin,
        IJB721TokenUriResolver _tokenUriResolver,
        IDefifaGovernor _governor,
        IJBController _controller,
        IJBAddressRegistry _registry,
        uint256 _defifaProjectId,
        uint256 _baseProtocolProjectId
    ) {
        hookCodeOrigin = _hookCodeOrigin;
        tokenUriResolver = _tokenUriResolver;
        governor = _governor;
        controller = _controller;
        registry = _registry;
        defifaProjectId = _defifaProjectId;
        baseProtocolProjectId = _baseProtocolProjectId;
        splitGroup = uint256(uint160(address(this)));
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Launches a new game owned by this contract with a DefifaHook attached.
    /// @param _launchProjectData Data necessary to fulfill the transaction to launch a game.
    /// @return gameId The ID of the newly configured game.
    function launchGameWith(DefifaLaunchProjectData memory _launchProjectData)
        external
        override
        returns (uint256 gameId)
    {
        // Start the game right after the mint and refund durations if it isnt provided.
        if (_launchProjectData.start == 0) {
            _launchProjectData.start = uint48(
                block.timestamp + _launchProjectData.mintPeriodDuration + _launchProjectData.refundPeriodDuration
            );
        }
        // Start minting right away if a start time isn't provided.
        else if (
            _launchProjectData.mintPeriodDuration == 0
                && _launchProjectData.start > block.timestamp + _launchProjectData.refundPeriodDuration
        ) {
            _launchProjectData.mintPeriodDuration =
                uint24(_launchProjectData.start - (block.timestamp + _launchProjectData.refundPeriodDuration));
        }

        // Make sure the provided gameplay timestamps are sequential and that there is a mint duration.
        if (
            _launchProjectData.mintPeriodDuration == 0
                || _launchProjectData.start
                    < block.timestamp + _launchProjectData.refundPeriodDuration + _launchProjectData.mintPeriodDuration
        ) revert INVALID_GAME_CONFIGURATION();

        // Get the game ID, optimistically knowing it will be one greater than the current count.
        gameId = controller.PROJECTS().count() + 1;

        {
            // Store the timestamps that'll define the game phases.
            _opsOf[gameId] = DefifaOpsData({
                token: _launchProjectData.token.token,
                mintPeriodDuration: _launchProjectData.mintPeriodDuration,
                refundPeriodDuration: _launchProjectData.refundPeriodDuration,
                start: _launchProjectData.start
            });

            // Keep a reference to the number of splits.
            uint256 _numberOfSplits = _launchProjectData.splits.length;

            // If there are splits being added, store the fee alongside. The fee will otherwise be added later.
            if (_numberOfSplits != 0) {
                // Make a new splits where fees will be added to.
                JBSplit[] memory _splits = new JBSplit[](_launchProjectData.splits.length + 1);

                // Copy the splits over.
                for (uint256 _i; _i < _numberOfSplits;) {
                    // Copy the split over.
                    _splits[_i] = _launchProjectData.splits[_i];
                    unchecked {
                        ++_i;
                    }
                }

                // Add a split for the fee.
                _splits[_numberOfSplits] = JBSplit({
                    preferAddToBalance: false,
                    percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT / defifaFeeDivisor),
                    projectId: uint64(defifaProjectId),
                    beneficiary: payable(address(this)),
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(0))
                });

                // Store the splits.
                JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
                _groupedSplits[0] = JBSplitGroup({groupId: splitGroup, splits: _splits});

                // This contract must have SET_SPLITS (index 18) operator permissions.
                controller.SPLITS().setSplitGroupsOf(defifaProjectId, gameId, _groupedSplits);
            }
        }

        // Keep track of the number of tiers.
        uint256 _numberOfTiers = _launchProjectData.tiers.length;

        // Create the standard tiers struct that will be populated from the defifa tiers.
        JB721TierConfig[] memory _hookTiers = new JB721TierConfig[](
          _launchProjectData.tiers.length
        );

        // Group all the tier names together.
        string[] memory _tierNames = new string[](_launchProjectData.tiers.length);

        // Keep a reference to the tier being iterated on.
        DefifaTierParams memory _defifaTier;

        // Create the hook tiers from the Defifa tiers.
        for (uint256 _i; _i < _numberOfTiers;) {
            _defifaTier = _launchProjectData.tiers[_i];

            // Set the tier.
            _hookTiers[_i] = JB721TierConfig({
                price: _defifaTier.price,
                initialSupply: 999_999_999, // The max allowed value.
                votingUnits: 1,
                reserveFrequency: _defifaTier.reservedRate,
                reserveBeneficiary: _defifaTier.reservedTokenBeneficiary,
                encodedIPFSUri: _defifaTier.encodedIPFSUri,
                category: 0,
                discountPercent: 0,
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: _defifaTier.shouldUseReservedTokenBeneficiaryAsDefault,
                transfersPausable: false,
                useVotingUnits: true,
                cannotBeRemoved: true,
                cannotIncreaseDiscountPercent: true
            });

            // Set the name.
            _tierNames[_i] = _defifaTier.name;

            unchecked {
                ++_i;
            }
        }

        // Clone and initialize the new hook with a new token uri resolver.
        DefifaHook _hook = DefifaHook(Clones.clone(hookCodeOrigin));

        // Use the default uri resolver if provided, else use the hardcoded generic default.
        IJB721TokenUriResolver _uriResolver = _launchProjectData.defaultTokenUriResolver
            != IJB721TokenUriResolver(address(0)) ? _launchProjectData.defaultTokenUriResolver : tokenUriResolver;

        _hook.initialize({
            _gameId: gameId,
            _name: _launchProjectData.name,
            _symbol: string.concat("DEFIFA #", gameId.toString()),
            _rulesets: controller.RULESETS(),
            _baseUri: _launchProjectData.baseUri,
            _tokenUriResolver: _uriResolver,
            _contractUri: _launchProjectData.contractUri,
            _tiers: _hookTiers,
            _currency: _launchProjectData.token.currency,
            _store: _launchProjectData.store,
            _gamePhaseReporter: this,
            _gamePotReporter: this,
            _defaultAttestationDelegate: _launchProjectData.defaultAttestationDelegate,
            _tierNames: _tierNames
        });
        
        // Launch the Juicebox project, and sanity check our gameId.
        assert(gameId == _launchGame(_launchProjectData, gameId, address(_hook)));

        // Clone and initialize the new governor.
        governor.initializeGame({
            gameId: gameId,
            attestationStartTime: uint256(_launchProjectData.attestationStartTime),
            attestationGracePeriod: uint256(_launchProjectData.attestationGracePeriod)
        });

        // Transfer ownership to the specified owner.
        _hook.transferOwnership(address(governor));

        // Add the hook to the registry, contract nonce starts at 1
        registry.registerAddress(address(this), ++_nonce);

        emit LaunchGame(gameId, _hook, governor, _uriResolver, msg.sender);
    }

    /// @notice Fulfill split amounts between all splits for a game.
    /// @param _gameId The ID of the game to fulfill splits for.
    function fulfillCommitmentsOf(uint256 _gameId) external virtual override {
        // Make sure commitments haven't already been fulfilled.
        if (fulfilledCommitmentsOf[_gameId] != 0) return;
        // Set the fulfilled commitments to 1 to prevent re-entrance.
        fulfilledCommitmentsOf[_gameId] = 1;

        // Get the game's current funding cycle along with its metadata.
        (, JBRulesetMetadata memory _metadata) =
            controller.currentRulesetOf(_gameId);

        // Make sure the game's commitments can be fulfilled.
        if (!IDefifaHook(_metadata.dataHook).cashOutWeightIsSet()) {
            revert CANT_FULFILL_YET();
        }
        
        // Get the game token and the terminal.
        address _token = _opsOf[_gameId].token;
        IJBMultiTerminal _terminal = IJBMultiTerminal(address(controller.DIRECTORY().primaryTerminalOf(_gameId, _token)));

        // Get the current pot.
        uint256 _pot = _terminal.STORE().balanceOf(
            address(_terminal), _gameId, _token
        );
        
        // Send the payout to pay all the fees for this game.
        _terminal.sendPayoutsOf({
            projectId: _gameId,
            token: _token,
            amount: _pot,
            currency: _token == JBConstants.NATIVE_TOKEN ? _metadata.baseCurrency : uint32(uint160(_token)),
            minTokensPaidOut: _pot
        });

        // Queue the final ruleset.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0, 
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: _metadata.baseCurrency,
                pausePay: true,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                // Set this to true so only the deployer can fulfill the commitments.
                ownerMustSendPayouts: true,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: _metadata.dataHook,
                metadata: uint16(JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                    JB721TiersRulesetMetadata({
                    pauseTransfers: false,
                    pauseMintPendingReserves: false 
                })
                ))
            }),
            // No more payouts.
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0) 
        });
        
        // Update the ruleset to the final one.
        controller.queueRulesetsOf(_gameId, rulesetConfigs, 'Defifa game has finished.');

        // Update the fulfilled commitments to the actual pot amount.
        fulfilledCommitmentsOf[_gameId] = _pot;

        emit FulfilledCommitments({
            gameId: _gameId,
            pot: _pot,
            caller: msg.sender
        });
    }

    /// @notice Allows this contract to receive 721s.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    function _launchGame(DefifaLaunchProjectData memory _launchProjectData, uint256 _gameId, address _dataHook) internal returns (uint256 projectId) {
        // 
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = _launchProjectData.token;

        // Build the terminal configuration for the Defifa project.
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({
            terminal: _launchProjectData.terminal,
            accountingContextsToAccept: accountingContexts
        });

        // Build the rulesets that this Defifa game will go through.
        bool hasRefundPhase = _launchProjectData.refundPeriodDuration != 0;
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](hasRefundPhase ? 3 : 2);
        
        // `MINT` cycle.
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: _launchProjectData.start - _launchProjectData.mintPeriodDuration - _launchProjectData.refundPeriodDuration,
            duration: _launchProjectData.mintPeriodDuration, 
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: _launchProjectData.token.currency,
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: _dataHook,
                metadata: uint16(JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                    JB721TiersRulesetMetadata({
                    pauseTransfers: false,
                    // Reserved tokens can't be minted during this funding cycle.
                    pauseMintPendingReserves: true
                })
                ))
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0) 
        });
        
        uint256 cycleNumber = 1;
        if (hasRefundPhase) {
            // `REFUND` cycle.
            rulesetConfigs[cycleNumber++] = JBRulesetConfig({
                mustStartAtOrAfter: _launchProjectData.start - _launchProjectData.refundPeriodDuration,
                duration: _launchProjectData.refundPeriodDuration, 
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: JBRulesetMetadata({
                    reservedPercent: 0,
                    cashOutTaxRate: 0,
                    baseCurrency: _launchProjectData.token.currency,
                    // Refund phase does not allow new payments.
                    pausePay: true,
                    pauseCreditTransfers: false,
                    allowOwnerMinting: false,
                    allowSetCustomToken: false,
                    allowTerminalMigration: false,
                    allowSetTerminals: false,
                    allowSetController: false,
                    allowAddAccountingContext: false,
                    allowAddPriceFeed: false,
                    ownerMustSendPayouts: false,
                    holdFees: false,
                    useTotalSurplusForCashOuts: false,
                    useDataHookForPay: true,
                    useDataHookForCashOut: true,
                    dataHook: _dataHook,
                    metadata: uint16(JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({
                        pauseTransfers: false,
                        // Reserved tokens can't be minted during this funding cycle.
                        pauseMintPendingReserves: true
                    })
                    ))
                }),
                splitGroups: new JBSplitGroup[](0),
                fundAccessLimitGroups: new JBFundAccessLimitGroup[](0) 
            });
        }

        // Set fund access constraints.
        JBCurrencyAmount[] memory payoutAmounts = new JBCurrencyAmount[](1);
        payoutAmounts[0] = JBCurrencyAmount({
            // We allow a payout of the full amount, this will then mostly be added back to the balance of the project.
            amount: type(uint224).max,
            currency: _launchProjectData.token.currency
        });

        JBFundAccessLimitGroup[] memory fundAccessConstraints = new JBFundAccessLimitGroup[](1);
        fundAccessConstraints[0] = JBFundAccessLimitGroup({
            terminal: address(_launchProjectData.terminal),
            token: _launchProjectData.token.token,
            payoutLimits: payoutAmounts,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        
        // `SCORING` cycle.
        rulesetConfigs[cycleNumber++] = JBRulesetConfig({
            mustStartAtOrAfter: _launchProjectData.start,
            duration: 0, 
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: _launchProjectData.token.currency,
                pausePay: true,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                // Set this to true so only the deployer can fulfill the commitments.
                ownerMustSendPayouts: true,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: _dataHook,
                metadata: uint16(JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                    JB721TiersRulesetMetadata({
                    pauseTransfers: false,
                    pauseMintPendingReserves: false 
                })
                ))
            }),
            splitGroups: _buildSplits(_gameId, _dataHook, _launchProjectData.token.token, _launchProjectData.splits),
            fundAccessLimitGroups: fundAccessConstraints 
        });

        // launch the project.
        return controller.launchProjectFor({
            owner: address(this),
            projectUri: _launchProjectData.projectUri,
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs, 
            memo: 'Launching Defifa game.'
        });
    }

    function _buildSplits(uint256 _gameId, address _dataHook, address _token, JBSplit[] memory _initialSplits) internal view returns (JBSplitGroup[] memory) {
        uint256 _numberOfSplits = _initialSplits.length;
        uint256 _totalPercent;

        JBSplit[] memory _splits = new JBSplit[](_initialSplits.length + 3);
        // Copy the splits over.
        for (uint256 _i; _i < _numberOfSplits; _i++) {
            // Copy the split over.
            _splits[_i] = _initialSplits[_i];
            // Track the total percentage.
            _totalPercent += _initialSplits[_i].percent;
        }

        // Add a split for the NANA fee.
        _splits[_numberOfSplits] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT / baseProtocolFeeDivisor),
            projectId: uint64(baseProtocolProjectId),
            // Have the fee be paid directly to the data hook of the project.
            beneficiary: payable(address(_dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        _totalPercent += JBConstants.SPLITS_TOTAL_PERCENT / baseProtocolFeeDivisor;

        // Add a split for the Defifa fee.
        _splits[_numberOfSplits + 1] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT / defifaFeeDivisor),
            projectId: uint64(defifaProjectId),
            // Have the fee be paid directly to the data hook of the project.
            beneficiary: payable(address(_dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        _totalPercent += JBConstants.SPLITS_TOTAL_PERCENT / defifaFeeDivisor;
        
        // Add a split for the leftover percentage.
        _splits[_numberOfSplits + 2] = JBSplit({
            preferAddToBalance: true,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT - _totalPercent),
            projectId: uint64(_gameId),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        
        // Build the grouped split for the payment of the game token.
        JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
        _groupedSplits[0] = JBSplitGroup({groupId: uint256(uint160(_token)), splits: _splits});

        return _groupedSplits;
    }
}
