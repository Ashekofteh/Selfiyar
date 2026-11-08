import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

HuntDish dish(String id, String name, int price) =>
    HuntDish(optionId: id, name: name, priceRial: price);

void main() {
  group('the rate is clamped, never rejected', () {
    test('a peak interval below the floor is raised to the floor', () {
      final rate = HuntRate(peakInterval: const Duration(milliseconds: 200));
      expect(rate.peakInterval, HuntBounds.minPeakInterval);
    });

    test('a peak interval above the ceiling is lowered to the ceiling', () {
      final rate = HuntRate(peakInterval: const Duration(minutes: 30));
      expect(rate.peakInterval, HuntBounds.maxPeakInterval);
    });

    test('an off-peak interval below the floor is raised to the floor', () {
      final rate = HuntRate(offPeakInterval: const Duration(seconds: 5));
      expect(rate.offPeakInterval, HuntBounds.minOffPeakInterval);
    });

    test('an off-peak interval above the ceiling is lowered to the ceiling', () {
      final rate = HuntRate(offPeakInterval: const Duration(hours: 2));
      expect(rate.offPeakInterval, HuntBounds.maxOffPeakInterval);
    });

    test('a value inside the range is kept exactly', () {
      final rate = HuntRate(
        peakInterval: const Duration(seconds: 7),
        offPeakInterval: const Duration(minutes: 3),
      );
      expect(rate.peakInterval, const Duration(seconds: 7));
      expect(rate.offPeakInterval, const Duration(minutes: 3));
    });

    test('copyWith clamps as well', () {
      final rate = HuntRate.defaults.copyWith(
        peakInterval: const Duration(milliseconds: 1),
      );
      expect(rate.peakInterval, HuntBounds.minPeakInterval);
    });
  });

  group('the risk acknowledgement', () {
    test('is needed below ten seconds', () {
      expect(
        HuntRate(peakInterval: const Duration(seconds: 9)).needsRiskAcknowledgement,
        isTrue,
      );
    });

    test('is not needed at exactly ten seconds', () {
      expect(
        HuntRate(peakInterval: const Duration(seconds: 10)).needsRiskAcknowledgement,
        isFalse,
      );
    });

    test('the default rate needs no acknowledgement', () {
      expect(HuntRate.defaults.needsRiskAcknowledgement, isFalse);
    });
  });

  group('the peak window follows the target meal', () {
    test('a lunch hunt peaks at 09:00-15:30', () {
      final config = HuntConfig(targetSlot: MealSlot.lunch);
      expect(config.peakWindow.start, const ClockTime(9, 0));
      expect(config.peakWindow.end, const ClockTime(15, 30));
      expect(config.isPeak(const ClockTime(12, 0)), isTrue);
      expect(config.isPeak(const ClockTime(18, 0)), isFalse);
    });

    test('a dinner hunt peaks at 16:30-20:30', () {
      final config = HuntConfig(targetSlot: MealSlot.dinner);
      expect(config.peakWindow.start, const ClockTime(16, 30));
      expect(config.peakWindow.end, const ClockTime(20, 30));
      expect(config.isPeak(const ClockTime(18, 0)), isTrue);
      expect(config.isPeak(const ClockTime(12, 0)), isFalse);
    });

    test('breakfast and dinner share the evening window', () {
      // They are collected together, so a hunt for either is hot at the same
      // hours.
      expect(
        distributionWindows[MealSlot.breakfast],
        distributionWindows[MealSlot.dinner],
      );
    });

    test('the boundary instants are inside the window', () {
      final config = HuntConfig(targetSlot: MealSlot.dinner);
      expect(config.isPeak(const ClockTime(16, 30)), isTrue);
      expect(config.isPeak(const ClockTime(20, 30)), isTrue);
      expect(config.isPeak(const ClockTime(16, 29)), isFalse);
      expect(config.isPeak(const ClockTime(20, 31)), isFalse);
    });
  });

  group('the hunt window', () {
    test('contains the times inside it', () {
      final config = HuntConfig(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
      );
      expect(config.isWithinWindow(const ClockTime(18, 0)), isTrue);
      expect(config.isWithinWindow(const ClockTime(16, 30)), isTrue);
      expect(config.isWithinWindow(const ClockTime(20, 30)), isTrue);
      expect(config.isWithinWindow(const ClockTime(12, 0)), isFalse);
    });

    test('a window that ends before it starts is inert', () {
      final config = HuntConfig(
        windowStart: const ClockTime(20, 30),
        windowEnd: const ClockTime(16, 30),
      );
      expect(config.isWithinWindow(const ClockTime(18, 0)), isFalse);
    });
  });

  group('the interval selection', () {
    final config = HuntConfig(
      targetSlot: MealSlot.dinner,
      rate: HuntRate(
        peakInterval: const Duration(seconds: 5),
        offPeakInterval: const Duration(minutes: 2),
      ),
    );

    test('peak inside the distribution window', () {
      expect(config.intervalAt(const ClockTime(18, 0)), const Duration(seconds: 5));
    });

    test('off-peak outside it', () {
      expect(config.intervalAt(const ClockTime(10, 0)), const Duration(minutes: 2));
    });
  });

  group('the required credit', () {
    test('is the dearest dish in the priority list, not the sum', () {
      final config = HuntConfig(
        dishPriority: [
          dish('a', 'لوبیا پلو', 350000),
          dish('b', 'چلو گوشت', 500000),
        ],
      );
      expect(config.requiredCreditRial, 500000);
    });

    test('is equal to either dish when prices are identical', () {
      final config = HuntConfig(
        dishPriority: [
          dish('a', 'قورمه سبزی', 400000),
          dish('b', 'قیمه سیب‌زمینی', 400000),
        ],
      );
      expect(config.requiredCreditRial, 400000);
    });

    test('is zero for an empty list', () {
      expect(HuntConfig().requiredCreditRial, 0);
    });
  });

  group('the price ceiling', () {
    test('is the dearest dish on the list', () {
      final config = HuntConfig(
        dishPriority: [
          dish('a', 'لوبیا پلو', 350000),
          dish('b', 'چلو گوشت', 500000),
        ],
      );
      expect(config.maxPriceRial, 500000);
    });

    test('is null for an empty list', () {
      expect(HuntConfig().maxPriceRial, isNull);
    });
  });

  group('retargeting the hunt', () {
    HuntConfig configured() => HuntConfig(
          targetSlot: MealSlot.lunch,
          targetDate: DateTime.utc(2026, 10, 22),
          dishPriority: [
            dish('a', 'شوید پلو با تن ماهی', 500000),
          ],
          hallPriority: [const HuntHall(id: '1', name: 'مرکزی برادران')],
        );

    test('a new slot clears the dish and hall lists', () {
      // A price belongs to a (date, slot): the same dish costs 150,000 as a
      // breakfast and 500,000 as a lunch. A lunch dish left on the list after
      // the slot becomes breakfast is a dish the portal is not offering, and
      // the pre-flight would demand credit for a meal the hunt cannot buy.
      final retargeted = configured().retargeted(targetSlot: MealSlot.breakfast);

      expect(retargeted.targetSlot, MealSlot.breakfast);
      expect(retargeted.dishPriority, isEmpty);
      expect(retargeted.hallPriority, isEmpty);
    });

    test('a new date clears the dish and hall lists', () {
      final retargeted =
          configured().retargeted(targetDate: DateTime.utc(2026, 10, 23));

      expect(retargeted.targetDate, DateTime.utc(2026, 10, 23));
      expect(retargeted.dishPriority, isEmpty);
      expect(retargeted.hallPriority, isEmpty);
    });

    test('the same target keeps the lists', () {
      final config = configured();

      expect(config.retargeted(targetSlot: MealSlot.lunch), same(config));
      expect(
        config.retargeted(targetDate: DateTime.utc(2026, 10, 22)),
        same(config),
      );
    });

    test('the window and the rate are not disturbed', () {
      final config = HuntConfig(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 10, 22),
        dishPriority: [dish('a', 'لوبیا پلو', 350000)],
      );

      final retargeted = config.retargeted(targetSlot: MealSlot.dinner);

      expect(retargeted.windowStart, const ClockTime(16, 30));
      expect(retargeted.windowEnd, const ClockTime(20, 30));
    });
  });

  group('the projected request count', () {
    test('counts the peak and off-peak parts of the window', () {
      // A four-hour window fully inside the peak, at one request per five
      // seconds: 14400 / 5 = 2880.
      final config = HuntConfig(
        targetSlot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        rate: HuntRate(
          peakInterval: const Duration(seconds: 5),
          offPeakInterval: const Duration(minutes: 2),
        ),
      );
      expect(config.peakOverlapSeconds, 4 * 3600);
      expect(config.projectedRequests(), 2880);
    });

    test('a window that misses the peak entirely polls off-peak throughout', () {
      // A lunch hunt running in the evening window never sees peak, so
      // projecting it as if it were peak would overstate the request count and
      // hide the fact that the hunt was set up wrong.
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        rate: HuntRate(
          peakInterval: const Duration(seconds: 5),
          offPeakInterval: const Duration(minutes: 2),
        ),
      );
      expect(config.peakOverlapSeconds, 0);
      expect(config.projectedRequests(), 4 * 3600 ~/ 120);
    });

    test('a faster rate projects a larger count', () {
      HuntConfig withPeak(Duration interval) => HuntConfig(
            targetSlot: MealSlot.dinner,
            windowStart: const ClockTime(16, 30),
            windowEnd: const ClockTime(20, 30),
            rate: HuntRate(
              peakInterval: interval,
              offPeakInterval: const Duration(minutes: 15),
            ),
          );

      expect(
        withPeak(const Duration(seconds: 2)).projectedRequests(),
        greaterThan(withPeak(const Duration(seconds: 10)).projectedRequests()),
      );
    });

    test('the request count for a span never goes negative', () {
      expect(HuntConfig.requestsFor(const Duration(seconds: 5), 0), 0);
      expect(HuntConfig.requestsFor(Duration.zero, 100), 0);
    });
  });

  group('the derived rule', () {
    test('carries the hunt window and the target slot', () {
      final config = HuntConfig(
        targetSlot: MealSlot.dinner,
        windowStart: const ClockTime(17, 0),
        windowEnd: const ClockTime(19, 0),
        dishPriority: [dish('a', 'لوبیا پلو', 350000)],
      );

      final rule = config.toRule(id: 'r1', account: 'a1');

      expect(rule.id, 'r1');
      expect(rule.windowStart, const ClockTime(17, 0));
      expect(rule.windowEnd, const ClockTime(19, 0));
      expect(rule.slots, {MealSlot.dinner});
    });

    test('the ceiling is the dearest dish, so the fallback stays affordable', () {
      final config = HuntConfig(
        dishPriority: [
          dish('a', 'لوبیا پلو', 350000),
          dish('b', 'چلو گوشت', 500000),
        ],
      );

      expect(config.toRule(id: 'r1', account: 'a1').maxPriceRial, 500000);
    });

    test('toRule carries windowStartDate and windowDate for cross-day hunt', () {
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );

      final rule = config.toRule(id: 'r1', account: 'a1');

      expect(rule.windowStartDate, DateTime.utc(2026, 11, 2));
      expect(rule.windowDate, DateTime.utc(2026, 11, 3));
      expect(rule.windowStart, const ClockTime(18, 20));
      expect(rule.windowEnd, const ClockTime(14, 0));
    });
  });

  group('cross-day hunt configuration', () {
    test('effectiveStartDate uses startDate when provided', () {
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
      );
      expect(config.effectiveStartDate, DateTime.utc(2026, 11, 2));
      expect(config.collectionDate, DateTime.utc(2026, 11, 3));
    });

    test('windowSeconds calculates exact span across days', () {
      // From 2026-11-02 18:20 to 2026-11-03 14:00:
      // 19 hours and 40 minutes = 1180 minutes = 70800 seconds.
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );
      expect(config.windowSeconds, 1180 * 60);
    });

    test('peak overlap is calculated only on the collection date', () {
      // Lunch peak window: 09:00 - 15:30.
      // Hunt runs from 2026-11-02 18:20 to 2026-11-03 14:00.
      // On 2026-11-03 (collection day), hunt runs from 00:00 to 14:00.
      // Peak overlap on 2026-11-03: 09:00 to 14:00 = 5 hours = 18000 seconds.
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );
      expect(config.peakOverlapSeconds, 5 * 3600);
    });

    test('isPeak and intervalAt are off-peak before collection date even during meal hours', () {
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
        rate: HuntRate(
          peakInterval: const Duration(seconds: 5),
          offPeakInterval: const Duration(minutes: 2),
        ),
      );

      // On 2026-11-02 (the day before) at 12:00, lunch is not being distributed today
      expect(
        config.isPeak(const ClockTime(12, 0), portalDate: DateTime.utc(2026, 11, 2)),
        isFalse,
      );
      expect(
        config.intervalAt(const ClockTime(12, 0), portalDate: DateTime.utc(2026, 11, 2)),
        const Duration(minutes: 2),
      );

      // On 2026-11-03 (collection date) at 12:00, lunch IS distributed
      expect(
        config.isPeak(const ClockTime(12, 0), portalDate: DateTime.utc(2026, 11, 3)),
        isTrue,
      );
      expect(
        config.intervalAt(const ClockTime(12, 0), portalDate: DateTime.utc(2026, 11, 3)),
        const Duration(seconds: 5),
      );
    });

    test('isWithinWindow checks datetime span when portalDate is provided', () {
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );

      // 2026-11-02 17:00: before start
      expect(
        config.isWithinWindow(const ClockTime(17, 0), portalDate: DateTime.utc(2026, 11, 2)),
        isFalse,
      );

      // 2026-11-02 18:20: start instant
      expect(
        config.isWithinWindow(const ClockTime(18, 20), portalDate: DateTime.utc(2026, 11, 2)),
        isTrue,
      );

      // 2026-11-03 10:00: morning of collection day
      expect(
        config.isWithinWindow(const ClockTime(10, 0), portalDate: DateTime.utc(2026, 11, 3)),
        isTrue,
      );

      // 2026-11-03 14:00: end instant
      expect(
        config.isWithinWindow(const ClockTime(14, 0), portalDate: DateTime.utc(2026, 11, 3)),
        isTrue,
      );

      // 2026-11-03 14:01: after end
      expect(
        config.isWithinWindow(const ClockTime(14, 1), portalDate: DateTime.utc(2026, 11, 3)),
        isFalse,
      );
    });

    test('effectiveStartDate defaults to day before collectionDate for overnight window when startDate is null', () {
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: null,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );
      expect(config.effectiveStartDate, DateTime.utc(2026, 11, 2));
      expect(config.windowSeconds, 1180 * 60);
    });

    test('retargeted preserves valid startDate when switching target slot or date', () {
      final initial = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3),
        startDate: DateTime.utc(2026, 11, 2),
      );
      final changedSlot = initial.retargeted(targetSlot: MealSlot.dinner);
      expect(changedSlot.startDate, DateTime.utc(2026, 11, 2));

      final changedDate = initial.retargeted(targetDate: DateTime.utc(2026, 11, 4));
      expect(changedDate.startDate, DateTime.utc(2026, 11, 2));

      // If retargeted to an earlier date before startDate, startDate is cleared
      final earlierDate = initial.retargeted(targetDate: DateTime.utc(2026, 11, 1));
      expect(earlierDate.startDate, isNull);
    });
  });

  group('dynamic request budget calculation', () {
    test('allocates proportional budget covering 4-hour window with safety margin', () {
      // 4-hour window from 16:30 to 20:30 (14400s) with 6s peak poll interval
      // Projected requests = 14400 / 6 = 2400.
      // Dynamic budget with 30% margin = 2400 * 1.3 = 3120 requests (far exceeding 400).
      final config = HuntConfig(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        targetSlot: MealSlot.dinner,
        rate: HuntRate(peakInterval: const Duration(seconds: 6)),
      );
      expect(config.requestBudget, greaterThanOrEqualTo(3120));
    });

    test('respects default floor of 400 requests for short windows', () {
      // 5-minute window with 10s poll -> projected = 30 requests.
      // Dynamic budget should floor at HuntBounds.defaultRequestBudget (400).
      final config = HuntConfig(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(16, 35),
        targetSlot: MealSlot.dinner,
        rate: HuntRate(peakInterval: const Duration(seconds: 10)),
      );
      expect(config.requestBudget, 400);
    });

    test('copyWith recalculates dynamic budget when rate or window changes', () {
      final config = HuntConfig(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(17, 30), // 1 hour -> 600 requests at 6s -> 780 budget
        rate: HuntRate(peakInterval: const Duration(seconds: 6)),
      );
      expect(config.requestBudget, 780);

      final expanded = config.copyWith(
        windowEnd: const ClockTime(20, 30), // expands to 4 hours
      );
      expect(expanded.requestBudget, greaterThanOrEqualTo(3120));
    });
  });
}
