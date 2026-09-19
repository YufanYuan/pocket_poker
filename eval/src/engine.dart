/// Re-exports the app's pure-Dart poker engine and AI contracts so the eval
/// package can run headless without the Flutter SDK.
///
/// The main package depends on Flutter, so `dart pub get` cannot resolve it
/// as a path dependency. Files under `lib/` may not import outside their
/// package, so the harness sources live in `src/` and `bin/` and reach the
/// engine through relative file imports. Every engine file must be reached
/// through this barrel so there is a single library instance per file.
library;

export '../../lib/src/ai/ai_decision_provider.dart';
export '../../lib/src/ai/ai_prompt_builder.dart';
export '../../lib/src/ai/heuristic_ai_decision_provider.dart';
export '../../lib/src/ai/poker_features.dart';
export '../../lib/src/domain/card.dart';
export '../../lib/src/domain/deck.dart';
export '../../lib/src/domain/hand_evaluator.dart';
export '../../lib/src/domain/models.dart';
export '../../lib/src/domain/money.dart';
export '../../lib/src/domain/poker_game.dart';
