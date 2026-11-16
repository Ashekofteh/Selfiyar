import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/shared/app_version.dart';
import '../core/shared/platform_stores.dart';

/// Status outcomes of an update check.
enum AppUpdateStatus {
  /// The running version is identical or newer than the published release.
  upToDate,

  /// A strictly newer version was found.
  updateAvailable,

  /// A newer version was found, but the user previously chose to skip it.
  skipped,

  /// Automatic check skipped because the 24-hour rate-limiting cool-down has not elapsed.
  throttled,

  /// The check failed due to network unavailability or API rate limits.
  error,
}

/// The result returned by [AppUpdateService.checkForUpdates].
class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.status,
    this.release,
    this.errorMessage,
    this.checkedAt,
  });

  factory AppUpdateCheckResult.upToDate({
    required AppReleaseInfo release,
    required DateTime checkedAt,
  }) =>
      AppUpdateCheckResult(
        status: AppUpdateStatus.upToDate,
        release: release,
        checkedAt: checkedAt,
      );

  factory AppUpdateCheckResult.updateAvailable({
    required AppReleaseInfo release,
    required DateTime checkedAt,
  }) =>
      AppUpdateCheckResult(
        status: AppUpdateStatus.updateAvailable,
        release: release,
        checkedAt: checkedAt,
      );

  factory AppUpdateCheckResult.skipped({
    required AppReleaseInfo release,
    required DateTime checkedAt,
  }) =>
      AppUpdateCheckResult(
        status: AppUpdateStatus.skipped,
        release: release,
        checkedAt: checkedAt,
      );

  factory AppUpdateCheckResult.throttled({
    AppReleaseInfo? cachedRelease,
  }) =>
      AppUpdateCheckResult(
        status: AppUpdateStatus.throttled,
        release: cachedRelease,
      );

  factory AppUpdateCheckResult.error(String message) => AppUpdateCheckResult(
        status: AppUpdateStatus.error,
        errorMessage: message,
      );

  final AppUpdateStatus status;
  final AppReleaseInfo? release;
  final String? errorMessage;
  final DateTime? checkedAt;

  bool get hasUpdate =>
      status == AppUpdateStatus.updateAvailable || status == AppUpdateStatus.skipped;
}

/// Service that coordinates update checks, rate-limiting, and platform download resolution.
class AppUpdateService {
  AppUpdateService({
    required this.plainStore,
    http.Client? httpClient,
    this.currentVersion = kAppVersion,
    this.currentBuild = kAppBuildNumber,
    DateTime Function()? now,
  })  : _client = httpClient ?? http.Client(),
        _now = now ?? DateTime.now;

  static const String keyLastCheckedMs = 'update_last_check_ms';
  static const String keySkippedVersion = 'update_skipped_version';
  static const String keyCachedReleaseJson = 'update_cached_release_json';

  /// Automatic checks are limited to at most once per 24 hours.
  static const Duration autoCheckInterval = Duration(hours: 24);

  final PlainStore plainStore;
  final http.Client _client;
  final String currentVersion;
  final int currentBuild;
  final DateTime Function() _now;

  /// Checks for available updates.
  ///
  /// Set [force] to `true` when triggered by an explicit user action (e.g. "بررسی بروزرسانی" button),
  /// which bypasses the 24-hour rate limit and skipped version status.
  Future<AppUpdateCheckResult> checkForUpdates({bool force = false}) async {
    final now = _now();

    // Check throttle cool-down for non-forced requests
    if (!force) {
      final lastCheckMs = await plainStore.readInt(keyLastCheckedMs);
      if (lastCheckMs != null) {
        final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(lastCheckMs));
        if (elapsed < autoCheckInterval) {
          final cached = await _readCachedRelease();
          return AppUpdateCheckResult.throttled(cachedRelease: cached);
        }
      }
    }

    AppReleaseInfo? release;
    String? errorReason;

    // 1. Primary query: version.json on GitHub Raw (No 60 req/hr rate-limit)
    try {
      final uri = Uri.parse(kVersionJsonUrl);
      final response = await _client.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final bodyText = utf8.decode(response.bodyBytes);
        final data = jsonDecode(bodyText) as Map<String, dynamic>;
        release = AppReleaseInfo.fromJson(data);
      }
    } catch (e) {
      errorReason = e.toString();
    }

    // 2. Secondary fallback: GitHub Releases API
    if (release == null) {
      try {
        final apiUri = Uri.parse(kGitHubLatestReleaseApiUrl);
        final response = await _client.get(
          apiUri,
          headers: {
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'Selfiyar-App',
          },
        ).timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final bodyText = utf8.decode(response.bodyBytes);
          final data = jsonDecode(bodyText) as Map<String, dynamic>;
          release = AppReleaseInfo.fromGitHubRelease(data);
        } else if (response.statusCode == 403) {
          return AppUpdateCheckResult.error(
            'محدودیت تعداد درخواست اعمال شده است. لطفاً بعداً بررسی کنید.',
          );
        }
      } catch (e) {
        errorReason = e.toString();
      }
    }

    if (release == null) {
      return AppUpdateCheckResult.error(
        'عدم برقراری ارتباط با سرور بروزرسانی ($errorReason)',
      );
    }

    // Persist check timestamp and cache release metadata
    await plainStore.writeInt(keyLastCheckedMs, now.millisecondsSinceEpoch);
    await plainStore.writeString(keyCachedReleaseJson, jsonEncode(release.toJson()));

    final isNewer = isNewerVersion(
      current: currentVersion,
      candidate: release.version,
      currentBuild: currentBuild,
      candidateBuild: release.buildNumber,
    );

    if (!isNewer) {
      return AppUpdateCheckResult.upToDate(release: release, checkedAt: now);
    }

    // Check if user skipped this specific version
    final skippedVer = await plainStore.readString(keySkippedVersion);
    if (!force && skippedVer == release.version) {
      return AppUpdateCheckResult.skipped(release: release, checkedAt: now);
    }

    return AppUpdateCheckResult.updateAvailable(release: release, checkedAt: now);
  }

  /// Records that the user wishes to ignore notifications for [version].
  Future<void> skipVersion(String version) async {
    await plainStore.writeString(keySkippedVersion, version);
  }

  /// Clears the ignored version preference.
  Future<void> clearSkippedVersion() async {
    await plainStore.writeString(keySkippedVersion, null);
  }

  /// Resolves the optimal download link for the host platform.
  String resolvePlatformDownloadUrl(AppReleaseInfo release) {
    if (kIsWeb) return release.releaseUrl;

    if (Platform.isAndroid && release.assets.containsKey('android')) {
      return release.assets['android']!;
    }
    if (Platform.isWindows && release.assets.containsKey('windows')) {
      return release.assets['windows']!;
    }
    if (Platform.isLinux && release.assets.containsKey('linux')) {
      return release.assets['linux']!;
    }
    if (Platform.isMacOS && release.assets.containsKey('macos')) {
      return release.assets['macos']!;
    }
    // On iOS, point to the release page where IPA and Sideload instructions reside.
    return release.releaseUrl;
  }

  Future<AppReleaseInfo?> _readCachedRelease() async {
    try {
      final raw = await plainStore.readString(keyCachedReleaseJson);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        return AppReleaseInfo.fromJson(map);
      }
    } catch (_) {}
    return null;
  }
}
