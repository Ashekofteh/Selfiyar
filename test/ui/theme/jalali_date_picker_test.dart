import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:bahonar_nut/ui/theme/jalali_date_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(
  locale: const Locale('fa', 'IR'),
  supportedLocales: const [Locale('fa', 'IR')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

void main() {
  group('the Jalali calendar', () {
    testWidgets('shows the Persian month and year, never a Gregorian one', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                first: DateTime.utc(2026, 1, 1),
                last: DateTime.utc(2027, 12, 31),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // 28 October 2026 is 6 Aban 1405.
      expect(find.textContaining('آبان'), findsOneWidget);
      expect(find.textContaining('۱۴۰۵'), findsOneWidget);
      expect(
        find.textContaining('اکتبر'),
        findsNothing,
        reason: 'a Persian calendar never shows a Gregorian month',
      );
    });

    testWidgets('the day numbers are Jalali', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                first: DateTime.utc(2026, 1, 1),
                last: DateTime.utc(2027, 12, 31),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // Aban 1405 has 30 days.
      expect(find.text('۳۰'), findsOneWidget);
      expect(
        find.text('۳۱'),
        findsNothing,
        reason: 'a day that does not exist must not be rendered',
      );
    });

    testWidgets('picking a day returns the right Gregorian date', (
      tester,
    ) async {
      DateTime? picked;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showJalaliDatePicker(
                  context: context,
                  initial: DateTime.utc(2026, 10, 28),
                  first: DateTime.utc(2026, 1, 1),
                  last: DateTime.utc(2027, 12, 31),
                );
              },
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // 6 Aban 1405 is 28 October 2026.
      await tester.tap(find.text('۶'));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.year, 2026);
      expect(picked!.month, 10);
      expect(picked!.day, 28);
    });

    testWidgets('a 30-day month does not show a 31st', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                // 1 Mehr 1405 — a 30-day month.
                initial: DateTime.utc(2026, 9, 23),
                first: DateTime.utc(2026, 1, 1),
                last: DateTime.utc(2027, 12, 31),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      expect(find.textContaining('مهر'), findsOneWidget);
      expect(find.text('۳۰'), findsOneWidget, reason: 'Mehr has 30 days');
      expect(
        find.text('۳۱'),
        findsNothing,
        reason: 'a day that does not exist must not be rendered',
      );
    });

    testWidgets('the first of the month sits under its own weekday', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                // 1 Mehr 1405 is 23 September 2026, a Wednesday.
                initial: DateTime.utc(2026, 9, 23),
                first: DateTime.utc(2026, 1, 1),
                last: DateTime.utc(2027, 12, 31),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // The header of the column the first of the month sits under, and the
      // cell itself, must share a column. Getting this wrong puts every day
      // of the month under the wrong weekday — a calendar that silently lies.
      final headerFinder = find.text('چ'); // Wednesday.
      final dayFinder = find.text('۱');

      final headerBox = tester.getRect(headerFinder.first);
      final dayBox = tester.getRect(dayFinder.first);

      expect(
        (headerBox.center.dx - dayBox.center.dx).abs(),
        lessThan(headerBox.width),
        reason: 'the first of the month must sit under its own weekday',
      );
    });

    testWidgets('a date outside the allowed range cannot be picked', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                // The range covers only 28 and 29 October.
                first: DateTime.utc(2026, 10, 28),
                last: DateTime.utc(2026, 10, 29),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // 1 Aban is 23 October — before the allowed range, so it is disabled.
      final cell = tester.widget<InkWell>(
        find.ancestor(of: find.text('۱'), matching: find.byType(InkWell)).first,
      );
      expect(
        cell.onTap,
        isNull,
        reason: 'a date before the range must not be selectable',
      );
    });

    testWidgets('a day the picker rejects cannot be picked', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                first: DateTime.utc(2026, 10, 20),
                last: DateTime.utc(2026, 10, 30),
                // Every day but the 27th is rejected — the shape of "the halls are
                // shut except on the days they serve".
                isSelectable: (d) => d.day == 27,
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // The calendar opens on 6 Aban, so the days on screen are 1..9 Aban.
      // 5 Aban is 27 October, and it is the one day not rejected.
      final allowed = tester.widget<InkWell>(
        find.ancestor(of: find.text('۵'), matching: find.byType(InkWell)).first,
      );
      expect(
        allowed.onTap,
        isNotNull,
        reason: 'a day inside the range that is not rejected is offered',
      );

      // 6 Aban is 28 October — also inside the range, but rejected.
      final rejected = tester.widget<InkWell>(
        find.ancestor(of: find.text('۶'), matching: find.byType(InkWell)).first,
      );
      expect(
        rejected.onTap,
        isNull,
        reason: 'a rejected day must not be selectable',
      );
    });

    testWidgets('the calendar opens on a date inside the range', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                // A stored configuration naming a date the portal no longer serves.
                initial: DateTime.utc(2027, 1, 1),
                first: DateTime.utc(2026, 10, 20),
                last: DateTime.utc(2026, 10, 30),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // The calendar opens on the month of the clamped date, not on the month
      // of the out-of-range initial date.
      expect(find.textContaining('آبان'), findsOneWidget);
      expect(find.textContaining('۱۴۰۵'), findsOneWidget);
    });

    testWidgets('the month arrows point outwards', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                first: DateTime.utc(2026, 10, 20),
                last: DateTime.utc(2026, 10, 30),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      // The chevrons carry `matchTextDirection`, so under RTL Flutter mirrors
      // them. Left unmirrored, both arrows point inward at the month name —
      // a calendar whose arrows point the wrong way. They are forced to LTR,
      // so the glyph is drawn as authored: the right arrow points right, the
      // left one left.
      Icon iconFor(String tooltip) => tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(Icon),
        ),
      );

      // "ماه قبل" is the previous month, and in an RTL row it is the
      // rightmost button, so it points right.
      expect(iconFor('ماه قبل').icon, Icons.chevron_right);
      expect(iconFor('ماه بعد').icon, Icons.chevron_left);

      // And each is drawn without the mirror.
      expect(iconFor('ماه قبل').textDirection, TextDirection.ltr);
      expect(iconFor('ماه بعد').textDirection, TextDirection.ltr);
    });

    testWidgets('a month outside the range cannot be reached', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showJalaliDatePicker(
                context: context,
                initial: DateTime.utc(2026, 10, 28),
                // A range that covers only Aban.
                first: DateTime.utc(2026, 10, 20),
                last: DateTime.utc(2026, 10, 30),
              ),
              child: const Text('انتخاب'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('انتخاب'));
      await tester.pumpAndSettle();

      final next = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('ماه بعد'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(
        next.onPressed,
        isNull,
        reason: 'a month with no selectable day must not be reachable',
      );
    });
  });

  group('the month lengths', () {
    test('match the conversion', () {
      // Spot-check the months the calendar draws against the conversion that
      // the portal's own dates were verified against.
      expect(jalaliMonthLength(1405, 1), 31);
      expect(jalaliMonthLength(1405, 6), 31);
      expect(jalaliMonthLength(1405, 7), 30);
      expect(jalaliMonthLength(1405, 11), 30);
      expect(jalaliMonthLength(1405, 12), 29);
      expect(jalaliMonthLength(1403, 12), 30);
    });
  });
}
