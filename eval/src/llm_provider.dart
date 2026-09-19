import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine.dart';
import 'prompt_variants.dart';

/// Connection settings for any OpenAI-compatible chat endpoint.
///
/// Works with a local LiteLLM proxy (`http://localhost:4000/v1`) or with
/// OpenRouter (`https://openrouter.ai/api/v1`). Resolution order for each
/// field: explicit CLI flag, then environment variable, then default.
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 60),
    this.useTools = true,
    this.forceTool = true,
    this.temperature,
    this.maxTokens,
    this.thinking,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final bool useTools;
  final bool forceTool;
  final double? temperature;
  final int? maxTokens;

  /// DeepSeek-style reasoning switch: `enabled` or `disabled`. Null sends
  /// nothing. The official DeepSeek API rejects a forced `tool_choice` while
  /// thinking is on, so pass `disabled` to keep the app's forced-tool contract.
  final String? thinking;

  static String envBaseUrl() =>
      Platform.environment['POKER_EVAL_BASE_URL'] ??
      Platform.environment['LITELLM_BASE_URL'] ??
      'http://localhost:4000/v1';

  static String envApiKey() =>
      Platform.environment['POKER_EVAL_API_KEY'] ??
      Platform.environment['LITELLM_API_KEY'] ??
      Platform.environment['OPENROUTER_API_KEY'] ??
      '';

  static String envModel() =>
      Platform.environment['POKER_EVAL_MODEL'] ?? 'deepseek/deepseek-v4-flash';

  Uri get endpoint {
    final String base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/chat/completions');
  }
}

class LlmResponse {
  const LlmResponse({
    required this.statusCode,
    required this.latencyMs,
    this.content,
    this.toolArguments,
    this.promptTokens,
    this.completionTokens,
    this.error,
    this.raw,
  });

  final int statusCode;
  final int latencyMs;
  final String? content;
  final Map<String, Object?>? toolArguments;
  final int? promptTokens;
  final int? completionTokens;
  final String? error;
  final String? raw;
}

class LlmClient {
  LlmClient(this.config);

  final LlmConfig config;

  Future<LlmResponse> chat({
    required String system,
    required String user,
    required List<LegalAction> legalActions,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'model': config.model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': system},
        <String, String>{'role': 'user', 'content': user},
      ],
      'stream': false,
      if (config.temperature != null) 'temperature': config.temperature,
      if (config.maxTokens != null) 'max_tokens': config.maxTokens,
      if (config.thinking != null)
        'thinking': <String, String>{'type': config.thinking!},
      if (config.useTools) 'tools': <Object>[_toolDefinition(legalActions)],
      if (config.useTools && config.forceTool)
        'tool_choice': <String, Object>{
          'type': 'function',
          'function': <String, String>{'name': 'choose_poker_action'},
        },
    };
    final Stopwatch sw = Stopwatch()..start();
    final HttpClient client = HttpClient()..connectionTimeout = config.timeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(config.endpoint)
          .timeout(config.timeout);
      request.headers.set('Content-Type', 'application/json');
      if (config.apiKey.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer ${config.apiKey}');
      }
      request.headers.set('HTTP-Referer', 'https://local.poker-ai');
      request.headers.set('X-Title', 'Poker AI eval');
      request.write(jsonEncode(body));
      final HttpClientResponse response = await request.close().timeout(config.timeout);
      final String raw = await response
          .transform(utf8.decoder)
          .join()
          .timeout(config.timeout);
      sw.stop();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return LlmResponse(
          statusCode: response.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          error: 'HTTP ${response.statusCode}: ${_preview(raw)}',
          raw: raw,
        );
      }
      return _parse(raw, response.statusCode, sw.elapsedMilliseconds);
    } on TimeoutException {
      return LlmResponse(
        statusCode: 0,
        latencyMs: sw.elapsedMilliseconds,
        error: 'timeout after ${config.timeout.inSeconds}s',
      );
    } on Object catch (e) {
      return LlmResponse(
        statusCode: 0,
        latencyMs: sw.elapsedMilliseconds,
        error: 'transport: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  LlmResponse _parse(String raw, int status, int latencyMs) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return LlmResponse(statusCode: status, latencyMs: latencyMs, error: 'non-JSON body', raw: raw);
    }
    if (decoded is! Map<String, Object?>) {
      return LlmResponse(statusCode: status, latencyMs: latencyMs, error: 'unexpected body', raw: raw);
    }
    final Map<String, Object?>? usage = decoded['usage'] as Map<String, Object?>?;
    final List<Object?>? choices = decoded['choices'] as List<Object?>?;
    if (choices == null || choices.isEmpty) {
      return LlmResponse(
        statusCode: status,
        latencyMs: latencyMs,
        error: 'no choices: ${_preview(raw)}',
        raw: raw,
      );
    }
    final Map<String, Object?> message =
        (choices.first as Map<String, Object?>)['message'] as Map<String, Object?>? ??
        <String, Object?>{};
    Map<String, Object?>? toolArgs;
    final Object? toolCalls = message['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      for (final Object? call in toolCalls) {
        final Object? fn = (call as Map<String, Object?>?)?['function'];
        if (fn is! Map<String, Object?>) {
          continue;
        }
        final Object? args = fn['arguments'];
        if (args is Map<String, Object?>) {
          toolArgs = args;
        } else if (args is String) {
          try {
            final Object? parsed = jsonDecode(args);
            if (parsed is Map<String, Object?>) {
              toolArgs = parsed;
            }
          } on FormatException {
            toolArgs = <String, Object?>{'_unparsed': args};
          }
        }
        if (toolArgs != null) {
          break;
        }
      }
    }
    String? content;
    final Object? c = message['content'];
    if (c is String) {
      content = c;
    } else if (c is List) {
      content = c
          .whereType<Map<String, Object?>>()
          .where((Map<String, Object?> p) => p['type'] == 'text')
          .map((Map<String, Object?> p) => p['text'])
          .join();
    }
    return LlmResponse(
      statusCode: status,
      latencyMs: latencyMs,
      content: content,
      toolArguments: toolArgs,
      promptTokens: (usage?['prompt_tokens'] as num?)?.toInt(),
      completionTokens: (usage?['completion_tokens'] as num?)?.toInt(),
      raw: raw,
    );
  }

  static Map<String, Object> _toolDefinition(List<LegalAction> legal) {
    return <String, Object>{
      'type': 'function',
      'function': <String, Object>{
        'name': 'choose_poker_action',
        'description':
            'Explain concise poker thinking, then choose exactly one legal Texas Holdem poker action.',
        'parameters': <String, Object>{
          'type': 'object',
          'properties': <String, Object>{
            'thinking': <String, Object>{
              'type': 'string',
              'description':
                  'Concise public decision summary before action, based only on visible state and legal actions. Prefer: Hand: ...; Line: ...; Price: ...; Plan: ....',
            },
            'action': <String, Object>{
              'type': 'string',
              'enum': legal.map((LegalAction a) => a.type.name).toList(growable: false),
              'description': 'One action from the current legal action list.',
            },
            'amount': <String, Object>{
              'type': 'number',
              'description':
                  'Total chip amount for bet, raise, or allIn. Omit for fold, check, and call.',
            },
          },
          'required': <String>['thinking', 'action'],
          'additionalProperties': false,
        },
      },
    };
  }

  static String _preview(String s) => s.length > 300 ? '${s.substring(0, 300)}...' : s;
}

/// What happened when a model was asked for one decision.
class DecisionOutcome {
  const DecisionOutcome({
    required this.status,
    required this.attempts,
    required this.latencyMs,
    this.action,
    this.thinking,
    this.clamped = false,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.failure,
    this.rawArguments,
    this.rawContent,
    this.prompt,
  });

  /// `valid` (strict parse), `clamped` (needed repair), `invalid` (no usable
  /// action), or `error` (transport/HTTP failure).
  final String status;
  final int attempts;
  final int latencyMs;
  final PokerAction? action;
  final String? thinking;
  final bool clamped;
  final int promptTokens;
  final int completionTokens;
  final String? failure;
  final Map<String, Object?>? rawArguments;
  final String? rawContent;
  final String? prompt;

  bool get usable => action != null;
}

/// Asks an LLM for a decision using one [PromptVariant], with optional
/// amount clamping and invalid-output retries.
class LlmDecisionProvider {
  LlmDecisionProvider({
    required this.client,
    required this.variant,
    this.clamp = false,
    this.retries = 0,
    FeatureExtractor? extractor,
  }) : _extractor = extractor ?? FeatureExtractor();

  final LlmClient client;
  final PromptVariant variant;
  final bool clamp;
  final int retries;
  final FeatureExtractor _extractor;

  Future<DecisionOutcome> decide(
    AiDecisionRequest request, {
    PokerFeatures? features,
  }) async {
    final PokerFeatures? f = variant.needsFeatures
        ? (features ?? _extractor.extract(request.snapshot, request.legalActions))
        : features;
    final String basePrompt = variant.build(request, f);
    final String system = buildAiDecisionSystemPrompt();
    int promptTokens = 0;
    int completionTokens = 0;
    int latency = 0;
    String? lastFailure;
    Map<String, Object?>? lastArgs;
    String? lastContent;
    for (int attempt = 1; attempt <= retries + 1; attempt += 1) {
      final String prompt = attempt == 1
          ? basePrompt
          : '$basePrompt\n\n## Retry\n\nThe previous response was not a legal action ($lastFailure). '
                'Choose exactly one action from the Action space and, for bet/raise/allIn, an amount inside its range.';
      final LlmResponse r = await client.chat(
        system: system,
        user: prompt,
        legalActions: request.legalActions,
      );
      promptTokens += r.promptTokens ?? 0;
      completionTokens += r.completionTokens ?? 0;
      latency += r.latencyMs;
      if (r.error != null) {
        return DecisionOutcome(
          status: 'error',
          attempts: attempt,
          latencyMs: latency,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          failure: r.error,
          prompt: prompt,
        );
      }
      lastArgs = r.toolArguments;
      lastContent = r.content;
      final ParsedDecision parsed = parseDecision(
        r.toolArguments,
        r.content,
        request.legalActions,
        clamp: clamp,
      );
      if (parsed.action != null) {
        return DecisionOutcome(
          status: parsed.clamped ? 'clamped' : 'valid',
          attempts: attempt,
          latencyMs: latency,
          action: parsed.action,
          thinking: parsed.thinking,
          clamped: parsed.clamped,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          failure: parsed.clamped ? parsed.failure : null,
          rawArguments: r.toolArguments,
          rawContent: r.content,
          prompt: prompt,
        );
      }
      lastFailure = parsed.failure;
    }
    return DecisionOutcome(
      status: 'invalid',
      attempts: retries + 1,
      latencyMs: latency,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      failure: lastFailure,
      rawArguments: lastArgs,
      rawContent: lastContent,
      prompt: basePrompt,
    );
  }
}

class ParsedDecision {
  const ParsedDecision({this.action, this.thinking, this.clamped = false, this.failure});

  final PokerAction? action;
  final String? thinking;
  final bool clamped;
  final String? failure;
}

/// Strict parse first (exactly what the app accepts today); with [clamp],
/// repair the common failure modes instead of discarding the decision.
ParsedDecision parseDecision(
  Map<String, Object?>? toolArguments,
  String? content,
  List<LegalAction> legal, {
  required bool clamp,
}) {
  Map<String, Object?>? args = toolArguments;
  if (args == null && content != null) {
    final String? json = _extractJsonObject(content);
    if (json != null) {
      try {
        final Object? decoded = jsonDecode(json);
        if (decoded is Map<String, Object?>) {
          args = decoded;
        }
      } on FormatException {
        args = null;
      }
    }
    args ??= _looseArguments(content);
  }
  if (args == null) {
    return const ParsedDecision(failure: 'no tool call or JSON object in response');
  }
  final AiDecision? strict = decisionFromModelArguments(args, legal);
  if (strict != null) {
    return ParsedDecision(action: strict.action, thinking: strict.thinking);
  }
  final String? thinking = args['thinking']?.toString();
  final String actionText = (args['action'] ?? '').toString().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
  PokerActionType? type = switch (actionText) {
    'fold' => PokerActionType.fold,
    'check' => PokerActionType.check,
    'call' => PokerActionType.call,
    'bet' => PokerActionType.bet,
    'raise' || 'raiseto' || 'reraise' => PokerActionType.raise,
    'allin' || 'shove' || 'push' || 'jam' => PokerActionType.allIn,
    _ => null,
  };
  if (type == null) {
    return ParsedDecision(thinking: thinking, failure: 'unknown action "${args['action']}"');
  }
  final Set<PokerActionType> legalTypes = legal.map((LegalAction l) => l.type).toSet();
  final num? amount = _number(args['amount']);
  String failure = '';
  if (!legalTypes.contains(type)) {
    if (!clamp) {
      return ParsedDecision(thinking: thinking, failure: 'action ${type.name} is not legal');
    }
    // Repair verb confusion: bet<->raise, call<->check.
    final PokerActionType? swapped = switch (type) {
      PokerActionType.bet when legalTypes.contains(PokerActionType.raise) => PokerActionType.raise,
      PokerActionType.raise when legalTypes.contains(PokerActionType.bet) => PokerActionType.bet,
      PokerActionType.call when legalTypes.contains(PokerActionType.check) => PokerActionType.check,
      PokerActionType.check when legalTypes.contains(PokerActionType.call) => PokerActionType.call,
      _ => null,
    };
    if (swapped == null) {
      return ParsedDecision(thinking: thinking, failure: 'action ${type.name} is not legal');
    }
    failure = 'mapped ${type.name} to ${swapped.name}';
    type = swapped;
  }
  final LegalAction la = legal.firstWhere((LegalAction l) => l.type == type);
  if (!la.needsAmount) {
    return ParsedDecision(action: PokerAction(type), thinking: thinking, clamped: failure.isNotEmpty, failure: failure);
  }
  if (type == PokerActionType.allIn) {
    return ParsedDecision(
      action: PokerAction(type, amount: la.maxAmount),
      thinking: thinking,
      clamped: failure.isNotEmpty,
      failure: failure,
    );
  }
  if (amount == null) {
    if (!clamp) {
      return ParsedDecision(thinking: thinking, failure: '${type.name} without amount');
    }
    return ParsedDecision(
      action: PokerAction(type, amount: la.minAmount),
      thinking: thinking,
      clamped: true,
      failure: '${failure.isEmpty ? '' : '$failure; '}missing amount -> min',
    );
  }
  final int chips = Chips.fromWhole(amount);
  if (la.minAmount != null && chips < la.minAmount!) {
    if (!clamp) {
      return ParsedDecision(thinking: thinking, failure: 'amount ${Chips.format(chips)} below min ${Chips.format(la.minAmount!)}');
    }
    return ParsedDecision(
      action: PokerAction(type, amount: la.minAmount),
      thinking: thinking,
      clamped: true,
      failure: '${failure.isEmpty ? '' : '$failure; '}amount ${Chips.format(chips)} below min ${Chips.format(la.minAmount!)}',
    );
  }
  if (la.maxAmount != null && chips > la.maxAmount!) {
    if (!clamp) {
      return ParsedDecision(thinking: thinking, failure: 'amount ${Chips.format(chips)} above max ${Chips.format(la.maxAmount!)}');
    }
    return ParsedDecision(
      action: PokerAction(type, amount: la.maxAmount),
      thinking: thinking,
      clamped: true,
      failure: '${failure.isEmpty ? '' : '$failure; '}amount ${Chips.format(chips)} above max ${Chips.format(la.maxAmount!)}',
    );
  }
  return ParsedDecision(
    action: PokerAction(type, amount: chips),
    thinking: thinking,
    clamped: failure.isNotEmpty,
    failure: failure.isEmpty ? null : failure,
  );
}

num? _number(Object? v) {
  if (v is num) {
    return v;
  }
  if (v is String) {
    return num.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }
  return null;
}

Map<String, Object?>? _looseArguments(String source) {
  final RegExpMatch? action = RegExp(
    r'''\baction\s*[:=]\s*("[^"]*"|'[^']*'|[^,})\s]+)''',
    caseSensitive: false,
  ).firstMatch(source);
  if (action == null) {
    return null;
  }
  String strip(String s) => s.replaceAll(RegExp('''^["']|["']\$'''), '');
  final RegExpMatch? amount = RegExp(
    r'''\bamount\s*[:=]\s*("[^"]*"|'[^']*'|[^,})\s]+)''',
    caseSensitive: false,
  ).firstMatch(source);
  return <String, Object?>{
    'action': strip(action.group(1)!),
    if (amount != null) 'amount': strip(amount.group(1)!),
  };
}

String? _extractJsonObject(String source) {
  final int start = source.indexOf('{');
  if (start < 0) {
    return null;
  }
  int depth = 0;
  bool inString = false;
  bool escaping = false;
  for (int i = start; i < source.length; i += 1) {
    final String ch = source[i];
    if (escaping) {
      escaping = false;
      continue;
    }
    if (ch == r'\') {
      escaping = inString;
      continue;
    }
    if (ch == '"') {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (ch == '{') {
      depth += 1;
    } else if (ch == '}') {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  return null;
}
