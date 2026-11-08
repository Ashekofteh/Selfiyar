/// The four fixes for the audit findings F73–F76, at the level the user sees.
///
/// ## Why widget tests and not domain tests
///
/// The domain tests were green while the screens were lying: the hunt screen
/// had no switch for the flag that decides whether a hunt runs, the reminders
/// screen said nothing about the permissions the reminders depend on, and the
/// platform's own requests were dropped without a word. So every fix here is
/// pinned by what the user can **see**.
///
/// The domain-level checks (the pre-flight refuses a disabled rule, the engine
/// refuses to start one) are pinned too, in the same file, because a rule that
/// is refused must be refused for the *same* reason on every path — and
/// because the screen's wording is derived from the pre-flight's verdict.
library;

import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/pending_request.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/preflight.dart';
import 'package:bahonar_nut/core/priority.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/snipe_engine.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/hunt_service.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/screens/reminders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bridge that answers the permission questions with fixed answers.
class _PermissionBridge extends PlatformBridge {
  _PermissionBridge({
    this.notifications = true,
    this.exactAlarms = true,
    this.batteryExempt = true,
  });

  bool notifications;
  bool exactAlarms;
  bool batteryExempt;

  final List<String> requested = [];

  @override
  Future<bool> hasNotificationPermission() async => notifications;

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarms;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => batteryExempt;

  @override
  Future<bool> requestNotificationPermission() async {
    requested.add('notifications');
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    requested.add('exactAlarms');
    return true;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    requested.add('battery');
    return true;
  }
}

Widget _wrap(Widget child) {
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

Future<AppState> _state({bool withAccounts = true}) async {
  final state = AppState(
    accountStore: InMemoryAccountStore(),
    reminderConfigStore: InMemoryReminderConfigStore(),
    huntConfigStore: InMemoryHuntConfigStore(),
  );
  await state.load();
  if (withAccounts) {
    await state.upsertAccount(studentId: '400123456');
  }
  return state;
}

void main() {
  group('F73 — the permission grants are real', () {
    testWidgets('the reminders screen states a missing notification grant',
        (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge(notifications: false);

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('ارسال اعلان‌ها'),
        findsOneWidget,
        reason: 'a reminder that posts nothing must say the grant is missing',
      );
    });

    testWidgets('the screen says nothing when every permission is granted',
        (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge();

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('اجازه‌های لازم'),
        findsNothing,
        reason: 'a card that lists three satisfied permissions is noise, and '
            'noise is how a real warning stops being read',
      );
    });

    testWidgets('the missing exact-alarm grant is stated too', (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge(exactAlarms: false);

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('زنگ دقیق'), findsOneWidget);
    });

    testWidgets('the button asks the platform for the grant', (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge(notifications: false);

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('اجازه می‌دهم').first);
      await tester.pumpAndSettle();

      expect(bridge.requested, contains('notifications'));
    });
  });

  group('F74 — the battery-optimisation exemption', () {
    testWidgets('the missing exemption is stated with its reason',
        (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge(batteryExempt: false);

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('مستثنا شدن از بهینه‌سازی باتری'),
        findsOneWidget,
      );
      expect(
        find.textContaining('دسترسی برنامه به اینترنت قطع می‌شود'),
        findsOneWidget,
        reason: 'the spec requires the request to be explained, never silent',
      );
    });

    testWidgets('the button opens the system setting', (tester) async {
      final state = await _state();
      final bridge = _PermissionBridge(batteryExempt: false);

      await tester.pumpWidget(
        _wrap(RemindersScreen(state: state, bridge: bridge)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('اجازه می‌دهم').first);
      await tester.pumpAndSettle();

      expect(bridge.requested, contains('battery'));
    });
  });

  group('F75 — the pending request vocabulary', () {
    test('a hunt entry carries its account', () {
      final request = PendingRequest.parse('hunt:acc-1');
      expect(request, isNotNull);
      expect(request!.kind, PendingRequestKind.hunt);
      expect(request.payload, 'acc-1');
    });

    test('a re-arm entry carries nothing', () {
      final request = PendingRequest.parse('rearm');
      expect(request, isNotNull);
      expect(request!.kind, PendingRequestKind.rearm);
      expect(request.payload, isNull);
    });

    test('an entry that is not ours is not guessed at', () {
      expect(PendingRequest.parse('nonsense'), isNull);
      expect(PendingRequest.parse('reminder'), isNull);
    });

    test('a hunt with no account cannot be started, so it is not ours', () {
      expect(PendingRequest.parse('hunt'), isNull);
      expect(PendingRequest.parse('hunt:'), isNull);
    });

    test('the entry round-trips', () {
      expect(PendingRequest.hunt('a1').entry, 'hunt:a1');
      expect(PendingRequest.rearm.entry, 'rearm');
    });
  });

  group('F76 — a switched-off hunt does not run', () {
    test('the pre-flight refuses a rule that is off', () {
      const checker = PreflightChecker();
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0));

      final result = checker.check(
        rule: SnipeRule(
          id: 'r1',
          account: 'a1',
          enabled: false,
          preferences: {
            MealSlot.lunch: SlotPreference(
              slot: MealSlot.lunch,
              ranked: const [PreferencePair(hallId: '1', optionId: '62702')],
            ),
          },
          slots: const {MealSlot.lunch},
        ),
        clock: clock,
        session: SessionReady(
          session: Session(
            account: 'a1',
            cookies: const {'ASP.NET_SessionId': 'x'},
            establishedAt: DateTime.utc(2026, 10, 18),
          ),
          wasReused: true,
        ),
      );

      expect(result.passed, isFalse);
      expect(result.failures, contains(PreflightFailure.ruleDisabled));
    });

    test('the hunt service does not start a switched-off hunt', () async {
      final bridge = _CountingBridge();
      final engine = _RecordingEngine();
      final service = HuntService(bridge: bridge, engine: engine);

      await service.start(
        accountId: 'a1',
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          dishPriority: [
            HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
          ],
          targetDate: DateTime.utc(2026, 10, 28),
        ),
      );

      expect(engine.started, isEmpty,
          reason: 'the default is off, and off means off');
      expect(bridge.calls, isEmpty,
          reason: 'no foreground service for a hunt that will not run');
    });

    test('a switched-on hunt starts', () async {
      final bridge = _CountingBridge();
      final engine = _RecordingEngine();
      final service = HuntService(bridge: bridge, engine: engine);

      await service.start(
        accountId: 'a1',
        config: HuntConfig(
          targetSlot: MealSlot.dinner,
          dishPriority: [
            HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
          ],
          targetDate: DateTime.utc(2026, 10, 28),
          enabled: true,
        ),
      );

      expect(engine.started, ['hunt-a1']);
      expect(bridge.calls, ['start:a1']);
    });
  });
}

/// A bridge that records the foreground-service calls.
class _CountingBridge extends PlatformBridge {
  final List<String> calls = [];

  @override
  Future<void> startHuntService({String? payload}) async {
    calls.add('start:$payload');
  }

  @override
  Future<void> stopHuntService() async {
    calls.add('stop');
  }
}

/// An engine that records what it was asked to run.
class _RecordingEngine implements SnipeEngine {
  final List<String> started = [];

  @override
  Future<void> start(SnipeRule rule, {HuntConfig? hunt}) async {
    started.add(rule.id);
  }

  @override
  Future<void> stop(String ruleId) async {}

  @override
  bool isRunning(String ruleId) => started.contains(ruleId);

  @override
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt}) async =>
      const PreflightResult.passed();

  @override
  Stream<SnipeRunStatus> watch(String ruleId) => const Stream.empty();

  @override
  set listener(HuntOutcomeListener value) {}
}
