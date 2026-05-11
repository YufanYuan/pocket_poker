import 'dart:convert';

import '../domain/card.dart';
import '../domain/models.dart';
import '../domain/money.dart';

class AiDecisionRequest {
  const AiDecisionRequest({
    required this.snapshot,
    required this.profile,
    required this.legalActions,
  });

  final AiVisibleSnapshot snapshot;
  final AiProfile profile;
  final List<LegalAction> legalActions;
}

class AiDecision {
  const AiDecision(this.action, {this.reason, this.thinking});

  final PokerAction action;
  final String? reason;
  final String? thinking;
}

abstract class AiDecisionProvider {
  Future<AiDecision> decide(AiDecisionRequest request);
}

class AiVisibleSnapshot {
  const AiVisibleSnapshot({
    required this.handNumber,
    required this.seatIndex,
    required this.phase,
    required this.smallBlind,
    required this.bigBlind,
    required this.pot,
    required this.currentBet,
    required this.toCall,
    required this.board,
    required this.holeCards,
    required this.seats,
    required this.recentActions,
  });

  final int handNumber;
  final int seatIndex;
  final BettingPhase phase;
  final int smallBlind;
  final int bigBlind;
  final int pot;
  final int currentBet;
  final int toCall;
  final List<PlayingCard> board;
  final List<PlayingCard> holeCards;
  final List<AiSeatSnapshot> seats;
  final List<String> recentActions;

  Map<String, Object> toJson() => <String, Object>{
    'handNumber': handNumber,
    'seatIndex': seatIndex,
    'phase': phase.name,
    'smallBlind': Chips.format(smallBlind),
    'bigBlind': Chips.format(bigBlind),
    'pot': Chips.format(pot),
    'currentBet': Chips.format(currentBet),
    'toCall': Chips.format(toCall),
    'board': board.map((PlayingCard card) => card.label).toList(),
    'holeCards': holeCards.map((PlayingCard card) => card.label).toList(),
    'seats': seats.map((AiSeatSnapshot seat) => seat.toJson()).toList(),
    'recentActions': recentActions,
  };

  String toCompactJson() => jsonEncode(toJson());
}

class AiSeatSnapshot {
  const AiSeatSnapshot({
    required this.index,
    required this.name,
    required this.kind,
    required this.stack,
    required this.currentBet,
    required this.totalCommitted,
    required this.hasFolded,
    required this.isAllIn,
    required this.isDealer,
    required this.isSmallBlind,
    required this.isBigBlind,
  });

  final int index;
  final String name;
  final PlayerKind kind;
  final int stack;
  final int currentBet;
  final int totalCommitted;
  final bool hasFolded;
  final bool isAllIn;
  final bool isDealer;
  final bool isSmallBlind;
  final bool isBigBlind;

  Map<String, Object> toJson() => <String, Object>{
    'index': index,
    'name': name,
    'kind': kind.name,
    'stack': Chips.format(stack),
    'currentBet': Chips.format(currentBet),
    'totalCommitted': Chips.format(totalCommitted),
    'hasFolded': hasFolded,
    'isAllIn': isAllIn,
    'isDealer': isDealer,
    'isSmallBlind': isSmallBlind,
    'isBigBlind': isBigBlind,
  };
}

AiDecision? decisionFromModelJson(
  String source,
  List<LegalAction> legalActions,
) {
  final String? jsonSource = _extractJsonObject(source);
  if (jsonSource == null) {
    final PokerAction? looseAction = _actionFromLooseToolText(
      source,
      legalActions,
    );
    return looseAction == null ? null : AiDecision(looseAction);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonSource);
  } on FormatException {
    final PokerAction? looseAction = _actionFromLooseToolText(
      source,
      legalActions,
    );
    return looseAction == null ? null : AiDecision(looseAction);
  }
  if (decoded is! Map<String, Object?>) {
    final PokerAction? looseAction = _actionFromLooseToolText(
      source,
      legalActions,
    );
    return looseAction == null ? null : AiDecision(looseAction);
  }
  return decisionFromModelArguments(decoded, legalActions);
}

PokerAction? actionFromModelJson(
  String source,
  List<LegalAction> legalActions,
) {
  return decisionFromModelJson(source, legalActions)?.action;
}

AiDecision? decisionFromModelArguments(
  Map<String, Object?> arguments,
  List<LegalAction> legalActions,
) {
  final PokerAction? action = actionFromModelArguments(arguments, legalActions);
  if (action == null) {
    return null;
  }
  return AiDecision(
    action,
    thinking: _normalizedModelString(arguments['thinking']),
  );
}

PokerAction? actionFromModelArguments(
  Map<String, Object?> arguments,
  List<LegalAction> legalActions,
) {
  final String? actionValue = _normalizedModelString(arguments['action']);
  if (actionValue == null) {
    return null;
  }
  final PokerActionType? type = _modelActionType(actionValue);
  if (type == null) {
    return null;
  }
  final LegalAction? legal = legalActions
      .where((LegalAction action) => action.type == type)
      .firstOrNull;
  if (legal == null) {
    return null;
  }

  if (!legal.needsAmount) {
    return PokerAction(type);
  }

  final Object? amountValue = arguments['amount'];
  final num? amountWhole = _normalizedModelNumber(amountValue);
  if (amountWhole == null &&
      type == PokerActionType.allIn &&
      legal.minAmount != null &&
      legal.maxAmount != null &&
      legal.minAmount == legal.maxAmount) {
    return PokerAction(type, amount: legal.maxAmount);
  }
  if (amountWhole == null) {
    return null;
  }
  final int amount = Chips.fromWhole(amountWhole);
  if (legal.minAmount != null && amount < legal.minAmount!) {
    return null;
  }
  if (legal.maxAmount != null && amount > legal.maxAmount!) {
    return null;
  }
  return PokerAction(type, amount: amount);
}

PokerActionType? _modelActionType(String source) {
  final String normalized = source.toLowerCase().replaceAll(
    RegExp(r'[\s_-]+'),
    '',
  );
  for (final PokerActionType type in PokerActionType.values) {
    final String candidate = type.name.toLowerCase().replaceAll(
      RegExp(r'[\s_-]+'),
      '',
    );
    if (candidate == normalized) {
      return type;
    }
  }
  return null;
}

String? _normalizedModelString(Object? value) {
  if (value is! String) {
    return null;
  }
  return value.replaceAll('<|"|>', '').replaceAll('<escape>', '').trim();
}

num? _normalizedModelNumber(Object? value) {
  if (value is num) {
    return value;
  }
  final String? stringValue = _normalizedModelString(value);
  if (stringValue == null || stringValue.isEmpty) {
    return null;
  }
  return num.tryParse(stringValue.replaceAll(',', ''));
}

PokerAction? _actionFromLooseToolText(
  String source,
  List<LegalAction> legalActions,
) {
  final Map<String, Object?>? arguments = _extractLooseToolArguments(source);
  if (arguments == null) {
    return null;
  }
  return actionFromModelArguments(arguments, legalActions);
}

Map<String, Object?>? _extractLooseToolArguments(String source) {
  final RegExp actionPattern = RegExp(
    r'''\baction\s*[:=]\s*("[^"]*"|'[^']*'|[^,})\s]+)''',
    caseSensitive: false,
  );
  final RegExpMatch? actionMatch = actionPattern.firstMatch(source);
  if (actionMatch == null) {
    return null;
  }

  final Map<String, Object?> arguments = <String, Object?>{
    'action': _looseValue(actionMatch.group(1) ?? ''),
  };

  final RegExp amountPattern = RegExp(
    r'''\bamount\s*[:=]\s*("[^"]*"|'[^']*'|[^,})\s]+)''',
    caseSensitive: false,
  );
  final RegExpMatch? amountMatch = amountPattern.firstMatch(source);
  if (amountMatch != null) {
    arguments['amount'] = _looseValue(amountMatch.group(1) ?? '');
  }
  return arguments;
}

String _looseValue(String source) {
  final String trimmed = source.trim();
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

String? _extractJsonObject(String source) {
  final String trimmed = source.trim();
  final RegExp fencedJson = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
    caseSensitive: false,
  );
  final RegExpMatch? fencedMatch = fencedJson.firstMatch(trimmed);
  final String candidate = fencedMatch?.group(1)?.trim() ?? trimmed;

  final int start = candidate.indexOf('{');
  if (start < 0) {
    return null;
  }

  bool inString = false;
  bool escaping = false;
  int depth = 0;
  for (int index = start; index < candidate.length; index += 1) {
    final String char = candidate[index];
    if (escaping) {
      escaping = false;
      continue;
    }
    if (char == '\\') {
      escaping = inString;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (char == '{') {
      depth += 1;
    } else if (char == '}') {
      depth -= 1;
      if (depth == 0) {
        return candidate.substring(start, index + 1);
      }
    }
  }
  return null;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
