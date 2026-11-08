import 'package:bahonar_nut/platform/desktop_bridge.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');
  final calls = <MethodCall>[];
  var biometricShouldSucceed = true;
  var biometricShouldThrow = false;
  var smsConsentShouldSucceed = true;

  setUp(() {
    calls.clear();
    biometricShouldSucceed = true;
    biometricShouldThrow = false;
    smsConsentShouldSucceed = true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'authenticateBiometric':
          if (biometricShouldThrow) {
            throw PlatformException(code: 'AUTH_ERROR', message: 'Biometric hardware failure');
          }
          return biometricShouldSucceed;
        case 'startSmsUserConsent':
          return smsConsentShouldSucceed;
        case 'stopSmsUserConsent':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PlatformBridge Biometric & SMS User Consent', () {
    test('authenticateBiometric returns false when auth fails or platform throws', () async {
      final bridge = PlatformBridge(channel: channel);

      // Successful auth
      biometricShouldSucceed = true;
      expect(await bridge.authenticateBiometric(), isTrue);

      // Failed auth
      biometricShouldSucceed = false;
      expect(await bridge.authenticateBiometric(), isFalse);

      // Thrown exception (e.g. SecurityException on device without permission)
      biometricShouldThrow = true;
      expect(await bridge.authenticateBiometric(), isFalse);
    });

    test('startSmsUserConsent invokes channel and returns bool', () async {
      final bridge = PlatformBridge(channel: channel);

      smsConsentShouldSucceed = true;
      expect(await bridge.startSmsUserConsent(), isTrue);
      expect(calls.last.method, equals('startSmsUserConsent'));

      smsConsentShouldSucceed = false;
      expect(await bridge.startSmsUserConsent(), isFalse);
    });

    test('stopSmsUserConsent invokes channel', () async {
      final bridge = PlatformBridge(channel: channel);
      await bridge.stopSmsUserConsent();
      expect(calls.last.method, equals('stopSmsUserConsent'));
    });

    test('onOtpSmsReceived dispatches incoming SMS from channel', () async {
      final bridge = PlatformBridge(channel: channel);
      String? receivedMessage;

      bridge.onOtpSmsReceived((message) {
        receivedMessage = message;
      });

      // Simulate channel invocation from Android MainActivity
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'ir.ac.uk.bahonar_nut/platform',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onOtpSmsReceived', 'بانک سامان: رمز پویا 654321'),
        ),
        (data) {},
      );

      expect(receivedMessage, equals('بانک سامان: رمز پویا 654321'));
    });

    test('DesktopPlatformBridge handles SMS consent methods as safe no-op', () async {
      final desktopBridge = DesktopPlatformBridge();
      expect(await desktopBridge.startSmsUserConsent(), isFalse);
      await desktopBridge.stopSmsUserConsent();

      var received = false;
      desktopBridge.onOtpSmsReceived((_) => received = true);
      expect(received, isFalse);
    });
  });
}
