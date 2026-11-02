import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

void main() {
  final config = HuntConfig(
    windowStart: const ClockTime(17, 15),
    windowEnd: const ClockTime(19, 45),
    targetSlot: MealSlot.lunch,
    targetDate: DateTime.utc(2026, 10, 28),
    dishPriority: [
      HuntDish(optionId: '62738', name: 'چلو اکبرجوجه,دوغ', priceRial: 500000),
      HuntDish(optionId: '62740', name: 'چلو گوشت,ماست', priceRial: 500000),
    ],
    hallPriority: const [
      HuntHall(id: '1', name: 'مرکزی برادران'),
      HuntHall(id: '2', name: 'فنی برادران'),
    ],
    rate: HuntRate(
      peakInterval: const Duration(seconds: 5),
      offPeakInterval: const Duration(minutes: 2),
    ),
    enabled: true,
    requestBudget: 250,
    riskAcknowledged: true,
  );

  group('the round trip', () {
    test('a configuration survives being written and read back', () {
      final decoded = decodeHuntConfig(encodeHuntConfig(config))!;

      expect(decoded.windowStart, const ClockTime(17, 15));
      expect(decoded.windowEnd, const ClockTime(19, 45));
      expect(decoded.targetSlot, MealSlot.lunch);
      expect(decoded.targetDate, DateTime.utc(2026, 10, 28));
      expect(decoded.dishPriority, hasLength(2));
      expect(decoded.dishPriority.first.name, 'چلو اکبرجوجه,دوغ');
      expect(decoded.dishPriority.first.priceRial, 500000);
      expect(decoded.hallPriority.map((h) => h.id), ['1', '2']);
      expect(decoded.rate.peakInterval, const Duration(seconds: 5));
      expect(decoded.rate.offPeakInterval, const Duration(minutes: 2));
      expect(decoded.enabled, isTrue);
      expect(decoded.requestBudget, 250);
      expect(decoded.riskAcknowledged, isTrue);
    });

    test('startDate survives being written and read back', () {
      final crossDayConfig = config.copyWith(
        startDate: DateTime.utc(2026, 10, 27),
      );
      final decoded = decodeHuntConfig(encodeHuntConfig(crossDayConfig))!;
      expect(decoded.startDate, DateTime.utc(2026, 10, 27));
      expect(decoded.targetDate, DateTime.utc(2026, 10, 28));
    });

    test('the dish name is kept, not just the option id', () {
      // The market renumbers option ids, so a configuration that stored only
      // the id would match nothing. The name is the identity.
      final decoded = decodeHuntConfig(encodeHuntConfig(config))!;
      expect(decoded.dishPriority.first.dishKey,
          normalizeDishName('چلو اکبرجوجه,دوغ'));
    });

    test('an unreadable record reads as null, not as a default', () {
      // Failing closed: a default hunt would start polling and buying dishes
      // the user never chose.
      expect(decodeHuntConfig('not json'), isNull);
      expect(decodeHuntConfig('[]'), isNull);
      expect(decodeHuntConfig('{"dishes": "nonsense"}'), isNull);
    });

    test('a record with no dishes is still readable', () {
      final decoded = decodeHuntConfig(encodeHuntConfig(HuntConfig()))!;
      expect(decoded.dishPriority, isEmpty);
      expect(decoded.hallPriority, isEmpty);
    });

    test('an out-of-range time falls back to the default', () {
      final raw = '{"windowStart": "99:99", "windowEnd": "20:30"}';
      final decoded = decodeHuntConfig(raw)!;
      expect(decoded.windowStart, const ClockTime(16, 30));
      expect(decoded.windowEnd, const ClockTime(20, 30));
    });

    test('a rate read from the store is clamped like any other', () {
      // A stored value from an older build, or a hand-edited one, must not
      // put the hunt outside the bounds.
      final raw = '{"peakIntervalSeconds": 0, "offPeakIntervalSeconds": 999999}';
      final decoded = decodeHuntConfig(raw)!;
      expect(decoded.rate.peakInterval, HuntBounds.minPeakInterval);
      expect(decoded.rate.offPeakInterval, HuntBounds.maxOffPeakInterval);
    });
  });
}
