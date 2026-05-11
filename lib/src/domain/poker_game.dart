import 'dart:math';

import '../ai/ai_decision_provider.dart';
import '../ai/heuristic_ai_decision_provider.dart';
import 'card.dart';
import 'deck.dart';
import 'hand_evaluator.dart';
import 'models.dart';
import 'money.dart';

class PokerGame {
  PokerGame({
    required this.config,
    AiDecisionProvider aiDecisionProvider = const HeuristicAiDecisionProvider(),
    int? seed,
  }) : aiProvider = aiDecisionProvider,
       _profileRandom = Random(seed == null ? null : seed ^ 0x5eed5eed),
       _deck = Deck(random: Random(seed)) {
    _createPlayers();
    startNextHand();
  }

  final TableConfig config;
  final AiDecisionProvider aiProvider;
  final Random _profileRandom;
  final Deck _deck;
  final List<PlayerState> players = <PlayerState>[];
  final List<PlayingCard> board = <PlayingCard>[];
  final List<ActionHistoryEntry> actionLog = <ActionHistoryEntry>[];

  BettingPhase phase = BettingPhase.waiting;
  int handNumber = 0;
  int dealerIndex = 0;
  int currentPlayerIndex = -1;
  int currentBet = 0;
  int lastRaiseSize = 0;
  bool completedByShowdown = false;
  final Set<String> showdownPlayerIds = <String>{};
  String statusMessage = 'Setting up table';

  PlayerState get humanPlayer => players.firstWhere(
    (PlayerState player) => player.kind == PlayerKind.human,
  );

  PlayerState? get currentPlayer {
    if (currentPlayerIndex < 0 || currentPlayerIndex >= players.length) {
      return null;
    }
    return players[currentPlayerIndex];
  }

  int get potTotal => players.fold<int>(
    0,
    (int total, PlayerState player) => total + player.totalCommitted,
  );

  bool get isHumanTurn {
    final PlayerState? player = currentPlayer;
    return player != null &&
        player.kind == PlayerKind.human &&
        player.canAct &&
        phase != BettingPhase.handComplete;
  }

  bool get isHandComplete => phase == BettingPhase.handComplete;

  bool get canRebuyHuman {
    final PlayerState hero = humanPlayer;
    if (hero.stack >= config.maxBuyIn) {
      return false;
    }
    return isHandComplete || hero.hasFolded || phase == BettingPhase.waiting;
  }

  int get humanRebuyRoom => max(0, config.maxBuyIn - humanPlayer.stack);

  int rebuyHuman(int amount) {
    if (!canRebuyHuman || amount <= 0) {
      return 0;
    }
    final int paid = amount.clamp(0, humanRebuyRoom).toInt();
    if (paid <= 0) {
      return 0;
    }
    humanPlayer.stack += paid;
    humanPlayer.isAllIn = false;
    statusMessage =
        '${humanPlayer.name} rebuys ${Chips.format(paid)}. Stack ${Chips.format(humanPlayer.stack)}.';
    return paid;
  }

  void startNextHand() {
    _topUpBustedPlayers();
    if (_activeSeatCount() < 2) {
      phase = BettingPhase.handComplete;
      statusMessage = 'Need at least two funded seats.';
      currentPlayerIndex = -1;
      return;
    }

    if (handNumber > 0) {
      dealerIndex = _nextFundedSeat(dealerIndex);
    }

    handNumber += 1;
    phase = BettingPhase.preflop;
    currentBet = 0;
    lastRaiseSize = config.bigBlind;
    currentPlayerIndex = -1;
    board.clear();
    completedByShowdown = false;
    showdownPlayerIds.clear();
    _deck.reset();

    for (final PlayerState player in players) {
      player.resetForHand();
    }

    players[dealerIndex].isDealer = true;
    final int smallBlindIndex = _smallBlindIndex();
    final int bigBlindIndex = _nextFundedSeat(smallBlindIndex);
    players[smallBlindIndex].isSmallBlind = true;
    players[bigBlindIndex].isBigBlind = true;

    _postBlind(smallBlindIndex, config.smallBlind);
    _postBlind(bigBlindIndex, config.bigBlind);
    currentBet = players
        .map((PlayerState player) => player.currentBet)
        .reduce(max);

    for (int round = 0; round < 2; round += 1) {
      for (final PlayerState player in players.where(
        (PlayerState player) => player.stack >= 0,
      )) {
        if (player.stack + player.totalCommitted > 0) {
          player.holeCards.add(_deck.draw());
        }
      }
    }

    currentPlayerIndex = _activeSeatCount() == 2
        ? smallBlindIndex
        : _nextFundedSeat(bigBlindIndex);
    statusMessage =
        'Hand $handNumber started. ${players[currentPlayerIndex].name} acts first.';
  }

  Future<void> runAiUntilHumanTurn() async {
    int guard = 0;
    while (!isHandComplete &&
        !isHumanTurn &&
        currentPlayer?.kind == PlayerKind.ai) {
      guard += 1;
      if (guard > 200) {
        throw StateError('AI action loop exceeded the safety limit.');
      }
      final bool applied = await runNextAiAction();
      if (!applied) {
        return;
      }
    }
  }

  Future<bool> runNextAiAction() async {
    if (isHandComplete || isHumanTurn || currentPlayer?.kind != PlayerKind.ai) {
      return false;
    }
    final int actorIndex = currentPlayerIndex;
    final AiDecision decision = await aiProvider.decide(
      AiDecisionRequest(
        snapshot: visibleSnapshotFor(actorIndex),
        profile: players[actorIndex].profile ?? AiProfile.balanced,
        legalActions: legalActionsForCurrentPlayer(),
      ),
    );
    applyAction(decision.action);
    if (decision.thinking case final String thinking
        when thinking.trim().isNotEmpty) {
      statusMessage = '${players[actorIndex].name}: ${thinking.trim()}';
    }
    return true;
  }

  void applyAction(PokerAction action) {
    final PlayerState? player = currentPlayer;
    if (player == null || !player.canAct || isHandComplete) {
      return;
    }

    final PokerAction legalAction = _normalizeAction(action);
    final int previousCurrentBet = currentBet;
    player.actedThisRound = true;

    switch (legalAction.type) {
      case PokerActionType.fold:
        player.hasFolded = true;
      case PokerActionType.check:
        break;
      case PokerActionType.call:
        player.commit(currentBet - player.currentBet);
      case PokerActionType.bet:
      case PokerActionType.raise:
      case PokerActionType.allIn:
        final int target =
            legalAction.amount ?? (player.currentBet + player.stack);
        player.commit(target - player.currentBet);
        if (player.currentBet > currentBet) {
          currentBet = player.currentBet;
          lastRaiseSize = max(config.bigBlind, currentBet - previousCurrentBet);
          for (final PlayerState other in players) {
            if (other != player && other.canAct) {
              other.actedThisRound = false;
            }
          }
          player.actedThisRound = true;
        }
    }

    final int actionAmount = switch (legalAction.type) {
      PokerActionType.fold || PokerActionType.check => 0,
      PokerActionType.call ||
      PokerActionType.bet ||
      PokerActionType.raise ||
      PokerActionType.allIn => player.currentBet,
    };
    actionLog.add(
      ActionHistoryEntry(
        handNumber: handNumber,
        phase: phase,
        playerName: player.name,
        action: legalAction.type,
        amount: actionAmount,
        stackAfter: player.stack,
      ),
    );

    if (_awardIfEveryoneFolded()) {
      return;
    }

    if (_bettingRoundComplete()) {
      _advancePhase();
      return;
    }

    currentPlayerIndex = _nextActorAfter(currentPlayerIndex);
    statusMessage = '${players[currentPlayerIndex].name} to act.';
  }

  List<LegalAction> legalActionsForCurrentPlayer() {
    final PlayerState? player = currentPlayer;
    if (player == null || !player.canAct || isHandComplete) {
      return const <LegalAction>[];
    }

    final int toCall = max(0, currentBet - player.currentBet);
    final List<LegalAction> actions = <LegalAction>[];
    if (toCall > 0) {
      actions.add(const LegalAction(type: PokerActionType.fold));
      actions.add(const LegalAction(type: PokerActionType.call));
      if (player.stack > toCall) {
        final int minTotal = currentBet + lastRaiseSize;
        final int maxTotal = player.currentBet + player.stack;
        if (maxTotal >= minTotal) {
          actions.add(
            LegalAction(
              type: PokerActionType.raise,
              minAmount: minTotal,
              maxAmount: maxTotal,
            ),
          );
        }
        actions.add(
          LegalAction(
            type: PokerActionType.allIn,
            minAmount: maxTotal,
            maxAmount: maxTotal,
          ),
        );
      }
    } else {
      actions.add(const LegalAction(type: PokerActionType.check));
      if (player.stack > 0) {
        final int maxTotal = player.currentBet + player.stack;
        if (player.stack >= config.bigBlind) {
          actions.add(
            LegalAction(
              type: PokerActionType.bet,
              minAmount: player.currentBet + config.bigBlind,
              maxAmount: maxTotal,
            ),
          );
        }
        actions.add(
          LegalAction(
            type: PokerActionType.allIn,
            minAmount: maxTotal,
            maxAmount: maxTotal,
          ),
        );
      }
    }
    return actions;
  }

  AiVisibleSnapshot visibleSnapshotFor(int seatIndex) {
    final PlayerState actor = players[seatIndex];
    return AiVisibleSnapshot(
      handNumber: handNumber,
      seatIndex: seatIndex,
      phase: phase,
      smallBlind: config.smallBlind,
      bigBlind: config.bigBlind,
      pot: potTotal,
      currentBet: currentBet,
      toCall: max(0, currentBet - actor.currentBet),
      board: List<PlayingCard>.unmodifiable(board),
      holeCards: List<PlayingCard>.unmodifiable(actor.holeCards),
      seats: List<AiSeatSnapshot>.generate(players.length, (int index) {
        final PlayerState player = players[index];
        return AiSeatSnapshot(
          index: index,
          name: player.name,
          kind: player.kind,
          stack: player.stack,
          currentBet: player.currentBet,
          totalCommitted: player.totalCommitted,
          hasFolded: player.hasFolded,
          isAllIn: player.isAllIn,
          isDealer: player.isDealer,
          isSmallBlind: player.isSmallBlind,
          isBigBlind: player.isBigBlind,
        );
      }),
      recentActions: actionLog
          .where((ActionHistoryEntry entry) => entry.handNumber == handNumber)
          .map((ActionHistoryEntry entry) => entry.label)
          .toList(growable: false),
    );
  }

  ActionHistoryEntry? lastActionFor(PlayerState player) {
    final BettingPhase? actionPhase = _currentActionPhase;
    for (final ActionHistoryEntry entry in actionLog.reversed) {
      if (entry.handNumber == handNumber &&
          entry.playerName == player.name &&
          (actionPhase == null || entry.phase == actionPhase)) {
        return entry;
      }
    }
    return null;
  }

  BettingPhase? get _currentActionPhase {
    return switch (phase) {
      BettingPhase.preflop ||
      BettingPhase.flop ||
      BettingPhase.turn ||
      BettingPhase.river => phase,
      BettingPhase.waiting ||
      BettingPhase.showdown ||
      BettingPhase.handComplete => null,
    };
  }

  void _createPlayers() {
    players.add(
      PlayerState(
        id: 'human',
        name: config.humanName.trim(),
        kind: PlayerKind.human,
        stack: config.startingStack,
      ),
    );
    final List<AiProfile> aiProfiles = _randomAiProfiles(config.seatCount - 1);
    for (int i = 1; i < config.seatCount; i += 1) {
      players.add(
        PlayerState(
          id: 'ai_$i',
          name: 'AI $i',
          kind: PlayerKind.ai,
          stack: config.startingStack,
          profile: aiProfiles[i - 1],
        ),
      );
    }
  }

  List<AiProfile> _randomAiProfiles(int count) {
    final List<AiProfile> profiles = <AiProfile>[];
    int cycle = 0;
    while (profiles.length < count) {
      final List<AiProfile> pool = List<AiProfile>.of(AiProfile.presets)
        ..shuffle(_profileRandom);
      for (final AiProfile preset in pool) {
        final int seatNumber = profiles.length + 1;
        profiles.add(_variantProfile(preset, seatNumber, cycle));
        if (profiles.length == count) {
          break;
        }
      }
      cycle += 1;
    }
    return profiles;
  }

  AiProfile _variantProfile(AiProfile base, int seatNumber, int cycle) {
    final int spread = cycle == 0 ? 10 : 14;
    int vary(int value) {
      final int delta = _profileRandom.nextInt(spread * 2 + 1) - spread;
      return (value + delta).clamp(5, 95).toInt();
    }

    final String variant = _profileRandom.nextInt(1 << 20).toRadixString(36);
    return base.copyWith(
      id: '${base.id}_seat_${seatNumber}_$variant',
      tightness: vary(base.tightness),
      aggression: vary(base.aggression),
      bluffFrequency: vary(base.bluffFrequency),
      callTolerance: vary(base.callTolerance),
      riskAppetite: vary(base.riskAppetite),
      tiltResistance: vary(base.tiltResistance),
    );
  }

  void _topUpBustedPlayers() {
    for (final PlayerState player in players) {
      if (player.stack < config.bigBlind) {
        player.stack = config.startingStack;
      }
    }
  }

  int _activeSeatCount() {
    return players.where((PlayerState player) => player.stack > 0).length;
  }

  int _smallBlindIndex() {
    if (_activeSeatCount() == 2) {
      return dealerIndex;
    }
    return _nextFundedSeat(dealerIndex);
  }

  int _nextFundedSeat(int fromIndex) {
    for (int step = 1; step <= players.length; step += 1) {
      final int index = (fromIndex + step) % players.length;
      if (players[index].stack > 0) {
        return index;
      }
    }
    throw StateError('No funded seat available.');
  }

  void _postBlind(int index, int blind) {
    players[index].commit(blind);
    players[index].actedThisRound = false;
  }

  PokerAction _normalizeAction(PokerAction requested) {
    final List<LegalAction> legal = legalActionsForCurrentPlayer();
    final LegalAction? match = legal.cast<LegalAction?>().firstWhere(
      (LegalAction? action) => action?.type == requested.type,
      orElse: () => null,
    );
    if (match == null) {
      return _defaultLegalAction(legal);
    }
    if (!match.needsAmount) {
      return PokerAction(match.type);
    }
    final int minAmount = match.minAmount ?? 0;
    final int maxAmount = match.maxAmount ?? minAmount;
    final int amount = (requested.amount ?? maxAmount)
        .clamp(minAmount, maxAmount)
        .toInt();
    return PokerAction(match.type, amount: amount);
  }

  PokerAction _defaultLegalAction(List<LegalAction> legal) {
    for (final PokerActionType type in <PokerActionType>[
      PokerActionType.check,
      PokerActionType.call,
      PokerActionType.fold,
      PokerActionType.allIn,
    ]) {
      for (final LegalAction action in legal) {
        if (action.type == type) {
          return PokerAction(type, amount: action.maxAmount);
        }
      }
    }
    return const PokerAction(PokerActionType.fold);
  }

  bool _awardIfEveryoneFolded() {
    final List<PlayerState> contenders = players
        .where(
          (PlayerState player) =>
              !player.hasFolded && player.totalCommitted + player.stack > 0,
        )
        .toList();
    if (contenders.length != 1) {
      return false;
    }
    final PlayerState winner = contenders.first;
    final int pot = potTotal;
    winner.stack += pot;
    completedByShowdown = false;
    showdownPlayerIds.clear();
    phase = BettingPhase.handComplete;
    currentPlayerIndex = -1;
    statusMessage =
        '${winner.name} wins ${Chips.format(pot)} after everyone folds.';
    return true;
  }

  bool _bettingRoundComplete() {
    final Iterable<PlayerState> actors = players.where(
      (PlayerState player) => !player.hasFolded && !player.isAllIn,
    );
    for (final PlayerState player in actors) {
      if (!player.actedThisRound) {
        return false;
      }
      if (player.currentBet != currentBet) {
        return false;
      }
    }
    return true;
  }

  void _advancePhase() {
    for (final PlayerState player in players) {
      player.resetForBettingRound();
    }
    currentBet = 0;
    lastRaiseSize = config.bigBlind;

    if (_playersStillIn().length <= 1) {
      _awardIfEveryoneFolded();
      return;
    }

    switch (phase) {
      case BettingPhase.preflop:
        board.addAll(_deck.drawMany(3));
        phase = BettingPhase.flop;
      case BettingPhase.flop:
        board.add(_deck.draw());
        phase = BettingPhase.turn;
      case BettingPhase.turn:
        board.add(_deck.draw());
        phase = BettingPhase.river;
      case BettingPhase.river:
        _settleShowdown();
        return;
      case BettingPhase.waiting:
      case BettingPhase.showdown:
      case BettingPhase.handComplete:
        return;
    }

    if (_playersAbleToAct().isEmpty) {
      _completeBoardAndSettle();
      return;
    }
    currentPlayerIndex = _firstActorAfterDealer();
    statusMessage =
        '${phase.name}: ${players[currentPlayerIndex].name} to act.';
  }

  List<PlayerState> _playersStillIn() {
    return players
        .where(
          (PlayerState player) =>
              !player.hasFolded && player.totalCommitted + player.stack > 0,
        )
        .toList();
  }

  List<PlayerState> _playersAbleToAct() {
    return players
        .where((PlayerState player) => player.canAct && !player.hasFolded)
        .toList();
  }

  int _firstActorAfterDealer() {
    int index = dealerIndex;
    for (int step = 0; step < players.length; step += 1) {
      index = (index + 1) % players.length;
      if (players[index].canAct && !players[index].hasFolded) {
        return index;
      }
    }
    return -1;
  }

  int _nextActorAfter(int fromIndex) {
    int index = fromIndex;
    for (int step = 0; step < players.length; step += 1) {
      index = (index + 1) % players.length;
      if (players[index].canAct && !players[index].hasFolded) {
        return index;
      }
    }
    return -1;
  }

  void _completeBoardAndSettle() {
    while (board.length < 5) {
      if (board.isEmpty) {
        board.addAll(_deck.drawMany(3));
      } else {
        board.add(_deck.draw());
      }
    }
    _settleShowdown();
  }

  void _settleShowdown() {
    phase = BettingPhase.showdown;
    completedByShowdown = true;
    showdownPlayerIds
      ..clear()
      ..addAll(
        _playersStillIn()
            .where((PlayerState player) => !player.hasFolded)
            .map((PlayerState player) => player.id),
      );
    final List<int> levels =
        players
            .where((PlayerState player) => player.totalCommitted > 0)
            .map((PlayerState player) => player.totalCommitted)
            .toSet()
            .toList()
          ..sort();

    int previousLevel = 0;
    final Map<PlayerState, int> winnings = <PlayerState, int>{};
    for (final int level in levels) {
      final List<PlayerState> contributors = players
          .where((PlayerState player) => player.totalCommitted >= level)
          .toList();
      final int sidePot = (level - previousLevel) * contributors.length;
      previousLevel = level;
      if (sidePot <= 0) {
        continue;
      }
      final List<PlayerState> eligible = contributors
          .where((PlayerState player) => !player.hasFolded)
          .toList();
      if (eligible.isEmpty) {
        continue;
      }

      HandValue? best;
      final List<PlayerState> winners = <PlayerState>[];
      for (final PlayerState player in eligible) {
        final HandValue value = HandEvaluator.bestOf(<PlayingCard>[
          ...board,
          ...player.holeCards,
        ]);
        if (best == null || value.compareTo(best) > 0) {
          best = value;
          winners
            ..clear()
            ..add(player);
        } else if (value.compareTo(best) == 0) {
          winners.add(player);
        }
      }

      final int share = sidePot ~/ winners.length;
      int remainder = sidePot % winners.length;
      for (final PlayerState winner in winners) {
        final int bonus = remainder > 0 ? 1 : 0;
        winnings[winner] = (winnings[winner] ?? 0) + share + bonus;
        remainder -= bonus;
      }
    }

    for (final MapEntry<PlayerState, int> entry in winnings.entries) {
      entry.key.stack += entry.value;
    }

    phase = BettingPhase.handComplete;
    currentPlayerIndex = -1;
    if (winnings.isEmpty) {
      statusMessage = 'Hand complete.';
    } else {
      final String summary = winnings.entries
          .map(
            (MapEntry<PlayerState, int> entry) =>
                '${entry.key.name} wins ${Chips.format(entry.value)}',
          )
          .join(', ');
      statusMessage = summary;
    }
  }
}
