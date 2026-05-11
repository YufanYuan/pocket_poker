# Poker AI

Mobile-first Flutter Texas Holdem cash table for one human player against AI
seats. The app targets iOS and Android only for v1.

## What is implemented

- Flutter setup screen for player name, seat count, min/max buy-in, and starting stack.
- Fixed blinds of `0.5 / 1`, represented internally as integer chip units.
- Pure Dart poker engine for hand flow, betting rounds, rotating positions, all-in,
  side pots, showdown, split pots, and continuous hands.
- AI decision abstraction with:
  - deterministic heuristic fallback,
  - Gemma 4 E2B / LiteRT-LM provider boundary,
  - OpenRouter provider with model selection,
  - tool/function-calling first decision contract,
  - legal-action validation before the engine accepts model output.
- Local Gemma inference through `flutter_gemma`.
- Tests for hand evaluation, game flow, AI snapshot safety, and widget setup.

## Mobile-only scope

The v1 product deliberately does not support macOS, Linux, Windows, or Web.
Only `android/` and `ios/` should be treated as maintained Flutter targets.

## Gemma 4 E2B model

Place the bundled model at:

```text
assets/models/gemma-4-E2B-it.litertlm
```

Local decisions now use `flutter_gemma: ^0.15.0` from Dart instead of the app's
old custom `poker_ai/litert_lm` platform channel. The provider installs the
Flutter asset model with `FlutterGemma.installModel(...).fromAsset(...)`, opens it
with `PreferredBackend.gpu`, and uses Gemma 4 native function calling via
`FunctionCallResponse`.

Android and iOS both use the same Flutter asset file. Android `.litertlm`
support is arm64-only, so the app filters the APK to `arm64-v8a`.
flutter_gemma 0.15.0 uses LiteRT-LM through FFI for `.litertlm` files; on
physical iOS devices this path uses Metal. The simulator can build on Apple
Silicon but remains CPU-only because of Metal simulator allocation limits.

Official references:

- https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/
- https://developers.googleblog.com/bring-state-of-the-art-agentic-skills-to-the-edge-with-gemma-4/
- https://ai.google.dev/edge/litert/genai/overview
- https://ai.google.dev/edge/litert-lm

## OpenRouter

The setup screen can switch AI decisions from local Gemma to OpenRouter and
choose the model id. The settings button in the top-right corner stores the
OpenRouter API key and preferred model locally with `shared_preferences`.
`OPENROUTER_API_KEY` remains supported as a development fallback.

For Flutter mobile builds, pass the key as a dart define:

```sh
flutter run -d ios --dart-define-from-file=.env
flutter run -d android --dart-define-from-file=.env
```

Direct `--dart-define=OPENROUTER_API_KEY=...` also works, but it can expose the
key in local process listings during development. For local tests or Dart
processes, a normal shell environment variable also works:

```sh
export OPENROUTER_API_KEY=...
```

Current starter model presets in the UI:

- `openrouter/free`
- `~moonshotai/kimi-latest`
- `moonshotai/kimi-k2.6`
- `minimax/minimax-m2.7`
- `z-ai/glm-5.1`
- `~google/gemini-pro-latest`
- `~google/gemini-flash-latest`
- `google/gemini-3.1-flash-lite`
- `google/gemini-3.1-pro-preview`
- `~openai/gpt-latest`
- `openai/gpt-chat-latest`
- `openai/gpt-5.5-pro`
- `openai/gpt-5.5`
- `deepseek/deepseek-v4-pro`
- `deepseek/deepseek-v4-flash`
- `~anthropic/claude-opus-latest`
- `~anthropic/claude-sonnet-latest`
- `anthropic/claude-opus-4.7`

OpenRouter calls use `/api/v1/chat/completions` with a forced
`choose_poker_action` tool call containing `thinking` before `action`. Tool
arguments are still validated against the engine-generated legal actions before
they can affect the hand.

## Development

After installing Flutter and the iOS/Android toolchains:

```sh
flutter pub get
flutter test
flutter run -d ios
flutter run -d android
```
