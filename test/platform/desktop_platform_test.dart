import 'dart:io';

import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/platform/desktop_bridge.dart';
import 'package:bahonar_nut/platform/desktop_stores.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bahonar_desktop_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FilePlainStore', () {
    test('persists strings, ints, and bools across instances', () async {
      final store1 = FilePlainStore(directory: tempDir);
      await store1.writeString('app.name', 'Selfiyar');
      await store1.writeInt('theme.code', 42);
      await store1.writeBool('feature.enabled', true);

      expect(await store1.readString('app.name'), 'Selfiyar');
      expect(await store1.readInt('theme.code'), 42);
      expect(await store1.readBool('feature.enabled'), true);
      expect(await store1.keys(), containsAll(['app.name', 'theme.code', 'feature.enabled']));

      // Re-create from disk
      final store2 = FilePlainStore(directory: tempDir);
      expect(await store2.readString('app.name'), 'Selfiyar');
      expect(await store2.readInt('theme.code'), 42);
      expect(await store2.readBool('feature.enabled'), true);

      // Remove
      await store2.remove('theme.code');
      expect(await store2.readInt('theme.code'), isNull);

      final store3 = FilePlainStore(directory: tempDir);
      expect(await store3.readInt('theme.code'), isNull);
    });
  });

  group('FileSecureStore', () {
    test('stores and restores encrypted credentials across instances', () async {
      final store1 = FileSecureStore(directory: tempDir);
      const accId = 'student_9912345';
      const creds = Credentials(studentId: '9912345', password: 'SecretPassword#123');

      await store1.write(accId, creds);
      final read1 = await store1.read(accId);
      expect(read1?.studentId, '9912345');
      expect(read1?.password, 'SecretPassword#123');
      expect(await store1.listAccountIds(), [accId]);

      // Re-create instance
      final store2 = FileSecureStore(directory: tempDir);
      final read2 = await store2.read(accId);
      expect(read2?.studentId, '9912345');
      expect(read2?.password, 'SecretPassword#123');

      // Delete
      await store2.delete(accId);
      expect(await store2.read(accId), isNull);
      expect(await store2.listAccountIds(), isEmpty);
    });
  });

  group('DesktopPlatformBridge', () {
    test('reports granted permissions for all desktop requirements', () async {
      final bridge = DesktopPlatformBridge(storageDirectory: tempDir);
      expect(await bridge.hasNotificationPermission(), isTrue);
      expect(await bridge.requestNotificationPermission(), isTrue);
      expect(await bridge.canScheduleExactAlarms(), isTrue);
      expect(await bridge.requestExactAlarmPermission(), isTrue);
      expect(await bridge.isIgnoringBatteryOptimizations(), isTrue);
      expect(await bridge.requestIgnoreBatteryOptimizations(), isTrue);
      bridge.dispose();
    });

    test('scheduleAlarm triggers handler on desktop', () async {
      final bridge = DesktopPlatformBridge(storageDirectory: tempDir);
      String? deliveredPayload;
      bridge.onHuntRequested((p) => deliveredPayload = p);

      // Trigger almost immediately
      await bridge.scheduleAlarm(
        requestCode: 101,
        triggerAt: DateTime.now().add(const Duration(milliseconds: 10)),
        payload: 'lunch',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(deliveredPayload, 'lunch');
      bridge.dispose();
    });
  });

  group('AppServices.forDesktop', () {
    test('assembles and initializes all required stores and clients', () async {
      final services = AppServices.forDesktop(storageDirectory: tempDir);
      expect(services.bridge, isA<DesktopPlatformBridge>());
      expect(services.plainStore, isA<FilePlainStore>());
      expect(services.credentialStore, isA<FileSecureStore>());
      expect(services.accountStore, isNotNull);
      expect(services.reminderConfigStore, isNotNull);
      expect(services.bankCardStore, isNotNull);
      expect(services.huntConfigStore, isNotNull);
      expect(services.mealStore, isNotNull);

      services.dispose();
    });
  });

  group('defaultDesktopStorageDirectory', () {
    test('returns a valid non-empty Directory path on desktop', () {
      final dir = defaultDesktopStorageDirectory();
      expect(dir.path, isNotEmpty);
    });
  });
}
