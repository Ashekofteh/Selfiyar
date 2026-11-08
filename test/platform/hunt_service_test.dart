import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_notify.dart';
import 'package:bahonar_nut/core/hunt_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/preflight.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/snipe_engine.dart';
import 'package:bahonar_nut/platform/hunt_service.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A platform bridge that records what it was asked to do.
class RecordingBridge extends PlatformBridge {
  RecordingBridge();

  final List<String> calls = [];
  final List<Map<Object?, Object?>> notifications = [];

  @override
  Future<void> startHuntService({String? payload}) async {
    calls.add('start:$payload');
  }

  @override
  Future<void> stopHuntService() async {
    calls.add('stop');
  }

  @override
  Future<void> cancelHuntAlarm(AccountId accountId) async {
    calls.add('cancelAlarm:$accountId');
  }

  @override
  Future<void> postNotification({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    calls.add('notify');
    notifications.add({
      'id': id,
      'title': title,
      'body': body,
      'deepLink': deepLink,
    });
  }
}

class FakeHuntConfigStore implements HuntConfigStore {
  final Map<AccountId, HuntConfig> configs = {};

  @override
  Future<HuntConfig?> load(AccountId accountId) async => configs[accountId];

  @override
  Future<void> save(AccountId accountId, HuntConfig config) async {
    configs[accountId] = config;
  }

  @override
  Future<void> remove(AccountId accountId) async {
    configs.remove(accountId);
  }
}

/// An engine that does nothing, so the service can be tested on its own.
class NoopEngine implements SnipeEngine {
  final List<String> started = [];
  final List<String> stopped = [];

  @override
  Future<void> start(SnipeRule rule, {HuntConfig? hunt}) async {
    started.add(rule.id);
  }

  @override
  Future<void> stop(String ruleId) async {
    stopped.add(ruleId);
  }

  @override
  bool isRunning(String ruleId) => started.contains(ruleId) && !stopped.contains(ruleId);

  @override
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt}) async =>
      const PreflightResult.passed();

  @override
  Stream<SnipeRunStatus> watch(String ruleId) => const Stream.empty();

  @override
  set listener(HuntOutcomeListener value) {}
}

void main() {
  // A hunt is opt-in, so the fixture switches it on: these tests are about
  // the service's behaviour, not about the switch.
  final config = HuntConfig(
    targetSlot: MealSlot.dinner,
    dishPriority: [
      HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
    ],
    targetDate: DateTime.utc(2026, 10, 28),
    enabled: true,
  );

  group('starting a hunt', () {
    test('the foreground service is started before the hunt runs', () async {
      final bridge = RecordingBridge();
      final engine = NoopEngine();
      final service = HuntService(bridge: bridge, engine: engine);

      await service.start(accountId: 'a1', config: config);

      expect(bridge.calls, ['start:a1']);
      expect(engine.started, ['hunt-a1']);
    });
  });

  group('stopping a hunt', () {
    test('the engine is stopped and the service released', () async {
      final bridge = RecordingBridge();
      final engine = NoopEngine();
      final service = HuntService(bridge: bridge, engine: engine);

      await service.stop('a1');

      expect(engine.stopped, ['hunt-a1']);
      expect(bridge.calls, contains('stop'));
    });
  });

  group('reporting the outcome', () {
    test('a purchase posts the success notification and releases the service',
        () async {
      final bridge = RecordingBridge();
      final service = HuntService(bridge: bridge, engine: NoopEngine());
      final notifier = HuntNotifier(service: service, accountId: 'a1');

      await notifier.onClaimed(
        ruleId: 'hunt-a1',
        listing: Listing.composite(
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(
            id: '62742',
            name: 'لوبیا پلو',
            priceRial: 350000,
          ),
        ),
        reservation: Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(
            id: '62742',
            name: 'لوبیا پلو',
            priceRial: 350000,
          ),
          state: ReservationState.active,
        ),
      );

      expect(bridge.notifications, hasLength(1));
      expect(bridge.notifications.first['title'], '🌙 خرید موفق');
      expect(bridge.notifications.first['body'], contains('لوبیا پلو'));
      expect(bridge.notifications.first['body'], contains('تومان'));
      expect(bridge.notifications.first['body'], isNot(contains('ریال')));

      expect(bridge.notifications.first['deepLink'], startsWith('nut://hunt-success'));
      expect(bridge.notifications.first['deepLink'], contains('dish=%D9%84%D9%88%D8%A8%DB%8C%D8%A7+%D9%BE%D9%84%D9%88'));
      expect(bridge.notifications.first['deepLink'], contains('price=350000'));
      expect(bridge.notifications.first['deepLink'], contains('hall=%D9%85%D8%B1%DA%A9%D8%B2%DB%8C+%D8%A8%D8%B1%D8%A7%D8%AF%D8%B1%D8%A7%D9%86'));

      // The service is released on the purchase: there is nothing left to
      // hunt for, and a lingering foreground service is a battery drain.
      expect(bridge.calls, contains('stop'));
    });

    test('a purchase disables the hunt in the config store and cancels the alarm', () async {
      final bridge = RecordingBridge();
      final store = FakeHuntConfigStore();
      store.configs['a1'] = HuntConfig(enabled: true);
      final service = HuntService(bridge: bridge, engine: NoopEngine(), configStore: store);
      final notifier = HuntNotifier(service: service, accountId: 'a1', configStore: store);

      await notifier.onClaimed(
        ruleId: 'hunt-a1',
        listing: Listing.composite(
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: const Hall(id: '1', name: 'مرکزی'),
          option: const MenuOption(id: '1', name: 'کباب', priceRial: 500000),
        ),
        reservation: Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: const Hall(id: '1', name: 'مرکزی'),
          option: const MenuOption(id: '1', name: 'کباب', priceRial: 500000),
          state: ReservationState.active,
        ),
      );

      final saved = await store.load('a1');
      expect(saved?.enabled, isFalse);
      expect(bridge.calls, contains('cancelAlarm:a1'));
    });

    test('an ended hunt disables the hunt in the config store and cancels the alarm', () async {
      final bridge = RecordingBridge();
      final store = FakeHuntConfigStore();
      store.configs['a1'] = HuntConfig(enabled: true);
      final service = HuntService(bridge: bridge, engine: NoopEngine(), configStore: store);
      final notifier = HuntNotifier(service: service, accountId: 'a1', configStore: store);

      await notifier.onEnded(
        ruleId: 'hunt-a1',
        state: SnipeState.windowExpired,
        reason: 'window closed',
      );

      final saved = await store.load('a1');
      expect(saved?.enabled, isFalse);
      expect(bridge.calls, contains('cancelAlarm:a1'));
    });

    test('HuntService.stop disables the hunt in the config store and cancels the alarm', () async {
      final bridge = RecordingBridge();
      final store = FakeHuntConfigStore();
      store.configs['a1'] = HuntConfig(enabled: true);
      final service = HuntService(bridge: bridge, engine: NoopEngine(), configStore: store);

      await service.stop('a1');

      final saved = await store.load('a1');
      expect(saved?.enabled, isFalse);
      expect(bridge.calls, contains('cancelAlarm:a1'));
    });

    test('a hunt that ended without a purchase says so', () async {
      final bridge = RecordingBridge();
      final service = HuntService(bridge: bridge, engine: NoopEngine());
      final notifier = HuntNotifier(service: service, accountId: 'a1');

      await notifier.onEnded(
        ruleId: 'hunt-a1',
        state: SnipeState.windowExpired,
        reason: 'window closed',
      );

      expect(bridge.notifications, hasLength(1));
      expect(bridge.notifications.first['title'], isNot('🌙 خرید موفق'));
      expect(bridge.notifications.first['body'], contains('بدون خرید'));
      expect(bridge.calls, contains('stop'));
    });

    test('a dry run that matched does not claim a meal was bought', () async {
      final bridge = RecordingBridge();
      final service = HuntService(bridge: bridge, engine: NoopEngine());
      final notifier = HuntNotifier(service: service, accountId: 'a1');

      await notifier.onEnded(
        ruleId: 'hunt-a1',
        state: SnipeState.claimed,
        reason: 'dry run match',
      );

      expect(bridge.notifications.first['title'], isNot('🌙 خرید موفق'));
      expect(bridge.notifications.first['body'], contains('آزمایشی'));
    });
  });

  group('a platform failure', () {
    test('does not turn a completed purchase into an error', () async {
      // The service releases itself when the process ends, so a failed stop
      // is ugly, not dangerous. Failing here would make a *purchase* look
      // like an error to the user.
      final bridge = _FailingStopBridge();
      final service = HuntService(bridge: bridge, engine: NoopEngine());

      await service.reportOutcome(
        accountId: 'a1',
        notification: composeHuntEnded(reason: 'x'),
      );

      expect(bridge.notifications, hasLength(1));
    });
  });
}

/// A bridge whose stop call fails.
class _FailingStopBridge extends RecordingBridge {
  @override
  Future<void> stopHuntService() async {
    throw StateError('platform is not available');
  }
}
