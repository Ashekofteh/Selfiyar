import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/hunt/hunt_success.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/ui/features/hunt/hunt_screen.dart';
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
  group('HuntScreen — Last Successful Hunt Card (Pillar 4)', () {
    final success = HuntSuccess(
      accountId: 'account-1',
      dishName: 'چلو جوجه کباب',
      hallName: 'مرکزی برادران',
      priceRial: 550000,
      date: DateTime.utc(2026, 11, 25),
      slot: MealSlot.lunch,
      claimedAt: DateTime.utc(2026, 11, 23, 12, 0),
    );

    testWidgets('renders success card details at top when lastSuccess is present', (tester) async {
      await tester.pumpWidget(
        wrap(
          HuntScreen(
            config: HuntConfig(targetSlot: MealSlot.lunch),
            dishes: const [],
            halls: const [],
            targetDates: const [],
            lastSuccess: success,
            onConfigChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('شکار موفق'), findsOneWidget);
      expect(find.text('چلو جوجه کباب'), findsOneWidget);
      expect(find.text('مرکزی برادران'), findsOneWidget);
      // 550,000 Rial = 55,000 Toman -> '۵۵,۰۰۰ تومان'
      expect(find.textContaining('۵۵٬۰۰۰ تومان'), findsOneWidget);
      expect(find.textContaining('چهارشنبه ۴ آذر'), findsOneWidget);
    });

    testWidgets('tapping dismiss button triggers onDismissSuccess callback', (tester) async {
      var dismissed = false;

      await tester.pumpWidget(
        wrap(
          HuntScreen(
            config: HuntConfig(targetSlot: MealSlot.lunch),
            dishes: const [],
            halls: const [],
            targetDates: const [],
            lastSuccess: success,
            onConfigChanged: (_) {},
            onDismissSuccess: () {
              dismissed = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dismissBtn = find.byTooltip('بستن');
      expect(dismissBtn, findsOneWidget);

      await tester.tap(dismissBtn);
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });

    testWidgets('omits success card when lastSuccess is null', (tester) async {
      await tester.pumpWidget(
        wrap(
          HuntScreen(
            config: HuntConfig(targetSlot: MealSlot.lunch),
            dishes: const [],
            halls: const [],
            targetDates: const [],
            lastSuccess: null,
            onConfigChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('شکار موفق'), findsNothing);
      expect(find.text('چلو جوجه کباب'), findsNothing);
    });
  });
}
