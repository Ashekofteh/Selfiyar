/// The headless hunt's decisions.
///
/// ## The defect this pins
///
/// F85: the hunt's alarm fired and the service started, but the Dart engine
/// did not run with the app closed — the request was recorded and the hunt
/// started on the *next launch*. For a 16:30 snipe, "the next launch" is
/// usually after the meal is gone.
///
/// The headless entrypoint is what closes that gap. Its decision to start a
/// hunt is the part that spends money, so it is a pure function and it is
/// tested directly: no engine, no network, no platform.
///
/// The two mistakes that matter are both refusals in one direction and a
/// purchase in the other:
///
///  * a hunt that starts when the student switched it off **spends their
///    money** and burns the account's goodwill with the portal;
///  * a hunt that refuses silently **looks like a broken app** — and a
///    student with no screen to check has no way to tell a refusal from a
///    failure.
library;

import 'package:bahonar_nut/background/hunt_entrypoint.dart';
import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/portal/preflight.dart';
import 'package:test/test.dart';

void main() {
  group('the headless decision', () {
    test('a hunt with no configuration does not run', () {
      // No configuration means no window, no dishes and no account's worth of
      // intent. There is nothing to hunt for.
      final decision = decideHeadlessHunt(null);

      expect(decision.shouldRun, isFalse);
      expect(decision.reason, isNotNull,
          reason: 'a refusal must carry a reason, or it is not actionable');
    });

    test('a switched-off hunt does not run', () {
      // The switch is the student's own decision, and it is checked on every
      // path — the platform can ask for a hunt when nobody is looking.
      final decision = decideHeadlessHunt(
        HuntConfig(targetDate: DateTime.utc(2026, 10, 22), enabled: false),
      );

      expect(decision.shouldRun, isFalse,
          reason: 'a hunt the student switched off must not start because an '
              'alarm fired');
      expect(decision.reason, contains('خاموش'),
          reason: 'and the refusal must say why');
    });

    test('a switched-on hunt runs', () {
      final decision = decideHeadlessHunt(
        HuntConfig(targetDate: DateTime.utc(2026, 10, 22), enabled: true),
      );

      expect(decision.shouldRun, isTrue);
      expect(decision.reason, isNull);
    });

    test('the default configuration does not run', () {
      // `HuntConfig()` is off by default, and the default is what a hunt
      // looks like when it was never configured.
      final decision = decideHeadlessHunt(HuntConfig());

      expect(decision.shouldRun, isFalse);
    });
  });

  group('the refusal reaches the student', () {
    // A headless hunt that silently did nothing is indistinguishable from a
    // broken app. The wording is shared with the hunt screen so the two
    // cannot drift — the copy nobody is looking at is the one that matters
    // most when the app is closed.
    test('the reason names the problem', () {
      expect(
        describePreflightFailures([PreflightFailure.insufficientFunds]),
        contains('موجودی'),
      );
      expect(
        describePreflightFailures([PreflightFailure.noSession]),
        contains('ورود'),
      );
      expect(
        describePreflightFailures([PreflightFailure.clockUnsynced]),
        contains('ساعت سرور'),
      );
    });

    test('an unknown failure still says something', () {
      // An empty list is not a real outcome, but the text must never be
      // empty: an empty body is a refusal the student cannot act on.
      expect(describePreflightFailures([]), isNotEmpty);
    });

    test('the first reason is the one that is reported', () {
      // Several failures can hold at once. The order is the priority order,
      // and it is the same order the screen uses.
      final text = describePreflightFailures([
        PreflightFailure.insufficientFunds,
        PreflightFailure.alreadyBooked,
      ]);

      expect(text, contains('تکراری'),
          reason: 'the double-purchase guard is the more urgent of the two');
    });
  });
}
