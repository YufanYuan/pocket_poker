import 'dart:math';

import 'engine.dart';

/// Engine-computed poker facts for one decision point.
///
/// Everything here is derived only from information the acting seat can see,
/// so it is safe to hand to a model or to a rule-based policy.
class PokerFeatures {
  const PokerFeatures({
    required this.position,
    required this.opponentsInHand,
    required this.opponentsAbleToAct,
    required this.handClass,
    required this.draws,
    required this.equity,
    required this.equityOpponents,
    required this.potOdds,
    required this.effectiveStack,
    required this.spr,
    required this.sizePresets,
    required this.myCurrentBet,
    required this.potAfterCall,
  });

  final String position;
  final int opponentsInHand;
  final int opponentsAbleToAct;
  final String handClass;
  final List<String> draws;

  /// Win share (ties split) versus [equityOpponents] random hands.
  final double equity;
  final int equityOpponents;

  /// toCall / (pot + toCall); zero when no bet is pending.
  final double potOdds;
  final int effectiveStack;
  final double spr;
  final List<SizePreset> sizePresets;
  final int myCurrentBet;
  final int potAfterCall;

  Map<String, Object?> toJson() => <String, Object?>{
    'position': position,
    'opponentsInHand': opponentsInHand,
    'opponentsAbleToAct': opponentsAbleToAct,
    'handClass': handClass,
    'draws': draws,
    'equity': double.parse(equity.toStringAsFixed(3)),
    'equityOpponents': equityOpponents,
    'potOdds': double.parse(potOdds.toStringAsFixed(3)),
    'effectiveStack': Chips.format(effectiveStack),
    'spr': double.parse(spr.toStringAsFixed(1)),
    'sizePresets': sizePresets
        .map((SizePreset p) => '${p.label}=${Chips.format(p.amount)}')
        .toList(),
  };

  /// Markdown block appended to the model prompt by the "facts" variants.
  String toPromptSection({required int pot, required int toCall}) {
    final StringBuffer b = StringBuffer()
      ..writeln('## Engine-computed poker facts (trustworthy, use them)')
      ..writeln()
      ..writeln(
        '- Position: $position. Opponents still in the hand: $opponentsInHand '
        '($opponentsAbleToAct can still act).',
      )
      ..writeln('- Your hand right now: $handClass.');
    if (draws.isNotEmpty) {
      b.writeln('- Draws: ${draws.join('; ')}.');
    }
    b.writeln(
      '- Equity versus $equityOpponents random hand${equityOpponents == 1 ? '' : 's'} '
      '(Monte Carlo, ties split): ${(equity * 100).round()}%. Real opponents '
      'who bet or raise usually hold better than random, so discount this against aggression.',
    );
    if (toCall > 0) {
      b.writeln(
        '- Price: pot ${Chips.format(pot)}, to call ${Chips.format(toCall)}, '
        'pot odds ${(potOdds * 100).round()}%. You need at least '
        '${(potOdds * 100).round()}% equity to call profitably.',
      );
    } else {
      b.writeln('- No bet pending: pot ${Chips.format(pot)}.');
    }
    b.writeln(
      '- Effective stack ${Chips.format(effectiveStack)}, stack-to-pot ratio ${spr.toStringAsFixed(1)}.',
    );
    if (sizePresets.isNotEmpty) {
      b.writeln(
        '- Amounts are your TOTAL chips in this betting round. Legal presets: '
        '${sizePresets.map((SizePreset p) => '${p.label} = ${Chips.format(p.amount)}').join(', ')}.',
      );
    }
    return b.toString().trimRight();
  }
}

class SizePreset {
  const SizePreset(this.label, this.amount, this.type);

  final String label;
  final int amount;
  final PokerActionType type;
}

class FeatureExtractor {
  FeatureExtractor({int equityIterations = 600, Random? random})
    : _iterations = equityIterations,
      _random = random ?? Random(7);

  final int _iterations;
  final Random _random;

  PokerFeatures extract(AiVisibleSnapshot s, List<LegalAction> legal) {
    final AiSeatSnapshot me = s.seats[s.seatIndex];
    final List<AiSeatSnapshot> inHand = s.seats
        .where(
          (AiSeatSnapshot x) =>
              !x.hasFolded && (x.stack > 0 || x.totalCommitted > 0),
        )
        .toList();
    final int opponentsInHand = inHand
        .where((AiSeatSnapshot x) => x.index != s.seatIndex)
        .length;
    final int opponentsAbleToAct = inHand
        .where(
          (AiSeatSnapshot x) =>
              x.index != s.seatIndex && !x.isAllIn && x.stack > 0,
        )
        .length;
    final int equityOpponents = max(1, min(opponentsInHand, 3));
    final double equity = monteCarloEquity(
      s.holeCards,
      s.board,
      equityOpponents,
      _iterations,
      _random,
    );
    final int potAfterCall = s.pot + s.toCall;
    final double potOdds = s.toCall == 0 ? 0 : s.toCall / potAfterCall;
    final int effectiveStack = _effectiveStack(s, me, inHand);
    final double spr = s.pot == 0 ? 99 : effectiveStack / s.pot;

    return PokerFeatures(
      position: positionLabel(s),
      opponentsInHand: opponentsInHand,
      opponentsAbleToAct: opponentsAbleToAct,
      handClass: describeHand(s.holeCards, s.board),
      draws: describeDraws(s.holeCards, s.board),
      equity: equity,
      equityOpponents: equityOpponents,
      potOdds: potOdds,
      effectiveStack: effectiveStack,
      spr: spr,
      sizePresets: sizePresets(s, legal),
      myCurrentBet: me.currentBet,
      potAfterCall: potAfterCall,
    );
  }

  static int _effectiveStack(
    AiVisibleSnapshot s,
    AiSeatSnapshot me,
    List<AiSeatSnapshot> inHand,
  ) {
    int largestOpponent = 0;
    for (final AiSeatSnapshot x in inHand) {
      if (x.index == s.seatIndex) {
        continue;
      }
      largestOpponent = max(largestOpponent, x.stack + x.currentBet);
    }
    return min(me.stack + me.currentBet, largestOpponent);
  }

  /// Seat label relative to the button among seats that were dealt in.
  static String positionLabel(AiVisibleSnapshot s) {
    final AiSeatSnapshot me = s.seats[s.seatIndex];
    if (me.isBigBlind) {
      return 'BB (big blind)';
    }
    if (me.isSmallBlind) {
      return me.isDealer ? 'BTN/SB (heads-up button)' : 'SB (small blind)';
    }
    final List<AiSeatSnapshot> dealt = s.seats
        .where((AiSeatSnapshot x) => x.stack > 0 || x.totalCommitted > 0)
        .toList();
    final int dealerIndex = s.seats
        .firstWhere(
          (AiSeatSnapshot x) => x.isDealer,
          orElse: () => s.seats.first,
        )
        .index;
    // Order seats clockwise starting after the dealer: SB, BB, UTG, ..., BTN.
    final List<int> order = <int>[];
    for (int step = 1; step <= s.seats.length; step += 1) {
      final int idx = (dealerIndex + step) % s.seats.length;
      if (dealt.any((AiSeatSnapshot x) => x.index == idx)) {
        order.add(idx);
      }
    }
    final List<int> afterBlinds = order.length > 2 ? order.sublist(2) : order;
    final int m = afterBlinds.length;
    final int pos = afterBlinds.indexOf(s.seatIndex);
    if (pos < 0) {
      return 'unknown';
    }
    final int fromEnd = m - 1 - pos;
    switch (fromEnd) {
      case 0:
        return 'BTN (dealer, last to act postflop)';
      case 1:
        return 'CO (cutoff)';
      case 2:
        return 'HJ (hijack)';
      case 3:
        return 'MP (middle position)';
      default:
        return pos == 0 ? 'UTG (first to act)' : 'UTG+$pos (early position)';
    }
  }

  static List<SizePreset> sizePresets(
    AiVisibleSnapshot s,
    List<LegalAction> legal,
  ) {
    final AiSeatSnapshot me = s.seats[s.seatIndex];
    final int potAfterCall = s.pot + s.toCall;
    final List<SizePreset> out = <SizePreset>[];
    void add(String label, int total, LegalAction action) {
      final int rounded = _roundToSmallBlind(total);
      final int clamped = rounded
          .clamp(action.minAmount ?? rounded, action.maxAmount ?? rounded)
          .toInt();
      if (out.any((SizePreset p) => p.amount == clamped)) {
        return;
      }
      out.add(SizePreset(label, clamped, action.type));
    }

    for (final LegalAction action in legal) {
      switch (action.type) {
        case PokerActionType.bet:
          add('min bet', action.minAmount!, action);
          add('33% pot', me.currentBet + (potAfterCall * 0.33).round(), action);
          add('50% pot', me.currentBet + (potAfterCall * 0.5).round(), action);
          add('75% pot', me.currentBet + (potAfterCall * 0.75).round(), action);
          add('pot', me.currentBet + potAfterCall, action);
        case PokerActionType.raise:
          add('min raise', action.minAmount!, action);
          add('2.5x raise', (s.currentBet * 2.5).round(), action);
          if (s.phase == BettingPhase.preflop) {
            add('3x raise', s.currentBet * 3, action);
          } else {
            add(
              'pot raise',
              me.currentBet + s.toCall + potAfterCall + s.toCall,
              action,
            );
          }
        case PokerActionType.allIn:
          add('all-in', action.maxAmount ?? action.minAmount ?? 0, action);
        case PokerActionType.fold:
        case PokerActionType.check:
        case PokerActionType.call:
          break;
      }
    }
    return out;
  }

  static int _roundToSmallBlind(int amount) {
    const int unit = Chips.smallBlind;
    return ((amount + unit ~/ 2) ~/ unit) * unit;
  }

  /// Human-readable made-hand class relative to the board.
  static String describeHand(List<PlayingCard> hole, List<PlayingCard> board) {
    final PlayingCard a = hole[0];
    final PlayingCard b = hole[1];
    if (board.isEmpty) {
      final bool pair = a.rank == b.rank;
      final bool suited = a.suit == b.suit;
      final int gap = (a.rank.value - b.rank.value).abs();
      final String label =
          '${_hi(a, b).rank.label}${_lo(a, b).rank.label}${pair ? '' : suited ? 's' : 'o'}';
      if (pair) {
        return 'pocket pair $label'
            '${a.rank.value >= 10 ? ' (premium pair)' : a.rank.value >= 7 ? ' (medium pair)' : ' (small pair)'}';
      }
      final List<String> tags = <String>[];
      if (suited) {
        tags.add('suited');
      }
      if (gap == 1) {
        tags.add('connected');
      } else if (gap <= 3) {
        tags.add('${gap - 1}-gap');
      }
      if (_hi(a, b).rank.value >= 10 && _lo(a, b).rank.value >= 10) {
        tags.add('broadway');
      }
      if (_hi(a, b).rank == Rank.ace) {
        tags.add('ace-high');
      }
      return 'unpaired $label${tags.isEmpty ? '' : ' (${tags.join(', ')})'}';
    }

    final HandValue made = HandEvaluator.bestOf(<PlayingCard>[...board, ...hole]);
    final HandValue boardOnly = board.length >= 5
        ? HandEvaluator.bestOf(board)
        : const HandValue(HandCategory.highCard, <int>[]);
    final List<int> boardRanks = board.map((PlayingCard c) => c.rank.value).toList()
      ..sort((int x, int y) => y.compareTo(x));
    final int topBoard = boardRanks.first;
    final Map<int, int> boardCounts = <int, int>{};
    for (final int r in boardRanks) {
      boardCounts[r] = (boardCounts[r] ?? 0) + 1;
    }
    final bool pocketPair = a.rank == b.rank;
    final int hiHole = _hi(a, b).rank.value;
    final int loHole = _lo(a, b).rank.value;

    switch (made.category) {
      case HandCategory.highCard:
        final String over = hiHole > topBoard
            ? (loHole > topBoard ? 'two overcards' : 'one overcard')
            : 'no pair, no overcard';
        return 'high card ${_rankName(hiHole)} ($over)';
      case HandCategory.onePair:
        final int pairRank = made.kickers.first;
        if (pocketPair) {
          if (pairRank > topBoard) {
            return 'overpair ${_rankName(pairRank)}s';
          }
          final int above = boardRanks.toSet().where((int r) => r > pairRank).length;
          return above == 1
              ? 'pocket pair ${_rankName(pairRank)}s below top card (second pair)'
              : 'underpair ${_rankName(pairRank)}s ($above board cards above)';
        }
        if ((boardCounts[pairRank] ?? 0) >= 2) {
          return 'no pair of your own; board is paired ${_rankName(pairRank)}s (you play ${_rankName(hiHole)} kicker)';
        }
        final int kicker = pairRank == hiHole ? loHole : hiHole;
        final List<int> distinct = boardRanks.toSet().toList()
          ..sort((int x, int y) => y.compareTo(x));
        final int rankPos = distinct.indexOf(pairRank);
        final String which = rankPos == 0
            ? 'top pair'
            : rankPos == 1
            ? 'second pair'
            : rankPos == distinct.length - 1
            ? 'bottom pair'
            : 'middle pair';
        final bool topKicker = kicker == 14 ||
            (kicker > distinct.where((int r) => r != pairRank).fold(0, max) &&
                kicker >= 13);
        return '$which ${_rankName(pairRank)}s with ${_rankName(kicker)} kicker'
            '${topKicker ? ' (top kicker)' : kicker <= 9 ? ' (weak kicker)' : ''}';
      case HandCategory.twoPair:
        final int p1 = made.kickers[0];
        final int p2 = made.kickers[1];
        final bool bothMine = (p1 == hiHole || p1 == loHole) && (p2 == hiHole || p2 == loHole);
        if (bothMine) {
          final bool top = p1 == topBoard;
          return '${top ? 'top two pair' : 'two pair'} ${_rankName(p1)}s and ${_rankName(p2)}s (both hole cards hit)';
        }
        if (boardOnly.category == HandCategory.twoPair) {
          return 'two pair on the board only (you play a kicker)';
        }
        final int mine = (p1 == hiHole || p1 == loHole) ? p1 : p2;
        final int fromBoard = mine == p1 ? p2 : p1;
        return 'two pair ${_rankName(p1)}s and ${_rankName(p2)}s (your pair of ${_rankName(mine)}s plus board pair of ${_rankName(fromBoard)}s)';
      case HandCategory.threeOfAKind:
        final int trips = made.kickers.first;
        if (pocketPair && trips == hiHole) {
          return 'set of ${_rankName(trips)}s (hidden, very strong)';
        }
        if ((boardCounts[trips] ?? 0) >= 3) {
          return 'board trips ${_rankName(trips)}s (you play a kicker)';
        }
        return 'trips ${_rankName(trips)}s (one hole card, ${_rankName(trips == hiHole ? loHole : hiHole)} kicker)';
      case HandCategory.straight:
        final bool nut = made.kickers.first == 14 || _isNutStraight(made, board);
        return '${nut ? 'nut ' : ''}straight to the ${_rankName(made.kickers.first)}'
            '${boardOnly.category == HandCategory.straight ? ' (board plays; watch for a better straight)' : ''}';
      case HandCategory.flush:
        final bool nut = _isNutFlush(hole, board);
        return '${nut ? 'nut ' : ''}flush, ${_rankName(made.kickers.first)} high'
            '${boardOnly.category == HandCategory.flush ? ' (flush is on the board)' : ''}';
      case HandCategory.fullHouse:
        return 'full house ${_rankName(made.kickers[0])}s full of ${_rankName(made.kickers[1])}s';
      case HandCategory.fourOfAKind:
        return 'four of a kind ${_rankName(made.kickers.first)}s';
      case HandCategory.straightFlush:
        return 'straight flush to the ${_rankName(made.kickers.first)}';
    }
  }

  static List<String> describeDraws(
    List<PlayingCard> hole,
    List<PlayingCard> board,
  ) {
    if (board.isEmpty || board.length >= 5) {
      return const <String>[];
    }
    final List<PlayingCard> all = <PlayingCard>[...board, ...hole];
    final HandValue now = HandEvaluator.bestOf(all);
    final List<String> out = <String>[];

    // Flush draws.
    final Map<Suit, int> suitCount = <Suit, int>{};
    for (final PlayingCard c in all) {
      suitCount[c.suit] = (suitCount[c.suit] ?? 0) + 1;
    }
    for (final MapEntry<Suit, int> e in suitCount.entries) {
      final int holeOfSuit = hole.where((PlayingCard c) => c.suit == e.key).length;
      if (holeOfSuit == 0) {
        continue;
      }
      if (e.value == 4 && now.category.index < HandCategory.flush.index) {
        final bool nutDraw = hole.any((PlayingCard c) => c.suit == e.key && c.rank == Rank.ace);
        out.add('${nutDraw ? 'nut ' : ''}flush draw (9 outs)');
      } else if (e.value == 3 && board.length == 3 && holeOfSuit == 2) {
        out.add('backdoor flush draw');
      }
    }

    // Straight draws by brute force over unseen cards.
    if (now.category.index < HandCategory.straight.index) {
      final Set<PlayingCard> seen = all.toSet();
      int straightOuts = 0;
      for (final Suit s in Suit.values) {
        for (final Rank r in Rank.values) {
          final PlayingCard c = PlayingCard(r, s);
          if (seen.contains(c)) {
            continue;
          }
          final HandValue next = HandEvaluator.bestOf(<PlayingCard>[...all, c]);
          if (next.category == HandCategory.straight ||
              next.category == HandCategory.straightFlush) {
            straightOuts += 1;
          }
        }
      }
      if (straightOuts >= 8) {
        out.add('open-ended or double gutshot straight draw ($straightOuts outs)');
      } else if (straightOuts >= 4) {
        out.add('gutshot straight draw ($straightOuts outs)');
      }
    }
    return out;
  }

  static bool _isNutStraight(HandValue made, List<PlayingCard> board) {
    final Set<int> ranks = board.map((PlayingCard c) => c.rank.value).toSet();
    // If any higher straight is possible with two unknown cards, not the nuts.
    for (int high = 14; high > made.kickers.first; high -= 1) {
      final List<int> need = List<int>.generate(5, (int i) => high - i)
          .map((int r) => r == 1 ? 14 : r)
          .toList();
      final int missing = need.where((int r) => !ranks.contains(r)).length;
      if (missing <= 2) {
        return false;
      }
    }
    return true;
  }

  static bool _isNutFlush(List<PlayingCard> hole, List<PlayingCard> board) {
    final Map<Suit, int> count = <Suit, int>{};
    for (final PlayingCard c in <PlayingCard>[...hole, ...board]) {
      count[c.suit] = (count[c.suit] ?? 0) + 1;
    }
    final Suit suit = count.entries
        .reduce((MapEntry<Suit, int> x, MapEntry<Suit, int> y) => x.value >= y.value ? x : y)
        .key;
    final Set<int> seen = <PlayingCard>[...hole, ...board]
        .where((PlayingCard c) => c.suit == suit)
        .map((PlayingCard c) => c.rank.value)
        .toSet();
    final int myTop = hole
        .where((PlayingCard c) => c.suit == suit)
        .map((PlayingCard c) => c.rank.value)
        .fold(0, max);
    for (int r = 14; r > myTop; r -= 1) {
      if (!seen.contains(r)) {
        return false;
      }
    }
    return true;
  }

  static PlayingCard _hi(PlayingCard a, PlayingCard b) =>
      a.rank.value >= b.rank.value ? a : b;
  static PlayingCard _lo(PlayingCard a, PlayingCard b) =>
      a.rank.value >= b.rank.value ? b : a;

  static String _rankName(int value) {
    const Map<int, String> names = <int, String>{
      14: 'Ace', 13: 'King', 12: 'Queen', 11: 'Jack', 10: 'Ten',
      9: 'Nine', 8: 'Eight', 7: 'Seven', 6: 'Six', 5: 'Five',
      4: 'Four', 3: 'Three', 2: 'Two',
    };
    return names[value] ?? '$value';
  }
}

/// Monte Carlo win share of [hole] against [opponents] random hands.
double monteCarloEquity(
  List<PlayingCard> hole,
  List<PlayingCard> board,
  int opponents,
  int iterations,
  Random random,
) {
  final Set<PlayingCard> seen = <PlayingCard>{...hole, ...board};
  final List<PlayingCard> deck = <PlayingCard>[
    for (final Suit s in Suit.values)
      for (final Rank r in Rank.values)
        if (!seen.contains(PlayingCard(r, s))) PlayingCard(r, s),
  ];
  final int boardNeeded = 5 - board.length;
  double score = 0;
  for (int i = 0; i < iterations; i += 1) {
    // Partial Fisher-Yates for the cards we need.
    final int needed = boardNeeded + opponents * 2;
    for (int k = 0; k < needed; k += 1) {
      final int j = k + random.nextInt(deck.length - k);
      final PlayingCard tmp = deck[k];
      deck[k] = deck[j];
      deck[j] = tmp;
    }
    final List<PlayingCard> fullBoard = <PlayingCard>[
      ...board,
      ...deck.sublist(0, boardNeeded),
    ];
    final HandValue mine = HandEvaluator.bestOf(<PlayingCard>[...fullBoard, ...hole]);
    int better = 0;
    int equal = 0;
    for (int o = 0; o < opponents; o += 1) {
      final int base = boardNeeded + o * 2;
      final HandValue theirs = HandEvaluator.bestOf(<PlayingCard>[
        ...fullBoard,
        deck[base],
        deck[base + 1],
      ]);
      final int cmp = theirs.compareTo(mine);
      if (cmp > 0) {
        better += 1;
        break;
      } else if (cmp == 0) {
        equal += 1;
      }
    }
    if (better == 0) {
      score += equal == 0 ? 1 : 1 / (equal + 1);
    }
  }
  return score / iterations;
}

/// Extractor with a fixed seed, for seats that need reproducible equity.
FeatureExtractor seededExtractor(int seed) =>
    FeatureExtractor(equityIterations: 400, random: Random(seed));
