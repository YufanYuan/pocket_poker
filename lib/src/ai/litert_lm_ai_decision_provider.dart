import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/money.dart';
import 'ai_decision_provider.dart';
import 'ai_prompt_builder.dart';
import 'heuristic_ai_decision_provider.dart';
import 'native_litert_lm.dart';

class LiteRtLmAiDecisionProvider implements AiDecisionProvider {
  LiteRtLmAiDecisionProvider({
    NativeLiteRtLm? native,
    AiDecisionProvider fallback = const HeuristicAiDecisionProvider(),
    this.timeout = const Duration(seconds: 60),
    this.invalidActionRetries = 1,
  }) : _native = native ?? NativeLiteRtLm(),
       _fallback = fallback;

  final NativeLiteRtLm _native;
  final AiDecisionProvider _fallback;
  final Duration timeout;
  final int invalidActionRetries;

  Future<LiteRtLmStatus> status() => _native.status();

  @override
  Future<AiDecision> decide(AiDecisionRequest request) async {
    final LiteRtLmStatus currentStatus = await _native.status();
    _liteRtLmDecisionLog(
      'status available=${currentStatus.available} '
      'runtime=${currentStatus.runtime} reason=${currentStatus.reason}',
    );
    if (!currentStatus.available) {
      throw StateError(
        'Local Gemma is not available: ${currentStatus.reason ?? 'LiteRT-LM runtime is not ready.'}',
      );
    }

    _liteRtLmDecisionLog(
      'decide hand=${request.snapshot.handNumber} '
      'seat=${request.snapshot.seatIndex} phase=${request.snapshot.phase.name} '
      'legal=${_legalActionsSummary(request.legalActions)}',
    );
    final String basePrompt = buildAiDecisionPrompt(request);
    LiteRtLmGeneration? lastResponse;
    final int attempts = invalidActionRetries < 0
        ? 1
        : invalidActionRetries + 1;
    for (int attempt = 1; attempt <= attempts; attempt += 1) {
      final LiteRtLmGeneration response = await _native.generate(
        prompt: attempt == 1
            ? basePrompt
            : _retryPrompt(basePrompt, request, lastResponse),
        timeout: timeout,
      );
      lastResponse = response;
      _liteRtLmDecisionLog(
        'response attempt=$attempt/$attempts source=${response.source} '
        'arguments=${response.arguments} text=${_preview(response.text)}',
      );
      final AiDecision? decision = response.isToolCall
          ? decisionFromModelArguments(
              response.arguments!,
              request.legalActions,
            )
          : decisionFromModelJson(response.text ?? '', request.legalActions);
      if (decision != null) {
        _liteRtLmDecisionLog(
          'accepted action=${_actionSummary(decision.action)} attempt=$attempt',
        );
        return AiDecision(
          decision.action,
          reason: response.isToolCall
              ? 'gemma-4-e2b-litert-lm-tool'
              : 'gemma-4-e2b-litert-lm-text-fallback',
          thinking: decision.thinking,
        );
      }
      _liteRtLmDecisionLog(
        'rejected invalid action attempt=$attempt/$attempts '
        'source=${response.source} legal=${_legalActionsSummary(request.legalActions)}',
      );
    }

    _liteRtLmDecisionLog(
      'falling back after invalid local responses '
      'legal=${_legalActionsSummary(request.legalActions)}',
    );
    final AiDecision fallback = await _fallback.decide(request);
    _liteRtLmDecisionLog(
      'fallback action=${_actionSummary(fallback.action)} '
      'reason=${fallback.reason}',
    );
    return AiDecision(
      fallback.action,
      reason: 'gemma-4-e2b-litert-lm-invalid-fallback:${fallback.reason}',
      thinking: fallback.thinking,
    );
  }
}

void _liteRtLmDecisionLog(String message) {
  if (kDebugMode) {
    debugPrint('[LiteRT-LM][decision] $message');
  }
}

String _legalActionsSummary(List<LegalAction> legalActions) {
  return legalActions
      .map((LegalAction action) {
        final String range = action.needsAmount
            ? '(${_chips(action.minAmount)}-${_chips(action.maxAmount)})'
            : '';
        return '${action.type.name}$range';
      })
      .join(',');
}

String _actionSummary(PokerAction action) {
  if (action.amount == null) {
    return action.type.name;
  }
  return '${action.type.name}:${Chips.format(action.amount!)}';
}

String _chips(int? amount) {
  if (amount == null) {
    return '?';
  }
  return Chips.format(amount);
}

String _preview(Object? value) {
  final String text = value.toString();
  if (text.length <= 300) {
    return text;
  }
  return '${text.substring(0, 300)}...';
}

String _retryPrompt(
  String basePrompt,
  AiDecisionRequest request,
  LiteRtLmGeneration? lastResponse,
) {
  return '$basePrompt\n\n'
      'The previous response could not be parsed or was not legal.\n'
      'Retry now. Choose exactly one legal action from: '
      '${_legalActionsSummary(request.legalActions)}.\n'
      'Return only a choose_poker_action tool call or a JSON object like '
      '{"thinking":"Hand: pair plus draw; Line: facing turn bet; Price: fair; Plan: call","action":"call"} with amount only when required.\n'
      'Previous response: ${_preview(lastResponse?.arguments ?? lastResponse?.text)}';
}
