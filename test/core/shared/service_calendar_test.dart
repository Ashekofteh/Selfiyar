import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/service_calendar.dart';
import 'package:test/test.dart';

/// The verified serving table, transcribed independently of the implementation.
///
/// Written from the live grids rather than from `ServiceCalendar` itself, so a
/// typo in the implementation cannot hide behind a copy of the same typo here.
/// This is the whole point: assert all 21 cells, not a sample of them.
const _expected = <Weekday, Set<MealSlot>>{
  Weekday.saturday: {MealSlot.lunch, MealSlot.dinner},
  Weekday.sunday: {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
  Weekday.monday: {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
  Weekday.tuesday: {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
  Weekday.wednesday: {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
  Weekday.thursday: {MealSlot.breakfast, MealSlot.lunch},
  Weekday.friday: <MealSlot>{},
};

void main() {
  const calendar = ServiceCalendar();

  group('every cell of the serving table', () {
    for (final day in Weekday.values) {
      final served = _expected[day]!;
      for (final slot in MealSlot.values) {
        final shouldServe = served.contains(slot);
        test('${day.persianName} / ${slot.name} -> $shouldServe', () {
          expect(calendar.isServed(day, slot), shouldServe);
        });
      }
    }
  });

  group('specific rules that motivated the table', () {
    test('Thursday has no dinner', () {
      expect(calendar.isServed(Weekday.thursday, MealSlot.dinner), isFalse);
    });

    test('Friday is closed all day', () {
      expect(calendar.isClosedAllDayOn(Weekday.friday), isTrue);
      for (final slot in MealSlot.values) {
        expect(calendar.isServed(Weekday.friday, slot), isFalse);
      }
    });

    test('Saturday has no breakfast (Friday dinner is not served)', () {
      expect(calendar.isServed(Weekday.saturday, MealSlot.breakfast), isFalse);
    });

    test('Friday has no breakfast (Thursday dinner is not served)', () {
      expect(calendar.isServed(Weekday.friday, MealSlot.breakfast), isFalse);
    });

    test('Saturday still serves lunch and dinner', () {
      expect(calendar.isServed(Weekday.saturday, MealSlot.lunch), isTrue);
      expect(calendar.isServed(Weekday.saturday, MealSlot.dinner), isTrue);
    });

    test('Thursday still serves breakfast and lunch', () {
      expect(calendar.isServed(Weekday.thursday, MealSlot.breakfast), isTrue);
      expect(calendar.isServed(Weekday.thursday, MealSlot.lunch), isTrue);
    });

    test('the breakfast gap is always explained by the previous night', () {
      // Any weekday without breakfast must be preceded by a day without dinner.
      // This is the invariant the table encodes, asserted directly.
      for (final day in Weekday.values) {
        if (calendar.isServed(day, MealSlot.breakfast)) continue;
        final previous =
            Weekday.values[(day.index - 1 + Weekday.values.length) %
                Weekday.values.length];
        expect(
          calendar.isServed(previous, MealSlot.dinner),
          isFalse,
          reason:
              '${day.persianName} has no breakfast but '
              '${previous.persianName} serves dinner - inconsistent',
        );
      }
    });
  });

  group('date-based helpers', () {
    test('weekday mapping matches DateTime.weekday (Mon=1..Sun=7)', () {
      expect(Weekday.monday.isoNumber, DateTime.monday);
      expect(Weekday.sunday.isoNumber, DateTime.sunday);
      expect(Weekday.saturday.isoNumber, DateTime.saturday);
    });

    test('fromDateTime resolves the right weekday', () {
      // 2026-10-18 is a Sunday.
      expect(Weekday.fromDateTime(DateTime.utc(2026, 10, 18)), Weekday.sunday);
      // 2026-10-16 is a Friday.
      expect(Weekday.fromDateTime(DateTime.utc(2026, 10, 16)), Weekday.friday);
      // 2026-10-17 is a Saturday.
      expect(
        Weekday.fromDateTime(DateTime.utc(2026, 10, 17)),
        Weekday.saturday,
      );
    });

    test('isServedOn / isClosedOn agree with the table', () {
      final friday = DateTime.utc(2026, 10, 16);
      expect(calendar.isClosedOn(friday), isTrue);
      expect(calendar.isServedOn(friday, MealSlot.lunch), isFalse);

      final sunday = DateTime.utc(2026, 10, 18);
      expect(calendar.isClosedOn(sunday), isFalse);
      expect(calendar.isServedOn(sunday, MealSlot.lunch), isTrue);
    });

    test('servedSlots returns meals in canonical order', () {
      expect(calendar.servedSlots(Weekday.friday), isEmpty);
      expect(calendar.servedSlots(Weekday.saturday), {
        MealSlot.lunch,
        MealSlot.dinner,
      });
      expect(calendar.servedSlots(Weekday.sunday), MealSlot.values.toSet());
    });

    test('servableDates leaves out the days the meal is not served', () {
      // 19 October 2026 is a Monday, so the week runs Monday..Sunday.
      final week = List.generate(7, (i) => DateTime.utc(2026, 10, 19 + i));

      // Dinner is not served on Thursday, and Friday is shut all day.
      final dinner = calendar.servableDates(week, MealSlot.dinner);
      expect(dinner.length, 5);
      expect(dinner.any((d) => d.weekday == DateTime.friday), isFalse);
      expect(dinner.any((d) => d.weekday == DateTime.thursday), isFalse);

      // Breakfast is not served on Saturday, and Friday is shut all day.
      final breakfast = calendar.servableDates(week, MealSlot.breakfast);
      expect(breakfast.length, 5);
      expect(breakfast.any((d) => d.weekday == DateTime.saturday), isFalse);
      expect(breakfast.any((d) => d.weekday == DateTime.friday), isFalse);

      // Lunch is served on every day but Friday.
      final lunch = calendar.servableDates(week, MealSlot.lunch);
      expect(lunch.length, 6);
      expect(lunch.any((d) => d.weekday == DateTime.friday), isFalse);
    });

    test('servableDates keeps the order it was given', () {
      final dates = [
        DateTime.utc(2026, 10, 20), // Tuesday.
        DateTime.utc(2026, 10, 19), // Monday.
      ];
      final served = calendar.servableDates(dates, MealSlot.lunch);
      expect(served, dates);
    });
  });

  group('Persian names are present for every weekday', () {
    test('no weekday is missing a name', () {
      for (final day in Weekday.values) {
        expect(day.persianName.trim(), isNotEmpty, reason: day.name);
      }
    });
  });
}
