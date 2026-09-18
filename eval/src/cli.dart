import 'dart:async';

/// Minimal `--key value` / `--flag` parser so the harness has no pub deps.
class Args {
  Args._(this._values, this._flags);

  factory Args.parse(List<String> argv) {
    final Map<String, String> values = <String, String>{};
    final Set<String> flags = <String>{};
    for (int i = 0; i < argv.length; i += 1) {
      final String a = argv[i];
      if (!a.startsWith('--')) {
        continue;
      }
      final String key = a.substring(2);
      final int eq = key.indexOf('=');
      if (eq >= 0) {
        values[key.substring(0, eq)] = key.substring(eq + 1);
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        values[key] = argv[i + 1];
        i += 1;
      } else {
        flags.add(key);
      }
    }
    return Args._(values, flags);
  }

  final Map<String, String> _values;
  final Set<String> _flags;

  String? operator [](String key) => _values[key];
  String str(String key, String fallback) => _values[key] ?? fallback;
  int integer(String key, int fallback) =>
      int.tryParse(_values[key] ?? '') ?? fallback;
  double real(String key, double fallback) =>
      double.tryParse(_values[key] ?? '') ?? fallback;
  bool flag(String key) => _flags.contains(key) || _values[key] == 'true';
  List<String> list(String key, List<String> fallback) =>
      _values[key]?.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList() ??
      fallback;
}

/// Runs [fn] over [items] with at most [width] in flight, preserving order.
Future<List<R>> mapPool<T, R>(
  Iterable<T> items,
  int width,
  Future<R> Function(T item) fn,
) async {
  final List<T> list = items.toList();
  final List<R?> out = List<R?>.filled(list.length, null);
  int next = 0;
  Future<void> worker() async {
    while (true) {
      final int i = next;
      if (i >= list.length) {
        return;
      }
      next += 1;
      out[i] = await fn(list[i]);
    }
  }

  await Future.wait(List<Future<void>>.generate(width.clamp(1, 64), (_) => worker()));
  return out.cast<R>();
}

String pct(num numerator, num denominator) =>
    denominator == 0 ? '-' : '${(100 * numerator / denominator).toStringAsFixed(1)}%';

String padRight(Object v, int w) => v.toString().padRight(w);
String padLeft(Object v, int w) => v.toString().padLeft(w);
