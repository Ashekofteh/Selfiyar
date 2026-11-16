// Runs ON THE DEVICE, against the real Android platform.
//
// The platform stores are the one part of the app that cannot be tested on the
// VM: the Keystore, the preferences and the notification manager exist only on
// Android. This test drives them through the real method channel, so it proves
// the wiring works rather than proving a mock works.
//
// Run with:
//   flutter test integration_test/platform_store_test.dart -d <device>

import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = PlatformBridge();

  test('the Keystore-backed credential store round-trips', () async {
    const accountId = 'integration-account';
    const credentials =
        Credentials(studentId: '400123456', password: 'TestPass123');

    await bridge.credentialStore.write(accountId, credentials);

    final read = await bridge.credentialStore.read(accountId);
    expect(read, isNotNull, reason: 'the credentials should be readable back');
    expect(read!.studentId, '400123456');
    expect(read.password, 'TestPass123');

    final ids = await bridge.credentialStore.listAccountIds();
    expect(ids, contains(accountId));

    await bridge.credentialStore.delete(accountId);
    expect(await bridge.credentialStore.read(accountId), isNull);
  });

  test('the preferences store round-trips', () async {
    final store = bridge.plainStore;

    await store.writeString('probe.key', 'probe-value');
    expect(await store.readString('probe.key'), 'probe-value');

    await store.writeInt('probe.int', 7);
    expect(await store.readInt('probe.int'), 7);

    await store.writeBool('probe.bool', true);
    expect(await store.readBool('probe.bool'), isTrue);

    expect(
      await store.keys(),
      containsAll(['probe.key', 'probe.int', 'probe.bool']),
    );

    await store.remove('probe.key');
    expect(await store.readString('probe.key'), isNull);
  });

  test('the notification and alarm permissions are reportable', () async {
    // The values depend on the device, so only the call is asserted: it must
    // not throw, and it must answer with a boolean.
    expect(await bridge.hasNotificationPermission(), isA<bool>());
    expect(await bridge.canScheduleExactAlarms(), isA<bool>());
  });

  test('a notification is posted without error', () async {
    // The channel, the permission check and the posting path all have to work
    // together. Whether it is *visible* is checked by screenshotting the shade
    // on the device, because the platform offers no way to read back a posted
    // notification from Dart.
    const title = 'یادآور آزمایشی';
    const body = 'این یک اعلان آزمایشی است.';

    // The permission may not be granted on a fresh install; ask for it first.
    if (!await bridge.hasNotificationPermission()) {
      await bridge.requestNotificationPermission();
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    await bridge.postNotification(
      id: 4999,
      title: title,
      body: body,
      deepLink: 'reminder://test',
    );

    // Give the system a moment to lay the notification out.
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  test('an alarm is scheduled and can be cancelled', () async {
    final at = DateTime.now().add(const Duration(minutes: 5));

    await bridge.scheduleAlarm(
      requestCode: 4998,
      triggerAt: at,
      payload: 'test',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await bridge.cancelAlarm(4998);
  });
}
