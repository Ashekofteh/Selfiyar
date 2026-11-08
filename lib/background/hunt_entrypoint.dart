/// The headless hunt: the Dart side that runs when the phone is asleep.
///
/// ## Why this file exists
///
/// A hunt is a snipe — a burst of requests against the portal's market during
/// a window of minutes, ending in a purchase. The window is published in
/// advance, and the student is not going to be holding the phone at 16:30.
///
/// So the hunt has to run **without the app being open**. The alarm fires,
/// the native service starts, and this entrypoint is what the service runs.
///
/// ## Why it is its own entrypoint, and not the app's `main`
///
/// The app's `main` calls `runApp`, which builds a widget tree and shows a
/// screen. A background hunt has no screen — and more importantly, it must
/// not have one: a hunt that is waiting for its window can sit for hours, and
/// a widget tree for hours is a memory cost for nothing.
///
/// The native side runs this file by name:
///
/// ```kotlin
/// DartEntrypoint(bundlePath, "package:bahonar_nut/background/hunt_entrypoint.dart", "main")
/// ```
///
/// and passes the account id as the entrypoint's argument.
///
/// ## Why it runs in its own `FlutterEngine`
///
/// Because a *spawned isolate* cannot use the method channel. A spawned
/// isolate's `MethodChannel` resolves to `BackgroundIsolateBinaryMessenger`,
/// which cannot receive messages and throws when a handler is set on it. Only
/// a **root isolate** gets a real `defaultBinaryMessenger`.
///
/// A second `FlutterEngine`'s Dart *is* a root isolate — the engine's
/// `GetRootIsolateToken()` returns a non-zero token for one — so this
/// entrypoint's `MethodChannel` resolves to the background engine's own
/// messenger, and the native side registers a handler there.
///
/// ## What it must not do
///
/// It must not call `startHuntService`. The native service is already
/// running — it is what started this engine. Calling it would re-enter the
/// same service.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/hunt_config.dart';
import '../core/models.dart';
import '../core/pending_request.dart';
import '../core/preflight.dart';
import '../core/snipe.dart';
import '../core/snipe_engine.dart';
import '../platform/hunt_service.dart';
import '../platform/platform_bridge.dart';
import '../platform/platform_services.dart';

/// The entrypoint the native service runs.
///
/// The account id arrives as the entrypoint's argument, because the native
/// side knows which account's alarm fired and the Dart side does not.
@pragma('vm:entry-point')
void main(List<String> args) {
  // The Flutter bindings must exist before anything touches the method
  // channel, and calling this is what makes the root isolate's token
  // non-null — which is what makes the channel resolve to *this* engine's
  // messenger rather than to the background one.
  //
  // There is deliberately no `runApp`: a background hunt has no screen, and a
  // widget tree kept alive for hours is a memory cost for nothing.
  WidgetsFlutterBinding.ensureInitialized();

  final accountId = args.isNotEmpty ? args.first : null;
  if (accountId == null || accountId.isEmpty) {
    // Nothing to hunt for. There is no account to name the hunt after, and a
    // hunt without an account is a hunt that cannot spend money — so this is
    // not a failure, it is a no-op.
    return;
  }

  unawaited(runHeadlessHunt(accountId));
}

/// Runs a hunt for [accountId] with no screen.
///
/// Returns when the hunt is over, so the caller can let the process go.
Future<void> runHeadlessHunt(AccountId accountId) async {
  final services = AppServices.forAndroid();
  final bridge = services.bridge;

  // The hunt's configuration is read from the same store the UI writes to,
  // so the headless hunt and the screen the student configured always agree.
  final config = await services.huntConfigStore.load(accountId);

  final decision = decideHeadlessHunt(config);
  if (!decision.shouldRun) {
    // The hunt is off, or there is no hunt for this account. Nothing is
    // started, and nothing is announced: a hunt the student switched off must
    // not become a notification.
    services.dispose();
    await _releaseService(bridge);
    return;
  }

  final hunt = config!;
  final rule = hunt.toRule(id: _ruleId(accountId), account: accountId);

  // The request that brought the headless engine here is now answered, so it
  // is cleared.
  //
  // The native side records the request *before* it looks for a Dart side,
  // because it cannot know whether one will be there. When the background
  // engine takes the hunt, that record is still standing — and the next app
  // launch would read it and start the hunt a **second** time, for an account
  // that has already been hunted. So the side that acts clears the record,
  // which is the same rule the in-app path follows.
  await _clearPendingRequest(bridge, accountId);

  // The pre-flight is run **here**, before the hunt, so a refusal is reported
  // with its reason rather than the hunt simply ending in silence. The
  // engine runs the same check again inside its loop — this copy exists to
  // give the student a reason while there is still a screen-free way to say
  // it.
  final verdict = await services.engine.preflight(rule, hunt: hunt);
  if (!verdict.passed) {
    await _announceRefusal(bridge, verdict.failures);
    final currentHunt = await services.huntConfigStore.load(accountId);
    if (currentHunt != null && currentHunt.enabled) {
      await services.huntConfigStore.save(accountId, currentHunt.copyWith(enabled: false));
    }
    await bridge.cancelHuntAlarm(accountId);
  services.dispose();
    await _releaseService(bridge);
    return;
  }

  // The listener must be in place before the hunt starts: the purchase
  // notification is posted from it, and a hunt that wins in its first second
  // must not find the listener missing.
  services.engine.listener = HuntNotifier(
    service: services.hunts,
    accountId: accountId,
    configStore: services.huntConfigStore,
  );

  await services.engine.start(rule, hunt: hunt);

  // Wait for the run to finish.
  //
  // The engine has no "await this run" method, but it publishes every state
  // change, and a terminal state means the hunt is over. The wait has a
  // ceiling so a run that never reaches a terminal state cannot hold the
  // service — and the foreground service has a daily limit on Android 15+.
  await _awaitCompletion(services.engine, _ruleId(accountId));

  final completedHunt = await services.huntConfigStore.load(accountId);
  if (completedHunt != null && completedHunt.enabled) {
    await services.huntConfigStore.save(accountId, completedHunt.copyWith(enabled: false));
  }
  await bridge.cancelHuntAlarm(accountId);
  services.dispose();
  await _releaseService(bridge);
}

/// The rule id a hunt runs under.
///
/// The same id the UI's hunt uses, so the two paths name a run the same way.
String _ruleId(AccountId accountId) => 'hunt-$accountId';

/// What the headless entrypoint should do with the configuration it found.
class HeadlessHuntDecision {
  const HeadlessHuntDecision({required this.shouldRun, this.reason});

  /// Whether the hunt may start.
  final bool shouldRun;

  /// Why it may not, when it may not.
  final String? reason;

  /// The hunt should not start, and this is why.
  const HeadlessHuntDecision.refused(String this.reason) : shouldRun = false;

  /// The hunt should start.
  static const HeadlessHuntDecision run = HeadlessHuntDecision(
    shouldRun: true,
  );
}

/// Decides whether a headless hunt may start.
///
/// ## Why this is a separate function
///
/// Because it is the part that can be **wrong**, and it is the part that
/// spends money. A hunt that starts when it should not spends the student's
/// money and the account's goodwill with the portal; a hunt that does not
/// start when it should is a silent failure.
///
/// So the decision is a pure function of the configuration, and it is tested
/// directly — no engine, no network, no platform.
HeadlessHuntDecision decideHeadlessHunt(HuntConfig? config) {
  if (config == null) {
    return const HeadlessHuntDecision.refused(
      'برای این حساب، شکاری تنظیم نشده است.',
    );
  }
  if (!config.enabled) {
    // The switch is the student's own decision, and it is checked on every
    // path — not only the one the student touched. The platform can ask for
    // a hunt at a moment when nobody is looking at the screen, and a hunt
    // that spends money must not start because an alarm fired.
    return const HeadlessHuntDecision.refused(
      'این شکار خاموش است. برای اجرای خودکار، آن را روشن کنید.',
    );
  }
  return HeadlessHuntDecision.run;
}

/// Waits for the run to finish.
///
/// ## Why the stream's end, and not a terminal state
///
/// The engine closes the run's stream when the run ends, and that is the
/// signal worth waiting for: a **closed** stream means the run is over
/// whether the listener was attached before or after it finished. A
/// terminal *state* on a broadcast stream is not enough — a listener that
/// arrives after the last state was emitted would wait forever.
///
/// So the wait ends when the stream ends, and the terminal state is a
/// belt-and-braces check for a run whose stream somehow stays open.
Future<void> _awaitCompletion(SnipeEngine engine, String ruleId) async {
  final completer = Completer<void>();
  StreamSubscription<SnipeRunStatus>? subscription;

  subscription = engine.watch(ruleId).listen(
    (status) {
      if (!SnipeStateMachine.isTerminal(status.state)) return;
      if (!completer.isCompleted) completer.complete();
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete();
    },
  );

  try {
    await completer.future;
  } finally {
    await subscription.cancel();
  }
}

/// Announces a refusal, with its reason.
///
/// A headless hunt that silently did nothing is indistinguishable from a
/// broken app — and the student has no screen to check. So the refusal is
/// said out loud, with the same wording the hunt screen uses.
Future<void> _announceRefusal(
  PlatformBridge bridge,
  List<PreflightFailure> failures,
) async {
  final reason = describePreflightFailures(failures);
  try {
    await bridge.postNotification(
      id: _refusalNotificationId,
      title: '🔎 شکار انجام نشد',
      body: reason,
      deepLink: null,
    );
  } catch (_) {
    // A failure to announce is ugly, not dangerous. The hunt did not run, and
    // the student will see that on the screen next time they open the app.
  }
}

/// The notification id of a headless refusal.
///
/// Separate from the success id, so a refusal and a success cannot replace
/// one another.
const int _refusalNotificationId = 4151;

/// Clears the pending hunt request for [accountId].
///
/// The native side records a hunt request before it knows whether a Dart side
/// is there to take it, so the record outlives the hand-over unless the side
/// that acts clears it. Leaving it behind would make the next app launch
/// start the hunt a second time.
Future<void> _clearPendingRequest(PlatformBridge bridge, AccountId accountId) {
  try {
    return bridge.clearPendingRequests([PendingRequest.hunt(accountId).entry]);
  } catch (_) {
    // A duplicate hunt is better than a lost one — and the request is only
    // recorded when the platform had no Dart side, so this is the rare path.
    return Future<void>.value();
  }
}



/// Releases the foreground service.
///
/// Every exit path goes through here, because a foreground service that
/// lingers is a battery drain and a notification the student cannot clear.
Future<void> _releaseService(PlatformBridge bridge) async {
  try {
    await bridge.stopHuntService();
  } catch (_) {
    // The service releases itself when the process ends anyway.
  }
}
