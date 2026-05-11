import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ai/src/domain/models.dart';
import 'package:poker_ai/src/domain/money.dart';
import 'package:poker_ai/src/domain/poker_game.dart';

void main() {
  test('posts fixed blinds and sets preflop action order', () {
    final PokerGame game = PokerGame(config: config(seats: 3), seed: 1);

    expect(game.phase, BettingPhase.preflop);
    expect(game.players[1].currentBet, Chips.smallBlind);
    expect(game.players[2].currentBet, Chips.bigBlind);
    expect(game.currentBet, Chips.bigBlind);
    expect(game.currentPlayerIndex, 0);
  });

  test('heads-up small blind is the dealer and folding awards the pot', () {
    final PokerGame game = PokerGame(config: config(seats: 2), seed: 2);

    expect(game.players[0].isDealer, isTrue);
    expect(game.players[0].isSmallBlind, isTrue);
    expect(game.players[1].isBigBlind, isTrue);

    game.applyAction(const PokerAction(PokerActionType.fold));

    expect(game.isHandComplete, isTrue);
    expect(game.completedByShowdown, isFalse);
    expect(game.showdownPlayerIds, isEmpty);
    expect(game.players[1].stack, Chips.fromWhole(100) + Chips.smallBlind);
  });

  test('checked-down river marks showdown players for card reveal', () {
    final PokerGame game = PokerGame(config: config(seats: 2), seed: 4);

    game.applyAction(const PokerAction(PokerActionType.call));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));
    game.applyAction(const PokerAction(PokerActionType.check));

    expect(game.isHandComplete, isTrue);
    expect(game.completedByShowdown, isTrue);
    expect(game.showdownPlayerIds, containsAll(<String>['human', 'ai_1']));
  });

  test('dealer rotates between hands', () {
    final PokerGame game = PokerGame(config: config(seats: 4), seed: 3);
    expect(game.dealerIndex, 0);

    game.startNextHand();

    expect(game.dealerIndex, 1);
    expect(game.players[1].isDealer, isTrue);
  });

  test('call history records matched bet total, not paid delta', () {
    final PokerGame game = PokerGame(config: config(seats: 3), seed: 5);

    game.applyAction(
      PokerAction(PokerActionType.raise, amount: Chips.fromWhole(3)),
    );
    expect(game.actionLog.last.playerName, 'Hero');
    expect(game.actionLog.last.amount, Chips.fromWhole(3));
    expect(game.actionLog.last.label, contains('raise 3'));

    game.applyAction(const PokerAction(PokerActionType.call));
    expect(game.actionLog.last.playerName, 'AI 1');
    expect(game.actionLog.last.amount, Chips.fromWhole(3));
    expect(game.actionLog.last.label, contains('call 3'));

    game.applyAction(const PokerAction(PokerActionType.call));
    expect(game.actionLog.last.playerName, 'AI 2');
    expect(game.actionLog.last.amount, Chips.fromWhole(3));
    expect(game.actionLog.last.label, contains('call 3'));
  });

  test('all-in history records street total, not hand total', () {
    final PokerGame game = PokerGame(config: config(seats: 2), seed: 7);
    final PlayerState hero = game.players[0];

    game.phase = BettingPhase.turn;
    game.currentPlayerIndex = 0;
    game.currentBet = 0;
    game.lastRaiseSize = game.config.bigBlind;
    hero.stack = Chips.fromWhole(39);
    hero.currentBet = 0;
    hero.totalCommitted = Chips.fromWhole(11);
    hero.isAllIn = false;
    hero.hasFolded = false;
    hero.actedThisRound = false;

    game.applyAction(
      PokerAction(PokerActionType.allIn, amount: Chips.fromWhole(39)),
    );

    expect(hero.isAllIn, isTrue);
    expect(hero.currentBet, Chips.fromWhole(39));
    expect(hero.totalCommitted, Chips.fromWhole(50));
    expect(game.actionLog.last.action, PokerActionType.allIn);
    expect(game.actionLog.last.amount, Chips.fromWhole(39));
    expect(game.actionLog.last.label, contains('allIn 39'));
  });

  test('manual rebuy adds chips only when hero is out of the live hand', () {
    final PokerGame game = PokerGame(config: config(seats: 2), seed: 8);
    final PlayerState hero = game.humanPlayer;
    hero.stack = Chips.fromWhole(30);

    expect(game.canRebuyHuman, isFalse);
    expect(game.rebuyHuman(Chips.fromWhole(20)), 0);
    expect(hero.stack, Chips.fromWhole(30));

    hero.hasFolded = true;
    final int room = game.humanRebuyRoom;
    expect(game.canRebuyHuman, isTrue);
    expect(game.rebuyHuman(room + Chips.fromWhole(10)), room);
    expect(hero.stack, game.config.maxBuyIn);
    expect(game.statusMessage, contains('rebuys ${Chips.format(room)}'));
  });

  test('seat action status resets when a new betting round starts', () {
    final PokerGame game = PokerGame(config: config(seats: 2), seed: 6);

    game.applyAction(const PokerAction(PokerActionType.call));
    expect(game.lastActionFor(game.players[0])?.action, PokerActionType.call);

    game.applyAction(const PokerAction(PokerActionType.check));
    expect(game.phase, BettingPhase.flop);
    expect(game.lastActionFor(game.players[0]), isNull);
    expect(game.lastActionFor(game.players[1]), isNull);
    expect(game.actionLog.length, 2);
  });

  test('AI seats receive seeded randomized individual profiles', () {
    final PokerGame game = PokerGame(config: config(seats: 6), seed: 21);
    final List<AiProfile> profiles = game.players
        .where((PlayerState player) => player.kind == PlayerKind.ai)
        .map((PlayerState player) => player.profile!)
        .toList();

    expect(profiles, hasLength(5));
    expect(
      profiles.map((AiProfile profile) => profile.id).toSet(),
      hasLength(5),
    );
    expect(
      profiles.map((AiProfile profile) => profile.name).toSet().length,
      greaterThan(1),
    );

    final PokerGame repeat = PokerGame(config: config(seats: 6), seed: 21);
    final List<String> repeatedSignatures = repeat.players
        .where((PlayerState player) => player.kind == PlayerKind.ai)
        .map((PlayerState player) => _profileSignature(player.profile!))
        .toList();

    expect(profiles.map(_profileSignature).toList(), repeatedSignatures);
  });
}

TableConfig config({required int seats}) {
  return TableConfig(
    humanName: 'Hero',
    seatCount: seats,
    minBuyIn: Chips.fromWhole(40),
    maxBuyIn: Chips.fromWhole(200),
    startingStack: Chips.fromWhole(100),
  );
}

String _profileSignature(AiProfile profile) {
  return <Object>[
    profile.id,
    profile.name,
    profile.tightness,
    profile.aggression,
    profile.bluffFrequency,
    profile.callTolerance,
    profile.riskAppetite,
    profile.tiltResistance,
  ].join(':');
}
