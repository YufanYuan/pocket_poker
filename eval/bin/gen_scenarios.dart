import 'dart:io';

import '../src/cli.dart';
import '../src/scenario.dart';

/// Builds a stratified scenario bank by playing seeded hands.
///
/// dart run bin/gen_scenarios.dart --count 240 --seats 6 --seed 42 --out scenarios/bank_v1.json
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final int count = args.integer('count', 240);
  final int seats = args.integer('seats', 6);
  final int seed = args.integer('seed', 42);
  final int stack = args.integer('stack-bb', 100);
  final String out = args.str('out', 'scenarios/bank_v1.json');
  final bool verbose = args.flag('verbose');

  stdout.writeln('generating $count scenarios, $seats seats, seed $seed, $stack bb stacks');
  final List<Scenario> scenarios = await ScenarioGenerator(
    seats: seats,
    seed: seed,
    startingStackBB: stack,
  ).generate(count, log: (String m) => verbose || m.startsWith('buckets') ? stdout.writeln(m) : null);
  Scenario.saveFile(out, scenarios, <String, Object?>{
    'count': scenarios.length,
    'seats': seats,
    'seed': seed,
    'stackBB': stack,
    'gradingIterations': Scenario.gradingIterations,
  });
  stdout.writeln('wrote ${scenarios.length} scenarios to $out');
}
