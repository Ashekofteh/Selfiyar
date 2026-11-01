import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
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
  final testConfig = HuntConfig(targetSlot: MealSlot.lunch);

  testWidgets('shows "توقف شکار" when hunt is running and invokes onStop',
      (tester) async {
    var stopped = false;

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig,
      dishes: const [],
      halls: const [],
      isRunning: true,
      onConfigChanged: (_) {},
      onStop: () => stopped = true,
    )));

    final btnFinder = find.text('توقف شکار');
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();

    expect(btnFinder, findsOneWidget);
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(stopped, isTrue);
  });

  testWidgets(
      'shows "شروع شکار" when window is open now, enabling and starting when tapped',
      (tester) async {
    var started = false;
    HuntConfig? changedConfig;

    final dummyDate = DateTime(2026, 11, 2);
    final openSchedule = HuntScheduleResult(
      status: HuntScheduleStatus.windowOpen,
      schedule: HuntSchedule(
        collectionDate: dummyDate,
        wakeAtUtc: dummyDate,
        windowEndUtc: dummyDate.add(const Duration(hours: 2)),
      ),
    );

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig.copyWith(enabled: false),
      dishes: const [],
      halls: const [],
      schedule: openSchedule,
      onConfigChanged: (c) => changedConfig = c,
      onStart: () => started = true,
    )));

    final btnFinder = find.text('شروع شکار');
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();

    expect(btnFinder, findsOneWidget);
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(started, isTrue);
    expect(changedConfig?.enabled, isTrue);
  });

  testWidgets(
      'shows "فعال‌سازی و زمان‌بندی خودکار" when window is in the future and hunt is off',
      (tester) async {
    HuntConfig? changedConfig;

    final dummyDate = DateTime(2026, 11, 2);
    final scheduledResult = HuntScheduleResult(
      status: HuntScheduleStatus.scheduled,
      schedule: HuntSchedule(
        collectionDate: dummyDate,
        wakeAtUtc: dummyDate,
        windowEndUtc: dummyDate.add(const Duration(hours: 2)),
      ),
    );

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig.copyWith(enabled: false),
      dishes: const [],
      halls: const [],
      schedule: scheduledResult,
      onConfigChanged: (c) => changedConfig = c,
    )));

    final btnFinder = find.text('فعال‌سازی و زمان‌بندی خودکار');
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();

    expect(btnFinder, findsOneWidget);
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(changedConfig?.enabled, isTrue);
  });

  testWidgets(
      'shows "لغو زمان‌بندی شکار" when window is in the future and hunt is already on',
      (tester) async {
    HuntConfig? changedConfig;

    final dummyDate = DateTime(2026, 11, 2);
    final scheduledResult = HuntScheduleResult(
      status: HuntScheduleStatus.scheduled,
      schedule: HuntSchedule(
        collectionDate: dummyDate,
        wakeAtUtc: dummyDate,
        windowEndUtc: dummyDate.add(const Duration(hours: 2)),
      ),
    );

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig.copyWith(enabled: true),
      dishes: const [],
      halls: const [],
      schedule: scheduledResult,
      onConfigChanged: (c) => changedConfig = c,
    )));

    final btnFinder = find.text('لغو زمان‌بندی شکار');
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();

    expect(btnFinder, findsOneWidget);
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(changedConfig?.enabled, isFalse);
  });

  testWidgets(
      'shows "مهلت زمانی شکار گذشته است" and is disabled when window passed',
      (tester) async {
    const passedResult = HuntScheduleResult(
      status: HuntScheduleStatus.windowPassed,
    );

    await tester.pumpWidget(wrap(HuntScreen(
      config: testConfig.copyWith(enabled: true),
      dishes: const [],
      halls: const [],
      schedule: passedResult,
      onConfigChanged: (_) {},
    )));

    final btnFinder = find.text('مهلت زمانی شکار گذشته است');
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();

    expect(btnFinder, findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: btnFinder,
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
