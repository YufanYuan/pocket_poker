import '../domain/card.dart';
import '../domain/hand_evaluator.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'ai_decision_provider.dart';

class HeuristicAiDecisionProvider implements AiDecisionProvider {
  const HeuristicAiDecisionProvider();

  @override
  Future<AiDecision> decide(AiDecisionRequest request) async {
    return AiDecision(_chooseAction(request), reason: 'heuristic');
  }

  PokerAction _chooseAction(AiDecisionRequest request) {
    final AiVisibleSnapshot snapshot = request.snapshot;
    final AiProfile profile = request.profile;
    final List<LegalAction> legal = request.legalActions;
    final int strength = _handStrength(snapshot);
    final double noise = _stableNoise(snapshot, profile);
    final double aggression = profile.aggression / 100;
    final double looseness = (100 - profile.tightness) / 100;
    final double callTolerance = profile.callTolerance / 100;
    final double risk = profile.riskAppetite / 100;
    final double bluff = profile.bluffFrequency / 100;
    final double appetite = strength / 100 + noise * 0.18 + looseness * 0.15;
    final double pressure = snapshot.toCall == 0
        ? 0
        : snapshot.toCall / (snapshot.pot + snapshot.toCall).clamp(1, 1 << 30);

    final LegalAction? check = _find(legal, PokerActionType.check);
    final LegalAction? call = _find(legal, PokerActionType.call);
    final LegalAction? fold = _find(legal, PokerActionType.fold);
    final LegalAction? bet = _find(legal, PokerActionType.bet);
    final LegalAction? raise = _find(legal, PokerActionType.raise);
    final LegalAction? allIn = _find(legal, PokerActionType.allIn);

    if (snapshot.toCall == 0) {
      final double betUrge =
          strength / 100 * 0.5 + aggression * 0.3 + bluff * 0.2 + noise * 0.1;
      if (bet != null && betUrge > 0.58) {
        return PokerAction(
          PokerActionType.bet,
          amount: _wagerAmount(bet, snapshot, profile, strength),
        );
      }
      if (allIn != null && strength > 88 && risk > 0.72 && noise > 0.68) {
        return PokerAction(PokerActionType.allIn, amount: allIn.maxAmount);
      }
      return PokerAction(check?.type ?? PokerActionType.check);
    }

    final double continueScore =
        appetite + callTolerance * 0.3 + risk * 0.12 - pressure * 0.95;
    final bool canRaise = raise != null && (strength > 62 || noise < bluff);
    if (canRaise &&
        continueScore > 0.42 &&
        aggression + strength / 130 > 0.95) {
      return PokerAction(
        PokerActionType.raise,
        amount: _wagerAmount(raise, snapshot, profile, strength),
      );
    }
    if (allIn != null && strength > 92 && risk + aggression > 1.35) {
      return PokerAction(PokerActionType.allIn, amount: allIn.maxAmount);
    }
    if (call != null && continueScore > 0.15) {
      return const PokerAction(PokerActionType.call);
    }
    if (fold != null) {
      return const PokerAction(PokerActionType.fold);
    }
    return const PokerAction(PokerActionType.call);
  }

  int _handStrength(AiVisibleSnapshot snapshot) {
    if (snapshot.board.length >= 3) {
      final HandValue made = HandEvaluator.bestOf(<PlayingCard>[
        ...snapshot.board,
        ...snapshot.holeCards,
      ]);
      const Map<HandCategory, int> base = <HandCategory, int>{
        HandCategory.highCard: 24,
        HandCategory.onePair: 42,
        HandCategory.twoPair: 62,
        HandCategory.threeOfAKind: 72,
        HandCategory.straight: 82,
        HandCategory.flush: 86,
        HandCategory.fullHouse: 94,
        HandCategory.fourOfAKind: 98,
        HandCategory.straightFlush: 100,
      };
      final int kickerBonus = made.kickers.isEmpty
          ? 0
          : (made.kickers.first - 8).clamp(0, 8).toInt();
      return ((base[made.category] ?? 30) + kickerBonus).clamp(0, 100).toInt();
    }

    final PlayingCard a = snapshot.holeCards[0];
    final PlayingCard b = snapshot.holeCards[1];
    final int high = a.rank.value > b.rank.value ? a.rank.value : b.rank.value;
    final int low = a.rank.value < b.rank.value ? a.rank.value : b.rank.value;
    int score = (high - 2) * 4 + (low - 2) * 2;
    if (a.rank == b.rank) {
      score += 34 + high;
    }
    if (a.suit == b.suit) {
      score += 8;
    }
    if ((a.rank.value - b.rank.value).abs() <= 1) {
      score += 7;
    }
    if (high >= 12) {
      score += 8;
    }
    return score.clamp(5, 100).toInt();
  }

  int _wagerAmount(
    LegalAction action,
    AiVisibleSnapshot snapshot,
    AiProfile profile,
    int strength,
  ) {
    final int min = action.minAmount ?? action.maxAmount ?? 0;
    final int max = action.maxAmount ?? min;
    if (max <= min) {
      return min;
    }
    final double intensity =
        (profile.aggression + profile.riskAppetite + strength) / 300;
    final int target = min + ((max - min) * intensity * 0.45).round();
    return _roundToBlindIncrement(target).clamp(min, max).toInt();
  }

  int _roundToBlindIncrement(int amount) {
    final int unit = Chips.smallBlind;
    return ((amount + unit ~/ 2) ~/ unit) * unit;
  }

  LegalAction? _find(List<LegalAction> actions, PokerActionType type) {
    for (final LegalAction action in actions) {
      if (action.type == type) {
        return action;
      }
    }
    return null;
  }

  double _stableNoise(AiVisibleSnapshot snapshot, AiProfile profile) {
    final String seed =
        '${snapshot.handNumber}:${snapshot.seatIndex}:'
        '${snapshot.phase.name}:${snapshot.recentActions.length}:${profile.id}';
    int hash = 0;
    for (final int codeUnit in seed.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return (hash % 1000) / 1000;
  }
}
