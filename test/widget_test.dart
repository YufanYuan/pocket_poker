import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ai/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('creates a mobile poker table from setup', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const PokerAiApp());

    expect(find.text('Poker AI'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Bot'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Table'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Pot'), findsWidgets);
    expect(find.textContaining('Hand'), findsWidgets);
  });
}
