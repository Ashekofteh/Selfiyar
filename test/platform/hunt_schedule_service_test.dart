/// When the hunt's alarm is armed, and when it is deliberately not.
///
/// ## The defect this pins
///
/// F85: the headless hunt re-armed its alarm with the **same** target date,
/// and the re-arm used the first arm's rule — which arms a window that is
/// open *right now*. So the alarm fired at once, the hunt refused, the
/// refusal re-armed again, and the loop ran for as long as the window stayed
/// open: a wake-up every few seconds, each one a round of portal requests.
///
/// The two arms are genuinely different, and this file is where that
/// difference is pinned:
///
///  * the **first** arm is the student's own action, so a window that is
///    open now is a window they mean to hunt in, and it fires at once;
///  * the **re-arm** is automatic and follows a run that has just ended, so
///    it only arms a window that is still ahead.
library;

import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/hunt_schedule_service.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bridge that records the alarms it was asked for.
class _RecordingBridge extends PlatformBridge {
  final List<String> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<void> scheduleHuntAlarm({
    required AccountId accountId,
    required DateTime triggerAt,
  }) async {
    scheduled.add('$accountId@${triggerAt.toIso8601String()}');
  }

  @override
  Future<void> cancelHuntAlarm(AccountId accountId) async {
    cancelled.add(accountId);
  }
}

/// A clock that says what it is told.
class _FixedClock implements ServerClock {
  _FixedClock(this._now, {this.synced = true});

  final DateTime _now;
  final bool synced;

  @override
  DateTime get nowUtc => _now;

  @override
  bool get isSynced => synced;

  @override
  Duration get staleness => Duration.zero;
}

void main() {
  const account = 'acc-1';

  // A hunt for the 24th's dinner, in the evening window. 2026-10-24 is a
  // Saturday, and Saturday serves a dinner.
  HuntConfig configFor(DateTime target) => HuntConfig(
        targetSlot: MealSlot.dinner,
        targetDate: target,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        enabled: true,
      );

  group('the first arm', () {
    test('arms a window that is ahead', () async {
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.arm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 22)),
      );

      expect(result.status, HuntScheduleStatus.scheduled);
      expect(bridge.scheduled, hasLength(1));
    });

    test('arms a window that is open right now', () async {
      // The student set this hunt up while its window is open, so it fires at
      // once. That is what they meant, and the first arm honours it.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.arm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 24, 15)),
      );

      // The status says the window is **open**, not that a future start was
      // scheduled — so the screen can say "starts now" rather than printing
      // 16:30 at 18:11. The alarm is still armed, because for the first arm an
      // open window is exactly the "start immediately" the student asked for.
      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.isOpenNow, isTrue);
      expect(bridge.scheduled, hasLength(1),
          reason: 'a window the student is looking at is one they mean to '
              'hunt in');
    });

    test('refuses a window that has already closed', () async {
      // After 20:30 the meal has been released and taken, so there is nothing
      // left to hunt — and an alarm into the past would fire at once for a
      // hunt that can buy nothing.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.arm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 24, 17, 30)),
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
      expect(bridge.scheduled, isEmpty);
    });

    test('refuses a meal that is not served on the target date', () async {
      // 2026-10-22 is a Thursday, and Thursday serves no dinner. The hunt must
      // not be armed for a listing the portal will never publish.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.arm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 22)),
        clock: _FixedClock(DateTime.utc(2026, 10, 21)),
      );

      expect(result.status, HuntScheduleStatus.mealNotServed);
      expect(bridge.scheduled, isEmpty);
    });
  });

  group('the re-arm', () {
    test('does not arm a window that is open right now', () async {
      // The loop this prevents: the hunt refused, re-armed into the open
      // window, fired at once, refused again.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.rearm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 24, 15)),
      );

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(bridge.scheduled, isEmpty,
          reason: 'arming an open window would restart the hunt the instant '
              'it ended');
    });

    test('arms a window that is still ahead', () async {
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.rearm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 22)),
      );

      expect(result.status, HuntScheduleStatus.scheduled);
      expect(bridge.scheduled, hasLength(1));
    });

    test('cancels the old alarm first', () async {
      // A stale alarm must never be left behind to fire at the wrong time.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      await service.rearm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 22)),
      );

      expect(bridge.cancelled, contains(account));
    });

    test('an unsynced clock arms nothing', () async {
      // The comparison is between a portal-derived instant and "now", so
      // "now" has to be the portal's now. Guessing it is what the loop
      // looked like.
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.rearm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)),
        clock: _FixedClock(DateTime.utc(2026, 10, 22), synced: false),
      );

      expect(result.status, HuntScheduleStatus.clockUnsynced);
      expect(bridge.scheduled, isEmpty);
    });

    test('a switched-off hunt arms nothing', () async {
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      final result = await service.rearm(
        accountId: account,
        config: configFor(DateTime.utc(2026, 10, 24)).copyWith(enabled: false),
        clock: _FixedClock(DateTime.utc(2026, 10, 22)),
      );

      expect(result.status, HuntScheduleStatus.disabled);
      expect(bridge.scheduled, isEmpty);
    });

    test('scheduleFor resolves overnight window for future meal when startDate is null', () {
      final bridge = _RecordingBridge();
      final service = HuntScheduleService(bridge: bridge);

      // Today is Monday 2026-11-02 14:50 UTC (18:20 local)
      final clock = _FixedClock(DateTime.utc(2026, 11, 2, 14, 50));
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        targetDate: DateTime.utc(2026, 11, 3), // Tomorrow
        startDate: null,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
      );

      final result = service.scheduleFor(config, clock);

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.schedule!.startDate, DateTime.utc(2026, 11, 2));
      expect(result.schedule!.collectionDate, DateTime.utc(2026, 11, 3));
    });
  });
}
