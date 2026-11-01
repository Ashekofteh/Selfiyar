import 'package:bahonar_nut/core/account.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/ui/screens/hunt_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  const account1 = SavedAccount(
    id: 'acc1',
    studentId: '401157013',
    alias: 'رضا شریفی',
  );

  const account2 = SavedAccount(
    id: 'acc2',
    studentId: '401405035',
    alias: 'ابوالفضل شکفته',
  );

  final testConfig = HuntConfig(targetSlot: MealSlot.lunch);

  testWidgets('does not show account picker when there is only one account',
      (tester) async {
    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig,
      dishes: const [],
      halls: const [],
      onConfigChanged: (_) {},
      accounts: const [account1],
      activeAccountId: 'acc1',
      onAccountChanged: (_) {},
    )));

    expect(find.text('شکار برای حساب:'), findsNothing);
  });

  testWidgets(
      'shows account picker with chips, balances, and handles selection when multiple accounts exist',
      (tester) async {
    String? selectedAccount;

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig,
      dishes: const [],
      halls: const [],
      onConfigChanged: (_) {},
      accounts: const [account1, account2],
      activeAccountId: 'acc1',
      balanceFor: (id) => id == 'acc1' ? 350000 : 175000,
      onAccountChanged: (id) => selectedAccount = id,
    )));

    // Account picker is visible
    expect(find.text('شکار برای حساب:'), findsOneWidget);

    // Both chips with names and balances are visible
    expect(find.textContaining('رضا شریفی'), findsOneWidget);
    expect(find.textContaining('۳۵٬۰۰۰ تومان'), findsOneWidget);

    expect(find.textContaining('ابوالفضل شکفته'), findsOneWidget);
    expect(find.textContaining('۱۷٬۵۰۰ تومان'), findsOneWidget);

    // Active chip is selected
    final chip1 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'رضا شریفی • ۳۵٬۰۰۰ تومان'),
    );
    expect(chip1.selected, isTrue);

    final chip2 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'ابوالفضل شکفته • ۱۷٬۵۰۰ تومان'),
    );
    expect(chip2.selected, isFalse);

    // Tap account2 chip
    await tester.tap(find.textContaining('ابوالفضل شکفته'));
    await tester.pumpAndSettle();

    expect(selectedAccount, 'acc2');
  });
}
