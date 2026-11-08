import 'package:bahonar_nut/core/account.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/reminder.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/reminder_delivery.dart';
import 'package:bahonar_nut/platform/reminder_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reminder delivery, at the level the platform sees it.
///
/// The defect these guard against was a **wiring** one: the alarms were never
/// armed, and a fired alarm never reached the Dart side. The service had
/// `schedule` and `deliver`, and nothing called them, so a reminder could
/// never fire — while the screen showed the switches working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  final bridge = PlatformBridge(channel: channel);

  /// The alarms that were scheduled, as (requestCode, payload) pairs.
  List<(int, String?)> scheduledAlarms() => [
        for (final call in calls)
          if (call.method == 'scheduleAlarm')
            (
              (call.arguments as Map)['requestCode'] as int,
              (call.arguments as Map)['payload'] as String?,
            ),
      ];

  /// The alarm request codes that were cancelled.
  List<int> cancelledAlarms() => [
        for (final call in calls)
          if (call.method == 'cancelAlarm')
            (call.arguments as Map)['requestCode'] as int,
      ];

  /// The notifications that were posted.
  List<(String, String)> postedNotifications() => [
        for (final call in calls)
          if (call.method == 'postNotification')
            (
              (call.arguments as Map)['title'] as String,
              (call.arguments as Map)['body'] as String,
            ),
      ];

  group('arming the alarms', () {
    test('the configured slots are armed', () async {
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());

      await service.schedule(const ReminderConfig(
        accountIds: {'a1'},
      ));

      final scheduled = scheduledAlarms();
      expect(scheduled, hasLength(2),
          reason: 'the lunch and the evening slot are both armed');
      expect(scheduled.map((s) => s.$2), containsAll(['lunch', 'evening']));
    });

    test('the master switch off arms nothing', () async {
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());

      await service.schedule(const ReminderConfig(
        masterEnabled: false,
        accountIds: {'a1'},
      ));

      expect(scheduledAlarms(), isEmpty,
          reason: 'the switch says off, so no alarm may fire');
    });

    test('a slot with no account is not armed', () async {
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());

      await service.schedule(const ReminderConfig(
        accountIds: {},
      ));

      expect(scheduledAlarms(), isEmpty,
          reason: 'a reminder about no account is noise');
    });

    test('one slot switched off is not armed, and the other is', () async {
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());

      await service.schedule(ReminderConfig(
        accountIds: {'a1'},
        evening: ReminderSlotConfig.eveningDefault.copyWith(enabled: false),
      ));

      final scheduled = scheduledAlarms();
      expect(scheduled, hasLength(1));
      expect(scheduled.single.$2, 'lunch');
    });

    test('an unsynced clock still arms the slots', () async {
      // The clock throws when it is not synced, and a cold start has no server
      // time yet. Reading the clock's own "today" while arming the nudge
      // would throw out of the whole pass — and the slot alarms, which are
      // armed in the same call, would be lost with it.
      //
      // This is exactly what happened on the device: the slots were armed
      // only because a *later* pass succeeded, and the nudge never was.
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());
      final unsynced = SyncedServerClock();
      expect(unsynced.isSynced, isFalse);

      await service.schedule(
        ReminderConfig(accountIds: {'a1'}),
        clock: unsynced,
      );

      final scheduled = scheduledAlarms();
      expect(scheduled, isNotEmpty,
          reason: 'the slot alarms must survive an unsynced clock');
      expect(scheduled.map((s) => s.$2), contains('lunch'));
      expect(scheduled.map((s) => s.$2), contains('evening'));
    });

    test('arming replaces the old alarm rather than adding one', () async {
      final service = ReminderService(bridge: bridge, mealStore: LocalMealStore());

      await service.schedule(const ReminderConfig(accountIds: {'a1'}));

      expect(cancelledAlarms(), isNotEmpty,
          reason: 'a re-armed slot must not leave the old alarm behind, or it '
              'would fire at the old time as well');
    });
  });

  group('a fired alarm', () {
    late LocalMealStore store;
    late ReminderService service;
    late ReminderDelivery delivery;

    setUp(() {
      store = LocalMealStore();
      service = ReminderService(bridge: bridge, mealStore: store);
      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(accountIds: {'a1'}),
      );
    });

    test('a lunch fire posts the digest', () async {
      // The digest is scoped to **today**, so the fixture has to be today.
      // A hardcoded date made this test pass for one day and fail for the
      // rest — the same time-of-day trap the clock test had.
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      store.put(StoredMeal(
        accountId: 'a1',
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: today,
        dishName: 'چلو خورشت قیمه',
      ));

      await delivery.handleFire('lunch');

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$2, contains('چلو خورشت قیمه'));
      expect(posted.single.$2, contains('مقسمی'));
    });

    test('a fired alarm re-arms itself for tomorrow', () async {
      // An exact alarm is one-shot. Without a successor, the reminder works
      // exactly once and then stops, silently.
      store.put(StoredMeal(
        accountId: 'a1',
        date: DateTime.utc(2026, 10, 20),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 20),
      ));

      await delivery.handleFire('lunch');

      final scheduled = scheduledAlarms();
      expect(scheduled, isNotEmpty,
          reason: 'the alarm must re-arm itself, or tomorrow has no reminder');
      expect(scheduled.last.$2, 'lunch');
    });

    test('when liveCheckEnabled is true, handleFire reconciles from portal', () async {
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      var liveCheckCalled = false;
      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1'},
          liveCheckEnabled: true,
        ),
        readReservations: (accountId) async {
          liveCheckCalled = true;
          return [
            Reservation(
              id: 'res-live-1',
              date: today,
              slot: MealSlot.lunch,
              hall: const Hall(id: 'h1', name: 'مرکزی'),
              option: const MenuOption(id: 'o1', name: 'چلو قورمه سبزی', priceRial: 250000),
              state: ReservationState.active,
            ),
          ];
        },
      );

      expect(store.forAccount('a1'), isEmpty);

      final result = await delivery.handleFire('lunch');

      expect(result, ReminderSlot.lunch);
      expect(liveCheckCalled, isTrue);
      expect(store.forAccount('a1'), isNotEmpty);
      expect(postedNotifications(), hasLength(1));
      expect(postedNotifications().first.$2, contains('چلو قورمه سبزی'));
    });

    test(
        'when liveCheckEnabled is true, handleFire reconciles multiple accounts concurrently and calls persist once',
        () async {
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      var concurrentReads = 0;
      var maxConcurrent = 0;
      var persistCalls = 0;

      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
          SavedAccount(
            id: 'a2',
            studentId: '400123457',
            alias: 'احمدی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1', 'a2'},
          liveCheckEnabled: true,
        ),
        persist: () async {
          persistCalls++;
        },
        readReservations: (accountId) async {
          concurrentReads++;
          if (concurrentReads > maxConcurrent) {
            maxConcurrent = concurrentReads;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          concurrentReads--;
          return [
            Reservation(
              id: 'res-$accountId',
              date: today,
              slot: MealSlot.lunch,
              hall: const Hall(id: 'h1', name: 'مرکزی'),
              option: MenuOption(
                id: 'o1',
                name: accountId == 'a1' ? 'چلو قورمه سبزی' : 'چلو قیمه',
                priceRial: 250000,
              ),
              state: ReservationState.active,
            ),
          ];
        },
      );

      final result = await delivery.handleFire('lunch');

      expect(result, ReminderSlot.lunch);
      expect(maxConcurrent, 2,
          reason: 'Both accounts should be read concurrently');
      expect(persistCalls, 1,
          reason:
              'Persist should be called exactly once after all accounts are read');
      expect(store.forAccount('a1'), isNotEmpty);
      expect(store.forAccount('a2'), isNotEmpty);
      expect(postedNotifications(), hasLength(1));
    });

    test(
        'when liveCheckEnabled is true, failure in one account does not stop others and still persists',
        () async {
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      var persistCalls = 0;

      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
          SavedAccount(
            id: 'a2',
            studentId: '400123457',
            alias: 'احمدی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1', 'a2'},
          liveCheckEnabled: true,
        ),
        persist: () async {
          persistCalls++;
        },
        readReservations: (accountId) async {
          if (accountId == 'a1') {
            throw Exception('Network timeout for a1');
          }
          return [
            Reservation(
              id: 'res-a2',
              date: today,
              slot: MealSlot.lunch,
              hall: const Hall(id: 'h1', name: 'مرکزی'),
              option: const MenuOption(
                id: 'o2',
                name: 'زرشک پلو',
                priceRial: 250000,
              ),
              state: ReservationState.active,
            ),
          ];
        },
      );

      final result = await delivery.handleFire('lunch');

      expect(result, ReminderSlot.lunch);
      expect(store.forAccount('a1'), isEmpty);
      expect(store.forAccount('a2'), isNotEmpty);
      expect(persistCalls, 1,
          reason:
              'Persist should still be called for the successful account');
    });

    test(
        'when liveCheckEnabled is true, reconciliation preserves existing foodBasket meals and updates isConsumed',
        () async {
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      store.put(StoredMeal(
        accountId: 'a1',
        date: today,
        slot: MealSlot.dinner,
        source: MealSource.basketPurchase,
        capturedAt: today,
        dishName: 'اکبر جوجه سبد',
        hallName: 'مرکزی',
      ));

      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1'},
          liveCheckEnabled: true,
        ),
        readReservations: (accountId) async {
          return [
            Reservation(
              id: 'res-lunch',
              date: today,
              slot: MealSlot.lunch,
              hall: const Hall(id: 'h1', name: 'مرکزی'),
              option: const MenuOption(
                id: 'o1',
                name: 'چلو قورمه سبزی',
                priceRial: 250000,
              ),
              state: ReservationState.consumed,
            ),
          ];
        },
      );

      final result = await delivery.handleFire('lunch');
      expect(result, ReminderSlot.lunch);

      final meals = store.forAccount('a1');
      expect(meals, hasLength(2));
      final weeklyMeal = meals.firstWhere((m) => m.slot == MealSlot.lunch);
      expect(weeklyMeal.dishName, 'چلو قورمه سبزی');
      expect(weeklyMeal.isConsumed, isTrue);

      final basketMeal = meals.firstWhere((m) => m.slot == MealSlot.dinner);
      expect(basketMeal.dishName, 'اکبر جوجه سبد');
      expect(basketMeal.source, MealSource.basketPurchase);
    });

    test('a payload that is not a reminder is ignored', () async {
      final result = await delivery.handleFire('refresh');

      expect(result, isNull);
      expect(postedNotifications(), isEmpty);
    });

    test('a slot the user has switched off does not fire', () async {
      delivery.config = const ReminderConfig(
        masterEnabled: false,
        accountIds: {'a1'},
      );
      store.put(StoredMeal(
        accountId: 'a1',
        date: DateTime.utc(2026, 10, 20),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 20),
      ));

      await delivery.handleFire('lunch');

      expect(postedNotifications(), isEmpty,
          reason: 'a reminder the user switched off is noise');
    });

    test('the evening slot covers dinner and breakfast together', () async {
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);

      store.put(StoredMeal(
        accountId: 'a1',
        date: today,
        slot: MealSlot.dinner,
        source: MealSource.weeklyReservation,
        capturedAt: today,
        dishName: 'خوراک سالاد الویه',
      ));

      await delivery.handleFire('evening');

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$2, contains('خوراک سالاد الویه'));
    });

    test('an account with nothing to say produces no notification', () async {
      await delivery.handleFire('lunch');

      expect(postedNotifications(), isEmpty,
          reason: 'a reminder with nothing in it is noise');
    });

    test('the digest is about today, not about every meal held', () async {
      // The mirror holds a fortnight. A digest listing all of it would say
      // "you have 17 lunches", and the heading would name one date while the
      // body listed another. Seen on the device.
      final today = DateTime.now();
      final todayUtc = DateTime.utc(today.year, today.month, today.day);

      for (final offset in [0, 1, 2, 3, 5]) {
        store.put(StoredMeal(
          accountId: 'a1',
          date: todayUtc.add(Duration(days: offset)),
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: todayUtc,
          dishName: 'غذای روز $offset',
        ));
      }

      await delivery.handleFire('lunch');

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$2, contains('غذای روز 0'));
      expect(posted.single.$2, isNot(contains('غذای روز 1')),
          reason: "another day's lunch is not what today's reminder is about");
      expect(posted.single.$2, isNot(contains('غذای روز 2')));
    });

    test('the evening digest covers tonight and tomorrow morning', () async {
      // Dinner and the next breakfast are collected together, so the evening
      // reminder spans two days.
      final today = DateTime.now();
      final todayUtc = DateTime.utc(today.year, today.month, today.day);

      store.put(StoredMeal(
        accountId: 'a1',
        date: todayUtc,
        slot: MealSlot.dinner,
        source: MealSource.weeklyReservation,
        capturedAt: todayUtc,
        dishName: 'غذای شام امشب',
      ));
      store.put(StoredMeal(
        accountId: 'a1',
        date: todayUtc.add(const Duration(days: 1)),
        slot: MealSlot.breakfast,
        source: MealSource.weeklyReservation,
        capturedAt: todayUtc,
        dishName: 'صبحانه فردا',
      ));
      store.put(StoredMeal(
        accountId: 'a1',
        date: todayUtc.add(const Duration(days: 3)),
        slot: MealSlot.dinner,
        source: MealSource.weeklyReservation,
        capturedAt: todayUtc,
        dishName: 'شام پس فردا',
      ));

      await delivery.handleFire('evening');

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$2, contains('غذای شام امشب'));
      expect(posted.single.$2, contains('صبحانه فردا'));
      expect(posted.single.$2, isNot(contains('شام پس فردا')));
    });
  });

  group('the nudge', () {
    late ReminderDelivery nudge;
    late FixedServerClock clock;

    /// The reservations the fake portal serves.
    final reservationsByAccount = <AccountId, List<Reservation>>{};

    setUp(() {
      reservationsByAccount.clear();
      clock = FixedServerClock.now(DateTime.utc(2026, 10, 21, 5, 30));
      nudge = ReminderDelivery(
        service: ReminderService(bridge: bridge, mealStore: LocalMealStore()),
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1'},
          nextWeekNudgeEnabled: true,
        ),
        clock: clock,
        readReservations: (accountId) async =>
            reservationsByAccount[accountId] ?? const [],
      );
    });

    test('a fire arms the next check', () async {
      await nudge.handleFire(ReminderService.nudgePayload);

      final scheduled = scheduledAlarms();
      expect(scheduled, isNotEmpty,
          reason: 'the nudge is a sequence of checks: each one arms the next');
      expect(scheduled.last.$2, ReminderService.nudgePayload);
    });

    test('a fire with an unbooked week posts the nudge', () async {
      // No reservations: the whole coming week is missing.
      reservationsByAccount['a1'] = const [];

      await nudge.handleFire(ReminderService.nudgePayload);

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$1, contains('رزرو'),
          reason: 'the nudge is about reserving');
    });

    test('a fully booked week is silent, but the next check is still armed',
        () async {
      // The whole week is held: the nudge must stay quiet, or the user learns
      // to ignore it.
      reservationsByAccount['a1'] = [
        for (var day = 24; day <= 30; day++)
          for (final slot in MealSlot.values)
            Reservation(
              id: 'r$day${slot.name}',
              date: DateTime.utc(2026, 10, day),
              slot: slot,
              hall: const Hall(id: '1', name: 'مرکزی برادران'),
              option:
                  const MenuOption(id: '1', name: 'غذا', priceRial: 150000),
              state: ReservationState.active,
            ),
      ];

      await nudge.handleFire(ReminderService.nudgePayload);

      expect(postedNotifications(), isEmpty,
          reason: 'a booked week is not worth a notification');
      expect(scheduledAlarms(), isNotEmpty,
          reason: 'the next check is still armed, and it will be silent too');
    });

    test('the nudge is switched off by the configuration', () async {
      nudge.config = const ReminderConfig(
        accountIds: {'a1'},
        nextWeekNudgeEnabled: false,
      );

      await nudge.handleFire(ReminderService.nudgePayload);

      expect(postedNotifications(), isEmpty);
    });

    test('the nudge is suppressed if dismissed for the current week', () async {
      final targetSat = DateTime.utc(2026, 10, 24);
      nudge.config = ReminderConfig(
        accountIds: {'a1'},
        nextWeekNudgeEnabled: true,
        dismissedNudgeWeekSaturday: targetSat,
      );

      await nudge.handleFire(ReminderService.nudgePayload);

      expect(postedNotifications(), isEmpty,
          reason: 'snoozed/dismissed for this week only');
      expect(scheduledAlarms(), isNotEmpty,
          reason: 'still re-arms for subsequent weeks');
    });

    test('the nudge checks only accounts selected in nudgeAccountIds', () async {
      // a1 has no meals booked, but a2 has all meals booked.
      reservationsByAccount['a1'] = const [];
      reservationsByAccount['a2'] = [
        for (var day = 24; day <= 30; day++)
          for (final slot in MealSlot.values)
            Reservation(
              id: 'r',
              date: DateTime.utc(2026, 10, day),
              slot: slot,
              hall: const Hall(id: '1', name: 'مرکزی برادران'),
              option:
                  const MenuOption(id: '1', name: 'غذا', priceRial: 150000),
              state: ReservationState.active,
            ),
      ];

      // If both a1 and a2 were checked, a1 would trigger a nudge.
      // But only a2 is in nudgeAccountIds!
      nudge.config = const ReminderConfig(
        accountIds: {'a1', 'a2'},
        nudgeAccountIds: {'a2'},
        nextWeekNudgeEnabled: true,
      );

      await nudge.handleFire(ReminderService.nudgePayload);

      expect(postedNotifications(), isEmpty,
          reason: 'only a2 is checked, and a2 has all meals booked');
    });

    test('the nudge queries multiple accounts concurrently and isolates errors',
        () async {
      var concurrentReads = 0;
      var maxConcurrent = 0;
      final readAccounts = <AccountId>[];

      nudge = ReminderDelivery(
        service: ReminderService(bridge: bridge, mealStore: LocalMealStore()),
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
          SavedAccount(
            id: 'a2',
            studentId: '400123457',
            alias: 'احمدی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1', 'a2'},
          nextWeekNudgeEnabled: true,
        ),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21, 12)),
        readReservations: (accountId) async {
          readAccounts.add(accountId);
          concurrentReads++;
          if (concurrentReads > maxConcurrent) {
            maxConcurrent = concurrentReads;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          concurrentReads--;
          if (accountId == 'a1') {
            throw Exception('Simulated network error for a1');
          }
          return const <Reservation>[];
        },
      );

      await nudge.handleFire(ReminderService.nudgePayload);

      expect(readAccounts, containsAll(['a1', 'a2']));
      expect(maxConcurrent, 2,
          reason: 'Both accounts should be queried concurrently');
      final posted = postedNotifications();
      expect(posted, hasLength(1));
      // a1 failed and is reported in the failure digest, while a2 was processed
      expect(posted.single.$2, contains('مقسمی'));
    });

    test(
        'the nudge failure reporting order is deterministic across concurrent failures',
        () async {
      nudge = ReminderDelivery(
        service: ReminderService(bridge: bridge, mealStore: LocalMealStore()),
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'حساب اول',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
          SavedAccount(
            id: 'a2',
            studentId: '400123457',
            alias: 'حساب دوم',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
          SavedAccount(
            id: 'a3',
            studentId: '400123458',
            alias: 'حساب سوم',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(
          accountIds: {'a1', 'a2', 'a3'},
          nextWeekNudgeEnabled: true,
        ),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21, 12)),
        readReservations: (accountId) async {
          if (accountId == 'a3') {
            return const <Reservation>[];
          }
          // Simulate differing async delays where a2 finishes failing before a1
          if (accountId == 'a2') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          throw Exception('Network error for $accountId');
        },
      );

      await nudge.handleFire(ReminderService.nudgePayload);

      final posted = postedNotifications();
      expect(posted, hasLength(1));
      // Ordering must match targetAccounts order: 'حساب اول' then 'حساب دوم'
      expect(posted.single.$2, contains('بررسی نشد: حساب اول، حساب دوم'));
    });
  });

  group('the catch-up', () {
    late LocalMealStore store;
    late ReminderService service;
    late ReminderDelivery delivery;

    setUp(() {
      store = LocalMealStore();
      service = ReminderService(bridge: bridge, mealStore: store);
      delivery = ReminderDelivery(
        service: service,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(accountIds: {'a1'}),
      );
    });

    test('a delivery owed while the app was dead is delivered', () async {
      // The alarm fired when the process was dead, so the digest was owed.
      // The digest is composed in Dart, from the local mirror, and the
      // mirror says there is a lunch today.
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);
      store.put(StoredMeal(
        accountId: 'a1',
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: today,
        dishName: 'چلو خورشت قیمه',
      ));

      final delivered = await delivery.deliverPending(['lunch']);

      expect(delivered, ['lunch']);
      final posted = postedNotifications();
      expect(posted, hasLength(1));
      expect(posted.single.$2, contains('چلو خورشت قیمه'));
    });

    test('nothing owed means nothing delivered', () async {
      final delivered = await delivery.deliverPending([]);

      expect(delivered, isEmpty);
      expect(postedNotifications(), isEmpty);
    });

    test('a delivery that fails stays owed', () async {
      // The record is cleared by the caller only for what was delivered, so
      // a failure must not be reported as a delivery — otherwise the owed
      // reminder is cleared and the student never learns about it.
      final delivery = ReminderDelivery(
        service: ReminderService(bridge: bridge, mealStore: store),
        accounts: const [],
        // No configuration: the delivery cannot compose anything, and the
        // slot check rejects it.
        config: null,
      );

      final delivered = await delivery.deliverPending(['lunch']);

      expect(delivered, isEmpty);
    });

    test('the digests are delivered before the nudge', () async {
      // The digests come from the local mirror and need no network. The
      // nudge needs a live read, and a read in Doze is *blocked* — it hangs
      // rather than failing. So the nudge goes last, or it holds the
      // digests hostage until Android opens a maintenance window.
      //
      // Measured on the emulator: the catch-up waited ten seconds for a
      // blocked read, and the digest owed alongside it was stuck behind it
      // the whole time.
      final order = <String>[];

      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);
      store.put(StoredMeal(
        accountId: 'a1',
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: today,
        dishName: 'چلو خورشت قیمه',
      ));

      // The nudge is owed FIRST, so the order of the list cannot be what
      // puts it last — the delivery has to reorder them.
      final recording = _RecordingReminderService(
        bridge: bridge,
        mealStore: store,
        order: order,
      );

      final delivery = ReminderDelivery(
        service: recording,
        accounts: [
          SavedAccount(
            id: 'a1',
            studentId: '400123456',
            alias: 'مقسمی',
            addedAt: DateTime.utc(2026, 10, 20),
          ),
        ],
        config: const ReminderConfig(accountIds: {'a1'}),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21, 12)),
        readReservations: (accountId) async {
          order.add('read');
          return const <Reservation>[];
        },
      );

      await delivery.deliverPending([
        ReminderService.nudgePayload,
        'lunch',
      ]);

      // The digest was posted, and it was posted before the read happened.
      expect(order.first, 'digest',
          reason: 'the digest was delivered before the nudge went to the '
              'network');
      expect(order, contains('read'));
    });

    test('the nudge read is bounded', () async {
      // A network read in Doze does not fail — it hangs, waiting for the
      // system to open a maintenance window. An unbounded read would hold
      // the delivery hostage: the student opens the app and nothing happens
      // until Android decides to let the request through.
      final delivery = ReminderDelivery(
        service: ReminderService(bridge: bridge, mealStore: store),
        accounts: const [],
        config: const ReminderConfig(accountIds: {'a1'}),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21, 12)),
        readTimeout: const Duration(milliseconds: 50),
        readReservations: (accountId) =>
            Future<List<Reservation>>.delayed(
          const Duration(seconds: 30),
          () => const <Reservation>[],
        ),
      );

      final stopwatch = Stopwatch()..start();
      final delivered = await delivery.deliverPending([
        ReminderService.nudgePayload,
      ]);
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the read was bounded, not waited on');
      expect(delivered, [ReminderService.nudgePayload],
          reason: 'a read that timed out is a reported failure, not a lost '
              'delivery');
    });
  });
}

/// A reminder service that records when a digest was delivered.
///
/// The ordering matters: a digest is composed from the local mirror and
/// needs no network, while the nudge needs a live read — and a read in Doze
/// is blocked, and it *hangs* rather than failing. So the digests have to go
/// first, and this is what proves it.
class _RecordingReminderService extends ReminderService {
  _RecordingReminderService({
    required super.bridge,
    required super.mealStore,
    required this.order,
  });

  /// The order the deliveries happened in.
  final List<String> order;

  @override
  Future<NotificationText?> deliver(
    ReminderSlot slot, {
    required ReminderConfig config,
    required Map<AccountId, String> accountNames,
  }) async {
    order.add('digest');
    return super.deliver(
      slot,
      config: config,
      accountNames: accountNames,
    );
  }
}
