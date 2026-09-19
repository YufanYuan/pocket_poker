import 'dart:convert';
import 'dart:io';

import '../src/cli.dart';
import '../src/engine.dart';
import '../src/llm_provider.dart';
import '../src/prompt_variants.dart';
import '../src/reference_policy.dart';
import '../src/report.dart';
import '../src/scenario.dart';
import '../src/snapshot_codec.dart';

/// Runs one or more prompt variants (or a built-in policy) over a scenario
/// bank, grades every decision against the reference, and appends JSONL.
///
/// dart run bin/decide_eval.dart --scenarios scenarios/bank_v1.json \
///   --variants baseline,facts_guided --model deepseek-flash \
///   --base-url http://localhost:4000/v1 --concurrency 4 --clamp --retries 1
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final String scenariosPath = args.str('scenarios', 'scenarios/bank_v1.json');
  final String provider = args.str('provider', 'llm');
  final List<String> variants = args.list('variants', <String>['baseline']);
  final int limit = args.integer('limit', 0);
  final List<String> onlyTags = args.list('tags', <String>[]);
  final bool clamp = args.flag('clamp');
  final int retries = args.integer('retries', 0);
  final int concurrency = args.integer('concurrency', 4);
  final LlmConfig config = LlmConfig(
    baseUrl: args.str('base-url', LlmConfig.envBaseUrl()),
    apiKey: args.str('api-key', LlmConfig.envApiKey()),
    model: args.str('model', LlmConfig.envModel()),
    timeout: Duration(seconds: args.integer('timeout', 60)),
    useTools: !args.flag('no-tools'),
    forceTool: !args.flag('no-force-tool'),
    thinking: _thinkingArg(args['thinking']),
    temperature: args['temperature'] == null ? null : args.real('temperature', 0),
    maxTokens: args['max-tokens'] == null ? null : args.integer('max-tokens', 0),
  );
  final String modelLabel = provider == 'llm' ? config.model : provider;
  final String runName = args.str(
    'run',
    '${provider == 'llm' ? _slug(config.model) : provider}${clamp ? '_clamp' : ''}${retries > 0 ? '_r$retries' : ''}',
  );
  final String out = args.str('out', 'runs/$runName.jsonl');
  final bool fresh = args.flag('fresh');

  List<Scenario> scenarios = Scenario.loadFile(scenariosPath);
  if (onlyTags.isNotEmpty) {
    scenarios = scenarios.where((Scenario s) => onlyTags.contains(s.tag)).toList();
  }
  if (limit > 0 && scenarios.length > limit) {
    scenarios = scenarios.sublist(0, limit);
  }
  final File outFile = File(out)..parent.createSync(recursive: true);
  if (fresh && outFile.existsSync()) {
    outFile.deleteSync();
  }
  final List<Map<String, Object?>> existing = readRecords(out);
  final Set<String> done = existing
      .map((Map<String, Object?> r) => '${r['variant']}|${r['model']}|${r['scenarioId']}')
      .toSet();
  final IOSink sink = outFile.openWrite(mode: FileMode.append);
  final ReferencePolicy grader = ReferencePolicy();

  stdout.writeln(
    'provider=$provider model=$modelLabel variants=${variants.join(',')} '
    'scenarios=${scenarios.length} clamp=$clamp retries=$retries -> $out',
  );
  if (provider == 'llm') {
    stdout.writeln('endpoint=${config.endpoint} key=${config.apiKey.isEmpty ? 'NONE' : 'set'}');
  }

  final List<String> variantNames = provider == 'llm' ? variants : <String>[provider];
  for (final String variantName in variantNames) {
    final List<Scenario> todo = scenarios
        .where((Scenario s) => !done.contains('$variantName|$modelLabel|${s.id}'))
        .toList();
    stdout.writeln('[$variantName] ${todo.length} to run, ${scenarios.length - todo.length} cached');
    int finished = 0;
    final LlmDecisionProvider? llm = provider == 'llm'
        ? LlmDecisionProvider(
            client: LlmClient(config),
            variant: PromptVariant.byName(variantName),
            clamp: clamp,
            retries: retries,
          )
        : null;
    await mapPool(todo, provider == 'llm' ? concurrency : 1, (Scenario s) async {
      final Map<String, Object?> record = await _evaluate(s, provider, variantName, modelLabel, llm, grader);
      record['run'] = runName;
      sink.writeln(jsonEncode(record));
      finished += 1;
      if (finished % 10 == 0 || finished == todo.length) {
        stdout.writeln('[$variantName] $finished/${todo.length}');
      }
      return record;
    });
    await sink.flush();
  }
  await sink.close();

  final List<Map<String, Object?>> all = readRecords(out)
      .where((Map<String, Object?> r) => variantNames.contains(r['variant']))
      .toList();
  stdout
    ..writeln()
    ..writeln(summarize(all));
}

Future<Map<String, Object?>> _evaluate(
  Scenario s,
  String provider,
  String variant,
  String model,
  LlmDecisionProvider? llm,
  ReferencePolicy grader,
) async {
  final ReferenceAssessment ref = s.reference;
  PokerAction? action;
  String status = 'valid';
  String? thinking;
  String? failure;
  Map<String, Object?>? rawArgs;
  int latency = 0;
  int attempts = 1;
  int promptTokens = 0;
  int completionTokens = 0;
  bool clamped = false;
  switch (provider) {
    case 'heuristic':
      action = (await const HeuristicAiDecisionProvider().decide(s.request)).action;
    case 'reference':
      action = ref.recommended;
      thinking = ref.rationale;
    default:
      final DecisionOutcome o = await llm!.decide(s.request, features: s.features);
      action = o.action;
      status = o.status;
      thinking = o.thinking;
      failure = o.failure;
      rawArgs = o.rawArguments;
      latency = o.latencyMs;
      attempts = o.attempts;
      promptTokens = o.promptTokens;
      completionTokens = o.completionTokens;
      clamped = o.clamped;
  }
  GradedAction? graded;
  if (action != null) {
    graded = grader.grade(ref, action, s.snapshot, s.legalActions);
  }
  return <String, Object?>{
    'provider': provider,
    'variant': variant,
    'model': model,
    'scenarioId': s.id,
    'tag': s.tag,
    'status': status,
    'clamped': clamped,
    'attempts': attempts,
    'latencyMs': latency,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'action': SnapshotCodec.actionToJson(action),
    'verdict': graded?.verdict.name,
    'notes': graded?.notes ?? <String>[],
    'recommended': SnapshotCodec.actionToJson(ref.recommended),
    'equity': double.parse(s.features.equity.toStringAsFixed(3)),
    'potOdds': double.parse(s.features.potOdds.toStringAsFixed(3)),
    'handClass': s.features.handClass,
    'thinking': thinking,
    'failure': failure,
    'rawArguments': rawArgs,
  };
}

String _slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');

/// `--thinking off|on` maps to the DeepSeek `thinking.type` field.
String? _thinkingArg(String? v) => switch (v) {
  null => null,
  'off' || 'disabled' || 'false' => 'disabled',
  'on' || 'enabled' || 'true' => 'enabled',
  _ => throw ArgumentError('--thinking expects on or off, got $v'),
};
