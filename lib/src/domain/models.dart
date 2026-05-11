import 'card.dart';
import 'money.dart';

enum PlayerKind { human, ai }

enum AiBackend { openRouter, localGemma, testBot }

enum BettingPhase {
  waiting,
  preflop,
  flop,
  turn,
  river,
  showdown,
  handComplete,
}

enum PokerActionType { fold, check, call, bet, raise, allIn }

class TableConfig {
  const TableConfig({
    required this.humanName,
    required this.seatCount,
    required this.minBuyIn,
    required this.maxBuyIn,
    required this.startingStack,
    this.aiBackend = AiBackend.testBot,
    this.openRouterModel = 'openrouter/free',
    this.openRouterApiKey = '',
    this.smallBlind = Chips.smallBlind,
    this.bigBlind = Chips.bigBlind,
  });

  final String humanName;
  final int seatCount;
  final int minBuyIn;
  final int maxBuyIn;
  final int startingStack;
  final AiBackend aiBackend;
  final String openRouterModel;
  final String openRouterApiKey;
  final int smallBlind;
  final int bigBlind;

  String? validate() {
    if (humanName.trim().isEmpty) {
      return 'Enter a player name.';
    }
    if (seatCount < 2 || seatCount > 10) {
      return 'Use 2 to 10 seats.';
    }
    if (minBuyIn <= 0 || maxBuyIn <= 0 || startingStack <= 0) {
      return 'Buy-ins must be positive.';
    }
    if (minBuyIn > maxBuyIn) {
      return 'Min buy-in cannot exceed max buy-in.';
    }
    if (startingStack < minBuyIn || startingStack > maxBuyIn) {
      return 'Starting stack must be inside the buy-in range.';
    }
    if (startingStack < bigBlind * 20) {
      return 'Use at least 20 big blinds for a playable table.';
    }
    if (aiBackend == AiBackend.openRouter && openRouterModel.trim().isEmpty) {
      return 'Choose an OpenRouter model.';
    }
    return null;
  }
}

class AiProfile {
  const AiProfile({
    required this.id,
    required this.name,
    required this.tightness,
    required this.aggression,
    required this.bluffFrequency,
    required this.callTolerance,
    required this.riskAppetite,
    required this.tiltResistance,
  });

  final String id;
  final String name;
  final int tightness;
  final int aggression;
  final int bluffFrequency;
  final int callTolerance;
  final int riskAppetite;
  final int tiltResistance;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'name': name,
    'persona': persona,
    'concepts': styleConcepts,
    'tendencies': tendencies,
    'streetStrategy': streetStrategy,
    'tightness': tightness,
    'aggression': aggression,
    'bluffFrequency': bluffFrequency,
    'callTolerance': callTolerance,
    'riskAppetite': riskAppetite,
    'tiltResistance': tiltResistance,
  };

  AiProfile copyWith({
    String? id,
    String? name,
    int? tightness,
    int? aggression,
    int? bluffFrequency,
    int? callTolerance,
    int? riskAppetite,
    int? tiltResistance,
  }) {
    return AiProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      tightness: tightness ?? this.tightness,
      aggression: aggression ?? this.aggression,
      bluffFrequency: bluffFrequency ?? this.bluffFrequency,
      callTolerance: callTolerance ?? this.callTolerance,
      riskAppetite: riskAppetite ?? this.riskAppetite,
      tiltResistance: tiltResistance ?? this.tiltResistance,
    );
  }

  String get persona {
    return '$name: ${_rangeDescription(tightness)}, '
        '${_aggressionDescription(aggression)}, '
        '${_bluffDescription(bluffFrequency)}, '
        '${_callingDescription(callTolerance)}.';
  }

  List<String> get tendencies {
    return <String>[
      _rangeTendency(tightness),
      _aggressionTendency(aggression),
      _callingTendency(callTolerance),
      _riskTendency(riskAppetite),
      _tiltTendency(tiltResistance),
    ];
  }

  Map<String, String> get styleConcepts {
    return <String, String>{
      'tightness':
          'Tight players enter fewer pots and require stronger starting hands; loose players enter more pots with suited, connected, broadway, and speculative hands. Tight or loose changes the range, not the duty to ignore board texture or price.',
      'aggression':
          'Aggressive players prefer betting and raising to create fold equity, charge draws, and build pots with value. Passive players prefer checking and calling, keep pots smaller, and raise mostly with clearly strong hands.',
      'strength':
          'Strong play means matching the action to hand strength, position, pot odds, board texture, stack depth, and opponent pressure. Weak play over-calls, checks back too many value hands, folds too easily, or bluffs without equity.',
      'styleBlend': _styleBlendDescription(
        tightness: tightness,
        aggression: aggression,
        callTolerance: callTolerance,
        bluffFrequency: bluffFrequency,
      ),
    };
  }

  Map<String, List<String>> get streetStrategy {
    return <String, List<String>>{
      'preflop': <String>[
        _preflopRangeStrategy(tightness),
        _preflopPressureStrategy(aggression, callTolerance),
        'React to prior raises instead of automatically calling: fold dominated weak hands, call playable hands at a fair price, and raise premium or high-fold-equity hands according to this style.',
      ],
      'flop': <String>[
        _flopMadeHandStrategy(aggression),
        _flopDrawStrategy(bluffFrequency, riskAppetite),
        'When nobody has bet, checking is pot control, not a default. Consider value betting, protection betting, bluffing, or checking based on board texture and this style.',
      ],
      'turn': <String>[
        _turnPressureStrategy(aggression, bluffFrequency),
        _turnDisciplineStrategy(tightness, callTolerance),
        'The turn is where ranges narrow: continue barreling with strong value or credible equity, slow down on bad cards, and avoid calling only because chips are already invested.',
      ],
      'river': <String>[
        _riverValueStrategy(aggression),
        _riverCallStrategy(callTolerance),
        'With no cards left, draws have no future value: choose between thin value, bluff, bluff-catch, check back, or fold according to showdown value and the style.',
      ],
    };
  }

  static const AiProfile balanced = AiProfile(
    id: 'balanced',
    name: 'Balanced',
    tightness: 50,
    aggression: 50,
    bluffFrequency: 35,
    callTolerance: 50,
    riskAppetite: 50,
    tiltResistance: 65,
  );

  static const List<AiProfile> presets = <AiProfile>[
    AiProfile(
      id: 'tag',
      name: 'Tight Aggressive',
      tightness: 78,
      aggression: 76,
      bluffFrequency: 32,
      callTolerance: 36,
      riskAppetite: 58,
      tiltResistance: 82,
    ),
    AiProfile(
      id: 'lag',
      name: 'Loose Aggressive',
      tightness: 28,
      aggression: 86,
      bluffFrequency: 68,
      callTolerance: 62,
      riskAppetite: 78,
      tiltResistance: 54,
    ),
    AiProfile(
      id: 'nit',
      name: 'Tight Passive',
      tightness: 88,
      aggression: 22,
      bluffFrequency: 8,
      callTolerance: 28,
      riskAppetite: 18,
      tiltResistance: 88,
    ),
    AiProfile(
      id: 'calling_station',
      name: 'Loose Passive',
      tightness: 18,
      aggression: 18,
      bluffFrequency: 10,
      callTolerance: 88,
      riskAppetite: 46,
      tiltResistance: 42,
    ),
    balanced,
  ];

  static String _rangeDescription(int tightness) {
    if (tightness >= 70) {
      return 'selective starting range';
    }
    if (tightness <= 35) {
      return 'wide starting range';
    }
    return 'balanced starting range';
  }

  static String _aggressionDescription(int aggression) {
    if (aggression >= 70) {
      return 'pressures opponents with bets and raises';
    }
    if (aggression <= 35) {
      return 'prefers checking and calling over raising';
    }
    return 'mixes pressure with pot control';
  }

  static String _bluffDescription(int bluffFrequency) {
    if (bluffFrequency >= 60) {
      return 'willing to bluff when fold equity is plausible';
    }
    if (bluffFrequency <= 20) {
      return 'rarely bluffs without real equity';
    }
    return 'uses occasional bluffs';
  }

  static String _callingDescription(int callTolerance) {
    if (callTolerance >= 70) {
      return 'comfortable calling marginal spots';
    }
    if (callTolerance <= 35) {
      return 'folds marginal spots under pressure';
    }
    return 'continues with reasonable pot odds';
  }

  static String _rangeTendency(int tightness) {
    if (tightness >= 70) {
      return 'Fold weak and speculative hands more often before investing chips, especially versus raises.';
    }
    if (tightness <= 35) {
      return 'Continue with more suited, connected, broadway, and position-friendly hands, but still fold trash to large pressure.';
    }
    return 'Use a balanced range and avoid extreme preflop looseness or excessive folding.';
  }

  static String _aggressionTendency(int aggression) {
    if (aggression >= 70) {
      return 'Prefer betting or raising strong hands, vulnerable value hands, strong draws, and credible bluff spots.';
    }
    if (aggression <= 35) {
      return 'Prefer passive pot control, checking, and calling unless the hand is clearly strong.';
    }
    return 'Mix bets, raises, calls, and checks according to hand strength.';
  }

  static String _callingTendency(int callTolerance) {
    if (callTolerance >= 70) {
      return 'Call more often when the price is small or medium, especially with pairs, overcards, and draws.';
    }
    if (callTolerance <= 35) {
      return 'Avoid thin calls when facing meaningful pressure; prefer fold or raise with clear purpose.';
    }
    return 'Call when pot odds and showdown value are reasonable.';
  }

  static String _riskTendency(int riskAppetite) {
    if (riskAppetite >= 70) {
      return 'Accept higher-variance lines with strong draws or nut advantage.';
    }
    if (riskAppetite <= 35) {
      return 'Avoid high-variance lines without a strong made hand.';
    }
    return 'Take risk only when reward and equity justify it.';
  }

  static String _tiltTendency(int tiltResistance) {
    if (tiltResistance >= 70) {
      return 'Stay consistent after losses and avoid emotional overcorrection.';
    }
    if (tiltResistance <= 45) {
      return 'May chase slightly more after losing pots, but still obey legal actions.';
    }
    return 'Keep decisions stable across recent outcomes.';
  }

  static String _styleBlendDescription({
    required int tightness,
    required int aggression,
    required int callTolerance,
    required int bluffFrequency,
  }) {
    if (tightness >= 70 && aggression >= 70) {
      return 'Tight-aggressive: enter pots selectively, then apply pressure with raises and continuation bets when range advantage, strong value, or credible draws exist.';
    }
    if (tightness <= 35 && aggression >= 70) {
      return 'Loose-aggressive: play a wider range, attack limps and weakness, semi-bluff often, and accept more variance without calling every raise blindly.';
    }
    if (tightness >= 70 && aggression <= 35) {
      return 'Tight-passive: wait for strong hands, avoid marginal calls, check/call medium strength, and raise rarely without premium value.';
    }
    if (tightness <= 35 && aggression <= 35) {
      return 'Loose-passive: see more flops and call more often, but seldom pressure opponents without clear made hands; this style should still fold hopeless hands to large bets.';
    }
    if (callTolerance <= 35 && bluffFrequency <= 20) {
      return 'Cautious/weak-tight: over-fold marginal spots, bluff rarely, and need strong evidence before investing more chips.';
    }
    if (aggression >= 70) {
      return 'Aggressive-balanced: use pressure as a weapon while still respecting hand strength, position, and board texture.';
    }
    return 'Balanced: mix value, bluff, pot control, calls, and folds based on the current hand and public board.';
  }

  static String _preflopRangeStrategy(int tightness) {
    if (tightness >= 70) {
      return 'Open and continue with premium pairs, strong broadways, strong suited aces, and good position; fold many offsuit, dominated, and weak speculative hands.';
    }
    if (tightness <= 35) {
      return 'Open or continue wider with suited aces, suited connectors, broadways, pairs, and position, but avoid paying large raises with disconnected weak hands.';
    }
    return 'Use a medium opening and calling range; tighten versus raises and loosen slightly in late position.';
  }

  static String _preflopPressureStrategy(int aggression, int callTolerance) {
    if (aggression >= 70) {
      return 'Prefer raise or re-raise over flat call with premium hands and good bluff candidates; attack passive limps when legal.';
    }
    if (callTolerance >= 70) {
      return 'Flat-call more playable hands at small prices, but do not treat every raise as mandatory to call.';
    }
    if (aggression <= 35) {
      return 'Call or fold more than raise; reserve raises for premium value.';
    }
    return 'Mix calls and raises: raise strong hands, call playable hands with position or pot odds, fold dominated hands.';
  }

  static String _flopMadeHandStrategy(int aggression) {
    if (aggression >= 70) {
      return 'Bet strong and vulnerable made hands for value/protection; continuation-bet boards that favor your range.';
    }
    if (aggression <= 35) {
      return 'Check or call medium pairs and weak made hands; bet mainly strong top pair or better.';
    }
    return 'Value bet strong hands, protect vulnerable hands, and check medium showdown value when pot control matters.';
  }

  static String _flopDrawStrategy(int bluffFrequency, int riskAppetite) {
    if (bluffFrequency >= 60 || riskAppetite >= 70) {
      return 'Semi-bluff strong draws, overcards plus backdoors, and boards where opponents can fold.';
    }
    if (bluffFrequency <= 20 || riskAppetite <= 35) {
      return 'Prefer checking or calling draws at a fair price; avoid naked bluffs.';
    }
    return 'Mix semi-bluffs with calls/checks when draws have real equity and the price is fair.';
  }

  static String _turnPressureStrategy(int aggression, int bluffFrequency) {
    if (aggression >= 70) {
      return 'Keep betting strong value and high-equity draws; fire second barrels on scare cards that credibly improve your range.';
    }
    if (aggression <= 35) {
      return 'Slow down with one-pair and weak draws unless the price is small or the hand is clearly ahead.';
    }
    if (bluffFrequency >= 60) {
      return 'Use selected second barrels when the turn improves equity or fold equity.';
    }
    return 'Continue pressure with value and good equity; check more marginal holdings.';
  }

  static String _turnDisciplineStrategy(int tightness, int callTolerance) {
    if (tightness >= 70 || callTolerance <= 35) {
      return 'Fold more marginal pairs and weak draws to large turn bets.';
    }
    if (tightness <= 35 || callTolerance >= 70) {
      return 'Peel more often with live draws, pair-plus-draw hands, and reasonable pot odds.';
    }
    return 'Call only when pot odds, implied odds, or showdown value justify continuing.';
  }

  static String _riverValueStrategy(int aggression) {
    if (aggression >= 70) {
      return 'Value bet more confidently and bluff missed draws only when the story is credible and opponents can fold.';
    }
    if (aggression <= 35) {
      return 'Check back medium showdown value and value bet mostly strong hands.';
    }
    return 'Choose thin value, check back, or bluff based on blockers, board runout, and opponent pressure.';
  }

  static String _riverCallStrategy(int callTolerance) {
    if (callTolerance >= 70) {
      return 'Bluff-catch wider when the bet is small, the line is suspicious, or showdown value is decent.';
    }
    if (callTolerance <= 35) {
      return 'Fold more bluff-catchers to meaningful river pressure unless holding strong blockers or clear value.';
    }
    return 'Call river bets when the price, blockers, and opponent line make bluff-catching reasonable.';
  }
}

class PlayerState {
  PlayerState({
    required this.id,
    required this.name,
    required this.kind,
    required this.stack,
    this.profile,
  });

  final String id;
  final String name;
  final PlayerKind kind;
  final AiProfile? profile;
  int stack;
  int currentBet = 0;
  int totalCommitted = 0;
  bool hasFolded = false;
  bool isAllIn = false;
  bool actedThisRound = false;
  bool isDealer = false;
  bool isSmallBlind = false;
  bool isBigBlind = false;
  final List<PlayingCard> holeCards = <PlayingCard>[];

  bool get canAct => !hasFolded && !isAllIn && stack > 0;

  int get visibleStack => stack;

  void resetForHand() {
    currentBet = 0;
    totalCommitted = 0;
    hasFolded = false;
    isAllIn = stack <= 0;
    actedThisRound = false;
    isDealer = false;
    isSmallBlind = false;
    isBigBlind = false;
    holeCards.clear();
  }

  void resetForBettingRound() {
    currentBet = 0;
    actedThisRound = false;
  }

  int commit(int amount) {
    final int paid = amount.clamp(0, stack).toInt();
    stack -= paid;
    currentBet += paid;
    totalCommitted += paid;
    if (stack == 0) {
      isAllIn = true;
    }
    return paid;
  }
}

class LegalAction {
  const LegalAction({required this.type, this.minAmount, this.maxAmount});

  final PokerActionType type;

  /// Total chips committed by the actor in the current betting round.
  final int? minAmount;
  final int? maxAmount;

  bool get needsAmount {
    return type == PokerActionType.bet ||
        type == PokerActionType.raise ||
        type == PokerActionType.allIn;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    'minAmount': minAmount,
    'maxAmount': maxAmount,
  };
}

class PokerAction {
  const PokerAction(this.type, {this.amount});

  final PokerActionType type;

  /// Total chips committed by the actor in the current betting round.
  final int? amount;
}

class ActionHistoryEntry {
  const ActionHistoryEntry({
    required this.handNumber,
    required this.phase,
    required this.playerName,
    required this.action,
    required this.amount,
    required this.stackAfter,
  });

  final int handNumber;
  final BettingPhase phase;
  final String playerName;
  final PokerActionType action;

  /// Total chips committed by the actor in the current betting round.
  final int amount;
  final int stackAfter;

  String get label {
    final String amountText = amount > 0 ? ' ${Chips.format(amount)}' : '';
    return 'Hand $handNumber ${phase.name}: $playerName ${action.name}$amountText';
  }
}
