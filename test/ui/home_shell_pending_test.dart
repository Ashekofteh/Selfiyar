/// The shell's answer to the platform's own requests, at the level the user
/// sees it.
///
/// ## The defect
///
/// The platform can ask the Dart side to do things at moments when there is
/// no Dart side to ask:
///
///   * a **hunt** wake-up, fired by an alarm with the app killed;
///   * a **reboot**, fired by `BootReceiver` — and at boot the process is by
///     definition dead, so this one could never arrive even in principle.
///
/// Both were delivered through the method channel, whose other end only
/// exists while the activity is alive. The service started, posted its
/// notification claiming the basket was being watched, and told nobody. The
/// reboot receiver existed, was correctly declared, and re-armed nothing.
///
/// So the native side records the requests now, and the shell answers them
/// when it next runs. These tests are about the shell doing that — and about
/// a hunt request being answered *only* when that hunt is switched on.
library;

import 'package:bahonar_nut/core/account.dart';
import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/reminder.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/screens/hunt_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;

/// The account the tests use. Fixed, so a pending request can name it.
const AccountId accountId = 'acc-test';

/// A bridge that answers with a fixed set of owed requests.
class _RequestBridge extends PlatformBridge {
  _RequestBridge(this.owed);

  /// The requests the platform is holding.
  List<String> owed;

  /// The entries the shell cleared, in the order it cleared them.
  final List<List<String>> cleared = [];

  /// The alarms the shell armed, by request code.
  final List<int> armed = [];

  /// The hunt wake-ups the shell armed, by account.
  final List<String> huntsArmed = [];

  /// The hunt wake-ups the shell cancelled, by account.
  final List<String> huntsCancelled = [];

  /// The instant each hunt wake-up was armed for.
  final Map<String, DateTime> huntWakeAt = {};

  @override
  Future<List<String>> pendingRequests() async => List.of(owed);

  @override
  Future<void> clearPendingRequests(List<String> entries) async {
    cleared.add(entries);
    owed = owed.where((e) => !entries.contains(e)).toList();
  }

  @override
  Future<void> scheduleAlarm({
    required int requestCode,
    required DateTime triggerAt,
    String? payload,
  }) async {
    armed.add(requestCode);
  }

  @override
  Future<void> cancelAlarm(int requestCode) async {}

  int concurrentArms = 0;
  int maxConcurrentArms = 0;

  @override
  Future<void> scheduleHuntAlarm({
    required String accountId,
    required DateTime triggerAt,
  }) async {
    concurrentArms++;
    if (concurrentArms > maxConcurrentArms) {
      maxConcurrentArms = concurrentArms;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    concurrentArms--;
    huntsArmed.add(accountId);
    huntWakeAt[accountId] = triggerAt;
  }

  @override
  Future<void> cancelHuntAlarm(String accountId) async {
    huntsCancelled.add(accountId);
    huntWakeAt.remove(accountId);
  }

  /// Whether the shell asked for the hunt's foreground service to start.
  bool huntServiceStarted = false;

  @override
  Future<void> startHuntService({String? payload}) async {
    huntServiceStarted = true;
  }

  /// Whether the shell asked for the hunt's foreground service to be released.
  bool huntServiceStopped = false;

  @override
  Future<void> stopHuntService() async {
    huntServiceStopped = true;
  }

  /// Asks the shell for a hunt, the way the platform does.
  ///
  /// The platform's request arrives on the method channel, and the bridge's
  /// handler is what receives it. The real `PlatformBridge` installs that
  /// handler on the channel; this fake keeps the handler the shell installed
  /// and lets the test call it.
  void simulateHuntRequested(AccountId accountId) {
    _handler?.call(accountId);
  }

  /// The handler the shell installed on the bridge.
  void Function(String? payload)? _handler;

  /// Remembers the handler the shell registers.
  @override
  void onHuntRequested(void Function(String? payload) handler) {
    _handler = handler;
    super.onHuntRequested(handler);
  }
}

/// A store seeded with one known account.
class _SeededAccountStore implements AccountStore {
  final SavedAccount account = SavedAccount(
    id: accountId,
    studentId: '400123456',
    alias: 'برادر',
    addedAt: DateTime.utc(2026, 10, 20),
  );

  @override
  Future<List<SavedAccount>> loadAll() async => [account];

  @override
  Future<void> save(SavedAccount account) async {}

  @override
  Future<void> remove(AccountId id) async {}
}

/// A reminder store whose configuration names the test account.
class _SeededReminderStore implements ReminderConfigStore {
  _SeededReminderStore()
      : _config = const ReminderConfig(accountIds: {accountId});

  ReminderConfig _config;

  @override
  Future<ReminderConfig> load() async => _config;

  @override
  Future<void> save(ReminderConfig config) async {
    _config = config;
  }
}

void main() {
  late FakePortalClient portal;
  late AppState state;
  late AppServices services;

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  /// A dish the fake portal serves, so a hunt with a priority list has
  /// something the pre-flight can credit-check.
  final dish = HuntDish(
    optionId: 'opt-1',
    name: 'چلوگوشت',
    priceRial: 500000,
  );

  /// The menu the fake portal serves for the tests' target date, carrying
  /// [dish] at the same price the config quotes.
  final menu = MealMenu(
    date: DateTime.utc(2026, 10, 22),
    slot: MealSlot.breakfast,
    halls: const [Hall(id: 'hall-1', name: 'مرکزی')],
    dishes: const [
      MenuOption(
        id: 'opt-1',
        name: 'چلوگوشت',
        priceRial: 500000,
      ),
    ],
    reservable: true,
  );

  /// Builds the shell with one account and a hunt configuration.
  Future<void> pumpShell(
    WidgetTester tester, {
    required _RequestBridge bridge,
    bool huntEnabled = false,
    HuntConfig? config,
    int balanceRial = 1000000,
    List<MealMenu>? menus,
  }) async {
    portal = FakePortalClient(balanceRial: balanceRial);
    portal.menus = menus ?? [menu];

    services = AppServices(
      bridge: bridge,
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    state = AppState(
      accountStore: _SeededAccountStore(),
      reminderConfigStore: _SeededReminderStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.load();

    state.selectHuntAccount(accountId);
    await state.saveHuntConfig(
      config ??
          HuntConfig(
            targetDate: DateTime.utc(2026, 10, 22),
            targetSlot: MealSlot.breakfast,
            enabled: huntEnabled,
          ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a reboot request re-arms the alarms', (tester) async {
    final bridge = _RequestBridge(['rearm']);

    await pumpShell(tester, bridge: bridge);

    expect(
      bridge.armed,
      isNotEmpty,
      reason: 'a reboot clears the alarms, and the re-arm is the request that '
          'must not be lost',
    );
    expect(bridge.cleared.expand((e) => e), contains('rearm'));
  });

  testWidgets('a hunt request for a switched-off hunt is not answered',
      (tester) async {
    final bridge = _RequestBridge(['hunt:$accountId']);

    await pumpShell(tester, bridge: bridge, huntEnabled: false);

    expect(
      bridge.cleared,
      isEmpty,
      reason: 'a hunt the student switched off must not start because an '
          'alarm fired, and the request stays owed rather than being dropped',
    );
  });

  testWidgets('a hunt request for a switched-on hunt is answered',
      (tester) async {
    final bridge = _RequestBridge(['hunt:$accountId']);

    // A hunt with one dish chosen, and the portal serving that dish - so the
    // pre-flight the answer runs can pass. The dish is priced at what the
    // config quotes, so the credit check has nothing to refuse.
    await pumpShell(
      tester,
      bridge: bridge,
      config: HuntConfig(
        targetDate: DateTime.utc(2026, 10, 22),
        targetSlot: MealSlot.breakfast,
        dishPriority: [dish],
        enabled: true,
      ),
    );
    portal.menus = [menu];

    expect(
      bridge.cleared.expand((e) => e),
      contains('hunt:$accountId'),
      reason: 'a hunt the student switched on, asked for by the platform, is '
          'answered and the request is cleared',
    );
    services.hunts.stop(accountId);
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('a hunt request for an account the app does not have is not '
      'answered', (tester) async {
    final bridge = _RequestBridge(['hunt:no-such-account']);

    await pumpShell(tester, bridge: bridge, huntEnabled: true);

    expect(
      bridge.cleared,
      isEmpty,
      reason: 'a request naming an account the app does not have cannot be '
          'acted on, so it stays owed rather than being silently dropped',
    );
  });

  testWidgets('nothing is cleared when nothing is owed', (tester) async {
    final bridge = _RequestBridge([]);

    await pumpShell(tester, bridge: bridge);

    expect(bridge.cleared, isEmpty);
  });

  group('a live hunt request', () {
    // The defect this pins: the native service records a hunt request
    // **before** it looks for a Dart side — that is the F75 safety net, and
    // it is why a hunt survives the app dying between the alarm and the
    // hand-over. So the record outlives the hand-over, and the next launch
    // read it and started the hunt a *second* time, for an account that had
    // already been hunted. Nothing noticed: the two runs are separate, and
    // the app's own "already running" guard does not span them.
    //
    // So the side that acts clears the record. This is the live path — the
    // app's own engine, awake, answering the platform.

    testWidgets('the record is cleared once the hunt starts',
        (tester) async {
      final bridge = _RequestBridge([]);

      // The same fixture as the pending test above: one chosen dish, served
      // by the portal, priced as quoted - so the pre-flight can pass.
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 22),
          targetSlot: MealSlot.breakfast,
          dishPriority: [dish],
          enabled: true,
        ),
      );
      portal.menus = [menu];

      // The platform asks for a hunt while the app is alive.
      bridge.simulateHuntRequested(accountId);
      await tester.pumpAndSettle();

      expect(
        bridge.cleared.expand((e) => e),
        contains('hunt:$accountId'),
        reason: 'the record outlives the hand-over, so the side that acts '
            'has to clear it — or the next launch hunts the same account a '
            'second time',
      );
      services.hunts.stop(accountId);
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('a request for a switched-off hunt is left owed',
        (tester) async {
      final bridge = _RequestBridge([]);

      await pumpShell(tester, bridge: bridge, huntEnabled: false);

      bridge.simulateHuntRequested(accountId);
      await tester.pumpAndSettle();

      expect(
        bridge.cleared.expand((e) => e),
        isNot(contains('hunt:$accountId')),
        reason: 'a hunt the student switched off must not start, and the '
            'request stays owed rather than being silently dropped',
      );
    });

    testWidgets('a request the pre-flight refuses releases the service',
        (tester) async {
      // Found on the device (F87): the alarm started the foreground service
      // and *then* asked the Dart side. The pre-flight refused — no credit,
      // no dish — and the early return left «پایش سبد غذا» posted over a hunt
      // that never ran. It was still there 12 minutes later.
      final bridge = _RequestBridge([]);

      // A hunt that is switched on but targets a Thursday dinner, which the
      // halls never serve — so the pre-flight cannot pass.
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 22),
          targetSlot: MealSlot.dinner,
          enabled: true,
        ),
      );

      bridge.simulateHuntRequested(accountId);
      await tester.pumpAndSettle();

      expect(bridge.huntServiceStopped, isTrue,
          reason: 'a foreground service with no hunt behind it is a battery '
              'drain and a notification the student cannot clear');
      expect(bridge.huntsArmed, isEmpty);
    });
  });

  group('the hunt\'s wake-up', () {
    testWidgets('a switched-on hunt is armed for its window', (tester) async {
      final bridge = _RequestBridge([]);

      await pumpShell(tester, bridge: bridge, huntEnabled: true);

      expect(bridge.huntsArmed, contains(accountId),
          reason: 'a hunt the student switched on must have a wake-up armed, '
              'or the card\'s claim that it starts by itself is false');

      // The shell's fixture targets a breakfast on 2026-10-22, which is
      // collected with the 21st's dinner — so the window opens on the 21st.
      final wakeAt = bridge.huntWakeAt[accountId]!;
      expect(wakeAt.isBefore(DateTime.utc(2026, 10, 22)), isTrue,
          reason: 'a breakfast is collected the evening before its date');
    });

    testWidgets('a switched-off hunt is not armed', (tester) async {
      final bridge = _RequestBridge([]);

      await pumpShell(tester, bridge: bridge, huntEnabled: false);

      expect(bridge.huntsArmed, isEmpty,
          reason: 'a hunt the student switched off must not start by itself');
      expect(bridge.huntsCancelled, contains(accountId),
          reason: 'and any earlier alarm for it must be cancelled');
    });

    testWidgets('a reboot re-arms the hunt\'s wake-up too', (tester) async {
      final bridge = _RequestBridge(['rearm']);

      await pumpShell(tester, bridge: bridge, huntEnabled: true);

      expect(bridge.huntsArmed, contains(accountId),
          reason: 'a reboot clears every alarm, and the hunt\'s wake-up is '
              'one of them');
    });

    testWidgets('arms hunts for multiple accounts concurrently on load',
        (tester) async {
      final bridge = _RequestBridge([]);
      portal = FakePortalClient(balanceRial: 1000000);
      portal.menus = [menu];

      services = AppServices(
        bridge: bridge,
        client: portal,
        sessions: SessionManager(
          client: portal,
          store: MemorySessionStore(),
          solver: NoSolver(),
          clock: clock,
        ),
        credentialStore: MemorySecureStore(),
        plainStore: MemoryPlainStore(),
        clock: clock,
      );

      final accountStore = InMemoryAccountStore();
      await accountStore.save(const SavedAccount(
        id: 'acc1',
        studentId: '400123456',
        alias: 'حساب اول',
      ));
      await accountStore.save(const SavedAccount(
        id: 'acc2',
        studentId: '400123457',
        alias: 'حساب دوم',
      ));

      final huntConfigStore = InMemoryHuntConfigStore();
      await huntConfigStore.save(
        'acc1',
        HuntConfig(
          targetDate: DateTime.utc(2026, 10, 22),
          targetSlot: MealSlot.breakfast,
          enabled: true,
        ),
      );
      await huntConfigStore.save(
        'acc2',
        HuntConfig(
          targetDate: DateTime.utc(2026, 10, 22),
          targetSlot: MealSlot.breakfast,
          enabled: true,
        ),
      );

      state = AppState(
        accountStore: accountStore,
        reminderConfigStore: _SeededReminderStore(),
        huntConfigStore: huntConfigStore,
        mealStore: services.mealStore.store,
      );
      await state.load();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa', 'IR'),
          supportedLocales: const [Locale('fa', 'IR')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: HomeShell(
              state: state,
              services: services,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(bridge.huntsArmed, containsAll(['acc1', 'acc2']));
      expect(bridge.maxConcurrentArms, 2,
          reason: 'Hunts for multiple accounts should be armed concurrently');
    });
  });

  group('switching the hunt on is gated', () {
    // The defect these pin (F87): the switch stored `enabled: true` and armed
    // an alarm **without checking anything**. On the device that meant a hunt
    // for a Thursday dinner — a meal the halls never serve — was armed for
    // 16:30 at 18:11, fired at once, and left its "watching the basket"
    // notification standing with a balance far below the meal's price.

    /// Opens the hunt tab and returns the switch on it.
    ///
    /// The tab is opened rather than merely found: an `IndexedStack` builds
    /// every destination but only hit-tests the visible one, so a tap on a
    /// hidden screen's switch would land on whatever is actually on top.
    Future<Finder> openHuntTab(WidgetTester tester) async {
      await tester.tap(find.text('شکار'));
      await tester.pumpAndSettle();
      return find.descendant(
        of: find.byType(HuntScreen),
        matching: find.byType(Switch),
      );
    }

    testWidgets('a hunt for a meal that is not served is not switched on',
        (tester) async {
      // 2026-10-22 is a Thursday, and Thursday serves no dinner.
      final bridge = _RequestBridge([]);
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 22),
          targetSlot: MealSlot.dinner,
        ),
      );

      await tester.tap(await openHuntTab(tester));
      await tester.pumpAndSettle();

      // The flag is not stored, so the switch springs back and the reason is
      // on screen — a hunt that claims to be on with no alarm behind it is
      // the state the student cannot tell from a working one.
      expect(state.huntConfigFor(accountId)!.enabled, isFalse);
      expect(state.huntEnableRefusal, isNotNull);
      expect(bridge.huntsArmed, isEmpty);
    });

    testWidgets('a hunt whose window has closed is not switched on',
        (tester) async {
      // The clock is 2026-10-20 12:00Z (15:30 portal). A hunt for the 18th's
      // window — the 18th is a Sunday, so the meal is served — has a window
      // that has already closed.
      final bridge = _RequestBridge([]);
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 18),
          targetSlot: MealSlot.dinner,
        ),
      );

      await tester.tap(await openHuntTab(tester));
      await tester.pumpAndSettle();

      expect(state.huntConfigFor(accountId)!.enabled, isFalse);
      expect(state.huntEnableRefusal, isNotNull);
      expect(bridge.huntsArmed, isEmpty);
    });

    testWidgets('a hunt with no dishes chosen may still be switched on',
        (tester) async {
      // Nothing is selected yet, so there is no cost to judge and no request
      // to make. Refusing here would block the normal order of work — the
      // student picks the date first and the dishes after.
      final bridge = _RequestBridge([]);
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 25),
          targetSlot: MealSlot.dinner,
        ),
      );

      await tester.tap(await openHuntTab(tester));
      await tester.pumpAndSettle();

      expect(state.huntConfigFor(accountId)!.enabled, isTrue);
      expect(state.huntEnableRefusal, isNull);
    });

    testWidgets('a hunt whose window is open now is switched on and armed',
        (tester) async {
      // The device's case, and the answer the user chose: an open window is
      // allowed and starts at once. The clock is 15:30 portal on the 20th, and
      // this hunt's window is 15:00–16:00 that same day — so the wake instant
      // (15:00) is behind us and the window's end (16:00) is ahead.
      final bridge = _RequestBridge([]);
      await pumpShell(
        tester,
        bridge: bridge,
        config: HuntConfig(
          targetDate: DateTime.utc(2026, 10, 20),
          targetSlot: MealSlot.dinner,
          windowStart: const ClockTime(15, 0),
          windowEnd: const ClockTime(16, 0),
        ),
      );

      await tester.tap(await openHuntTab(tester));
      await tester.pumpAndSettle();

      expect(state.huntConfigFor(accountId)!.enabled, isTrue);
      expect(bridge.huntsArmed, contains(accountId),
          reason: 'an open window is armed for its (past) start, which fires '
              'at once — the immediate start the student asked for');
      expect(state.huntScheduleFor(accountId)!.status,
          HuntScheduleStatus.windowOpen);
    });
  });
}
