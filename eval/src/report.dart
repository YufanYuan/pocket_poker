import 'dart:convert';
import 'dart:io';

import 'cli.dart';

/// Aggregates decision-eval JSONL records into comparison tables.
class RunSummary {
  RunSummary(this.key);

  final String key;
  int n = 0;
  int valid = 0;
  int clamped = 0;
  int invalid = 0;
  int error = 0;
  int best = 0;
  int ok = 0;
  int mistake = 0;
  int blunder = 0;
  int oversized = 0;
  int latencyMs = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  final Map<String, List<int>> byTag = <String, List<int>>{};

  int get usable => valid + clamped;

  void add(Map<String, Object?> r) {
    n += 1;
    switch (r['status']) {
      case 'valid':
        valid += 1;
      case 'clamped':
        clamped += 1;
      case 'invalid':
        invalid += 1;
      default:
        error += 1;
    }
    latencyMs += (r['latencyMs'] as num?)?.toInt() ?? 0;
    promptTokens += (r['promptTokens'] as num?)?.toInt() ?? 0;
    completionTokens += (r['completionTokens'] as num?)?.toInt() ?? 0;
    final String? verdict = r['verdict'] as String?;
    final String tag = (r['tag'] as String?) ?? '?';
    final List<int> t = byTag.putIfAbsent(tag, () => <int>[0, 0]);
    if (verdict != null) {
      t[0] += 1;
    }
    switch (verdict) {
      case 'best':
        best += 1;
      case 'ok':
        ok += 1;
      case 'mistake':
        mistake += 1;
        t[1] += 1;
      case 'blunder':
        blunder += 1;
        t[1] += 1;
    }
    final Object? notes = r['notes'];
    if (notes is List && notes.any((Object? x) => x.toString().startsWith('oversized'))) {
      oversized += 1;
    }
  }
}

List<Map<String, Object?>> readRecords(String path) {
  final File f = File(path);
  if (!f.existsSync()) {
    return <Map<String, Object?>>[];
  }
  return f
      .readAsLinesSync()
      .where((String l) => l.trim().isNotEmpty)
      .map((String l) => jsonDecode(l) as Map<String, Object?>)
      .toList();
}

String summarize(List<Map<String, Object?>> records) {
  final Map<String, RunSummary> groups = <String, RunSummary>{};
  for (final Map<String, Object?> r in records) {
    final String key = '${r['variant']} @ ${r['model'] ?? '-'}';
    groups.putIfAbsent(key, () => RunSummary(key)).add(r);
  }
  final StringBuffer b = StringBuffer()
    ..writeln('Rates are over graded (usable) decisions; usable = valid + clamped.')
    ..writeln()
    ..writeln('| variant @ model | n | usable | valid | clamped | invalid | error | best | ok | mistake | blunder | oversized | avg ms | in tok | out tok |')
    ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (final RunSummary s in groups.values) {
    final int g = s.best + s.ok + s.mistake + s.blunder;
    b.writeln(
      '| ${s.key} | ${s.n} | ${pct(s.usable, s.n)} | ${pct(s.valid, s.n)} | ${pct(s.clamped, s.n)} | '
      '${pct(s.invalid, s.n)} | ${pct(s.error, s.n)} | ${pct(s.best, g)} | ${pct(s.ok, g)} | '
      '${pct(s.mistake, g)} | ${pct(s.blunder, g)} | ${pct(s.oversized, g)} | '
      '${s.n == 0 ? 0 : (s.latencyMs / s.n).round()} | ${s.n == 0 ? 0 : (s.promptTokens / s.n).round()} | '
      '${s.n == 0 ? 0 : (s.completionTokens / s.n).round()} |',
    );
  }
  final Set<String> tags = <String>{
    for (final RunSummary s in groups.values) ...s.byTag.keys,
  }..removeWhere((String t) => t == '?');
  final List<String> sortedTags = tags.toList()..sort(_tagOrder);
  if (sortedTags.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Mistake + blunder rate by street (graded decisions):')
      ..writeln()
      ..writeln('| variant @ model | ${sortedTags.join(' | ')} |')
      ..writeln('|---|${sortedTags.map((_) => '---:').join('|')}|');
    for (final RunSummary s in groups.values) {
      b.writeln(
        '| ${s.key} | ${sortedTags.map((String t) {
          final List<int> v = s.byTag[t] ?? <int>[0, 0];
          return '${pct(v[1], v[0])} (${v[0]})';
        }).join(' | ')} |',
      );
    }
  }
  return b.toString();
}

int _tagOrder(String a, String b) {
  const List<String> streets = <String>['preflop', 'flop', 'turn', 'river'];
  int idx(String t) => streets.indexOf(t.split('/').first) * 2 + (t.endsWith('free') ? 1 : 0);
  return idx(a).compareTo(idx(b));
}
