import 'package:flutter/material.dart';

import 'src/ai/ai_decision_provider.dart';
import 'src/ai/heuristic_ai_decision_provider.dart';
import 'src/ai/litert_lm_ai_decision_provider.dart';
import 'src/ai/openrouter_ai_decision_provider.dart';
import 'src/domain/models.dart';
import 'src/ui/setup_screen.dart';
import 'src/ui/table_screen.dart';

void main() {
  runApp(const PokerAiApp());
}

class PokerAiApp extends StatefulWidget {
  const PokerAiApp({super.key});

  @override
  State<PokerAiApp> createState() => _PokerAiAppState();
}

class _PokerAiAppState extends State<PokerAiApp> {
  TableConfig? _tableConfig = const bool.fromEnvironment('POKER_AI_AUTOSTART')
      ? const TableConfig(
          humanName: 'Hero',
          seatCount: int.fromEnvironment(
            'POKER_AI_AUTOSTART_SEATS',
            defaultValue: 6,
          ),
          minBuyIn: 4000,
          maxBuyIn: 20000,
          startingStack: 20000,
          aiBackend: AiBackend.testBot,
        )
      : null;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poker AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E4F),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111417),
        cardTheme: const CardThemeData(
          color: Color(0xFF1A2226),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xFF2B383D)),
          ),
        ),
      ),
      home: _tableConfig == null
          ? SetupScreen(
              onStart: (TableConfig config) {
                setState(() {
                  _tableConfig = config;
                });
              },
            )
          : TableScreen(
              key: ValueKey<TableConfig>(_tableConfig!),
              config: _tableConfig!,
              aiDecisionProvider: _providerFor(_tableConfig!),
              onLeaveTable: () {
                setState(() {
                  _tableConfig = null;
                });
              },
            ),
    );
  }

  AiDecisionProvider _providerFor(TableConfig config) {
    return switch (config.aiBackend) {
      AiBackend.openRouter => OpenRouterAiDecisionProvider(
        model: config.openRouterModel,
        apiKey: config.openRouterApiKey,
      ),
      AiBackend.localGemma => LiteRtLmAiDecisionProvider(),
      AiBackend.testBot => const HeuristicAiDecisionProvider(),
    };
  }
}
