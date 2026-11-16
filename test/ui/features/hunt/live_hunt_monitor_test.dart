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

/// A parent that can switch a hunt on after the screen has been scrolled.
class _RunningHarness extends StatefulWidget {
  const _RunningHarness({required this.config});

  final HuntConfig config;

  @override
  State<_RunningHarness> createState() => _RunningHarnessState();
}

class _RunningHarnessState extends State<_RunningHarness> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          key: const Key('start-hunt'),
          onPressed: () => setState(() => _running = true),
          child: const Text('شروع'),
        ),
        Expanded(
          child: HuntScreen(
            config: widget.config,
            dishes: const [],
            halls: const [],
            targetDates: [DateTime.utc(2026, 11, 20)],
            onConfigChanged: (_) {},
            isRunning: _running,
            huntStatus: SnipeRunStatus(
              ruleId: 'hunt-acc1',
              state: SnipeState.hunting,
              pollCount: 3,
            ),
          ),
        ),
      ],
    );
  }
}

void main() {
  final testConfig = HuntConfig(
    enabled: true,
    targetDate: DateTime(2026, 11, 20),
    targetSlot: MealSlot.dinner,
    rate: HuntRate(peakInterval: const Duration(seconds: 2)),
  );

  testWidgets('LiveHuntMonitorCard does not appear when isRunning is false', (
    tester,
  ) async {
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
    },
  );

  testWidgets('LiveHuntMonitorCard shows error message when lastError is set', (
    tester,
  ) async {
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

  testWidgets('starting a hunt brings the live monitor into view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(_RunningHarness(config: testConfig)));
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'the test screen must be tall enough to scroll',
    );

    // The student is reading the form, far below the top.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(position.pixels, greaterThan(0));

    await tester.tap(find.byKey(const Key('start-hunt')));
    await tester.pump(); // the monitor card is added and the scroll is queued
    // The animation starts in a post-frame callback, so it needs a frame to
    // tick before the duration can be advanced.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(position.pixels, 0);
    expect(find.text('پایش زنده شکار غذا'), findsOneWidget);
  });

  testWidgets('a screen opened while running starts at the monitor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        HuntScreen(
          dishes: const [],
          halls: const [],
          config: testConfig,
          onConfigChanged: (_) {},
          isRunning: true,
          huntStatus: SnipeRunStatus(
            ruleId: 'hunt-acc1',
            state: SnipeState.hunting,
            pollCount: 1,
          ),
        ),
      ),
    );
    await tester.pump();

    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(position.pixels, 0);
    expect(find.text('پایش زنده شکار غذا'), findsOneWidget);
  });

  group('the last-attempt time', () {
    testWidgets('is rendered relative to the device clock', (tester) async {
      final status = SnipeRunStatus(
        ruleId: 'hunt-acc1',
        state: SnipeState.hunting,
        pollCount: 5,
        lastPollAt: DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
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

      expect(find.text('۵ ثانیه پیش'), findsOneWidget);
    });

    testWidgets('shows the clock in local time, not UTC', (tester) async {
      // A local instant stored as UTC: the card must convert it back, or the
      // student reads a time that is off by their timezone.
      final local = DateTime(2026, 11, 20, 10, 15, 30);
      final status = SnipeRunStatus(
        ruleId: 'hunt-acc1',
        state: SnipeState.hunting,
        pollCount: 5,
        lastPollAt: local.toUtc(),
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

      expect(find.text('۱۰:۱۵:۳۰'), findsOneWidget);
    });

    testWidgets('a timestamp in the future renders as "just now"', (
      tester,
    ) async {
      // A device clock that jumped backwards must not produce "−۳۰ ثانیه پیش".
      final status = SnipeRunStatus(
        ruleId: 'hunt-acc1',
        state: SnipeState.hunting,
        pollCount: 5,
        lastPollAt: DateTime.now().toUtc().add(const Duration(seconds: 30)),
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

      expect(find.text('همین لحظه'), findsOneWidget);
    });
  });
}
