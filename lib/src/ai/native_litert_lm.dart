import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'ai_prompt_builder.dart';

class LiteRtLmStatus {
  const LiteRtLmStatus({
    required this.available,
    required this.runtime,
    this.modelPath,
    this.modelVersion,
    this.checksum,
    this.reason,
  });

  final bool available;
  final String runtime;
  final String? modelPath;
  final String? modelVersion;
  final String? checksum;
  final String? reason;

  factory LiteRtLmStatus.fromMap(Map<Object?, Object?> map) {
    return LiteRtLmStatus(
      available: map['available'] == true,
      runtime: (map['runtime'] as String?) ?? 'unknown',
      modelPath: map['modelPath'] as String?,
      modelVersion: map['modelVersion'] as String?,
      checksum: map['checksum'] as String?,
      reason: map['reason'] as String?,
    );
  }
}

class LiteRtLmGeneration {
  const LiteRtLmGeneration({required this.source, this.arguments, this.text});

  final String source;
  final Map<String, Object?>? arguments;
  final String? text;

  bool get isToolCall => source == 'tool_call' && arguments != null;

  factory LiteRtLmGeneration.fromResult(Object? result) {
    if (result is Map<Object?, Object?>) {
      final LiteRtLmGeneration generation = LiteRtLmGeneration(
        source: (result['source'] as String?) ?? 'unknown',
        arguments: _stringKeyedMap(result['arguments']),
        text: result['text'] as String?,
      );
      _liteRtLmLog(
        'generation source=${generation.source} '
        'arguments=${generation.arguments} text=${_preview(generation.text)}',
      );
      return generation;
    }
    if (result is String) {
      _liteRtLmLog('generation source=text text=${_preview(result)}');
      return LiteRtLmGeneration(source: 'text', text: result);
    }
    _liteRtLmLog('unexpected generation payload type=${result.runtimeType}');
    throw const FormatException(
      'Native LiteRT-LM bridge returned an unexpected generation payload.',
    );
  }
}

class NativeLiteRtLm {
  NativeLiteRtLm();

  static const String _modelAssetPath = 'assets/models/gemma-4-E2B-it.litertlm';
  static const String _modelFile = 'gemma-4-E2B-it.litertlm';
  static const String _modelVersion = 'gemma-4-E2B-it';
  static const int _maxTokens = 2048;
  static final Future<void> _initialization = FlutterGemma.initialize();

  InferenceModel? _model;

  Future<LiteRtLmStatus> status() async {
    try {
      await _initialization;
      final bool installed = await FlutterGemma.isModelInstalled(_modelFile);
      final bool supportedPlatform = Platform.isAndroid || Platform.isIOS;
      return LiteRtLmStatus(
        available: supportedPlatform,
        runtime: _runtimeName,
        modelPath: _modelAssetPath,
        modelVersion: _modelVersion,
        checksum: null,
        reason: installed
            ? 'flutter_gemma model is installed and ready.'
            : 'Flutter asset model will be installed on first AI decision.',
      );
    } catch (error) {
      return LiteRtLmStatus(
        available: false,
        runtime: _runtimeName,
        modelPath: _modelAssetPath,
        modelVersion: _modelVersion,
        reason: 'flutter_gemma is not ready: $error',
      );
    }
  }

  Future<LiteRtLmGeneration> generate({
    required String prompt,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    _liteRtLmLog(
      'generate promptChars=${prompt.length} timeoutMs=${timeout.inMilliseconds}',
    );
    final InferenceModel model = await _activeModel().timeout(timeout);
    final InferenceChat chat = await model
        .createChat(
          temperature: 0.1,
          randomSeed: 0,
          topK: 1,
          topP: 0.95,
          supportsFunctionCalls: true,
          modelType: ModelType.gemma4,
          toolChoice: ToolChoice.required,
          isThinking: false,
          systemInstruction: buildAiDecisionSystemPrompt(),
          tools: <Tool>[_pokerDecisionTool(prompt)],
        )
        .timeout(timeout);
    try {
      await chat
          .addQueryChunk(Message.text(text: prompt, isUser: true))
          .timeout(timeout);
      final ModelResponse response = await chat.generateChatResponse().timeout(
        timeout,
      );
      if (response is FunctionCallResponse) {
        return LiteRtLmGeneration(
          source: 'tool_call',
          arguments: _normalizeArguments(response.args),
        );
      }
      if (response is ParallelFunctionCallResponse &&
          response.calls.isNotEmpty) {
        return LiteRtLmGeneration(
          source: 'tool_call',
          arguments: _normalizeArguments(response.calls.first.args),
        );
      }
      if (response is TextResponse) {
        return LiteRtLmGeneration(source: 'text', text: response.token);
      }
      if (response is ThinkingResponse) {
        return LiteRtLmGeneration(source: 'text', text: response.content);
      }
      return LiteRtLmGeneration(source: 'text', text: response.toString());
    } finally {
      await chat.close();
    }
  }

  Future<InferenceModel> _activeModel() async {
    if (_model case final InferenceModel model) {
      return model;
    }
    await _initialization;
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromAsset(_modelAssetPath).install();
    _model = await FlutterGemma.getActiveModel(
      maxTokens: _maxTokens,
      preferredBackend: PreferredBackend.gpu,
      enableSpeculativeDecoding: true,
    );
    return _model!;
  }
}

String get _runtimeName {
  if (Platform.isIOS) {
    return 'flutter_gemma 0.15.0 LiteRT-LM FFI iOS Metal';
  }
  if (Platform.isAndroid) {
    return 'flutter_gemma 0.15.0 LiteRT-LM FFI Android GPU';
  }
  return 'flutter_gemma 0.15.0 unsupported platform';
}

Tool _pokerDecisionTool(String prompt) {
  return Tool(
    name: 'choose_poker_action',
    description:
        'Explain concise poker thinking, then choose exactly one legal action for this Texas Holdem decision.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'thinking': <String, Object?>{
          'type': 'string',
          'description':
              'Concise public decision summary before action, based only on visible state and legal actions. Prefer: Hand: ...; Line: ...; Price: ...; Plan: ....',
        },
        'action': <String, Object?>{
          'type': 'string',
          'enum': _legalActionTypes(prompt),
          'description': 'One action from the current legal action list.',
        },
        'amount': <String, Object?>{
          'type': 'number',
          'description':
              'Total chip amount for bet, raise, or allIn. Omit for fold, check, and call.',
        },
      },
      'required': <String>['thinking', 'action'],
      'additionalProperties': false,
    },
  );
}

List<String> _legalActionTypes(String prompt) {
  final List<String> markdownActions = _legalActionTypesFromMarkdown(prompt);
  if (markdownActions.isNotEmpty) {
    return markdownActions;
  }
  try {
    final Object? root = jsonDecode(prompt);
    if (root is! Map<String, Object?>) {
      return _defaultLegalActions;
    }
    final Object? legalActions = root['legalActions'];
    if (legalActions is! List<Object?>) {
      return _defaultLegalActions;
    }
    final List<String> actions = legalActions
        .whereType<Map<String, Object?>>()
        .map((Map<String, Object?> item) => item['type'])
        .whereType<String>()
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    return actions.isEmpty ? _defaultLegalActions : actions;
  } catch (_) {
    return _defaultLegalActions;
  }
}

List<String> _legalActionTypesFromMarkdown(String prompt) {
  int start = prompt.indexOf('## Action space');
  if (start < 0) {
    start = prompt.indexOf('## Legal actions');
  }
  if (start < 0) {
    return const <String>[];
  }
  final int nextSection = prompt.indexOf('\n## ', start + 1);
  final String section = nextSection < 0
      ? prompt.substring(start)
      : prompt.substring(start, nextSection);
  final RegExpMatch? jsonBlock = RegExp(
    r'```json\s*([\s\S]*?)```',
  ).firstMatch(section);
  if (jsonBlock != null) {
    try {
      final Object? decoded = jsonDecode(jsonBlock.group(1)!);
      if (decoded is List<Object?>) {
        final List<String> actions = decoded
            .whereType<Map<String, Object?>>()
            .map((Map<String, Object?> item) => item['type'])
            .whereType<String>()
            .where((String value) => value.isNotEmpty)
            .toList(growable: false);
        if (actions.isNotEmpty) {
          return actions;
        }
      }
    } catch (_) {
      // Fall through to the older inline Markdown format.
    }
  }
  return RegExp(r'`type:\s*([A-Za-z]+)`')
      .allMatches(section)
      .map((RegExpMatch match) => match.group(1))
      .whereType<String>()
      .where((String value) => value.isNotEmpty)
      .toList(growable: false);
}

const List<String> _defaultLegalActions = <String>[
  'fold',
  'check',
  'call',
  'bet',
  'raise',
  'allIn',
];

Map<String, Object?> _normalizeArguments(Map<String, dynamic> arguments) {
  return arguments.map(
    (String key, dynamic value) => MapEntry(key, _methodChannelValue(value)),
  );
}

Map<String, Object?>? _stringKeyedMap(Object? value) {
  if (value is! Map<Object?, Object?>) {
    return null;
  }
  return value.map(
    (Object? key, Object? mapValue) =>
        MapEntry(key.toString(), _methodChannelValue(mapValue)),
  );
}

Object? _methodChannelValue(Object? value) {
  if (value is Map<Object?, Object?>) {
    return _stringKeyedMap(value);
  }
  if (value is List<Object?>) {
    return value.map(_methodChannelValue).toList(growable: false);
  }
  if (value is String) {
    return _normalizeLiteRtLmString(value);
  }
  return value;
}

String _normalizeLiteRtLmString(String value) {
  final String normalized = value
      .replaceAll('<|"|>', '')
      .replaceAll('<escape>', '')
      .trim();
  if (normalized != value) {
    _liteRtLmLog(
      'normalized argument ${_preview(value)} -> ${_preview(normalized)}',
    );
  }
  return normalized;
}

void _liteRtLmLog(String message) {
  if (kDebugMode) {
    debugPrint('[LiteRT-LM] $message');
  }
}

String _preview(Object? value) {
  final String text = value.toString();
  if (text.length <= 300) {
    return text;
  }
  return '${text.substring(0, 300)}...';
}
