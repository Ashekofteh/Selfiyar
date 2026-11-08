import 'dart:async';
import 'package:bahonar_nut/platform/connectivity_service.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectivityService', () {
    test('starts with initial state', () {
      final serviceOnline = ConnectivityService();
      expect(serviceOnline.isOnline, isTrue);
      expect(serviceOnline.isOffline, isFalse);

      final serviceOffline = ConnectivityService(initialOnline: false);
      expect(serviceOffline.isOnline, isFalse);
      expect(serviceOffline.isOffline, isTrue);
    });

    test('markOffline and markOnline toggle state and notify listeners', () async {
      final service = ConnectivityService(initialOnline: true);
      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);

      service.markOffline();
      expect(service.isOnline, isFalse);
      expect(service.isOffline, isTrue);

      service.markOnline();
      expect(service.isOnline, isTrue);
      expect(service.isOffline, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, [false, true]);

      await sub.cancel();
      service.dispose();
    });

    test('duplicate status reports do not emit redundant events', () async {
      final service = ConnectivityService(initialOnline: true);
      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);

      service.markOnline(); // already online, no emit
      service.markOnline(); // no emit
      service.markOffline(); // emits false
      service.markOffline(); // no emit

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, [false]);

      await sub.cancel();
      service.dispose();
    });

    test('checkConnection delegates to checkHost and updates state', () async {
      var simulatedStatus = true;
      final service = ConnectivityService(
        checkHost: () async => simulatedStatus,
        initialOnline: false,
      );

      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);

      var result = await service.checkConnection();
      expect(result, isTrue);
      expect(service.isOnline, isTrue);

      simulatedStatus = false;
      result = await service.checkConnection();
      expect(result, isFalse);
      expect(service.isOnline, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, [true, false]);

      await sub.cancel();
      service.dispose();
    });

    test('checkConnection deduplicates concurrent calls', () async {
      var callCount = 0;
      final completer = Completer<bool>();
      final service = ConnectivityService(
        checkHost: () {
          callCount++;
          return completer.future;
        },
        initialOnline: true,
      );

      final f1 = service.checkConnection();
      final f2 = service.checkConnection();
      expect(callCount, 1);

      completer.complete(true);
      final r1 = await f1;
      final r2 = await f2;
      expect(r1, isTrue);
      expect(r2, isTrue);
      expect(callCount, 1);

      service.dispose();
    });

    test('offline periodic probe detects connection restoration', () async {
      var simulatedStatus = false;
      final service = ConnectivityService(
        checkHost: () async => simulatedStatus,
        initialOnline: false,
        enablePeriodicProbe: true,
        probeInterval: const Duration(milliseconds: 20),
      );

      expect(service.isOffline, isTrue);

      simulatedStatus = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(service.isOnline, isTrue);
      service.dispose();
    });
  });
}
