import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../src/cli.dart';

/// Minimal OpenAI-compatible endpoint that answers with a random legal action
/// (and sometimes a deliberately bad amount) so the harness can be smoke
/// tested without a real model or key.
///
/// dart run bin/mock_server.dart --port 4010
/// dart run bin/decide_eval.dart --base-url http://localhost:4010/v1 --model mock --limit 20 --clamp
Future<void> main(List<String> argv) async {
  final Args args = Args.parse(argv);
  final int port = args.integer('port', 4010);
  final Random rng = Random(args.integer('seed', 3));
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('mock model listening on http://localhost:$port/v1/chat/completions');
  await for (final HttpRequest req in server) {
    final String body = await utf8.decoder.bind(req).join();
    final Map<String, Object?> json = jsonDecode(body) as Map<String, Object?>;
    final List<Object?> tools = (json['tools'] as List<Object?>?) ?? <Object?>[];
    List<String> actions = <String>['fold', 'check', 'call'];
    if (tools.isNotEmpty) {
      final Map<String, Object?> fn = (tools.first as Map<String, Object?>)['function'] as Map<String, Object?>;
      final Map<String, Object?> params = fn['parameters'] as Map<String, Object?>;
      final Map<String, Object?> props = params['properties'] as Map<String, Object?>;
      actions = ((props['action'] as Map<String, Object?>)['enum'] as List<Object?>).cast<String>();
    }
    final String action = actions[rng.nextInt(actions.length)];
    final Map<String, Object?> arguments = <String, Object?>{
      'thinking': 'Hand: mock; Line: mock; Price: mock; Plan: $action',
      'action': action,
      if (action == 'bet' || action == 'raise' || action == 'allIn')
        'amount': rng.nextBool() ? 1 + rng.nextInt(40) : 0.5,
    };
    final bool asTool = tools.isNotEmpty && rng.nextDouble() < 0.9;
    final Map<String, Object?> message = asTool
        ? <String, Object?>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Object?>[
              <String, Object?>{
                'id': 'call_1',
                'type': 'function',
                'function': <String, Object?>{
                  'name': 'choose_poker_action',
                  'arguments': jsonEncode(arguments),
                },
              },
            ],
          }
        : <String, Object?>{'role': 'assistant', 'content': jsonEncode(arguments)};
    req.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode(<String, Object?>{
          'id': 'mock',
          'model': json['model'],
          'choices': <Object?>[
            <String, Object?>{'index': 0, 'message': message, 'finish_reason': 'stop'},
          ],
          'usage': <String, Object?>{
            'prompt_tokens': (body.length / 4).round(),
            'completion_tokens': 40,
          },
        }),
      );
    await req.response.close();
  }
}
