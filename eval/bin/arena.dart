import 'dart:io';

import '../src/arena.dart';
import '../src/cli.dart';
import '../src/llm_provider.dart';
import '../src/prompt_variants.dart';

/// Duplicate match between policies. Policy specs: `heuristic`, `reference`,
/// or `llm:<variant>` (uses --model/--base-url, with --clamp/--retries).
///
/// dart run bin/arena.dart --policies reference,heuristic --hands 200 --seed 1
/// dart run bin/arena.dart --policies llm:facts_guided,reference --hands 100 --clamp --retries 1
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final List<String> specs = args.list('policies', <String>['reference', 'heuristic']);
  final int hands = args.integer('hands', 200);
  final int seed = args.integer('seed', 1);
  final LlmConfig config = LlmConfig(
    baseUrl: args.str('base-url', LlmConfig.envBaseUrl()),
    apiKey: args.str('api-key', LlmConfig.envApiKey()),
    model: args.str('model', LlmConfig.envModel()),
    timeout: Duration(seconds: args.integer('timeout', 60)),
    useTools: !args.flag('no-tools'),
    forceTool: !args.flag('no-force-tool'),
  );
  final List<SeatPolicy> policies = <SeatPolicy>[];
  for (int i = 0; i < specs.length; i += 1) {
    final String spec = specs[i];
    if (spec == 'heuristic') {
      policies.add(const HeuristicSeat());
    } else if (spec == 'reference') {
      policies.add(ReferenceSeat(seed: seed + i));
    } else if (spec.startsWith('llm:')) {
      final String variant = spec.substring(4);
      policies.add(
        LlmSeat(
          label: 'llm:$variant@${config.model}',
          seed: seed + i,
          provider: LlmDecisionProvider(
            client: LlmClient(config),
            variant: PromptVariant.byName(variant),
            clamp: args.flag('clamp'),
            retries: args.integer('retries', 0),
          ),
        ),
      );
    } else {
      stderr.writeln('unknown policy "$spec"');
      exit(2);
    }
  }
  stdout.writeln('policies=${policies.map((SeatPolicy p) => p.name).join(' vs ')} hands=$hands seed=$seed');
  final MatchResult result = await runDuplicateMatch(
    policies: policies,
    hands: hands,
    seed: seed,
    startingStackBB: args.integer('stack-bb', 100),
    log: stdout.writeln,
  );
  stdout
    ..writeln()
    ..writeln(result.report());
}
