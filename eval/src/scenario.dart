import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'engine.dart';
import 'features.dart';
import 'reference_policy.dart';
import 'snapshot_codec.dart';

/// One frozen decision point: what the acting seat saw, what was legal, and
/// the reference grading for every legal action type.
class Scenario {
  Scenario({
    required this.id,
    required this.tag,
    required this.seed,
    required this.snapshot,
    required this.legalActions,
    required this.profile,
  });

  final String id;

  /// `<street>/<facing|free>`, used for stratified sampling and breakdowns.
  final String tag;
  final int seed;
  final AiVisibleSnapshot snapshot;
  final List<LegalAction> legalActions;
  final AiProfile profile;

  PokerFeatures? _features;
  ReferenceAssessment? _reference;

  static const int gradingIterations = 1500;

  /// Deterministic per scenario so grading is reproducible across runs.
  FeatureExtractor get extractor => FeatureExtractor(
    equityIterations: gradingIterations,
    random: Random(id.hashCode ^ seed),
  );

  PokerFeatures get features =>
      _features ??= extractor.extract(snapshot, legalActions);

  ReferenceAssessment get reference => _reference ??= ReferencePolicy()
      .assess(snapshot, legalActions, features: features);

  AiDecisionRequest get request => AiDecisionRequest(
    snapshot: snapshot,
    profile: profile,
    legalActions: legalActions,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'tag': tag,
    'seed': seed,
    'snapshot': snapshot.toJson(),
    'legalActions': SnapshotCodec.legalActionsToJson(legalActions),
    'profile': SnapshotCodec.profileToJson(profile),
    // Informational only; grading recomputes these deterministically.
    'features': features.toJson(),
    'reference': reference.toJson(),
  };

  static Scenario fromJson(Map<String, Object?> json) => Scenario(
    id: json['id'] as String,
    tag: json['tag'] as String,
    seed: json['seed'] as int,
    snapshot: SnapshotCodec.snapshot(json['snapshot'] as Map<String, Object?>),
    legalActions: SnapshotCodec.legalActions(json['legalActions'] as List<Object?>),
    profile: SnapshotCodec.profile(json['profile'] as Map<String, Object?>),
  );

  static List<Scenario> loadFile(String path) {
    final Object? decoded = jsonDecode(File(path).readAsStringSync());
    final List<Object?> items = decoded is Map<String, Object?>
        ? decoded['scenarios'] as List<Object?>
        : decoded as List<Object?>;
    return items
        .map((Object? e) => Scenario.fromJson(e as Map<String, Object?>))
        .toList();
  }

  static void saveFile(String path, List<Scenario> scenarios, Map<String, Object?> meta) {
    final File file = File(path)..parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'meta': meta,
        'scenarios': scenarios.map((Scenario s) => s.toJson()).toList(),
      }),
    );
  }
}

/// Plays seeded hands with a mix of drivers and samples decision points into
/// stratified buckets so the bank covers every street, facing and not.
class ScenarioGenerator {
  ScenarioGenerator({
    required this.seats,
    required this.seed,
    this.startingStackBB = 100,
  });

  final int seats;
  final int seed;
  final int startingStackBB;

  static const Map<String, double> bucketShares = <String, double>{
    'preflop/facing': 0.24,
    'preflop/free': 0.04,
    'flop/facing': 0.16,
    'flop/free': 0.16,
    'turn/facing': 0.12,
    'turn/free': 0.10,
    'river/facing': 0.10,
    'river/free': 0.08,
  };

  Future<List<Scenario>> generate(int count, {void Function(String)? log}) async {
    final Random rng = Random(seed);
    final Map<String, int> quota = bucketShares.map(
      (String k, double v) => MapEntry<String, int>(k, max(1, (count * v).round())),
    );
    final Map<String, int> filled = <String, int>{for (final String k in quota.keys) k: 0};
    final List<Scenario> out = <Scenario>[];
    final TableConfig config = TableConfig(
      humanName: 'Hero',
      seatCount: seats,
      minBuyIn: Chips.bigBlind * 20,
      maxBuyIn: Chips.bigBlind * startingStackBB * 3,
      startingStack: Chips.bigBlind * startingStackBB,
    );
    final ReferencePolicy reference = ReferencePolicy(
      extractor: FeatureExtractor(equityIterations: 300, random: Random(seed + 1)),
    );
    const HeuristicAiDecisionProvider heuristic = HeuristicAiDecisionProvider();

    int tableSeed = seed;
    int handsPlayed = 0;
    final int maxHands = count * 25;
    while (out.length < count && handsPlayed < maxHands) {
      tableSeed += 1;
      final PokerGame game = PokerGame(config: config, seed: tableSeed);
      // Each table plays a short session so stacks drift and profiles vary.
      final List<String> drivers = List<String>.generate(
        seats,
        (_) => const <String>['heuristic', 'reference', 'explorer'][rng.nextInt(3)],
      );
      for (int h = 0; h < 12 && out.length < count; h += 1) {
        if (h > 0) {
          game.startNextHand();
        }
        if (game.isHandComplete) {
          break;
        }
        handsPlayed += 1;
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
          final AiVisibleSnapshot snap = game.visibleSnapshotFor(idx);
          final AiProfile profile = game.players[idx].profile ??
              AiProfile.presets[rng.nextInt(AiProfile.presets.length)];
          final String tag = '${snap.phase.name}/${snap.toCall > 0 ? 'facing' : 'free'}';
          if ((filled[tag] ?? 0) < (quota[tag] ?? 0) && rng.nextDouble() < 0.4) {
            final Scenario s = Scenario(
              id: 's${(out.length + 1).toString().padLeft(3, '0')}',
              tag: tag,
              seed: tableSeed,
              snapshot: snap,
              legalActions: legal,
              profile: profile,
            );
            out.add(s);
            filled[tag] = (filled[tag] ?? 0) + 1;
            log?.call('${s.id} $tag hand ${snap.handNumber} seat $idx '
                '${snap.holeCards.join(' ')} | ${snap.board.join(' ')} '
                '-> ${s.reference.recommended.type.name} (${s.reference.rationale})');
          }
          final AiDecisionRequest req = AiDecisionRequest(
            snapshot: snap,
            profile: profile,
            legalActions: legal,
          );
          final PokerAction action;
          switch (drivers[idx]) {
            case 'reference':
              action = (await reference.decide(req)).action;
            case 'explorer':
              action = rng.nextDouble() < 0.35
                  ? _randomLegal(legal, rng, snap)
                  : (await heuristic.decide(req)).action;
            default:
              action = (await heuristic.decide(req)).action;
          }
          game.applyAction(action);
        }
      }
    }
    log?.call('buckets: ${filled.entries.map((MapEntry<String, int> e) => '${e.key}=${e.value}/${quota[e.key]}').join(', ')} '
        'from $handsPlayed hands');
    return out;
  }

  /// Random but sane action: sizes are pot-relative so the resulting spots
  /// look like real poker rather than random shoves.
  static PokerAction _randomLegal(List<LegalAction> legal, Random rng, AiVisibleSnapshot s) {
    final LegalAction pick = legal[rng.nextInt(legal.length)];
    if (pick.type == PokerActionType.allIn && rng.nextDouble() < 0.8) {
      return PokerAction(legal.first.type);
    }
    if (!pick.needsAmount) {
      return PokerAction(pick.type);
    }
    final int me = s.seats[s.seatIndex].currentBet;
    final int potAfterCall = s.pot + s.toCall;
    final List<double> fractions = <double>[0.33, 0.5, 0.75, 1.0, 1.5];
    final int target = pick.type == PokerActionType.raise
        ? (s.currentBet * (2 + rng.nextInt(3))).round()
        : me + (potAfterCall * fractions[rng.nextInt(fractions.length)]).round();
    const int unit = Chips.smallBlind;
    final int rounded = ((target + unit ~/ 2) ~/ unit) * unit;
    return PokerAction(pick.type, amount: rounded.clamp(pick.minAmount!, pick.maxAmount!).toInt());
  }
}
