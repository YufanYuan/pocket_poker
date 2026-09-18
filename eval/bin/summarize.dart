import 'dart:io';

import '../src/cli.dart';
import '../src/report.dart';

/// Prints the comparison tables for one or more run files.
///
/// dart run bin/summarize.dart --runs runs/a.jsonl,runs/b.jsonl
/// dart run bin/summarize.dart --dir runs
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final List<String> files = args.list('runs', <String>[]);
  final String? dir = args['dir'];
  if (dir != null) {
    files.addAll(
      Directory(dir)
          .listSync()
          .whereType<File>()
          .map((File f) => f.path)
          .where((String p) => p.endsWith('.jsonl')),
    );
  }
  if (files.isEmpty) {
    stderr.writeln('usage: --runs a.jsonl,b.jsonl or --dir runs');
    exit(2);
  }
  final List<Map<String, Object?>> records = <Map<String, Object?>>[
    for (final String f in files) ...readRecords(f),
  ];
  stdout.writeln(summarize(records));
  if (args.flag('worst')) {
    stdout.writeln('\nBlunders:');
    for (final Map<String, Object?> r in records.where((Map<String, Object?> r) => r['verdict'] == 'blunder')) {
      stdout.writeln(
        '- ${r['variant']} ${r['scenarioId']} ${r['tag']} ${r['handClass']} eq=${r['equity']} '
        'chose ${r['action']} ref ${r['recommended']} :: ${r['thinking'] ?? ''}',
      );
    }
  }
}
