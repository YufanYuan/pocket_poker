import 'dart:io';

import '../src/cli.dart';
import '../src/engine.dart';
import '../src/prompt_variants.dart';
import '../src/reference_policy.dart';
import '../src/scenario.dart';

/// Prints one scenario's prompt for a variant plus the reference grading.
///
/// dart run bin/show_scenario.dart --scenarios scenarios/bank_v1.json --id s001 --variant facts_guided
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final List<Scenario> bank = Scenario.loadFile(args.str('scenarios', 'scenarios/bank_v1.json'));
  final String id = args.str('id', bank.first.id);
  final Scenario s = bank.firstWhere((Scenario x) => x.id == id);
  final PromptVariant v = PromptVariant.byName(args.str('variant', 'facts_guided'));
  if (args.flag('system')) {
    stdout
      ..writeln('===== SYSTEM =====')
      ..writeln(buildAiDecisionSystemPrompt());
  }
  stdout
    ..writeln('===== USER (${v.name}) =====')
    ..writeln(v.build(s.request, s.features))
    ..writeln()
    ..writeln('===== REFERENCE =====')
    ..writeln('recommended: ${s.reference.recommended.type.name} ${s.reference.recommended.amount == null ? '' : Chips.format(s.reference.recommended.amount!)}')
    ..writeln('verdicts: ${s.reference.verdicts.map((PokerActionType k, Verdict v) => MapEntry<String, String>(k.name, v.name))}')
    ..writeln('rationale: ${s.reference.rationale}');
}
