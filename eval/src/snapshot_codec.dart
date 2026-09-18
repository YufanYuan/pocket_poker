import 'engine.dart';

/// JSON round trip for the AI-visible state so scenarios can be stored on
/// disk and replayed against any provider.
class SnapshotCodec {
  const SnapshotCodec._();

  static int chips(Object? value) {
    if (value is num) {
      return Chips.fromWhole(value);
    }
    return Chips.fromWhole(double.parse(value.toString()));
  }

  static PlayingCard card(String label) {
    final String rankLabel = label.substring(0, label.length - 1);
    final String suitLabel = label.substring(label.length - 1);
    final Rank rank = Rank.values.firstWhere((Rank r) => r.label == rankLabel);
    final Suit suit = Suit.values.firstWhere((Suit s) => s.label == suitLabel);
    return PlayingCard(rank, suit);
  }

  static AiVisibleSnapshot snapshot(Map<String, Object?> json) {
    return AiVisibleSnapshot(
      handNumber: json['handNumber'] as int,
      seatIndex: json['seatIndex'] as int,
      phase: BettingPhase.values.byName(json['phase'] as String),
      smallBlind: chips(json['smallBlind']),
      bigBlind: chips(json['bigBlind']),
      pot: chips(json['pot']),
      currentBet: chips(json['currentBet']),
      toCall: chips(json['toCall']),
      board: (json['board'] as List<Object?>)
          .map((Object? c) => card(c as String))
          .toList(),
      holeCards: (json['holeCards'] as List<Object?>)
          .map((Object? c) => card(c as String))
          .toList(),
      seats: (json['seats'] as List<Object?>)
          .map((Object? s) => seat(s as Map<String, Object?>))
          .toList(),
      recentActions: (json['recentActions'] as List<Object?>)
          .map((Object? a) => a as String)
          .toList(),
    );
  }

  static AiSeatSnapshot seat(Map<String, Object?> json) {
    return AiSeatSnapshot(
      index: json['index'] as int,
      name: json['name'] as String,
      kind: PlayerKind.values.byName(json['kind'] as String),
      stack: chips(json['stack']),
      currentBet: chips(json['currentBet']),
      totalCommitted: chips(json['totalCommitted']),
      hasFolded: json['hasFolded'] as bool,
      isAllIn: json['isAllIn'] as bool,
      isDealer: json['isDealer'] as bool,
      isSmallBlind: json['isSmallBlind'] as bool,
      isBigBlind: json['isBigBlind'] as bool,
    );
  }

  static List<Map<String, Object?>> legalActionsToJson(List<LegalAction> legal) {
    return legal
        .map(
          (LegalAction a) => <String, Object?>{
            'type': a.type.name,
            'minAmount': a.minAmount == null ? null : a.minAmount! / Chips.unit,
            'maxAmount': a.maxAmount == null ? null : a.maxAmount! / Chips.unit,
          },
        )
        .toList();
  }

  static List<LegalAction> legalActions(List<Object?> json) {
    return json.map((Object? item) {
      final Map<String, Object?> m = item as Map<String, Object?>;
      return LegalAction(
        type: PokerActionType.values.byName(m['type'] as String),
        minAmount: m['minAmount'] == null ? null : chips(m['minAmount']),
        maxAmount: m['maxAmount'] == null ? null : chips(m['maxAmount']),
      );
    }).toList();
  }

  static Map<String, Object?> profileToJson(AiProfile p) => <String, Object?>{
    'id': p.id,
    'name': p.name,
    'tightness': p.tightness,
    'aggression': p.aggression,
    'bluffFrequency': p.bluffFrequency,
    'callTolerance': p.callTolerance,
    'riskAppetite': p.riskAppetite,
    'tiltResistance': p.tiltResistance,
  };

  static AiProfile profile(Map<String, Object?> json) => AiProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    tightness: json['tightness'] as int,
    aggression: json['aggression'] as int,
    bluffFrequency: json['bluffFrequency'] as int,
    callTolerance: json['callTolerance'] as int,
    riskAppetite: json['riskAppetite'] as int,
    tiltResistance: json['tiltResistance'] as int,
  );

  static Map<String, Object?> actionToJson(PokerAction? a) => a == null
      ? <String, Object?>{}
      : <String, Object?>{
          'type': a.type.name,
          if (a.amount != null) 'amount': a.amount! / Chips.unit,
        };

  static PokerAction? action(Map<String, Object?>? json) {
    if (json == null || json['type'] == null) {
      return null;
    }
    return PokerAction(
      PokerActionType.values.byName(json['type'] as String),
      amount: json['amount'] == null ? null : chips(json['amount']),
    );
  }
}
