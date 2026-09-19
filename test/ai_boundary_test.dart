import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ai/src/ai/ai_decision_provider.dart';
import 'package:poker_ai/src/ai/heuristic_ai_decision_provider.dart';
import 'package:poker_ai/src/ai/ai_prompt_builder.dart';
import 'package:poker_ai/src/ai/litert_lm_ai_decision_provider.dart';
import 'package:poker_ai/src/ai/native_litert_lm.dart';
import 'package:poker_ai/src/ai/openrouter_ai_decision_provider.dart';
import 'package:poker_ai/src/domain/models.dart';
import 'package:poker_ai/src/domain/money.dart';
import 'package:poker_ai/src/domain/poker_game.dart';

void main() {
  test('AI snapshot does not expose other players hidden cards', () {
    final PokerGame game = PokerGame(config: config(), seed: 8);
    final AiVisibleSnapshot snapshot = game.visibleSnapshotFor(1);
    final String json = snapshot.toCompactJson();

    for (final hiddenCard in game.humanPlayer.holeCards) {
      expect(json.contains(hiddenCard.label), isFalse);
    }
    for (final ownCard in game.players[1].holeCards) {
      expect(json.contains(ownCard.label), isTrue);
    }
  });

  test('AI snapshot includes the full current hand action line', () {
    final PokerGame game = PokerGame(config: config(), seed: 8);
    game.actionLog.add(
      ActionHistoryEntry(
        handNumber: game.handNumber - 1,
        phase: BettingPhase.river,
        playerName: 'Hero',
        action: PokerActionType.bet,
        amount: Chips.fromWhole(12),
        stackAfter: Chips.fromWhole(88),
      ),
    );
    for (int i = 0; i < 10; i += 1) {
      game.actionLog.add(
        ActionHistoryEntry(
          handNumber: game.handNumber,
          phase: i < 4 ? BettingPhase.preflop : BettingPhase.flop,
          playerName: 'AI ${i % 5 + 1}',
          action: i.isEven ? PokerActionType.call : PokerActionType.raise,
          amount: Chips.fromWhole(i + 1),
          stackAfter: Chips.fromWhole(100 - i),
        ),
      );
    }

    final AiVisibleSnapshot snapshot = game.visibleSnapshotFor(1);

    expect(snapshot.recentActions, hasLength(10));
    expect(snapshot.recentActions.first, contains('Hand ${game.handNumber}'));
    expect(snapshot.recentActions.first, contains('AI 1 call 1'));
    expect(snapshot.recentActions.last, contains('AI 5 raise 10'));
    expect(snapshot.recentActions.join('\n'), isNot(contains('Hero bet 12')));
  });

  test('AI decision prompt is markdown for model readability', () {
    final PokerGame game = PokerGame(config: config(), seed: 19);
    final String prompt = buildAiDecisionPrompt(
      AiDecisionRequest(
        snapshot: game.visibleSnapshotFor(1),
        profile: game.players[1].profile!,
        legalActions: game.legalActionsForCurrentPlayer(),
      ),
    );

    expect(prompt, startsWith('# Texas Holdem decision'));
    expect(prompt, contains('## Current visible state'));
    expect(prompt, contains('### Full hand action line'));
    expect(prompt, contains('## Action space'));
    expect(prompt, contains('```json'));
    expect(prompt, contains('"type"'));
    expect(buildAiDecisionSystemPrompt(), contains('Decision process'));
    expect(buildAiDecisionSystemPrompt(), contains('Hand: ...; Line: ...'));
    expect(prompt.trimLeft(), isNot(startsWith('{')));
  });

  test('AI decision prompt ships engine facts and the ordered guide', () {
    final PokerGame game = PokerGame(config: config(), seed: 19);
    final AiDecisionRequest request = AiDecisionRequest(
      snapshot: game.visibleSnapshotFor(1),
      profile: game.players[1].profile!,
      legalActions: game.legalActionsForCurrentPlayer(),
    );

    final String shipped = buildAiDecisionPrompt(request);
    expect(shipped, contains('## Engine-computed poker facts'));
    expect(shipped, contains('Equity versus'));
    expect(shipped, contains('Decide in this order:'));
    expect(shipped, contains('- Persona:'));
    expect(shipped, isNot(contains('### Street strategy')));
    expect(
      shipped.indexOf('## Engine-computed poker facts'),
      lessThan(shipped.indexOf('## Action space')),
    );

    final String legacy = buildAiDecisionPrompt(
      request,
      options: const AiPromptOptions.legacy(),
    );
    expect(legacy, isNot(contains('## Engine-computed poker facts')));
    expect(legacy, isNot(contains('## Decision guide')));
    expect(legacy, contains('### Street strategy'));
  });

  test('invalid model action json is rejected before reaching the engine', () {
    final List<LegalAction> legal = <LegalAction>[
      const LegalAction(type: PokerActionType.fold),
      const LegalAction(type: PokerActionType.call),
    ];

    expect(
      actionFromModelArguments(<String, Object?>{
        'action': 'call',
      }, legal)?.type,
      PokerActionType.call,
    );
    expect(
      actionFromModelJson('{"action":"raise","amount":10}', legal),
      isNull,
    );
    expect(
      actionFromModelJson('{"action":"call"}', legal)?.type,
      PokerActionType.call,
    );
    final AiDecision? decision = decisionFromModelJson(
      '{"thinking":"priced in","action":"call"}',
      legal,
    );
    expect(decision?.thinking, 'priced in');
    expect(decision?.action.type, PokerActionType.call);
    expect(
      actionFromModelJson('```json\n{"action":"call"}\n```', legal)?.type,
      PokerActionType.call,
    );
    expect(actionFromModelJson('I would call.', legal), isNull);
  });

  test('LiteRT-LM tool call sentinels are ignored in arguments', () {
    final List<LegalAction> legal = <LegalAction>[
      const LegalAction(type: PokerActionType.fold),
      const LegalAction(type: PokerActionType.check),
      const LegalAction(type: PokerActionType.call),
      LegalAction(
        type: PokerActionType.raise,
        minAmount: Chips.fromWhole(10),
        maxAmount: Chips.fromWhole(40),
      ),
      LegalAction(
        type: PokerActionType.allIn,
        minAmount: Chips.fromWhole(40),
        maxAmount: Chips.fromWhole(40),
      ),
    ];

    final PokerAction? call = actionFromModelArguments(<String, Object?>{
      'action': '<|"|>call<|"|>',
    }, legal);
    expect(call?.type, PokerActionType.call);

    final PokerAction? raise = actionFromModelArguments(<String, Object?>{
      'action': '<|"|>raise<|"|>',
      'amount': '<|"|>10<|"|>',
    }, legal);
    expect(raise?.type, PokerActionType.raise);
    expect(raise?.amount, Chips.fromWhole(10));

    final LiteRtLmGeneration generation = LiteRtLmGeneration.fromResult(
      <Object?, Object?>{
        'source': 'tool_call',
        'arguments': <Object?, Object?>{'action': '<|"|>call<|"|>'},
      },
    );
    expect(generation.arguments?['action'], 'call');

    expect(
      actionFromModelJson(
        'choose_poker_action{action:<|"|>check<|"|>}',
        legal,
      )?.type,
      PokerActionType.check,
    );
    final PokerAction? allIn = actionFromModelArguments(<String, Object?>{
      'action': 'all-in',
    }, legal);
    expect(allIn?.type, PokerActionType.allIn);
    expect(allIn?.amount, Chips.fromWhole(40));
  });

  test('LiteRT-LM provider retries invalid generations', () async {
    final _FakeNativeLiteRtLm native = _FakeNativeLiteRtLm(<LiteRtLmGeneration>[
      const LiteRtLmGeneration(source: 'text', text: 'not a poker action'),
      const LiteRtLmGeneration(
        source: 'tool_call',
        arguments: <String, Object?>{'action': 'call'},
      ),
    ]);
    final PokerGame game = PokerGame(config: config(), seed: 17);
    final LiteRtLmAiDecisionProvider provider = LiteRtLmAiDecisionProvider(
      native: native,
      invalidActionRetries: 1,
      fallback: const _StaticAiDecisionProvider(
        PokerAction(PokerActionType.fold),
      ),
    );

    final AiDecision decision = await provider.decide(
      AiDecisionRequest(
        snapshot: game.visibleSnapshotFor(game.currentPlayerIndex),
        profile: AiProfile.presets.first,
        legalActions: <LegalAction>[
          const LegalAction(type: PokerActionType.fold),
          const LegalAction(type: PokerActionType.call),
        ],
      ),
    );

    expect(decision.action.type, PokerActionType.call);
    expect(native.generateCalls, 2);
  });

  test('AI decision prompt includes readable profile guidance', () {
    final PokerGame game = PokerGame(config: config(), seed: 19);
    final AiProfile profile = game.players[1].profile!;
    final Map<String, Object> payload = buildAiDecisionPayload(
      AiDecisionRequest(
        snapshot: game.visibleSnapshotFor(1),
        profile: profile,
        legalActions: game.legalActionsForCurrentPlayer(),
      ),
    );

    final Map<String, Object> style = payload['style'] as Map<String, Object>;
    expect(style['id'], profile.id);
    expect(style['persona'], isA<String>());
    expect(style['persona'] as String, contains(profile.name));
    expect(style['concepts'], isA<Map<String, Object>>());
    final Map<String, Object> concepts =
        style['concepts'] as Map<String, Object>;
    expect(concepts['tightness'] as String, contains('Tight players'));
    expect(concepts['aggression'] as String, contains('Aggressive players'));
    expect(style['tendencies'], isA<List<String>>());
    expect(style['tendencies'] as List<String>, hasLength(5));
    expect(style['streetStrategy'], isA<Map<String, Object>>());
    final Map<String, Object> streetStrategy =
        style['streetStrategy'] as Map<String, Object>;
    expect(
      streetStrategy.keys,
      containsAll(<String>['preflop', 'flop', 'turn', 'river']),
    );
    expect(
      payload['rules'] as List<String>,
      contains(
        'Follow the style persona, concepts, tendencies, and streetStrategy so different AI seats make different choices.',
      ),
    );
    expect(
      payload['rules'] as List<String>,
      contains(
        'Do not mechanically call when facing a bet, and do not mechanically check when no bet is pending.',
      ),
    );
  });

  test('heuristic provider always returns one legal action', () async {
    final PokerGame game = PokerGame(config: config(), seed: 11);
    final List<LegalAction> legal = game.legalActionsForCurrentPlayer();
    final AiDecision decision = await const HeuristicAiDecisionProvider()
        .decide(
          AiDecisionRequest(
            snapshot: game.visibleSnapshotFor(game.currentPlayerIndex),
            profile: AiProfile.presets.first,
            legalActions: legal,
          ),
        );

    expect(
      legal.map((LegalAction action) => action.type),
      contains(decision.action.type),
    );
  });

  test(
    'OpenRouter provider validates returned action against legal actions',
    () async {
      final PokerGame game = PokerGame(config: config(), seed: 13);
      final OpenRouterAiDecisionProvider
      provider = OpenRouterAiDecisionProvider(
        model: 'google/gemini-2.5-flash',
        apiKey: 'test-key',
        post:
            (
              Uri uri,
              Map<String, String> headers,
              String body,
              Duration timeout,
            ) async {
              expect(uri.host, 'openrouter.ai');
              expect(headers['Authorization'], 'Bearer test-key');
              expect(body, contains('"model":"google/gemini-2.5-flash"'));
              expect(body, contains('"tools"'));
              expect(body, contains('"choose_poker_action"'));
              expect(body, contains('"thinking"'));
              expect(body, contains('Decision process'));
              expect(body, contains('Hand: ...; Line: ...'));
              expect(body, isNot(contains('"temperature"')));
              expect(body, isNot(contains('"max_completion_tokens"')));
              return const OpenRouterResponse(
                statusCode: 200,
                body:
                    '{"choices":[{"message":{"tool_calls":[{"type":"function","function":{"name":"choose_poker_action","arguments":"{\\"thinking\\":\\"pot odds are fair\\",\\"action\\":\\"call\\"}"}}]}}]}',
              );
            },
      );

      final AiDecision decision = await provider.decide(
        AiDecisionRequest(
          snapshot: game.visibleSnapshotFor(game.currentPlayerIndex),
          profile: AiProfile.presets.first,
          legalActions: game.legalActionsForCurrentPlayer(),
        ),
      );

      expect(decision.action.type, PokerActionType.call);
      expect(decision.thinking, 'pot odds are fair');
    },
  );
}

class _FakeNativeLiteRtLm extends NativeLiteRtLm {
  _FakeNativeLiteRtLm(this.generations);

  final List<LiteRtLmGeneration> generations;
  int generateCalls = 0;

  @override
  Future<LiteRtLmStatus> status() async {
    return const LiteRtLmStatus(
      available: true,
      runtime: 'fake',
      reason: 'ready',
    );
  }

  @override
  Future<LiteRtLmGeneration> generate({
    required String prompt,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final LiteRtLmGeneration generation = generations[generateCalls];
    generateCalls += 1;
    return generation;
  }
}

class _StaticAiDecisionProvider implements AiDecisionProvider {
  const _StaticAiDecisionProvider(this.action);

  final PokerAction action;

  @override
  Future<AiDecision> decide(AiDecisionRequest request) async {
    return AiDecision(action, reason: 'static');
  }
}

TableConfig config() {
  return TableConfig(
    humanName: 'Hero',
    seatCount: 3,
    minBuyIn: Chips.fromWhole(40),
    maxBuyIn: Chips.fromWhole(200),
    startingStack: Chips.fromWhole(100),
  );
}
