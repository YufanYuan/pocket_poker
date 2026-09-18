import 'engine.dart';
import 'features.dart';

/// A named way of building the model prompt for one decision.
///
/// Variants change only what the model is told. Parsing robustness (clamping,
/// retries) is controlled separately so the two effects can be measured apart.
class PromptVariant {
  const PromptVariant(this.name, this.description, this._build);

  final String name;
  final String description;
  final String Function(AiDecisionRequest request, PokerFeatures? features) _build;

  bool get needsFeatures => name.startsWith('facts');

  String build(AiDecisionRequest request, PokerFeatures? features) =>
      _build(request, features);

  static const List<PromptVariant> all = <PromptVariant>[
    PromptVariant(
      'baseline',
      'The app prompt as shipped: raw state plus the long style guide.',
      _baseline,
    ),
    PromptVariant(
      'compact',
      'App prompt with the style guide reduced to the persona line.',
      _compact,
    ),
    PromptVariant(
      'facts',
      'Baseline plus engine-computed facts: hand class, draws, equity, pot odds, position, SPR, size presets.',
      _facts,
    ),
    PromptVariant(
      'facts_compact',
      'Compact style plus engine-computed facts.',
      _factsCompact,
    ),
    PromptVariant(
      'facts_guided',
      'Compact style, engine facts, and a short decision guide with thresholds.',
      _factsGuided,
    ),
  ];

  static PromptVariant byName(String name) =>
      all.firstWhere((PromptVariant v) => v.name == name);

  static String _baseline(AiDecisionRequest r, PokerFeatures? _) =>
      buildAiDecisionPrompt(r);

  static String _compact(AiDecisionRequest r, PokerFeatures? _) =>
      _shrinkStyle(buildAiDecisionPrompt(r), r.profile);

  static String _facts(AiDecisionRequest r, PokerFeatures? f) =>
      _insertFacts(buildAiDecisionPrompt(r), r, f!);

  static String _factsCompact(AiDecisionRequest r, PokerFeatures? f) =>
      _insertFacts(_shrinkStyle(buildAiDecisionPrompt(r), r.profile), r, f!);

  static String _factsGuided(AiDecisionRequest r, PokerFeatures? f) =>
      _insertFacts(
        _shrinkStyle(buildAiDecisionPrompt(r), r.profile),
        r,
        f!,
        extra: _guide,
      );

  static const String _styleStart = '## Style';
  static const String _stateStart = '## Current visible state';
  static const String _actionStart = '## Action space';

  static String _shrinkStyle(String prompt, AiProfile p) {
    final int start = prompt.indexOf(_styleStart);
    final int end = prompt.indexOf(_stateStart);
    if (start < 0 || end < 0) {
      return prompt;
    }
    final String style =
        '## Style\n\n'
        '- Persona: ${p.persona}\n'
        '- Tightness ${p.tightness}/100, aggression ${p.aggression}/100, '
        'bluff frequency ${p.bluffFrequency}/100, call tolerance ${p.callTolerance}/100.\n'
        '- Style shifts frequencies at the margin; it never overrides equity, price, or hand strength.\n\n';
    return prompt.replaceRange(start, end, style);
  }

  static String _insertFacts(
    String prompt,
    AiDecisionRequest r,
    PokerFeatures f, {
    String extra = '',
  }) {
    final int at = prompt.indexOf(_actionStart);
    final String block =
        '${f.toPromptSection(pot: r.snapshot.pot, toCall: r.snapshot.toCall)}\n\n'
        '${extra.isEmpty ? '' : '$extra\n\n'}';
    if (at < 0) {
      return '$prompt\n\n$block';
    }
    return prompt.replaceRange(at, at, block);
  }

  static const String _guide = '''
## Decision guide (apply after reading the facts)

- Facing a bet: fold when your equity is clearly below the pot odds and you hold no strong draw; call when equity beats the price; raise with very strong hands (about 70%+ equity) or strong draws that can also make opponents fold.
- No bet pending: bet 50-75% of the pot with 60%+ equity or to protect a vulnerable made hand; check medium-strength hands; bluff only against one or two opponents and with some equity.
- Preflop: open-raise 2.5-3 big blinds with strong hands, 3-bet premium hands, fold weak offsuit hands to raises, and never call large raises with junk.
- Do not bet or raise more than the pot unless the stack-to-pot ratio is under 2 or you hold a very strong hand.
- The amount is your total for this betting round. Pick one of the listed presets unless you have a precise reason.''';
}
