// Runs ON THE DEVICE, against the real Android platform.
//
// Sets up the F85 headless-hunt test: the working credential into the
// Keystore, a hunt configuration with a real dish, and the alarm armed for a
// window that is open now.
//
// The credentials come from argv, so they are never written into the source.
// The test is a *setup* — it writes state and then exits, and the hunt itself
// is left to the alarm.
//
// Run with:
//   flutter test integration_test/hunt_setup_test.dart -d <device> \
//     --dart-define=HUNT_STUDENT_ID=... --dart-define=HUNT_PASSWORD=...

import 'dart:io';

import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/hunt/hunt_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = PlatformBridge();

  const studentId = String.fromEnvironment('HUNT_STUDENT_ID');
  const password = String.fromEnvironment('HUNT_PASSWORD');
  const accountId = String.fromEnvironment('HUNT_ACCOUNT_ID');
  const dishName = String.fromEnvironment('HUNT_DISH_NAME');
  const dishOptionId = String.fromEnvironment('HUNT_DISH_OPTION_ID');
  const dishPriceRial = int.fromEnvironment('HUNT_DISH_PRICE_RIAL');
  const targetDate = String.fromEnvironment('HUNT_TARGET_DATE');
  const targetSlot = String.fromEnvironment('HUNT_TARGET_SLOT');
  const windowStart = String.fromEnvironment('HUNT_WINDOW_START');
  const windowEnd = String.fromEnvironment('HUNT_WINDOW_END');

  test('the device is set up for the headless hunt', () async {
    expect(accountId, isNotEmpty, reason: 'the account id must be given');
    expect(password, isNotEmpty, reason: 'the password must be given');

    // The credential goes into the Keystore through the app's own store — the
    // same path the "add account" dialog uses. The stored one on this device
    // was wrong, and the portal refused the login.
    await bridge.credentialStore.write(
      accountId,
      Credentials(studentId: studentId, password: password),
    );

    final stored = await bridge.credentialStore.read(accountId);
    expect(stored, isNotNull);
    expect(stored!.studentId, studentId);
    expect(stored.password, password);

    // The hunt configuration, with a real dish.
    final config = HuntConfig(
      windowStart: _time(windowStart),
      windowEnd: _time(windowEnd),
      targetSlot: MealSlot.values.firstWhere((s) => s.name == targetSlot),
      targetDate: DateTime.parse(targetDate).toUtc(),
      dishPriority: [
        HuntDish(
          optionId: dishOptionId,
          name: dishName,
          priceRial: dishPriceRial,
        ),
      ],
      enabled: true,
    );

    await bridge.plainStore.writeString(
      'hunt.$accountId',
      encodeHuntConfig(config),
    );

    final raw = await bridge.plainStore.readString('hunt.$accountId');
    expect(raw, isNotNull);
    final decoded = decodeHuntConfig(raw!);
    expect(decoded, isNotNull);
    expect(decoded!.dishPriority.length, 1);
    expect(decoded.dishPriority.first.name, dishName);
    expect(decoded.enabled, isTrue);

    // The alarm is armed for the window's start, so the device fires it by
    // itself — no app, no Dart side, no tap.
    final wakeAt = DateTime.now().toUtc().add(const Duration(minutes: 2));
    await bridge.scheduleHuntAlarm(accountId: accountId, triggerAt: wakeAt);

    // A setup harness, not production code: the log line is the whole point of
    // the output, and it goes to the console the operator is watching.
    stdout.writeln(
      'SETUP: account=$accountId dish=$dishName '
      'price=$dishPriceRial slot=$targetSlot date=$targetDate '
      'window=$windowStart-$windowEnd',
    );
    stdout.writeln('SETUP: alarm armed for $wakeAt');

    await Future<void>.delayed(const Duration(seconds: 2));
  });
}

ClockTime _time(String raw) {
  final parts = raw.split(':');
  return ClockTime(int.parse(parts[0]), int.parse(parts[1]));
}
