import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/hunt/snipe.dart';
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
  final testConfig = HuntConfig(
    enabled: true,
    targetDate: DateTime(2026, 11, 20),
    targetSlot: MealSlot.dinner,
    rate: HuntRate(peakInterval: const Duration(seconds: 2)),
  );

  testWidgets('LiveHuntMonitorCard does not appear when isRunning is false',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        HuntScreen(
          dishes: const [],
          halls: const [],
          config: testConfig,
          onConfigChanged: (_) {},
          isRunning: false,
        ),
      ),
    );

    expect(find.text('پایش زنده شکار غذا'), findsNothing);
    expect(find.text('تعداد استعلام'), findsNothing);
  });

  testWidgets(
      'LiveHuntMonitorCard displays live stats and stop button when isRunning is true',
      (tester) async {
    var stopped = false;
    final now = DateTime(2026, 11, 20, 14, 30, 0);

    final status = SnipeRunStatus(
      ruleId: 'hunt-acc1',
      state: SnipeState.hunting,
      pollCount: 42,
      lastPollAt: now,
    );

    await tester.pumpWidget(
      wrap(
        HuntScreen(
          dishes: const [],
          halls: const [],
          config: testConfig,
          onConfigChanged: (_) {},
          isRunning: true,
          huntStatus: status,
          onStop: () => stopped = true,
        ),
      ),
    );

    expect(find.text('پایش زنده شکار غذا'), findsOneWidget);
    expect(find.text('۴۲ بار'), findsOneWidget);
    expect(find.text('تعداد استعلام'), findsOneWidget);
    expect(find.text('هر ۲ ثانیه'), findsOneWidget);
    expect(find.text('ریتم بررسی'), findsOneWidget);
    expect(find.text('توقف سریع شکار'), findsOneWidget);

    await tester.tap(find.text('توقف سریع شکار'));
    expect(stopped, isTrue);
  });

  testWidgets('LiveHuntMonitorCard shows error message when lastError is set',
      (tester) async {
    final status = SnipeRunStatus(
      ruleId: 'hunt-acc1',
      state: SnipeState.hunting,
      pollCount: 15,
      lastPollAt: DateTime.now(),
      lastError: 'تایم‌اوت ارتباط با سرور',
    );

    await tester.pumpWidget(
      wrap(
        HuntScreen(
          dishes: const [],
          halls: const [],
          config: testConfig,
          onConfigChanged: (_) {},
          isRunning: true,
          huntStatus: status,
        ),
      ),
    );

    expect(find.textContaining('تایم‌اوت ارتباط با سرور'), findsOneWidget);
  });
}
