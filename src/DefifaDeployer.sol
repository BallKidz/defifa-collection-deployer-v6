// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {mulDiv} from "@prb/math/src/Common.sol";
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

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBController, JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {
    JB721TiersRulesetMetadata,
    JB721TiersRulesetMetadataResolver
} from "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import {IJBRulesets, IJBRulesetApprovalHook, JBRuleset} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";

/// @title DefifaDeployer
/// @notice Deploys and manages Defifa games.
contract DefifaDeployer is IDefifaDeployer, IDefifaGamePhaseReporter, IDefifaGamePotReporter, IERC721Receiver {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error DefifaDeployer_CantFulfillYet();
    error DefifaDeployer_NothingToFulfill();
    error DefifaDeployer_GameOver();
    error DefifaDeployer_InvalidFeePercent();
    error DefifaDeployer_InvalidGameConfiguration();
    error DefifaDeployer_IncorrectDecimalAmount();
    error DefifaDeployer_NotNoContest();
    error DefifaDeployer_NoContestAlreadyTriggered();
    error DefifaDeployer_TerminalNotFound();
    error DefifaDeployer_PhaseAlreadyQueued();
    error DefifaDeployer_SplitsDontAddUp();
    error DefifaDeployer_UnexpectedTerminalCurrency();

    //*********************************************************************//
    // ----------------------- internal properties ----------------------- //
    //*********************************************************************//

    /// @notice The game's ops.
    mapping(uint256 => DefifaOpsData) internal _opsOf;

    /// @notice This contract current nonce, used for the registry initialized at 1 since the first contract deployed is
    /// the hook
    uint256 internal _nonce;

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

    /// @notice The divisor that describes the protocol fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent (e.g. 40 = 2.5% fee).
    uint256 public constant override BASE_PROTOCOL_FEE_DIVISOR = 40;

    /// @notice The divisor that describes the Defifa fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent (e.g. 20 = 5% fee).
    uint256 public constant override DEFIFA_FEE_DIVISOR = 20;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The amount of commitments a game has fulfilled.
    /// @dev The ID of the game to check.
    mapping(uint256 => uint256) public override fulfilledCommitmentsOf;

    /// @notice The total absolute split percent for each game (out of SPLITS_TOTAL_PERCENT).
    mapping(uint256 => uint256) internal _commitmentPercentOf;

    /// @notice Whether the no-contest refund ruleset has been triggered for a game.
    /// @dev Once triggered, the game stays in NO_CONTEST and refunds are enabled.
    mapping(uint256 => bool) public noContestTriggeredFor;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The game times.
    /// @param gameId The ID of the game for which the game times apply.
    /// @return The game's start time, as a unix timestamp.
    /// @return The game's minting period duration, in seconds.
    /// @return The game's refund period duration, in seconds.
    function timesFor(uint256 gameId) external view override returns (uint48, uint24, uint24) {
        DefifaOpsData memory _ops = _opsOf[gameId];
        return (_ops.start, _ops.mintPeriodDuration, _ops.refundPeriodDuration);
    }

    /// @notice The token of a game.
    /// @param gameId The ID of the game to get the token of.
    /// @return The game's token.
    function tokenOf(uint256 gameId) external view override returns (address) {
        return _opsOf[gameId].token;
    }

    /// @notice The safety mechanism parameters of a game.
    /// @param gameId The ID of the game to get the safety params of.
    /// @return minParticipation The minimum treasury balance for the game to proceed to scoring.
    /// @return scorecardTimeout The maximum time after scoring begins for a scorecard to be ratified.
    function safetyParamsOf(uint256 gameId)
        external
        view
        override
        returns (uint256 minParticipation, uint32 scorecardTimeout)
    {
        DefifaOpsData memory _ops = _opsOf[gameId];
        return (_ops.minParticipation, _ops.scorecardTimeout);
    }

    /// @notice The current pot the game is being played with.
    /// @param gameId The ID of the game for which the pot applies.
    /// @param includeCommitments A flag indicating if the portion of the pot committed to fulfill preprogrammed
    /// obligations should be included.
    /// @return The game's pot amount, as a fixed point number.
    /// @return The token address the game's pot is measured in.
    /// @return The number of decimals included in the amount.
    function currentGamePotOf(
        uint256 gameId,
        bool includeCommitments
    )
        external
        view
        returns (uint256, address, uint256)
    {
        // Get a reference to the token being used by the project.
        address _token = _opsOf[gameId].token;

        // Get a reference to the terminal.
        IJBTerminal _terminal = controller.DIRECTORY().primaryTerminalOf({projectId: gameId, token: _token});

        // Get the accounting context for the project.
        JBAccountingContext memory _context = _terminal.accountingContextForTokenOf({projectId: gameId, token: _token});

        // Get the current balance.
        uint256 _pot = IJBMultiTerminal(address(_terminal)).STORE()
            .balanceOf({terminal: address(_terminal), projectId: gameId, token: _token});

        // Add any fulfilled commitments.
        if (includeCommitments) _pot += fulfilledCommitmentsOf[gameId];

        return (_pot, _token, _context.decimals);
    }

    /// @notice Whether or not the next phase still needs queuing.
    /// @param gameId The ID of the game to get the queue status of.
    /// @return Whether or not the next phase still needs queuing.
    function nextPhaseNeedsQueueing(uint256 gameId) external view override returns (bool) {
        // Get the game's current funding cycle along with its metadata.
        JBRuleset memory _currentRuleset = controller.RULESETS().currentOf(gameId);
        // Get the game's queued funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (JBRuleset memory _queuedRuleset,) = controller.RULESETS().latestQueuedOf(gameId);

        // If the configurations are the same and the game hasn't ended, queueing is still needed.
        return _currentRuleset.duration != 0 && _currentRuleset.id == _queuedRuleset.id;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the number of the game phase.
    /// @dev The game phase corresponds to the game's current funding cycle number.
    /// @dev NO_CONTEST is returned if the minimum participation threshold is not met, or if the scorecard timeout has
    /// elapsed without ratification.
    /// @param gameId The ID of the game to get the phase number of.
    /// @return The game phase.
    function currentGamePhaseOf(uint256 gameId) public view override returns (DefifaGamePhase) {
        // Get the game's current funding cycle along with its metadata.
        (JBRuleset memory _currentRuleset, JBRulesetMetadata memory _metadata) = controller.currentRulesetOf(gameId);

        if (_currentRuleset.cycleNumber == 0) return DefifaGamePhase.COUNTDOWN;
        if (_currentRuleset.cycleNumber == 1) return DefifaGamePhase.MINT;
        if (_currentRuleset.cycleNumber == 2 && _opsOf[gameId].refundPeriodDuration != 0) {
            return DefifaGamePhase.REFUND;
        }

        // Check if the scorecard has been ratified (game is COMPLETE).
        // This takes priority over all NO_CONTEST checks — a ratified scorecard is final.
        if (IDefifaHook(_metadata.dataHook).cashOutWeightIsSet()) return DefifaGamePhase.COMPLETE;

        // If no-contest has already been triggered, stay in NO_CONTEST.
        if (noContestTriggeredFor[gameId]) return DefifaGamePhase.NO_CONTEST;

        // Get the game's ops data for the safety mechanism checks.
        DefifaOpsData memory _ops = _opsOf[gameId];

        // Check minimum participation threshold: if the treasury balance is below the threshold, the game is
        // NO_CONTEST.
        if (_ops.minParticipation > 0) {
            IJBTerminal _terminal = controller.DIRECTORY().primaryTerminalOf({projectId: gameId, token: _ops.token});
            uint256 _balance = IJBMultiTerminal(address(_terminal)).STORE()
                .balanceOf({terminal: address(_terminal), projectId: gameId, token: _ops.token});
            if (_balance < _ops.minParticipation) return DefifaGamePhase.NO_CONTEST;
        }

        // Check scorecard ratification timeout: if enough time has passed without a ratified scorecard, the game is
        // NO_CONTEST.
        if (_ops.scorecardTimeout > 0 && block.timestamp > _currentRuleset.start + _ops.scorecardTimeout) {
            return DefifaGamePhase.NO_CONTEST;
        }

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
        /// @dev Uses the deployer address as group ID. Game scoring rulesets use uint160(token) as group ID.
        splitGroup = uint256(uint160(address(this)));
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Launches a new game owned by this contract with a DefifaHook attached.
    /// @param launchProjectData Data necessary to fulfill the transaction to launch a game.
    /// @return gameId The ID of the newly configured game.
    function launchGameWith(DefifaLaunchProjectData memory launchProjectData)
        external
        override
        returns (uint256 gameId)
    {
        // Start the game right after the mint and refund durations if it isnt provided.
        if (launchProjectData.start == 0) {
            launchProjectData.start =
                uint48(block.timestamp + launchProjectData.mintPeriodDuration + launchProjectData.refundPeriodDuration);
        }
        // Start minting right away if a start time isn't provided.
        // slither-disable-next-line incorrect-equality
        else if (
            launchProjectData.mintPeriodDuration == 0
                && launchProjectData.start > block.timestamp + launchProjectData.refundPeriodDuration
        ) {
            launchProjectData.mintPeriodDuration =
                uint24(launchProjectData.start - (block.timestamp + launchProjectData.refundPeriodDuration));
        }

        // Make sure the provided gameplay timestamps are sequential and that there is a mint duration.
        // slither-disable-next-line incorrect-equality
        if (
            launchProjectData.mintPeriodDuration == 0
                || launchProjectData.start
                    < block.timestamp + launchProjectData.refundPeriodDuration + launchProjectData.mintPeriodDuration
        ) revert DefifaDeployer_InvalidGameConfiguration();

        // Get the game ID, optimistically knowing it will be one greater than the current count.
        gameId = controller.PROJECTS().count() + 1;

        {
            // Store the timestamps that'll define the game phases.
            _opsOf[gameId] = DefifaOpsData({
                token: launchProjectData.token.token,
                mintPeriodDuration: launchProjectData.mintPeriodDuration,
                refundPeriodDuration: launchProjectData.refundPeriodDuration,
                start: launchProjectData.start,
                minParticipation: launchProjectData.minParticipation,
                scorecardTimeout: launchProjectData.scorecardTimeout
            });

            // Keep a reference to the number of splits.
            uint256 _numberOfSplits = launchProjectData.splits.length;

            // If there are splits being added, store the fee alongside. The fee will otherwise be added later.
            if (_numberOfSplits != 0) {
                // Make a new splits where fees will be added to.
                JBSplit[] memory _splits = new JBSplit[](launchProjectData.splits.length + 1);

                // Copy the splits over.
                for (uint256 _i; _i < _numberOfSplits;) {
                    // Copy the split over.
                    _splits[_i] = launchProjectData.splits[_i];
                    unchecked {
                        ++_i;
                    }
                }

                // Add a split for the fee.
                _splits[_numberOfSplits] = JBSplit({
                    preferAddToBalance: false,
                    percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT / DEFIFA_FEE_DIVISOR),
                    projectId: uint64(defifaProjectId),
                    beneficiary: payable(address(this)),
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(0))
                });

                // Store the splits.
                JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
                _groupedSplits[0] = JBSplitGroup({groupId: splitGroup, splits: _splits});

                // This contract must have SET_SPLIT_GROUPS permission from the defifa project owner.
                controller.setSplitGroupsOf({
                    projectId: defifaProjectId, rulesetId: gameId, splitGroups: _groupedSplits
                });
            }
        }

        // Keep track of the number of tiers.
        uint256 _numberOfTiers = launchProjectData.tiers.length;

        // Create the standard tiers struct that will be populated from the defifa tiers.
        JB721TierConfig[] memory _hookTiers = new JB721TierConfig[](launchProjectData.tiers.length);

        // Group all the tier names together.
        string[] memory _tierNames = new string[](launchProjectData.tiers.length);

        // Keep a reference to the tier being iterated on.
        DefifaTierParams memory _defifaTier;

        // Create the hook tiers from the Defifa tiers.
        for (uint256 _i; _i < _numberOfTiers;) {
            _defifaTier = launchProjectData.tiers[_i];

            // Set the tier. All tiers use the same price so that price-based voting power is equal.
            _hookTiers[_i] = JB721TierConfig({
                price: launchProjectData.tierPrice,
                initialSupply: 999_999_999, // Uncapped minting — max value allowed by the 721 store.
                votingUnits: 0,
                reserveFrequency: _defifaTier.reservedRate,
                reserveBeneficiary: _defifaTier.reservedTokenBeneficiary,
                encodedIPFSUri: _defifaTier.encodedIPFSUri,
                category: 0,
                discountPercent: 0,
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: _defifaTier.shouldUseReservedTokenBeneficiaryAsDefault,
                transfersPausable: false,
                useVotingUnits: false,
                cannotBeRemoved: true,
                cannotIncreaseDiscountPercent: true,
                splitPercent: 0,
                splits: new JBSplit[](0)
            });

            // Set the name.
            _tierNames[_i] = _defifaTier.name;

            unchecked {
                ++_i;
            }
        }

        // Increment the nonce for this deployment.
        uint256 _currentNonce = ++_nonce;

        // Clone deterministically using sender and nonce to prevent front-running.
        // Clones.clone() creates the proxy before initialize() is called, allowing an
        // attacker to front-run initialization and DOS the game deployment. Using
        // cloneDeterministic with msg.sender in the salt prevents this since a different
        // caller produces a different address.
        DefifaHook _hook = DefifaHook(
            Clones.cloneDeterministic(hookCodeOrigin, keccak256(abi.encodePacked(msg.sender, _currentNonce)))
        );

        // Use the default uri resolver if provided, else use the hardcoded generic default.
        IJB721TokenUriResolver _uriResolver = launchProjectData.defaultTokenUriResolver
            != IJB721TokenUriResolver(address(0))
            ? launchProjectData.defaultTokenUriResolver
            : tokenUriResolver;

        _hook.initialize({
            _gameId: gameId,
            _name: launchProjectData.name,
            _symbol: string.concat("DEFIFA #", gameId.toString()),
            _rulesets: controller.RULESETS(),
            _baseUri: launchProjectData.baseUri,
            _tokenUriResolver: _uriResolver,
            _contractUri: launchProjectData.contractUri,
            _tiers: _hookTiers,
            _currency: launchProjectData.token.currency,
            _store: launchProjectData.store,
            _gamePhaseReporter: this,
            _gamePotReporter: this,
            _defaultAttestationDelegate: launchProjectData.defaultAttestationDelegate,
            _tierNames: _tierNames
        });

        // Launch the Juicebox project.
        uint256 _actualGameId =
            _launchGame({launchProjectData: launchProjectData, _gameId: gameId, _dataHook: address(_hook)});

        // Revert if the game ID does not match (e.g. front-run by another project creation).
        if (gameId != _actualGameId) revert DefifaDeployer_InvalidGameConfiguration();

        // Clone and initialize the new governor.
        governor.initializeGame({
            gameId: gameId,
            attestationStartTime: uint256(launchProjectData.attestationStartTime),
            attestationGracePeriod: uint256(launchProjectData.attestationGracePeriod)
        });

        // Transfer ownership to the specified owner.
        _hook.transferOwnership(address(governor));

        // Add the hook to the registry, contract nonce starts at 1
        registry.registerAddress({deployer: address(this), nonce: _currentNonce});

        emit LaunchGame(gameId, _hook, governor, _uriResolver, msg.sender);
    }

    /// @notice Fulfill split amounts between all splits for a game.
    /// @param gameId The ID of the game to fulfill splits for.
    function fulfillCommitmentsOf(uint256 gameId) external virtual override {
        // Make sure commitments haven't already been fulfilled.
        if (fulfilledCommitmentsOf[gameId] != 0) return;

        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory _metadata) = controller.currentRulesetOf(gameId);

        // Make sure the game's commitments can be fulfilled.
        if (!IDefifaHook(_metadata.dataHook).cashOutWeightIsSet()) {
            revert DefifaDeployer_CantFulfillYet();
        }

        // Get the game token and the terminal.
        address _token = _opsOf[gameId].token;
        IJBMultiTerminal _terminal =
            IJBMultiTerminal(address(controller.DIRECTORY().primaryTerminalOf({projectId: gameId, token: _token})));

        // Get the current pot and store it. This also prevents re-entrance since the check above will return early.
        uint256 _pot = _terminal.STORE().balanceOf({terminal: address(_terminal), projectId: gameId, token: _token});
        // slither-disable-next-line incorrect-equality
        if (_pot == 0) revert DefifaDeployer_NothingToFulfill();

        // Compute the fee amount based on the total absolute split percent stored at game creation.
        uint256 _feeAmount = mulDiv(_pot, _commitmentPercentOf[gameId], JBConstants.SPLITS_TOTAL_PERCENT);

        // Store the actual fee amount for accurate currentGamePotOf reporting.
        // Use max(feeAmount, 1) to preserve the reentrancy guard when pot is 0.
        fulfilledCommitmentsOf[gameId] = _feeAmount > 0 ? _feeAmount : 1;

        // Send only the fee portion as payouts. The remaining balance stays as surplus for cash-outs.
        // slither-disable-next-line unused-return
        _terminal.sendPayoutsOf({
            projectId: gameId,
            token: _token,
            amount: _feeAmount,
            currency: _token == JBConstants.NATIVE_TOKEN ? _metadata.baseCurrency : uint32(uint160(_token)),
            minTokensPaidOut: _feeAmount
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
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            // No more payouts.
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Update the ruleset to the final one.
        // slither-disable-next-line unused-return
        controller.queueRulesetsOf({
            projectId: gameId, rulesetConfigurations: rulesetConfigs, memo: "Defifa game has finished."
        });

        emit FulfilledCommitments({gameId: gameId, pot: _pot, caller: msg.sender});
    }

    /// @notice Triggers the no-contest refund mechanism for a game.
    /// @dev Anyone can call this once the game is in the NO_CONTEST phase. This queues a new ruleset without
    /// payout limits, making the surplus equal to the balance so users can cash out at their mint price.
    /// @dev Analogous to fulfillCommitmentsOf for COMPLETE — must be called before NO_CONTEST cash-outs work.
    /// @param gameId The ID of the game to trigger no-contest for.
    function triggerNoContestFor(uint256 gameId) external override {
        // Make sure the game is currently in NO_CONTEST phase.
        if (currentGamePhaseOf(gameId) != DefifaGamePhase.NO_CONTEST) {
            revert DefifaDeployer_NotNoContest();
        }

        // Make sure no-contest hasn't already been triggered.
        if (noContestTriggeredFor[gameId]) revert DefifaDeployer_NoContestAlreadyTriggered();

        // Mark as triggered.
        noContestTriggeredFor[gameId] = true;

        // Get the game's current ruleset metadata for the data hook address.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory _metadata) = controller.currentRulesetOf(gameId);

        // Queue a new ruleset without payout limits so surplus = balance, enabling refunds.
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
                ownerMustSendPayouts: true,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: _metadata.dataHook,
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Queue the no-contest refund ruleset.
        // slither-disable-next-line unused-return
        controller.queueRulesetsOf({
            projectId: gameId, rulesetConfigurations: rulesetConfigs, memo: "Defifa game: no contest."
        });

        emit QueuedNoContest(gameId, msg.sender);
    }

    /// @notice Allows this contract to receive 721s.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    function _launchGame(
        DefifaLaunchProjectData memory launchProjectData,
        uint256 _gameId,
        address _dataHook
    )
        internal
        returns (uint256 projectId)
    {
        //
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = launchProjectData.token;

        // Build the terminal configuration for the Defifa project.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: launchProjectData.terminal, accountingContextsToAccept: accountingContexts});

        // Build the rulesets that this Defifa game will go through.
        bool hasRefundPhase = launchProjectData.refundPeriodDuration != 0;
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](hasRefundPhase ? 3 : 2);

        // `MINT` cycle.
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: launchProjectData.start - launchProjectData.mintPeriodDuration
                - launchProjectData.refundPeriodDuration,
            duration: launchProjectData.mintPeriodDuration,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: launchProjectData.token.currency,
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
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({
                            pauseTransfers: false,
                            // Reserved tokens can't be minted during this funding cycle.
                            pauseMintPendingReserves: true
                        })
                    )
                )
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 cycleNumber = 1;
        if (hasRefundPhase) {
            // `REFUND` cycle.
            rulesetConfigs[cycleNumber++] = JBRulesetConfig({
                mustStartAtOrAfter: launchProjectData.start - launchProjectData.refundPeriodDuration,
                duration: launchProjectData.refundPeriodDuration,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: JBRulesetMetadata({
                    reservedPercent: 0,
                    cashOutTaxRate: 0,
                    baseCurrency: launchProjectData.token.currency,
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
                    metadata: uint16(
                        JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                            JB721TiersRulesetMetadata({
                                pauseTransfers: false,
                                // Reserved tokens can't be minted during this funding cycle.
                                pauseMintPendingReserves: true
                            })
                        )
                    )
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
            currency: launchProjectData.token.currency
        });

        JBFundAccessLimitGroup[] memory fundAccessConstraints = new JBFundAccessLimitGroup[](1);
        fundAccessConstraints[0] = JBFundAccessLimitGroup({
            terminal: address(launchProjectData.terminal),
            token: launchProjectData.token.token,
            payoutLimits: payoutAmounts,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        // `SCORING` cycle.
        rulesetConfigs[cycleNumber++] = JBRulesetConfig({
            mustStartAtOrAfter: launchProjectData.start,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: launchProjectData.token.currency,
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
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            splitGroups: _buildSplits({
                _gameId: _gameId,
                _dataHook: _dataHook,
                _token: launchProjectData.token.token,
                _initialSplits: launchProjectData.splits
            }),
            fundAccessLimitGroups: fundAccessConstraints
        });

        // launch the project.
        return controller.launchProjectFor({
            owner: address(this),
            projectUri: launchProjectData.projectUri,
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigurations,
            memo: "Launching Defifa game."
        });
    }

    function _buildSplits(
        uint256 _gameId,
        address _dataHook,
        address _token,
        JBSplit[] memory _initialSplits
    )
        internal
        returns (JBSplitGroup[] memory)
    {
        uint256 _numberOfUserSplits = _initialSplits.length;

        // Compute absolute percents for protocol fees.
        uint256 _nanaAbsolutePercent = JBConstants.SPLITS_TOTAL_PERCENT / BASE_PROTOCOL_FEE_DIVISOR;
        uint256 _defifaAbsolutePercent = JBConstants.SPLITS_TOTAL_PERCENT / DEFIFA_FEE_DIVISOR;

        // Sum all absolute percents.
        uint256 _totalAbsolutePercent = _nanaAbsolutePercent + _defifaAbsolutePercent;
        for (uint256 _i; _i < _numberOfUserSplits; _i++) {
            _totalAbsolutePercent += _initialSplits[_i].percent;
        }

        // Validate that total fee splits don't exceed 100%.
        if (_totalAbsolutePercent > JBConstants.SPLITS_TOTAL_PERCENT) revert DefifaDeployer_SplitsDontAddUp();

        // Store the total absolute percent for use in fulfillCommitmentsOf.
        _commitmentPercentOf[_gameId] = _totalAbsolutePercent;

        // Build the splits array: user splits + Defifa + NANA (NANA last to absorb rounding).
        uint256 _splitCount = _numberOfUserSplits + 2;
        JBSplit[] memory _splits = new JBSplit[](_splitCount);

        // Normalize user splits and copy them over.
        uint256 _normalizedTotal;
        for (uint256 _i; _i < _numberOfUserSplits; _i++) {
            _splits[_i] = _initialSplits[_i];
            _splits[_i].percent =
                uint32(mulDiv(_initialSplits[_i].percent, JBConstants.SPLITS_TOTAL_PERCENT, _totalAbsolutePercent));
            _normalizedTotal += _splits[_i].percent;
        }

        // Add Defifa fee split (normalized).
        uint256 _defifaNormalized =
            mulDiv(_defifaAbsolutePercent, JBConstants.SPLITS_TOTAL_PERCENT, _totalAbsolutePercent);
        _splits[_numberOfUserSplits] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(_defifaNormalized),
            projectId: uint64(defifaProjectId),
            beneficiary: payable(address(_dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        _normalizedTotal += _defifaNormalized;

        // Add NANA protocol fee split last — absorbs rounding remainder.
        // Beneficiary is the data hook so the hook receives NANA tokens for distribution during cash-outs.
        _splits[_splitCount - 1] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT - _normalizedTotal),
            projectId: uint64(baseProtocolProjectId),
            beneficiary: payable(address(_dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Build the grouped split for the payment of the game token.
        JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
        _groupedSplits[0] = JBSplitGroup({groupId: uint256(uint160(_token)), splits: _splits});

        return _groupedSplits;
    }
}
