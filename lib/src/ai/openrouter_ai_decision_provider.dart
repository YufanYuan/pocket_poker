import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'ai_decision_provider.dart';
import 'ai_prompt_builder.dart';
import 'heuristic_ai_decision_provider.dart';

typedef OpenRouterPost =
    Future<OpenRouterResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
      Duration timeout,
    );

class OpenRouterResponse {
  const OpenRouterResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class OpenRouterConfig {
  static const String defaultModel = 'openrouter/free';

  static const List<String> modelPresets = <String>[
    'openrouter/free',
    '~moonshotai/kimi-latest',
    'moonshotai/kimi-k2.6',
    'minimax/minimax-m2.7',
    'z-ai/glm-5.1',
    '~google/gemini-pro-latest',
    '~google/gemini-flash-latest',
    'google/gemini-3.1-flash-lite',
    'google/gemini-3.1-pro-preview',
    '~openai/gpt-latest',
    'openai/gpt-chat-latest',
    'openai/gpt-5.5-pro',
    'openai/gpt-5.5',
    'deepseek/deepseek-v4-pro',
    'deepseek/deepseek-v4-flash',
    '~anthropic/claude-opus-latest',
    '~anthropic/claude-sonnet-latest',
    'anthropic/claude-opus-4.7',
  ];

  static String apiKeyFromEnvironment() {
    const String dartDefineKey = String.fromEnvironment('OPENROUTER_API_KEY');
    if (dartDefineKey.isNotEmpty) {
      return dartDefineKey;
    }
    return Platform.environment['OPENROUTER_API_KEY'] ?? '';
  }

  static bool get hasEnvironmentApiKey =>
      apiKeyFromEnvironment().trim().isNotEmpty;
}

class OpenRouterAiDecisionProvider implements AiDecisionProvider {
  OpenRouterAiDecisionProvider({
    required this.model,
    String? apiKey,
    Uri? endpoint,
    OpenRouterPost? post,
    AiDecisionProvider fallback = const HeuristicAiDecisionProvider(),
    this.timeout = const Duration(seconds: 15),
  }) : _apiKey = apiKey?.trim().isNotEmpty == true
           ? apiKey!
           : OpenRouterConfig.apiKeyFromEnvironment(),
       _endpoint =
           endpoint ??
           Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
       _post = post ?? _defaultPost,
       _fallback = fallback;

  final String model;
  final String _apiKey;
  final Uri _endpoint;
  final OpenRouterPost _post;
  final AiDecisionProvider _fallback;
  final Duration timeout;

  bool get isConfigured => _apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  @override
  Future<AiDecision> decide(AiDecisionRequest request) async {
    if (!isConfigured) {
      return _fallback.decide(request);
    }

    try {
      final OpenRouterResponse response = await _post(
        _endpoint,
        <String, String>{
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://local.poker-ai',
          'X-Title': 'Poker AI',
        },
        jsonEncode(_requestBody(request)),
        timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _fallback.decide(request);
      }
      final AiDecision? toolDecision = _extractToolDecision(
        response.body,
        request.legalActions,
      );
      if (toolDecision != null) {
        return AiDecision(
          toolDecision.action,
          reason: 'openrouter-tool:$model',
          thinking: toolDecision.thinking,
        );
      }
      final String? content = _extractContent(response.body);
      if (content == null) {
        return _fallback.decide(request);
      }
      final AiDecision? decision = decisionFromModelJson(
        content,
        request.legalActions,
      );
      if (decision != null) {
        return AiDecision(
          decision.action,
          reason: 'openrouter:$model',
          thinking: decision.thinking,
        );
      }
    } on Object {
      return _fallback.decide(request);
    }
    return _fallback.decide(request);
  }

  Map<String, Object> _requestBody(AiDecisionRequest request) {
    return <String, Object>{
      'model': model.trim(),
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': buildAiDecisionSystemPrompt(),
        },
        <String, String>{
          'role': 'user',
          'content': buildAiDecisionPrompt(request),
        },
      ],
      'tools': <Map<String, Object>>[_toolDefinition(request.legalActions)],
      'tool_choice': <String, Object>{
        'type': 'function',
        'function': <String, String>{'name': 'choose_poker_action'},
      },
      'stream': false,
    };
  }

  Map<String, Object> _toolDefinition(List<LegalAction> legalActions) {
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
              'enum': legalActions
                  .map((LegalAction action) => action.type.name)
                  .toList(growable: false),
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

  AiDecision? _extractToolDecision(
    String responseBody,
    List<LegalAction> legalActions,
  ) {
    final Object? decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final Object? choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }
    final Object? first = choices.first;
    if (first is! Map<String, Object?>) {
      return null;
    }
    final Object? message = first['message'];
    if (message is! Map<String, Object?>) {
      return null;
    }
    final Object? toolCalls = message['tool_calls'] ?? message['toolCalls'];
    if (toolCalls is! List || toolCalls.isEmpty) {
      return null;
    }
    for (final Object? call in toolCalls) {
      if (call is! Map<String, Object?>) {
        continue;
      }
      final Object? function = call['function'];
      if (function is! Map<String, Object?>) {
        continue;
      }
      if (function['name'] != 'choose_poker_action') {
        continue;
      }
      final Object? arguments = function['arguments'];
      final AiDecision? decision = _decisionFromToolArguments(
        arguments,
        legalActions,
      );
      if (decision != null) {
        return decision;
      }
    }
    return null;
  }

  AiDecision? _decisionFromToolArguments(
    Object? arguments,
    List<LegalAction> legalActions,
  ) {
    if (arguments is String) {
      try {
        final Object? decoded = jsonDecode(arguments);
        if (decoded is Map<String, Object?>) {
          return decisionFromModelArguments(decoded, legalActions);
        }
      } on FormatException {
        return null;
      }
    }
    if (arguments is Map<String, Object?>) {
      return decisionFromModelArguments(arguments, legalActions);
    }
    return null;
  }

  String? _extractContent(String responseBody) {
    final Object? decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final Object? choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }
    final Object? first = choices.first;
    if (first is! Map<String, Object?>) {
      return null;
    }
    final Object? message = first['message'];
    if (message is! Map<String, Object?>) {
      return null;
    }
    final Object? content = message['content'];
    if (content is String) {
      return content;
    }
    if (content is List) {
      final StringBuffer buffer = StringBuffer();
      for (final Object? part in content) {
        if (part is Map<String, Object?> &&
            part['type'] == 'text' &&
            part['text'] is String) {
          buffer.write(part['text']);
        }
      }
      final String text = buffer.toString();
      return text.isEmpty ? null : text;
    }
    return null;
  }

  static Future<OpenRouterResponse> _defaultPost(
    Uri uri,
    Map<String, String> headers,
    String body,
    Duration timeout,
  ) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(uri)
          .timeout(timeout);
      headers.forEach(request.headers.set);
      request.write(body);
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return OpenRouterResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } finally {
      client.close(force: true);
    }
  }
}
