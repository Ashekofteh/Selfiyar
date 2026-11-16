import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:bahonar_nut/platform/app_update_service.dart';

import '../helpers/memory_stores.dart';

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Response _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  final bytes = utf8.encode(jsonEncode(data));
  return http.Response.bytes(
    bytes,
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('AppUpdateService', () {
    late MemoryPlainStore store;

    setUp(() {
      store = MemoryPlainStore();
    });

    test(
      'returns updateAvailable when server version is strictly newer',
      () async {
        final fakeClient = _FakeHttpClient((request) async {
          return _jsonResponse({
            'version': '1.0.0-beta.20',
            'build_number': 20,
            'release_title': 'نسخه بتا ۲۰',
            'release_notes': 'بهینه‌سازی کلی',
            'release_url': 'https://example.com/v20',
            'assets': {'android': 'https://example.com/app.apk'},
          });
        });

        final service = AppUpdateService(
          plainStore: store,
          httpClient: fakeClient,
          currentVersion: '1.0.0-beta.19',
          currentBuild: 19,
        );

        final result = await service.checkForUpdates();

        expect(result.status, AppUpdateStatus.updateAvailable);
        expect(result.release?.version, '1.0.0-beta.20');
        expect(
          result.release?.assets['android'],
          'https://example.com/app.apk',
        );
      },
    );

    test('returns upToDate when server version matches or is older', () async {
      final fakeClient = _FakeHttpClient((request) async {
        return _jsonResponse({
          'version': '1.0.0-beta.19',
          'build_number': 19,
          'release_title': 'نسخه بتا ۱۹',
          'release_notes': 'بدون تغییر',
          'release_url': 'https://example.com/v19',
        });
      });

      final service = AppUpdateService(
        plainStore: store,
        httpClient: fakeClient,
        currentVersion: '1.0.0-beta.19',
        currentBuild: 19,
      );

      final result = await service.checkForUpdates();
      expect(
        result.status,
        AppUpdateStatus.upToDate,
        reason: result.errorMessage,
      );
    });

    test('respects skipped version for automatic check, but surfaces on forced check', () async {
      final fakeClient = _FakeHttpClient((request) async {
        return _jsonResponse({
          'version': '1.0.0-beta.20',
          'build_number': 20,
          'release_title': 'نسخه بتا ۲۰',
          'release_notes': 'ویژگی جدید',
          'release_url': 'https://example.com/v20',
        });
      });

      final service = AppUpdateService(
        plainStore: store,
        httpClient: fakeClient,
        currentVersion: '1.0.0-beta.19',
        currentBuild: 19,
      );

      await service.skipVersion('1.0.0-beta.20');

      // Auto check -> skipped
      final autoResult = await service.checkForUpdates(force: false);
      expect(
        autoResult.status,
        AppUpdateStatus.skipped,
        reason: autoResult.errorMessage,
      );

      // Explicit user check -> updateAvailable
      final forcedResult = await service.checkForUpdates(force: true);
      expect(
        forcedResult.status,
        AppUpdateStatus.updateAvailable,
        reason: forcedResult.errorMessage,
      );
    });

    test(
      'throttles automatic checks within 24 hours without hitting network',
      () async {
        int networkHits = 0;
        final fakeClient = _FakeHttpClient((request) async {
          networkHits++;
          return _jsonResponse({});
        });

        var currentTime = DateTime(2026, 10, 30, 10, 0);

        final service = AppUpdateService(
          plainStore: store,
          httpClient: fakeClient,
          currentVersion: '1.0.0-beta.19',
          currentBuild: 19,
          now: () => currentTime,
        );

        // First check hits network
        await service.checkForUpdates();
        expect(networkHits, 1);

        // Second check 2 hours later -> throttled, no network request
        currentTime = currentTime.add(const Duration(hours: 2));
        final throttledResult = await service.checkForUpdates(force: false);
        expect(throttledResult.status, AppUpdateStatus.throttled);
        expect(networkHits, 1);

        // Explicit forced check -> bypasses throttle
        final forcedResult = await service.checkForUpdates(force: true);
        expect(forcedResult.status, AppUpdateStatus.upToDate);
        expect(networkHits, 2);
      },
    );

    test('returns error gracefully when offline or network fails', () async {
      final fakeClient = _FakeHttpClient((request) async {
        throw http.ClientException('Network unreachable');
      });

      final service = AppUpdateService(
        plainStore: store,
        httpClient: fakeClient,
        currentVersion: '1.0.0-beta.19',
      );

      final result = await service.checkForUpdates(force: true);
      expect(result.status, AppUpdateStatus.error);
      expect(result.errorMessage, contains('عدم برقراری ارتباط'));
    });
  });
}
