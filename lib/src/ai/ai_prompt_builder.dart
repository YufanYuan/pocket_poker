import 'dart:convert';

import '../domain/models.dart';
import '../domain/money.dart';
import 'ai_decision_provider.dart';
import 'poker_features.dart';

/// Which decision guide, if any, follows the engine facts in the user prompt.
enum AiPromptGuide {
  none,

  /// Equity and price thresholds per situation.
  thresholds,

  /// Ordered rules: price check, commitment, then value/bluff guidance.
  /// Measured best on bank_v1 with deepseek-flash (see eval/README.md).
  ordered,
}

/// Controls how much help the user prompt gives the model.
///
/// The default is what the app ships. The eval harness builds the other
/// combinations so their effect can be measured in isolation.
class AiPromptOptions {
  const AiPromptOptions({
    this.compactStyle = true,
    this.includeFacts = true,
    this.guide = AiPromptGuide.ordered,
  });

  /// The original prompt: full style guide, no engine facts, no guide.
  const AiPromptOptions.legacy()
    : compactStyle = false,
      includeFacts = false,
      guide = AiPromptGuide.none;

  /// Persona line plus four style numbers instead of the full style guide.
  final bool compactStyle;

  /// Engine-computed facts: hand class, draws, equity, price, SPR, presets.
  final bool includeFacts;

  final AiPromptGuide guide;
}

String aiDecisionGuideText(AiPromptGuide guide) => switch (guide) {
  AiPromptGuide.none => '',
  AiPromptGuide.thresholds => _guideThresholds,
  AiPromptGuide.ordered => _guideOrdered,
};

const String _guideThresholds = '''
## Decision guide (apply after reading the facts)

- Facing a bet: fold when your equity is clearly below the pot odds and you hold no strong draw; call when equity beats the price; raise with very strong hands (about 70%+ equity) or strong draws that can also make opponents fold.
- No bet pending: bet 50-75% of the pot with 60%+ equity or to protect a vulnerable made hand; check medium-strength hands; bluff only against one or two opponents and with some equity.
- Preflop: open-raise 2.5-3 big blinds with strong hands, 3-bet premium hands, fold weak offsuit hands to raises, and never call large raises with junk.
- Do not bet or raise more than the pot unless the stack-to-pot ratio is under 2 or you hold a very strong hand.
- The amount is your total for this betting round. Pick one of the listed presets unless you have a precise reason.''';

const String _guideOrdered = '''
## Decision guide (apply after reading the facts)

Decide in this order:

1. Price check. Compare the equity number with the pot odds number. If equity is above pot odds, folding is a mistake; the cheaper the call relative to the pot, the worse a fold is. Facing a bet that costs under 20% of the pot, fold only with no pair, no draw and under 20% equity.
2. Commitment. If calling leaves you with less than the pot behind, you are committed: call or move all-in with any equity above the price, and never fold a made hand or a strong draw.
3. Facing a bet with a strong hand (about 70%+ equity): raise for value. With a draw or a medium hand that beats the price: call; raise only when opponents can still fold.
4. No bet pending: bet 50-75% of the pot with 60%+ equity or to protect a vulnerable made hand. Check medium and weak hands. Do not bluff into three or more opponents. Never move all-in with no pair and no strong draw; low stack-to-pot ratio makes a bluff worse, not better, because nobody folds.
5. Preflop: open-raise 2.5-3 big blinds with strong hands, 3-bet premium hands, fold weak offsuit hands to raises, and never call large raises with junk. Suited broadways and pairs call raises when the price is under a third of the pot.
6. Style only shifts close decisions. It never turns a clear call into a fold or a clear check into an all-in.

The amount is your total for this betting round. Pick one of the listed presets unless you have a precise reason.''';

String buildAiDecisionSystemPrompt() {
  return '''
You are a Texas Holdem poker decision engine.

Your job is to choose one legal action for the current seat. Use only public table state, the acting seat's hole cards, the full hand action line, stack sizes, current street bets, and the provided style profile. Never invent hidden cards, never assume folded cards, and never mention private information the acting seat cannot see.

Decision process:
1. Classify the hand: made hand, draw, blocker value, showdown value, vulnerability, and nut potential.
2. Read the board texture: paired/unpaired, wet/dry, high-card distribution, flush draws, straight draws, and which ranges are favored.
3. Reconstruct the full hand action line from preflop through the current street. Identify aggressors, callers, folds, delayed aggression, check-raises, donk bets, missed continuation bets, and whether the current bet is polarized or merged.
4. Compare price and risk: pot size, amount to call, current street bet, remaining stack, stack-to-pot ratio, fold equity, implied odds, reverse implied odds, and whether all-in pressure is credible.
5. Apply the style profile after the poker evaluation. Style changes frequencies and thresholds; it does not override legality, pot odds, board texture, or obvious hand strength.
6. Choose exactly one legal action. For bet, raise, or all-in, the amount is the acting player's total chips committed in the current betting round, not the added delta.

Public thinking requirement:
The `thinking` argument is not hidden chain-of-thought. It must be a concise public decision summary. Use this shape when possible:
`Hand: ...; Line: ...; Price: ...; Plan: ...`
Keep it short, concrete, and poker-specific. Mention visible cards, public action, price, and why the selected action fits. Do not write generic filler like "I should consider my options."

Output requirement:
Call `choose_poker_action` exactly once. Put the public decision summary in `thinking`, then choose `action`. Include `amount` only for bet, raise, or all-in. If a runtime cannot call tools, return exactly one compact JSON object with the same fields and no markdown fences.
'''
      .trim();
}

Map<String, Object> buildAiDecisionPayload(AiDecisionRequest request) {
  return <String, Object>{
    'role': 'texas_holdem_ai_player',
    'task':
        'First produce concise visible poker thinking, then choose exactly one legal action by calling choose_poker_action. Only runtimes without tool/function calling may return one compact JSON object.',
    'outputSchema': <String, Object>{
      'thinking':
          'public decision summary shaped like Hand: ...; Line: ...; Price: ...; Plan: ...; do not mention hidden cards you cannot see',
      'action': request.legalActions
          .map((LegalAction action) => action.type.name)
          .toList(),
      'amount': 'number of chips, only for bet, raise, or allIn',
    },
    'style': request.profile.toJson(),
    'state': request.snapshot.toJson(),
    'legalActions': request.legalActions
        .map(
          (LegalAction action) => <String, Object?>{
            'type': action.type.name,
            'minAmount': action.minAmount == null
                ? null
                : action.minAmount! / Chips.unit,
            'maxAmount': action.maxAmount == null
                ? null
                : action.maxAmount! / Chips.unit,
          },
        )
        .toList(),
    'rules': <String>[
      'Use only one action from legalActions.',
      'Return thinking before action.',
      'Prefer the choose_poker_action tool/function call over text output.',
      'For text fallback only: return exactly one compact JSON object and do not wrap it in markdown fences.',
      'Never invent hidden cards or assume folded player cards.',
      'For amount, output a numeric chip value such as 3.5, not a string.',
      'Do not mechanically call when facing a bet, and do not mechanically check when no bet is pending.',
      'First judge hand strength, draw equity, board texture, position, pot odds, stack depth, and recent betting pressure.',
      'If no bet is pending, choose between value bet, protection bet, bluff, semi-bluff, or check according to the style guide.',
      'If facing a bet or raise, choose between fold, call, raise, or all-in according to price, equity, blockers, and the style guide.',
      'Follow the style persona, concepts, tendencies, and streetStrategy so different AI seats make different choices.',
    ],
  };
}

String buildAiDecisionPrompt(
  AiDecisionRequest request, {
  AiPromptOptions options = const AiPromptOptions(),
  PokerFeatures? features,
}) {
  final AiVisibleSnapshot state = request.snapshot;
  final AiProfile style = request.profile;
  final StringBuffer buffer = StringBuffer()
    ..writeln('# Texas Holdem decision')
    ..writeln()
    ..writeln(
      'You are seat ${state.seatIndex}. Choose exactly one legal action.',
    )
    ..writeln(
      'First produce a concise public decision summary in `thinking`, then call `choose_poker_action`.',
    )
    ..writeln();
  if (options.compactStyle) {
    _writeCompactStyle(buffer, style);
  } else {
    _writeFullStyle(buffer, style);
  }
  buffer
    ..writeln('## Current visible state')
    ..writeln()
    ..writeln('- Hand: ${state.handNumber}')
    ..writeln('- Acting seat: ${state.seatIndex}')
    ..writeln('- Street: ${state.phase.name}')
    ..writeln(
      '- Blinds: ${Chips.format(state.smallBlind)}/${Chips.format(state.bigBlind)}',
    )
    ..writeln('- Pot: ${Chips.format(state.pot)}')
    ..writeln(
      '- Current street bet to match: ${Chips.format(state.currentBet)}',
    )
    ..writeln('- To call: ${Chips.format(state.toCall)}')
    ..writeln('- Board: ${_cards(state.board)}')
    ..writeln('- Your hole cards: ${_cards(state.holeCards)}')
    ..writeln()
    ..writeln('### Seats')
    ..writeln()
    ..writeln(
      '| Seat | Player | Kind | Stack | Street bet | Hand committed | State | Position |',
    )
    ..writeln('|---:|---|---|---:|---:|---:|---|---|');
  for (final AiSeatSnapshot seat in state.seats) {
    buffer.writeln(
      '| ${seat.index} | ${_cell(seat.name)} | ${seat.kind.name} | '
      '${Chips.format(seat.stack)} | ${Chips.format(seat.currentBet)} | '
      '${Chips.format(seat.totalCommitted)} | ${_seatState(seat)} | '
      '${_seatPosition(seat)} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('### Full hand action line')
    ..writeln();
  if (state.recentActions.isEmpty) {
    buffer.writeln('- No actions have been recorded yet.');
  } else {
    for (final String action in state.recentActions) {
      buffer.writeln('- $action');
    }
  }
  buffer.writeln();
  if (options.includeFacts) {
    final PokerFeatures facts =
        features ?? FeatureExtractor().extract(state, request.legalActions);
    buffer
      ..writeln(facts.toPromptSection(pot: state.pot, toCall: state.toCall))
      ..writeln();
    final String guide = aiDecisionGuideText(options.guide);
    if (guide.isNotEmpty) {
      buffer
        ..writeln(guide)
        ..writeln();
    }
  }
  buffer
    ..writeln('## Action space')
    ..writeln();
  buffer
    ..writeln('Use exactly one action from this JSON array:')
    ..writeln()
    ..writeln('```json')
    ..writeln(_legalActionsJson(request.legalActions))
    ..writeln('```');
  buffer
    ..writeln()
    ..writeln('## Rules')
    ..writeln()
    ..writeln('- Use only one action from the Action space JSON.')
    ..writeln(
      '- Return `thinking` before `action`; prefer `Hand: ...; Line: ...; Price: ...; Plan: ...`.',
    )
    ..writeln(
      '- Prefer the `choose_poker_action` tool/function call over text output.',
    )
    ..writeln(
      '- Text fallback only: return exactly one compact JSON object and do not wrap it in markdown fences.',
    )
    ..writeln('- Never invent hidden cards or assume folded player cards.')
    ..writeln(
      '- For `amount`, output a numeric chip value such as `3.5`, not a string.',
    )
    ..writeln(
      '- Amounts for bet, raise, and all-in are total chips committed by you in the current betting round, not the added delta.',
    )
    ..writeln(
      '- Do not mechanically call when facing a bet, and do not mechanically check when no bet is pending.',
    )
    ..writeln(
      '- First judge hand strength, draw equity, board texture, position, pot odds, stack depth, and the full hand action line.',
    )
    ..writeln(
      '- If no bet is pending, choose between value bet, protection bet, bluff, semi-bluff, or check according to the style guide.',
    )
    ..writeln(
      '- If facing a bet or raise, choose between fold, call, raise, or all-in according to price, equity, blockers, and the style guide.',
    )
    ..writeln(
      '- Follow the style persona, concepts, tendencies, and street strategy so different AI seats make different choices.',
    );
  return buffer.toString().trimRight();
}

void _writeCompactStyle(StringBuffer buffer, AiProfile style) {
  buffer
    ..writeln('## Style')
    ..writeln()
    ..writeln('- Persona: ${style.persona}')
    ..writeln(
      '- Tightness ${style.tightness}/100, aggression ${style.aggression}/100, '
      'bluff frequency ${style.bluffFrequency}/100, call tolerance ${style.callTolerance}/100.',
    )
    ..writeln(
      '- Style shifts frequencies at the margin; it never overrides equity, price, or hand strength.',
    )
    ..writeln();
}

void _writeFullStyle(StringBuffer buffer, AiProfile style) {
  buffer
    ..writeln('## Style')
    ..writeln()
    ..writeln('- ID: ${style.id}')
    ..writeln('- Name: ${style.name}')
    ..writeln('- Persona: ${style.persona}')
    ..writeln('- Tightness: ${style.tightness}')
    ..writeln('- Aggression: ${style.aggression}')
    ..writeln('- Bluff frequency: ${style.bluffFrequency}')
    ..writeln('- Call tolerance: ${style.callTolerance}')
    ..writeln('- Risk appetite: ${style.riskAppetite}')
    ..writeln('- Tilt resistance: ${style.tiltResistance}')
    ..writeln()
    ..writeln('### Concepts');
  for (final MapEntry<String, String> concept in style.styleConcepts.entries) {
    buffer.writeln('- ${_title(concept.key)}: ${concept.value}');
  }
  buffer
    ..writeln()
    ..writeln('### Tendencies');
  for (final String tendency in style.tendencies) {
    buffer.writeln('- $tendency');
  }
  buffer
    ..writeln()
    ..writeln('### Street strategy');
  for (final MapEntry<String, List<String>> street
      in style.streetStrategy.entries) {
    buffer.writeln('- ${_title(street.key)}: ${street.value.join(' ')}');
  }
  buffer.writeln();
}

String _title(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

String _cards(List<Object> cards) {
  if (cards.isEmpty) {
    return '(none)';
  }
  return cards.join(' ');
}

String _cell(String value) => value.replaceAll('|', r'\|');

String _seatState(AiSeatSnapshot seat) {
  if (seat.hasFolded) {
    return 'folded';
  }
  if (seat.isAllIn) {
    return 'all-in';
  }
  return 'active';
}

String _seatPosition(AiSeatSnapshot seat) {
  final List<String> labels = <String>[];
  if (seat.isDealer) {
    labels.add('dealer');
  }
  if (seat.isSmallBlind) {
    labels.add('small blind');
  }
  if (seat.isBigBlind) {
    labels.add('big blind');
  }
  return labels.isEmpty ? '-' : labels.join(', ');
}

String _legalActionsJson(List<LegalAction> legalActions) {
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(
    legalActions
        .map(
          (LegalAction action) => <String, Object?>{
            'type': action.type.name,
            'minAmount': _wholeChips(action.minAmount),
            'maxAmount': _wholeChips(action.maxAmount),
          },
        )
        .toList(growable: false),
  );
}

num? _wholeChips(int? amount) => amount == null ? null : amount / Chips.unit;
