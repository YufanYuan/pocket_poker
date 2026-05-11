# LiteRT-LM on iOS

The app no longer links or compiles its own LiteRT-LM iOS bridge.

Local Gemma inference is handled by `flutter_gemma: ^0.15.0` from Dart:

```dart
await FlutterGemma.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
).fromAsset('assets/models/gemma-4-E2B-it.litertlm').install();
```

The iOS Runner target should not reference `ios/LiteRT-LM/lib/LiteRTLM.xcframework`,
`PokerLiteRtLmBridge.mm`, or custom `POKER_AI_ENABLE_LITERTLM_*` flags. This
avoids duplicate LiteRT-LM symbols and lets flutter_gemma own the native-assets
runtime and Metal accelerator setup.
