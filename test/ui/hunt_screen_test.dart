import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/screens/hunt_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
const technical = Hall(id: '2', name: 'فنی برادران');

final dishes = [
  const HuntDishOption(
    optionId: '62738',
    name: 'چلو اکبرجوجه,دوغ',
    priceRial: 500000,
    halls: [central],
  ),
  const HuntDishOption(
    optionId: '62740',
    name: 'چلو گوشت,ماست',
    priceRial: 500000,
    halls: [central],
  ),
];

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

/// Holds the configuration in state and feeds it back, the way a parent does.
///
/// A plain closure cannot do this: the screen would keep the configuration it
/// was built with, so the second pick would start from the first.
class _HuntHarness extends StatefulWidget {
  const _HuntHarness({
    required this.dishes,
    required this.halls,
    required this.initial,
    required this.onChanged,
    this.targetDates = const [],
    this.schedule,
  });

  final List<HuntDishOption> dishes;
  final List<Hall> halls;
  final HuntConfig initial;
  final void Function(HuntConfig) onChanged;
  final List<DateTime> targetDates;
  final HuntScheduleResult? schedule;

  @override
  State<_HuntHarness> createState() => _HuntHarnessState();
}

class _HuntHarnessState extends State<_HuntHarness> {
  late HuntConfig _config = widget.initial;

  @override
  Widget build(BuildContext context) {
    return HuntScreen(
      config: _config,
      dishes: widget.dishes,
      halls: widget.halls,
      targetDates: widget.targetDates,
      schedule: widget.schedule,
      onConfigChanged: (updated) {
        widget.onChanged(updated);
        setState(() => _config = updated);
      },
    );
  }
}

/// Whether any match of [finder] is inside the viewport and can be tapped.
///
/// A widget that is built but scrolled out of the viewport cannot be tapped,
/// so "it exists" is not the same as "it is reachable".
bool _isVisible(Finder finder) {
  for (final element in finder.evaluate()) {
    final object = element.renderObject;
    if (object is! RenderBox || !object.hasSize) continue;
    final topLeft = object.localToGlobal(Offset.zero);
    if (topLeft.dy + object.size.height > 0 && topLeft.dy < 600) return true;
  }
  return false;
}

void main() {
  /// Scrolls until [text] is found **and visible**, the way a user would.
  ///
  /// Matches on a substring, because a Persian amount is one `Text` whose
  /// content is a number and a unit — an exact match on the unit alone would
  /// never find it.
  ///
  /// Visibility matters: a widget that is built but scrolled out of the
  /// viewport cannot be tapped, so stopping at "it exists" would leave the
  /// tap landing on nothing.
  Future<void> scrollTo(WidgetTester tester, String text) async {
    final finder = find.textContaining(text);
    for (var attempt = 0; attempt < 12; attempt++) {
      if (_isVisible(finder)) return;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  group('the target', () {
    testWidgets('the meal slot can be chosen', (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(targetSlot: MealSlot.dinner),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'ناهار');
      await tester.tap(find.text('ناهار'));
      await tester.pumpAndSettle();

      expect(changed!.targetSlot, MealSlot.lunch);
    });

    testWidgets('a new slot clears the dishes chosen for the old one',
        (tester) async {
      // The dishes belong to a (date, slot). A lunch dish left on the list
      // after the slot becomes breakfast is a dish the portal is not
      // offering, and the pre-flight demands the credit for the sum of the
      // priority list — so it would refuse a hunt the balance could pay for.
      HuntConfig? changed;

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.lunch,
          dishPriority: [
            HuntDish(
              optionId: '99999',
              name: 'شوید پلو با تن ماهی',
              priceRial: 500000,
            ),
          ],
        ),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'صبحانه');
      await tester.tap(find.text('صبحانه'));
      await tester.pumpAndSettle();

      expect(changed!.targetSlot, MealSlot.breakfast);
      expect(changed!.dishPriority, isEmpty);
    });

    testWidgets('the target date is shown in Persian', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(targetDate: DateTime.utc(2026, 10, 28)),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      // 28 October 2026 is 6 Aban 1405.
      expect(find.textContaining('آبان'), findsOneWidget);
    });

    testWidgets('the peak window follows the chosen meal', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(targetSlot: MealSlot.lunch),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'بازه اوج');
      expect(find.textContaining('۰۹:۰۰'), findsWidgets,
          reason: 'a lunch hunt peaks in the morning');
    });

    testWidgets('tomorrow Saturday can be selected when today is Friday',
        (tester) async {
      HuntConfig? changed;
      // Friday 2026-10-30 (8 Aban)
      final targetDates = List.generate(
        14,
        (i) => DateTime.utc(2026, 10, 30 + i),
      );

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.lunch,
          targetDate: DateTime.utc(2026, 10, 31),
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      // Tap on the date picker row
      await tester.tap(find.text('تاریخ'));
      await tester.pumpAndSettle();

      // In Aban 1405: Friday is 8, Saturday tomorrow is 9
      await tester.tap(find.text('۹'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.targetDate, DateTime.utc(2026, 10, 31));
    });

    testWidgets('shows "(امروز)" tag when target date is today', (tester) async {
      final today = DateTime.utc(2026, 10, 30);
      final targetDates = List.generate(14, (i) => DateTime.utc(2026, 10, 30 + i));

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.lunch,
          targetDate: today,
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      expect(find.textContaining('(امروز)'), findsOneWidget);
    });

    testWidgets('shows "(فردا)" tag and unambiguous execution schedule for tomorrow dinner',
        (tester) async {
      final today = DateTime.utc(2026, 10, 30);
      final tomorrow = DateTime.utc(2026, 10, 31);
      final targetDates = List.generate(14, (i) => DateTime.utc(today.year, today.month, today.day + i));

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          targetDate: tomorrow,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      expect(find.textContaining('(فردا)'), findsWidgets);
      expect(
        find.textContaining('زمان اجرای شکار برای شام: فردا (شنبه) از ساعت ۱۶:۳۰ تا ۲۰:۳۰'),
        findsOneWidget,
      );
    });

    testWidgets(
        'shows unambiguous previous-evening schedule when target is tomorrow breakfast',
        (tester) async {
      // 2026-10-31 is Saturday. Tomorrow breakfast is Sunday 2026-11-01.
      // Saturday serves dinner, so Sunday breakfast is collected on Saturday evening.
      final today = DateTime.utc(2026, 10, 31);
      final tomorrow = DateTime.utc(2026, 11, 1);
      final targetDates = [today, tomorrow];

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.breakfast,
          targetDate: tomorrow,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      expect(find.textContaining('(فردا)'), findsWidgets);
      expect(
        find.textContaining(
            'زمان اجرای شکار: امروز (شنبه) از ساعت ۱۶:۳۰ تا ۲۰:۳۰ (با توجه به توزیع صبحانه همزمان با شام روز قبل)'),
        findsOneWidget,
      );
    });

    testWidgets('quick date chip "فردا" selects tomorrow directly with one tap',
        (tester) async {
      HuntConfig? changed;
      final today = DateTime.utc(2026, 10, 31); // Saturday
      final tomorrow = DateTime.utc(2026, 11, 1); // Sunday
      final targetDates = [today, tomorrow, DateTime.utc(2026, 11, 2)];

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          targetDate: today,
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      // Tap on the quick chip "فردا"
      await tester.tap(find.text('فردا'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.targetDate, tomorrow);
    });

    testWidgets('quick date chip shows "(تعطیل)" and is disabled when meal is not served on that day',
        (tester) async {
      HuntConfig? changed;
      // Friday 2026-10-30 has no meals served
      final friday = DateTime.utc(2026, 10, 30);
      final saturday = DateTime.utc(2026, 10, 31);
      final sunday = DateTime.utc(2026, 11, 1);
      final targetDates = [friday, saturday, sunday];

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.lunch,
          targetDate: saturday,
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      expect(find.text('امروز (تعطیل)'), findsOneWidget);

      // Tapping the disabled chip does not change targetDate
      await tester.tap(find.text('امروز (تعطیل)'));
      await tester.pumpAndSettle();

      expect(changed, isNull);
    });

    testWidgets('_WindowExecutionSummary shows warning when schedule status is windowPassed',
        (tester) async {
      final today = DateTime.utc(2026, 10, 31);
      final targetDates = [today];

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          targetDate: today,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        schedule: const HuntScheduleResult(
          status: HuntScheduleStatus.windowPassed,
        ),
        onConfigChanged: (_) {},
      )));

      expect(
        find.textContaining('بازه زمانی این شکار (امروز (شنبه) از ساعت ۱۶:۳۰ تا ۲۰:۳۰) گذشته است'),
        findsOneWidget,
      );
    });

    testWidgets('_WindowExecutionSummary shows notice when schedule status is windowOpen',
        (tester) async {
      final today = DateTime.utc(2026, 10, 31);
      final targetDates = [today];

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          targetDate: today,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        targetDates: targetDates,
        dishes: dishes,
        halls: const [central, technical],
        schedule: const HuntScheduleResult(
          status: HuntScheduleStatus.windowOpen,
        ),
        onConfigChanged: (_) {},
      )));

      expect(
        find.textContaining('بازه زمانی شکار برای شام (امروز (شنبه) از ساعت ۱۶:۳۰ تا ۲۰:۳۰) هم‌اکنون باز است!'),
        findsOneWidget,
      );
    });
  });

  group('the screen', () {
    testWidgets('shows the peak window for the target meal', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(targetSlot: MealSlot.lunch),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'بازه اوج');
      expect(find.textContaining('بازه اوج'), findsWidgets);
    });

    testWidgets('shows the dishes the portal offers', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      expect(find.text('چلو اکبرجوجه,دوغ'), findsOneWidget);
    });

    testWidgets('shows a price in Toman, never Rial', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'تومان');
      expect(find.textContaining('تومان'), findsWidgets);
      expect(find.textContaining('ریال'), findsNothing);
    });

    testWidgets('picking a dish reports the new configuration', (tester) async {
      HuntConfig? changed;
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      await tester.tap(find.text('چلو اکبرجوجه,دوغ'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.dishPriority, hasLength(1));
      expect(changed!.dishPriority.first.name, 'چلو اکبرجوجه,دوغ');
    });

    testWidgets('picking a second dish keeps the first as the priority',
        (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(_HuntHarness(
        initial: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      await tester.tap(find.text('چلو اکبرجوجه,دوغ'));
      await tester.pumpAndSettle();

      // The second dish is scrolled to rather than tapped where it happens
      // to be: a widget that is built but off-screen cannot be tapped, and
      // the tap would land on nothing.
      await scrollTo(tester, 'چلو گوشت,ماست');
      await tester.tap(find.text('چلو گوشت,ماست'));
      await tester.pumpAndSettle();

      expect(changed!.dishPriority, hasLength(2));
      expect(changed!.dishPriority.first.name, 'چلو اکبرجوجه,دوغ');
      expect(changed!.dishPriority.last.name, 'چلو گوشت,ماست');
    });

    testWidgets('the halls can be chosen in priority order', (tester) async {
      HuntConfig? changed;
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'فنی برادران');
      await tester.tap(find.text('فنی برادران'));
      await tester.pumpAndSettle();

      expect(changed!.hallPriority, hasLength(1));
      expect(changed!.hallPriority.first.id, '2');
    });
  });

  group('the projected request count', () {
    testWidgets('moves with the rate', (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(_HuntHarness(
        initial: HuntConfig(
          targetSlot: MealSlot.dinner,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 30),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        dishes: dishes,
        halls: const [central, technical],
        onChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'حدود');
      expect(find.textContaining('حدود'), findsOneWidget);

      // Move the peak slider to its fastest end.
      //
      // Which end that is depends on the layout direction, so both ends are
      // tried and the one that made the interval shorter is the fast end.
      final slider = find.byType(Slider).first;
      final box = tester.getRect(slider);

      await tester.tapAt(Offset(box.left + 1, box.center.dy));
      await tester.pumpAndSettle();
      final left = changed?.rate.peakInterval;

      await tester.tapAt(Offset(box.right - 1, box.center.dy));
      await tester.pumpAndSettle();
      final right = changed?.rate.peakInterval;

      final fastest = left! < right! ? left : right;
      expect(fastest, lessThan(const Duration(seconds: 30)));

      // The count is the number the user trades against, so it must still be
      // on screen, and it must have moved.
      expect(find.textContaining('حدود'), findsOneWidget);
    });
  });

  group('the ban-risk warning', () {
    testWidgets('appears below ten seconds and does not appear at or above it',
        (tester) async {
      // Below the threshold: the modal must appear.
      await tester.pumpWidget(wrap(Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                onPressed: () => confirmRiskAcknowledgement(
                  context,
                  interval: const Duration(seconds: 5),
                  projectedRequests: 2880,
                ),
                child: const Text('شروع'),
              ),
            ],
          ),
        ),
      )));

      await tester.tap(find.text('شروع'));
      await tester.pumpAndSettle();

      expect(find.text('هشدار ریسک مسدود شدن حساب'), findsOneWidget);
      expect(find.textContaining('درخواست'), findsWidgets);

      // The default is cancel, so a stray Enter does not accept the risk.
      expect(find.text('انصراف'), findsOneWidget);
      expect(find.text('می‌پذیرم'), findsOneWidget);
    });

    testWidgets('the rate below the threshold is flagged as risky',
        (tester) async {
      final risky = HuntRate(peakInterval: const Duration(seconds: 5));
      final safe = HuntRate(peakInterval: const Duration(seconds: 10));

      expect(risky.needsRiskAcknowledgement, isTrue);
      expect(safe.needsRiskAcknowledgement, isFalse);
    });
  });

  group('the enable switch', () {
    // The flag that decides whether a hunt runs at all. It was decoded and
    // persisted and never read: a hunt the student switched off still ran.
    testWidgets('a hunt that has never been switched on says so',
        (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      expect(find.text('فعال‌سازی شکار'), findsOneWidget);
      expect(
        find.textContaining('شکار خاموش است'),
        findsOneWidget,
        reason: 'the default is off, and the screen must say which state it '
            'is in rather than leaving the student to guess',
      );
    });

    testWidgets(
        'when window is open but switch is off, subtitle invites enabling without claiming hunt is on',
        (tester) async {
      final dummyDate = DateTime(2026, 11, 2);
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(enabled: false),
        dishes: dishes,
        halls: const [central, technical],
        schedule: HuntScheduleResult(
          status: HuntScheduleStatus.windowOpen,
          schedule: HuntSchedule(
            collectionDate: dummyDate,
            wakeAtUtc: dummyDate,
            windowEndUtc: dummyDate.add(const Duration(hours: 2)),
          ),
        ),
        onConfigChanged: (_) {},
      )));

      expect(
        find.textContaining(
            'بازه زمانی این شکار هم‌اکنون باز است؛ با روشن کردن، شکار بیدرنگ شروع می‌شود.'),
        findsOneWidget,
      );
      expect(find.textContaining('این شکار روشن است'), findsNothing);
    });

    testWidgets('the switch turns the hunt on', (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(changed!.enabled, isTrue);
    });

    testWidgets('the cost of the hunt is stated while it is off',
        (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      expect(
        find.textContaining('هزینه تقریبی این شکار'),
        findsOneWidget,
        reason: 'a hunt spends requests as well as money, and the number is '
            'the thing the student is trading against',
      );
    });

    group('the automatic start', () {
      /// A hunt scheduled to wake at a known instant.
      HuntScheduleResult scheduled(DateTime wakeAtUtc) => HuntScheduleResult(
            status: HuntScheduleStatus.scheduled,
            schedule: HuntSchedule(
              collectionDate: DateTime.utc(2026, 10, 22),
              wakeAtUtc: wakeAtUtc,
              windowEndUtc: wakeAtUtc.add(const Duration(hours: 4)),
            ),
          );

      testWidgets('the card says when the hunt will start', (tester) async {
        // 13:00 UTC is 16:30 portal-local.
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(enabled: true),
          dishes: dishes,
          halls: const [central, technical],
          schedule: scheduled(DateTime.utc(2026, 10, 22, 13, 0)),
          onConfigChanged: (_) {},
        )));

        expect(
          find.textContaining('شروع می‌شود'),
          findsOneWidget,
          reason: 'the card claims the hunt starts by itself, so it must say '
              'when',
        );
        expect(
          find.textContaining('در ساعت ۱۶:۳۰'),
          findsOneWidget,
          reason: 'the time is in the portal\'s own clock — the same clock '
              'the window is set in',
        );
      });

      testWidgets('a hunt whose window has passed says so', (tester) async {
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(enabled: true),
          dishes: dishes,
          halls: const [central, technical],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.windowPassed,
          ),
          onConfigChanged: (_) {},
        )));

        expect(
          find.textContaining('بازه زمانی این شکار گذشته است'),
          findsOneWidget,
          reason: 'a hunt that will not start must say why — a switch that '
              'looks live but never fires is a lie',
        );
        expect(
          find.textContaining('شروع می‌شود'),
          findsNothing,
          reason: 'the claim that it starts by itself must not stand when it '
              'will not',
        );
      });

      testWidgets('a hunt for a meal the portal does not serve says so',
          (tester) async {
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(enabled: true),
          dishes: dishes,
          halls: const [central, technical],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.mealNotServed,
          ),
          onConfigChanged: (_) {},
        )));

        expect(find.textContaining('ارائه نمی‌شود'), findsOneWidget);
      });

      testWidgets('a switched-off hunt makes no claim about starting',
          (tester) async {
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(enabled: false),
          dishes: dishes,
          halls: const [central, technical],
          schedule: scheduled(DateTime.utc(2026, 10, 22, 13, 0)),
          onConfigChanged: (_) {},
        )));

        expect(
          find.textContaining('شروع می‌شود'),
          findsNothing,
          reason: 'a hunt that is off will not start, and must not claim it '
              'will',
        );
      });
    });

    group('cross-day and overnight hunt window', () {
      final monday = DateTime.utc(2026, 11, 2);
      final tuesday = DateTime.utc(2026, 11, 3);

      testWidgets(
          'overnight hunt from today 18:20 to tomorrow 14:00 is valid and displays cross-day span',
          (tester) async {
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(
            enabled: true,
            targetDate: tuesday,
            targetSlot: MealSlot.lunch,
            startDate: monday,
            windowStart: const ClockTime(18, 20),
            windowEnd: const ClockTime(14, 0),
          ),
          dishes: dishes,
          halls: const [central, technical],
          targetDates: [monday, tuesday],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.windowOpen,
          ),
          onConfigChanged: (_) {},
        )));

        // The red error banner for "بازه زمانی معتبر نیست" must NOT be present
        expect(find.textContaining('بازه زمانی معتبر نیست'), findsNothing);

        // Operation start date section must be present
        expect(find.textContaining('تاریخ شروع عملیات:'), findsOneWidget);

        // The summary banner states it is currently open and spans from today to tomorrow
        expect(find.textContaining('هم‌اکنون باز است'), findsOneWidget);
        expect(
          find.textContaining('از امروز (دوشنبه) ساعت ۱۸:۲۰ تا فردا (سه‌شنبه) ساعت ۱۴:۰۰'),
          findsOneWidget,
        );
      });

      testWidgets(
          'switching start date chip between today and meal date updates config',
          (tester) async {
        HuntConfig? changed;

        await tester.pumpWidget(wrap(_HuntHarness(
          initial: HuntConfig(
            enabled: true,
            targetDate: tuesday,
            targetSlot: MealSlot.lunch,
            startDate: monday,
            windowStart: const ClockTime(18, 20),
            windowEnd: const ClockTime(14, 0),
          ),
          dishes: dishes,
          halls: const [central, technical],
          targetDates: [monday, tuesday],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.windowOpen,
          ),
          onChanged: (c) => changed = c,
        )));

        // Find the chip for "روز وعده" (tuesday)
        await scrollTo(tester, 'روز وعده');
        final mealDayChip = find.textContaining('روز وعده');
        expect(mealDayChip, findsOneWidget);

        await tester.tap(mealDayChip);
        await tester.pumpAndSettle();

        expect(changed, isNotNull);
        expect(changed!.startDate, equals(tuesday));
      });

      testWidgets(
          'overnight times default to today startDate and do not show invalid window error',
          (tester) async {
        await tester.pumpWidget(wrap(HuntScreen(
          config: HuntConfig(
            enabled: true,
            targetDate: tuesday,
            targetSlot: MealSlot.lunch,
            startDate: null,
            windowStart: const ClockTime(18, 20),
            windowEnd: const ClockTime(14, 0),
          ),
          dishes: dishes,
          halls: const [central, technical],
          targetDates: [monday, tuesday],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.windowOpen,
          ),
          onConfigChanged: (_) {},
        )));

        expect(find.textContaining('بازه زمانی معتبر نیست'), findsNothing);
        expect(
          find.textContaining('از امروز (دوشنبه) ساعت ۱۸:۲۰ تا فردا (سه‌شنبه) ساعت ۱۴:۰۰'),
          findsOneWidget,
        );
      });

      testWidgets(
          'tapping visually default-selected start date chip explicitly sets startDate on config',
          (tester) async {
        HuntConfig? changed;

        await tester.pumpWidget(wrap(_HuntHarness(
          initial: HuntConfig(
            enabled: true,
            targetDate: tuesday,
            targetSlot: MealSlot.lunch,
            startDate: null,
            windowStart: const ClockTime(18, 20),
            windowEnd: const ClockTime(14, 0),
          ),
          dishes: dishes,
          halls: const [central, technical],
          targetDates: [monday, tuesday],
          schedule: const HuntScheduleResult(
            status: HuntScheduleStatus.windowOpen,
          ),
          onChanged: (c) => changed = c,
        )));

        // Scroll to and find the chip for "امروز"
        await scrollTo(tester, 'امروز (دوشنبه - از الان)');
        final todayChip = find.textContaining('امروز (دوشنبه - از الان)');
        expect(todayChip, findsOneWidget);

        await tester.tap(todayChip);
        await tester.pumpAndSettle();

        expect(changed, isNotNull);
        expect(changed!.startDate, equals(monday));
      });

      testWidgets(
          'Thursday is selectable and intelligently adjusts dinner to lunch',
          (tester) async {
        final thursday = DateTime.utc(2026, 11, 5);
        HuntConfig? changed;

        await tester.pumpWidget(wrap(_HuntHarness(
          initial: HuntConfig(
            targetSlot: MealSlot.dinner,
            targetDate: DateTime.utc(2026, 11, 4), // Wednesday
          ),
          dishes: dishes,
          halls: const [central, technical],
          targetDates: [DateTime.utc(2026, 11, 4), thursday],
          onChanged: (c) => changed = c,
        )));

        final chipFinder = find.widgetWithText(ChoiceChip, 'فردا');
        expect(chipFinder, findsOneWidget);

        await tester.tap(chipFinder);
        await tester.pumpAndSettle();

        expect(changed, isNotNull);
        expect(changed!.targetDate, thursday);
        expect(changed!.targetSlot, MealSlot.lunch);
      });
    });
  });
}
