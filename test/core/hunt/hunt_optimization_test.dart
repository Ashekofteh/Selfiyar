import 'dart:async';
import 'package:bahonar_nut/core/auth/account.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/hunt/hunt_success.dart';
import 'package:bahonar_nut/core/hunt/hunt_success_store.dart';
import 'package:bahonar_nut/core/hunt/snipe.dart';
import 'package:bahonar_nut/core/hunt/snipe_engine.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/hunt_service.dart';
import 'package:bahonar_nut/ui/state/hunt_state.dart';
import 'package:test/test.dart';

import '../../helpers/memory_stores.dart';
import '../../platform/hunt_service_test.dart';

void main() {
  group('Pillar 2 — Infinity (∞) Mode & Engine Safety', () {
    test('HuntBounds correctly clamps peak and off-peak intervals', () {
      expect(HuntBounds.clampPeak(Duration.zero), Duration.zero);
      expect(HuntBounds.clampPeak(const Duration(milliseconds: 500)), const Duration(seconds: 2));
      expect(HuntBounds.clampPeak(const Duration(seconds: 1)), const Duration(seconds: 2));
      expect(HuntBounds.clampPeak(const Duration(seconds: 10)), const Duration(seconds: 10));
      expect(HuntBounds.clampPeak(const Duration(seconds: 120)), const Duration(seconds: 60));

      // Off-peak is never infinity
      expect(HuntBounds.clampOffPeak(Duration.zero), HuntBounds.minOffPeakInterval);
      expect(HuntBounds.clampOffPeak(const Duration(seconds: 5)), HuntBounds.minOffPeakInterval);
    });

    test('risk acknowledgement is required for infinity mode', () {
      expect(HuntBounds.needsRiskAcknowledgement(Duration.zero), isTrue);
      expect(
        HuntRate(peakInterval: Duration.zero).needsRiskAcknowledgement,
        isTrue,
      );
    });

    test('projectedRequests returns -1 (unbounded) for infinity mode during peak', () {
      final config = HuntConfig(
        targetSlot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        rate: HuntRate(peakInterval: Duration.zero),
      );

      expect(config.projectedRequests(), equals(-1));
    });

    test('computeBudget returns unbounded budget for infinity mode without ceiling', () {
      final budget = HuntConfig.computeBudget(
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        targetSlot: MealSlot.dinner,
        rate: HuntRate(peakInterval: Duration.zero),
        targetDate: DateTime.utc(2026, 11, 23),
      );

      // User explicitly directed: No safety ceiling. Budget is effectively infinite.
      expect(budget, equals(1000000000));
    });
  });

  group('Pillar 3 — Multi-Account Concurrency & Ref Counting', () {
    test('SnipeEngine routes notifications to per-rule listeners', () async {
      final engine = DefaultSnipeEngine(
        client: FakePortalClient(),
        sessions: FakeSessionManager(),
        clock: FakeClock(now: DateTime.utc(2026, 11, 23)),
      );

      var listener1Called = false;
      var listener2Called = false;

      final listener1 = _RecordingListener(onClaimedCallback: () => listener1Called = true);
      final listener2 = _RecordingListener(onClaimedCallback: () => listener2Called = true);

      engine.setListener('hunt-account1', listener1);
      engine.setListener('hunt-account2', listener2);

      // Trigger listener on rule 1
      await engine.listenerFor('hunt-account1')?.onClaimed(
        ruleId: 'hunt-account1',
        listing: _dummyListing(),
        reservation: _dummyReservation(),
      );

      expect(listener1Called, isTrue);
      expect(listener2Called, isFalse);

      // Trigger listener on rule 2
      await engine.listenerFor('hunt-account2')?.onClaimed(
        ruleId: 'hunt-account2',
        listing: _dummyListing(),
        reservation: _dummyReservation(),
      );

      expect(listener2Called, isTrue);

      engine.clearListener('hunt-account1');
      expect(engine.listenerFor('hunt-account1'), isNull);
      expect(engine.listenerFor('hunt-account2'), isNotNull);
    });

    test('HuntService ref counts active accounts and only releases when all accounts are stopped', () async {
      final bridge = RecordingBridge();
      final store = FakeHuntConfigStore();
      final service = HuntService(
        bridge: bridge,
        engine: NoopEngine(),
        configStore: store,
      );

      // Start account 1
      await service.start(
        accountId: 'acc1',
        config: HuntConfig(enabled: true),
      );
      expect(service.isHunting('acc1'), isTrue);
      expect(service.isHunting('acc2'), isFalse);
      expect(bridge.calls, contains('start:acc1'));

      // Start account 2
      await service.start(
        accountId: 'acc2',
        config: HuntConfig(enabled: true),
      );
      expect(service.isHunting('acc1'), isTrue);
      expect(service.isHunting('acc2'), isTrue);

      // Stop account 1 -> Service must still be active for account 2!
      await service.stop('acc1');
      expect(service.isHunting('acc1'), isFalse);
      expect(service.isHunting('acc2'), isTrue);
      expect(bridge.calls, contains('stop:acc1'));

      // Stop account 2 -> Now both accounts are stopped
      await service.stop('acc2');
      expect(service.isHunting('acc1'), isFalse);
      expect(service.isHunting('acc2'), isFalse);
      expect(bridge.calls, contains('stop:acc2'));
    });
  });

  group('Pillar 4 — Successful Hunt Persistence & UI Banner State', () {
    test('HuntNotifier persists HuntSuccess upon successful claim', () async {
      final memoryStore = MemoryPlainStore();
      final successStore = PreferencesHuntSuccessStore(memoryStore);
      final bridge = RecordingBridge();
      final service = HuntService(
        bridge: bridge,
        engine: NoopEngine(),
        successStore: successStore,
      );

      final notifier = HuntNotifier(
        service: service,
        accountId: 'student-99',
        successStore: successStore,
      );

      final listing = Listing.composite(
        date: DateTime.utc(2026, 11, 24),
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(
          id: '101',
          name: 'چلو جوجه کباب زعفرانی',
          priceRial: 380000,
        ),
      );

      final reservation = Reservation(
        id: 'res-1',
        date: DateTime.utc(2026, 11, 24),
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(id: '101', name: 'چلو جوجه کباب زعفرانی', priceRial: 380000),
        state: ReservationState.active,
      );

      await notifier.onClaimed(
        ruleId: 'hunt-student-99',
        listing: listing,
        reservation: reservation,
      );

      final saved = await successStore.load('student-99');
      expect(saved, isNotNull);
      expect(saved?.dishName, 'چلو جوجه کباب زعفرانی');
      expect(saved?.hallName, 'مرکزی برادران');
      expect(saved?.priceRial, 380000);
      expect(saved?.priceToman, 38000);
      expect(saved?.slot, MealSlot.lunch);
    });

    test('HuntState isolates running status, live status, and last success per account', () async {
      final memoryStore = MemoryPlainStore();
      final successStore = PreferencesHuntSuccessStore(memoryStore);
      final huntState = HuntState(
        accounts: () => [
          const SavedAccount(id: 'acc1', studentId: '111', alias: 'User 1'),
          const SavedAccount(id: 'acc2', studentId: '222', alias: 'User 2'),
        ],
        successStore: successStore,
      );

      // Track running state independently
      huntState.setRunning(true, 'acc1');
      expect(huntState.isHuntRunning('acc1'), isTrue);
      expect(huntState.isHuntRunning('acc2'), isFalse);

      // Track status independently
      final status1 = SnipeRunStatus(
        ruleId: 'hunt-acc1',
        state: SnipeState.hunting,
        pollCount: 5,
      );
      huntState.setStatus(status1, 'acc1');
      expect(huntState.huntStatusFor('acc1')?.pollCount, equals(5));
      expect(huntState.huntStatusFor('acc2'), isNull);

      // Track successes independently
      final success = HuntSuccess(
        accountId: 'acc1',
        dishName: 'چلو خورشت قیمه',
        hallName: 'مرکزی خواهران',
        priceRial: 320000,
        date: DateTime.utc(2026, 11, 24),
        slot: MealSlot.dinner,
        claimedAt: DateTime.utc(2026, 11, 23, 17, 0),
      );
      await successStore.save(success);
      await huntState.loadSuccesses();

      expect(huntState.lastSuccessFor('acc1')?.dishName, equals('چلو خورشت قیمه'));
      expect(huntState.lastSuccessFor('acc2'), isNull);

      // Dismissing success for acc1 removes it
      await huntState.dismissSuccess('acc1');
      expect(huntState.lastSuccessFor('acc1'), isNull);
      expect(await successStore.load('acc1'), isNull);
    });

    test('HuntBounds.minBackoffInterval is 5 seconds', () {
      expect(HuntBounds.minBackoffInterval, equals(const Duration(seconds: 5)));
    });

    test('HuntService.outcomeNotificationId produces distinct IDs for different accounts', () {
      final id1 = HuntService.outcomeNotificationId('user-alpha');
      final id2 = HuntService.outcomeNotificationId('user-beta');
      expect(id1, isNot(equals(id2)));
      expect(id1, greaterThanOrEqualTo(4150));
      expect(id2, greaterThanOrEqualTo(4150));
    });

    test('HuntNotifier invokes onPersistMealStore on successful claim', () async {
      final mealStore = LocalMealStore();
      final memoryStore = MemoryPlainStore();
      final successStore = PreferencesHuntSuccessStore(memoryStore);
      final configStore = FakeHuntConfigStore();
      final bridge = RecordingBridge();
      final engine = NoopEngine();
      final huntService = HuntService(bridge: bridge, engine: engine);

      var persistCalled = false;
      final notifier = HuntNotifier(
        service: huntService,
        accountId: 'test-acc',
        mealStore: mealStore,
        successStore: successStore,
        configStore: configStore,
        onPersistMealStore: () async {
          persistCalled = true;
        },
      );

      await notifier.onClaimed(
        ruleId: 'hunt-test-acc',
        listing: _dummyListing(),
        reservation: _dummyReservation(),
      );

      expect(persistCalled, isTrue);
      expect(mealStore.all, isNotEmpty);
      expect(await successStore.load('test-acc'), isNotNull);
    });
  });
}

class _RecordingListener implements HuntOutcomeListener {
  _RecordingListener({this.onClaimedCallback});
  final void Function()? onClaimedCallback;

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {
    onClaimedCallback?.call();
  }

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {}
}

Listing _dummyListing() => Listing.composite(
  date: DateTime.utc(2026, 11, 24),
  slot: MealSlot.lunch,
  hall: const Hall(id: '1', name: 'مرکزی برادران'),
  option: const MenuOption(id: '1', name: 'غذا', priceRial: 300000),
);

Reservation _dummyReservation() => Reservation(
  id: 'r1',
  date: DateTime.utc(2026, 11, 24),
  slot: MealSlot.lunch,
  hall: const Hall(id: '1', name: 'مرکزی برادران'),
  option: const MenuOption(id: '1', name: 'غذا', priceRial: 300000),
  state: ReservationState.active,
);

class FakePortalClient implements PortalClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSessionManager implements SessionManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeClock implements ServerClock {
  FakeClock({required this.now});
  final DateTime now;

  @override
  DateTime get nowUtc => now;

  @override
  bool get isSynced => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
