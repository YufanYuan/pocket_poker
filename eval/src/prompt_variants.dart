import 'engine.dart';

/// A named way of building the model prompt for one decision.
///
/// Variants only change what the model is told, through [AiPromptOptions] in
/// the app's own prompt builder, so the harness grades exactly the prompt the
/// app can ship. Parsing robustness (clamping, retries) is controlled
/// separately so the two effects can be measured apart.
class PromptVariant {
  const PromptVariant(this.name, this.description, this.options);

  final String name;
  final String description;
  final AiPromptOptions options;

  bool get needsFeatures => options.includeFacts;

  String build(AiDecisionRequest request, PokerFeatures? features) =>
      buildAiDecisionPrompt(request, options: options, features: features);

  static const List<PromptVariant> all = <PromptVariant>[
    PromptVariant(
      'baseline',
      'The original app prompt: raw state plus the long style guide, no facts.',
      AiPromptOptions.legacy(),
    ),
    PromptVariant(
      'compact',
      'Original prompt with the style guide reduced to the persona line.',
      AiPromptOptions(
        compactStyle: true,
        includeFacts: false,
        guide: AiPromptGuide.none,
      ),
    ),
    PromptVariant(
      'facts',
      'Original prompt plus engine-computed facts: hand class, draws, equity, pot odds, position, SPR, size presets.',
      AiPromptOptions(
        compactStyle: false,
        includeFacts: true,
        guide: AiPromptGuide.none,
      ),
    ),
    PromptVariant(
      'facts_compact',
      'Compact style plus engine-computed facts.',
      AiPromptOptions(
        compactStyle: true,
        includeFacts: true,
        guide: AiPromptGuide.none,
      ),
    ),
    PromptVariant(
      'facts_guided',
      'Compact style, engine facts, and a short decision guide with thresholds.',
      AiPromptOptions(
        compactStyle: true,
        includeFacts: true,
        guide: AiPromptGuide.thresholds,
      ),
    ),
    PromptVariant(
      'facts_guided_v2',
      'facts_guided with ordered rules against over-folding to small bets, folding when committed, and shoving air at low SPR.',
      AiPromptOptions(
        compactStyle: true,
        includeFacts: true,
        guide: AiPromptGuide.ordered,
      ),
    ),
    PromptVariant(
      'app',
      'Whatever the app ships right now (AiPromptOptions defaults).',
      AiPromptOptions(),
    ),
  ];

  static PromptVariant byName(String name) =>
      all.firstWhere((PromptVariant v) => v.name == name);
}
