import 'dart:math';

import 'engine.dart';
import 'features.dart';

/// Coarse quality label for an action at a decision point.
///
/// The reference is an equity-versus-random rule set, not a solver. It is
/// meant to catch clear errors (folding the nuts, calling with no equity,
/// shoving 100 big blinds with air), not to arbitrate close spots. Treat
/// `mistake` and `blunder` rates as the signal; `best` versus `ok` is noisy.
enum Verdict { best, ok, mistake, blunder }

class GradedAction {
  const GradedAction(this.verdict, this.notes);

  final Verdict verdict;
  final List<String> notes;
}

class ReferenceAssessment {
  const ReferenceAssessment({
    required this.recommended,
    required this.verdicts,
    required this.features,
    required this.rationale,
  });

  final PokerAction recommended;
  final Map<PokerActionType, Verdict> verdicts;
  final PokerFeatures features;
  final String rationale;

  Map<String, Object?> toJson() => <String, Object?>{
    'recommended': <String, Object?>{
      'type': recommended.type.name,
      if (recommended.amount != null)
        'amount': recommended.amount! / Chips.unit,
    },
    'verdicts': verdicts.map(
      (PokerActionType k, Verdict v) => MapEntry<String, Object?>(k.name, v.name),
    ),
    'rationale': rationale,
  };
}

class ReferencePolicy implements AiDecisionProvider {
  ReferencePolicy({FeatureExtractor? extractor})
    : _extractor = extractor ?? FeatureExtractor();

  final FeatureExtractor _extractor;

  @override
  Future<AiDecision> decide(AiDecisionRequest request) async {
    final ReferenceAssessment a = assess(
      request.snapshot,
      request.legalActions,
    );
    return AiDecision(a.recommended, reason: 'reference', thinking: a.rationale);
  }

  ReferenceAssessment assess(
    AiVisibleSnapshot s,
    List<LegalAction> legal, {
    PokerFeatures? features,
  }) {
    final PokerFeatures f = features ?? _extractor.extract(s, legal);
    final Map<PokerActionType, Verdict> v = <PokerActionType, Verdict>{};
    final Set<PokerActionType> legalTypes = legal
        .map((LegalAction a) => a.type)
        .toSet();
    final bool facing = s.toCall > 0;
    final bool preflop = s.phase == BettingPhase.preflop;
    final int bb = s.bigBlind;
    final double stackBB = f.effectiveStack / bb;
    final double toCallBB = s.toCall / bb;
    final bool hasDraw = f.draws.any((String d) => !d.contains('backdoor'));
    final bool river = s.phase == BettingPhase.river;
    String rationale;

    void set(PokerActionType t, Verdict verdict) {
      if (legalTypes.contains(t)) {
        v[t] = verdict;
      }
    }

    // `bet` and `raise` are the same decision class; only one is ever legal.
    void aggressive(Verdict verdict) {
      set(PokerActionType.bet, verdict);
      set(PokerActionType.raise, verdict);
    }

    if (preflop) {
      final double r = f.equity * (f.equityOpponents + 1);
      final bool unopened = s.currentBet <= bb;
      if (facing) {
        if (r >= 1.45) {
          aggressive(Verdict.best);
          set(PokerActionType.call, Verdict.ok);
          set(PokerActionType.allIn, stackBB <= 25 || r >= 1.7 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.fold, Verdict.blunder);
          rationale = 'Premium preflop hand (strength ${r.toStringAsFixed(2)}x random): raise for value.';
        } else if (r >= 1.2) {
          set(PokerActionType.call, Verdict.best);
          aggressive(toCallBB <= 3 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.fold, toCallBB <= 3 ? Verdict.mistake : Verdict.ok);
          set(PokerActionType.allIn, stackBB <= 15 ? Verdict.ok : Verdict.blunder);
          rationale = 'Strong playable hand: call, raise only against small bets.';
        } else if (r >= 1.0) {
          if (toCallBB <= 1) {
            set(PokerActionType.call, Verdict.best);
            aggressive(unopened ? Verdict.ok : Verdict.mistake);
            set(PokerActionType.fold, Verdict.ok);
          } else if (toCallBB <= 4) {
            set(PokerActionType.fold, Verdict.best);
            set(PokerActionType.call, Verdict.ok);
            aggressive(Verdict.mistake);
          } else {
            set(PokerActionType.fold, Verdict.best);
            set(PokerActionType.call, Verdict.mistake);
            aggressive(Verdict.mistake);
          }
          set(PokerActionType.allIn, stackBB <= 10 ? Verdict.mistake : Verdict.blunder);
          rationale = 'Marginal hand: see a cheap flop, fold to real pressure.';
        } else {
          set(PokerActionType.fold, Verdict.best);
          set(
            PokerActionType.call,
            toCallBB <= 1
                ? Verdict.ok
                : toCallBB <= 3
                ? Verdict.mistake
                : Verdict.blunder,
          );
          aggressive(unopened && r >= 0.9 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Weak hand: fold, or steal only when nobody has raised.';
        }
      } else {
        if (r >= 1.3) {
          aggressive(Verdict.best);
          set(PokerActionType.check, Verdict.ok);
          set(PokerActionType.allIn, r >= 1.6 ? Verdict.ok : Verdict.mistake);
          rationale = 'Free option with a strong hand: raise for value.';
        } else if (r >= 1.05) {
          set(PokerActionType.check, Verdict.best);
          aggressive(Verdict.ok);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Playable hand with a free option: check or raise.';
        } else {
          set(PokerActionType.check, Verdict.best);
          aggressive(Verdict.mistake);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Weak hand with a free option: take the free card.';
        }
      }
    } else {
      final double e = f.equity;
      final double req = f.potOdds;
      if (facing) {
        if (e >= 0.75) {
          aggressive(Verdict.best);
          set(PokerActionType.call, Verdict.ok);
          set(PokerActionType.allIn, f.spr <= 4 || e >= 0.9 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.fold, Verdict.blunder);
          rationale = 'Very strong (${(e * 100).round()}% equity): raise for value.';
        } else if (e >= req + 0.10) {
          set(PokerActionType.call, Verdict.best);
          aggressive(e >= 0.55 || hasDraw ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.fold, e >= req + 0.30 ? Verdict.blunder : Verdict.mistake);
          set(
            PokerActionType.allIn,
            f.spr <= 2 || (e >= 0.6 && f.spr <= 3)
                ? Verdict.ok
                : f.spr <= 5
                ? Verdict.mistake
                : Verdict.blunder,
          );
          rationale = 'Equity ${(e * 100).round()}% beats the ${(req * 100).round()}% price: call.';
        } else if (e >= req - 0.05) {
          final bool prefersCall = hasDraw && !river;
          set(PokerActionType.call, prefersCall ? Verdict.best : Verdict.ok);
          set(PokerActionType.fold, prefersCall ? Verdict.ok : Verdict.best);
          aggressive(hasDraw ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.allIn, f.spr <= 1.5 ? Verdict.mistake : Verdict.blunder);
          rationale = 'Close price (${(e * 100).round()}% vs ${(req * 100).round()}%): call with a draw, otherwise fold.';
        } else {
          set(PokerActionType.fold, Verdict.best);
          set(PokerActionType.call, e >= req - 0.15 ? Verdict.mistake : Verdict.blunder);
          aggressive(e >= 0.25 && f.opponentsInHand == 1 ? Verdict.mistake : Verdict.blunder);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Equity ${(e * 100).round()}% is below the ${(req * 100).round()}% price: fold.';
        }
      } else {
        if (e >= 0.65) {
          aggressive(Verdict.best);
          set(PokerActionType.check, river && e >= 0.85 ? Verdict.mistake : Verdict.ok);
          set(PokerActionType.allIn, f.spr <= 3 ? Verdict.ok : Verdict.mistake);
          rationale = 'Strong hand (${(e * 100).round()}% equity): bet for value and protection.';
        } else if (e >= 0.45) {
          set(PokerActionType.check, Verdict.best);
          aggressive(Verdict.ok);
          set(PokerActionType.allIn, f.spr > 4 ? Verdict.blunder : Verdict.mistake);
          rationale = 'Medium hand: check for pot control, betting is fine.';
        } else if (e >= 0.25) {
          set(PokerActionType.check, Verdict.best);
          aggressive(f.opponentsInHand <= 2 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Weak hand: check, or bluff only against few opponents.';
        } else {
          set(PokerActionType.check, Verdict.best);
          aggressive(f.opponentsInHand == 1 ? Verdict.ok : Verdict.mistake);
          set(PokerActionType.allIn, Verdict.blunder);
          rationale = 'Air: check; a bluff is only defensible heads-up.';
        }
      }
    }

    final PokerAction recommended = _recommend(s, legal, v, f);
    return ReferenceAssessment(
      recommended: recommended,
      verdicts: v,
      features: f,
      rationale: rationale,
    );
  }

  /// Grades a concrete action, including bet-size sanity.
  GradedAction grade(
    ReferenceAssessment a,
    PokerAction action,
    AiVisibleSnapshot s,
    List<LegalAction> legal,
  ) {
    Verdict verdict = a.verdicts[action.type] ?? Verdict.blunder;
    final List<String> notes = <String>[];
    if (action.type == PokerActionType.bet || action.type == PokerActionType.raise) {
      final LegalAction? la = legal
          .where((LegalAction l) => l.type == action.type)
          .firstOrNull;
      final int amount = action.amount ?? 0;
      final bool isShove = la?.maxAmount != null && amount >= la!.maxAmount!;
      if (isShove) {
        // A max-sized bet is economically an all-in; grade it as one.
        verdict = a.verdicts[PokerActionType.allIn] ?? verdict;
        notes.add('bet is effectively all-in');
      } else if (s.phase == BettingPhase.preflop) {
        final double totalBB = amount / s.bigBlind;
        final bool unopened = s.currentBet <= s.bigBlind;
        if (unopened && totalBB > 6 && a.features.effectiveStack / s.bigBlind > 20) {
          verdict = _downgrade(verdict);
          notes.add('oversized open (${totalBB.toStringAsFixed(1)} bb)');
        } else if (!unopened && amount > s.currentBet * 5) {
          verdict = _downgrade(verdict);
          notes.add('oversized re-raise (${(amount / s.currentBet).toStringAsFixed(1)}x)');
        }
      } else {
        final double ratio = (amount - a.features.myCurrentBet) / max(1, a.features.potAfterCall);
        if (ratio > 1.5 && a.features.equity < 0.85 && a.features.spr > 2) {
          verdict = _downgrade(verdict);
          notes.add('oversized (${(ratio * 100).round()}% pot)');
        } else if (ratio < 0.25) {
          notes.add('undersized (${(ratio * 100).round()}% pot)');
        }
      }
    }
    return GradedAction(verdict, notes);
  }

  static Verdict _downgrade(Verdict v) => switch (v) {
    Verdict.best => Verdict.ok,
    Verdict.ok => Verdict.mistake,
    Verdict.mistake => Verdict.blunder,
    Verdict.blunder => Verdict.blunder,
  };

  PokerAction _recommend(
    AiVisibleSnapshot s,
    List<LegalAction> legal,
    Map<PokerActionType, Verdict> v,
    PokerFeatures f,
  ) {
    // Highest-graded legal action; when nothing is `best` (for example only
    // fold/call remain against an all-in), the least-bad option wins.
    PokerActionType? bestType;
    for (final Verdict target in Verdict.values) {
      for (final PokerActionType t in PokerActionType.values) {
        if (v[t] == target) {
          bestType = t;
          break;
        }
      }
      if (bestType != null) {
        break;
      }
    }
    bestType ??= legal.first.type;
    final LegalAction la = legal.firstWhere((LegalAction l) => l.type == bestType);
    if (!la.needsAmount) {
      return PokerAction(bestType);
    }
    final AiSeatSnapshot me = s.seats[s.seatIndex];
    int total;
    if (bestType == PokerActionType.allIn) {
      total = la.maxAmount!;
    } else if (s.phase == BettingPhase.preflop) {
      final bool unopened = s.currentBet <= s.bigBlind;
      if (unopened) {
        final int limpers = s.seats
            .where(
              (AiSeatSnapshot x) =>
                  x.index != s.seatIndex &&
                  !x.isBigBlind &&
                  !x.hasFolded &&
                  x.currentBet >= s.bigBlind,
            )
            .length;
        total = (s.bigBlind * 2.5).round() + s.bigBlind * limpers;
      } else {
        total = s.currentBet * 3;
      }
    } else {
      total = bestType == PokerActionType.bet
          ? me.currentBet + (f.potAfterCall * 0.66).round()
          : (s.currentBet * 2.5).round() + s.toCall ~/ 2;
    }
    const int unit = Chips.smallBlind;
    total = ((total + unit ~/ 2) ~/ unit) * unit;
    return PokerAction(bestType, amount: total.clamp(la.minAmount!, la.maxAmount!).toInt());
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
