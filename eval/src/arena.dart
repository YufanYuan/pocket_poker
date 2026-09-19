import 'dart:math';

import 'engine.dart';
import 'llm_provider.dart';
import 'reference_policy.dart';

class PolicyResult {
  const PolicyResult(this.action, {this.status = 'valid', this.fallback = false, this.latencyMs = 0});

  final PokerAction action;
  final String status;
  final bool fallback;
  final int latencyMs;
}

abstract class SeatPolicy {
  String get name;
  Future<PolicyResult> act(AiDecisionRequest request);
}

class HeuristicSeat implements SeatPolicy {
  const HeuristicSeat();

  @override
  String get name => 'heuristic';

  @override
  Future<PolicyResult> act(AiDecisionRequest request) async =>
      PolicyResult((await const HeuristicAiDecisionProvider().decide(request)).action);
}

class ReferenceSeat implements SeatPolicy {
  ReferenceSeat({int seed = 11}) : _policy = ReferencePolicy(extractor: seededExtractor(seed));

  final ReferencePolicy _policy;

  @override
  String get name => 'reference';

  @override
  Future<PolicyResult> act(AiDecisionRequest request) async =>
      PolicyResult((await _policy.decide(request)).action);
}

/// LLM seat that falls back to the reference policy on unusable output, so a
/// broken model still plays legal poker and the fallback rate is measured.
class LlmSeat implements SeatPolicy {
  LlmSeat({required this.provider, required this.label, int seed = 13})
    : _fallback = ReferencePolicy(extractor: seededExtractor(seed));

  final LlmDecisionProvider provider;
  final String label;
  final ReferencePolicy _fallback;

  @override
  String get name => label;

  @override
  Future<PolicyResult> act(AiDecisionRequest request) async {
    final DecisionOutcome outcome = await provider.decide(request);
    if (outcome.usable && _isLegal(outcome.action!, request.legalActions)) {
      return PolicyResult(outcome.action!, status: outcome.status, latencyMs: outcome.latencyMs);
    }
    final AiDecision fb = await _fallback.decide(request);
    return PolicyResult(fb.action, status: outcome.status, fallback: true, latencyMs: outcome.latencyMs);
  }
}

bool _isLegal(PokerAction a, List<LegalAction> legal) {
  for (final LegalAction l in legal) {
    if (l.type != a.type) {
      continue;
    }
    if (!l.needsAmount) {
      return true;
    }
    final int? amt = a.amount;
    return amt != null &&
        (l.minAmount == null || amt >= l.minAmount!) &&
        (l.maxAmount == null || amt <= l.maxAmount!);
  }
  return false;
}

class PolicyStats {
  PolicyStats(this.name);

  final String name;
  int hands = 0;
  int decisions = 0;
  int fallbacks = 0;
  int latencyMs = 0;
  final Map<String, int> statuses = <String, int>{};

  /// Chip delta per hand index, summed across rotations (duplicate pairing).
  final Map<int, int> deltaByHand = <int, int>{};

  int get totalDelta => deltaByHand.values.fold(0, (int a, int b) => a + b);
}

class MatchResult {
  MatchResult(this.stats, this.rotations, this.handsPerRotation, this.bigBlind);

  final Map<String, PolicyStats> stats;
  final int rotations;
  final int handsPerRotation;
  final int bigBlind;

  String report() {
    final StringBuffer b = StringBuffer()
      ..writeln('duplicate match: $rotations rotations x $handsPerRotation hands')
      ..writeln()
      ..writeln('| policy | hands | bb/100 | ±95% | fallback | statuses | avg ms |')
      ..writeln('|---|---:|---:|---:|---:|---|---:|');
    for (final PolicyStats s in stats.values) {
      final List<double> perHand = s.deltaByHand.values
          .map((int d) => d / bigBlind / max(1, rotations))
          .toList();
      final int n = perHand.length;
      final double mean = n == 0 ? 0 : perHand.reduce((double a, double c) => a + c) / n;
      final double variance = n < 2
          ? 0
          : perHand.map((double x) => (x - mean) * (x - mean)).reduce((double a, double c) => a + c) / (n - 1);
      final double se = n == 0 ? 0 : sqrt(variance / n);
      final String statuses = s.statuses.entries.map((MapEntry<String, int> e) => '${e.key}=${e.value}').join(' ');
      b.writeln(
        '| ${s.name} | ${s.hands} | ${(mean * 100).toStringAsFixed(1)} | '
        '${(1.96 * se * 100).toStringAsFixed(1)} | ${s.fallbacks}/${s.decisions} | $statuses | '
        '${s.decisions == 0 ? 0 : (s.latencyMs / s.decisions).round()} |',
      );
    }
    return b.toString();
  }
}

/// Plays [hands] seeded hands once per seat rotation so every policy sees
/// the same cards from every seat. Chip deltas are paired by hand index.
Future<MatchResult> runDuplicateMatch({
  required List<SeatPolicy> policies,
  required int hands,
  required int seed,
  int startingStackBB = 100,
  void Function(String message)? log,
}) async {
  final int n = policies.length;
  final TableConfig config = TableConfig(
    humanName: 'Seat0',
    seatCount: n,
    minBuyIn: Chips.bigBlind * 20,
    maxBuyIn: Chips.bigBlind * startingStackBB * 3,
    startingStack: Chips.bigBlind * startingStackBB,
  );
  final Map<String, PolicyStats> stats = <String, PolicyStats>{
    for (final SeatPolicy p in policies) p.name: PolicyStats(p.name),
  };
  final ReferencePolicy safety = ReferencePolicy(extractor: seededExtractor(seed));

  for (int rotation = 0; rotation < n; rotation += 1) {
    final List<SeatPolicy> seatPolicies = List<SeatPolicy>.generate(
      n,
      (int seat) => policies[(seat + rotation) % n],
    );
    final PokerGame game = PokerGame(config: config, seed: seed);
    for (int h = 0; h < hands; h += 1) {
      if (h > 0) {
        game.startNextHand();
      }
      if (game.isHandComplete) {
        log?.call('rotation $rotation stopped at hand $h: ${game.statusMessage}');
        break;
      }
      // Blinds are already posted when the hand starts, so count them as stack.
      final List<int> start = game.players.map((PlayerState p) => p.stack + p.totalCommitted).toList();
      int guard = 0;
      while (!game.isHandComplete && guard++ < 200) {
        final int idx = game.currentPlayerIndex;
        if (idx < 0) {
          break;
        }
        final List<LegalAction> legal = game.legalActionsForCurrentPlayer();
        if (legal.isEmpty) {
          break;
        }
        final AiDecisionRequest req = AiDecisionRequest(
          snapshot: game.visibleSnapshotFor(idx),
          profile: game.players[idx].profile ?? AiProfile.balanced,
          legalActions: legal,
        );
        final SeatPolicy policy = seatPolicies[idx];
        final PolicyStats ps = stats[policy.name]!;
        PolicyResult result = await policy.act(req);
        if (!_isLegal(result.action, legal)) {
          result = PolicyResult(
            (await safety.decide(req)).action,
            status: 'illegal-from-policy',
            fallback: true,
            latencyMs: result.latencyMs,
          );
        }
        ps.decisions += 1;
        ps.latencyMs += result.latencyMs;
        ps.statuses[result.status] = (ps.statuses[result.status] ?? 0) + 1;
        if (result.fallback) {
          ps.fallbacks += 1;
        }
        game.applyAction(result.action);
      }
      for (int seat = 0; seat < n; seat += 1) {
        final PolicyStats ps = stats[seatPolicies[seat].name]!;
        ps.hands += 1;
        ps.deltaByHand[h] = (ps.deltaByHand[h] ?? 0) + (game.players[seat].stack - start[seat]);
      }
      if (log != null && (h + 1) % 25 == 0) {
        log('rotation ${rotation + 1}/$n hand ${h + 1}/$hands');
      }
    }
  }
  return MatchResult(stats, n, hands, Chips.bigBlind);
}
