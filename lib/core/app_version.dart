/// Application version definitions, metadata, and version comparison utilities.
///
/// Pure Dart (spec §3.1): this file must never import Flutter or `dart:io`.
library;

/// The current application semantic version.
const String kAppVersion = '1.0.0';

/// The current build number.
const int kAppBuildNumber = 21;

/// The official GitHub repository URL.
const String kGitHubRepoUrl = 'https://github.com/Ashekofteh/Selfiyar';

/// The developer's GitHub profile URL.
const String kGitHubDeveloperUrl = 'https://github.com/Ashekofteh';

/// The official GitHub issues / feedback URL.
const String kGitHubIssuesUrl = 'https://github.com/Ashekofteh/Selfiyar/issues';

/// The raw GitHub CDN endpoint for rate-limit-free version metadata.
const String kVersionJsonUrl =
    'https://raw.githubusercontent.com/Ashekofteh/Selfiyar/master/version.json';

/// Fallback GitHub API endpoint for the latest release.
const String kGitHubLatestReleaseApiUrl =
    'https://api.github.com/repos/Ashekofteh/Selfiyar/releases/latest';

/// Metadata for an application release published on GitHub.
class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.buildNumber,
    required this.releaseTitle,
    required this.releaseNotes,
    required this.releaseUrl,
    this.publishedAt,
    this.assets = const {},
  });

  final String version;
  final int buildNumber;
  final String releaseTitle;
  final String releaseNotes;
  final String releaseUrl;
  final DateTime? publishedAt;
  final Map<String, String> assets;

  /// Parses an [AppReleaseInfo] from a JSON map (e.g. from `version.json`).
  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    DateTime? published;
    final publishedStr = json['published_at'] as String?;
    if (publishedStr != null) {
      published = DateTime.tryParse(publishedStr);
    }

    final rawAssets = json['assets'];
    final assets = <String, String>{};
    if (rawAssets is Map) {
      for (final entry in rawAssets.entries) {
        assets[entry.key.toString()] = entry.value.toString();
      }
    }

    return AppReleaseInfo(
      version: (json['version'] as String?)?.trim() ?? '',
      buildNumber: (json['build_number'] as num?)?.toInt() ?? 0,
      releaseTitle: (json['release_title'] as String?)?.trim() ?? '',
      releaseNotes: (json['release_notes'] as String?)?.trim() ?? '',
      releaseUrl: (json['release_url'] as String?)?.trim() ?? kGitHubRepoUrl,
      publishedAt: published,
      assets: assets,
    );
  }

  /// Parses from GitHub's REST API `/releases/latest` response.
  factory AppReleaseInfo.fromGitHubRelease(Map<String, dynamic> json) {
    final tagName = (json['tag_name'] as String?)?.trim() ?? '';
    final cleanVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    final body = (json['body'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? tagName;
    final htmlUrl = (json['html_url'] as String?)?.trim() ?? kGitHubRepoUrl;
    final publishedStr = json['published_at'] as String?;
    final published = publishedStr != null ? DateTime.tryParse(publishedStr) : null;

    final assetsMap = <String, String>{};
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is Map) {
          final assetName = item['name'] as String? ?? '';
          final downloadUrl = item['browser_download_url'] as String? ?? '';
          if (assetName.endsWith('.apk')) assetsMap['android'] = downloadUrl;
          if (assetName.endsWith('-windows-x64.zip')) assetsMap['windows'] = downloadUrl;
          if (assetName.endsWith('-linux-x64.tar.gz')) assetsMap['linux'] = downloadUrl;
          if (assetName.endsWith('-macos.zip')) assetsMap['macos'] = downloadUrl;
          if (assetName.endsWith('-ios.ipa')) assetsMap['ios'] = downloadUrl;
        }
      }
    }

    return AppReleaseInfo(
      version: cleanVersion,
      buildNumber: _extractBuildNumber(cleanVersion),
      releaseTitle: name,
      releaseNotes: body,
      releaseUrl: htmlUrl,
      publishedAt: published,
      assets: assetsMap,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'build_number': buildNumber,
        'release_title': releaseTitle,
        'release_notes': releaseNotes,
        'release_url': releaseUrl,
        if (publishedAt != null) 'published_at': publishedAt!.toIso8601String(),
        'assets': assets,
      };

  static int _extractBuildNumber(String ver) {
    if (ver.contains('+')) {
      final part = ver.split('+').last;
      return int.tryParse(part) ?? 0;
    }
    // Check if beta.X can be mapped
    final betaMatch = RegExp(r'beta\.(\d+)', caseSensitive: false).firstMatch(ver);
    if (betaMatch != null) {
      return int.tryParse(betaMatch.group(1)!) ?? 0;
    }
    return 0;
  }
}

/// Compares two semantic version strings and returns true if [candidate] is strictly
/// newer than [current].
///
/// Handles versions like:
/// - `1.0.0-beta.19` vs `1.0.0-beta.20` -> true
/// - `1.0.0-beta.19` vs `1.0.0` -> true (final release is newer than pre-release)
/// - `1.0.0-beta.19` vs `1.0.0-beta.19` -> false
/// - `1.0.0-beta.20` vs `1.0.0-beta.19` -> false
/// - `v1.0.1` vs `1.0.0` -> true (leading 'v' tolerated)
bool isNewerVersion({
  required String current,
  required String candidate,
  int? currentBuild,
  int? candidateBuild,
}) {
  final cleanCurrent = _stripLeadingV(current);
  final cleanCandidate = _stripLeadingV(candidate);

  if (cleanCurrent.isEmpty || cleanCandidate.isEmpty) return false;

  final currParsed = _ParsedVersion.parse(cleanCurrent, fallbackBuild: currentBuild);
  final candParsed = _ParsedVersion.parse(cleanCandidate, fallbackBuild: candidateBuild);

  return candParsed.compareTo(currParsed) > 0;
}

String _stripLeadingV(String v) {
  final trimmed = v.trim();
  if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
    return trimmed.substring(1).trim();
  }
  return trimmed;
}

class _ParsedVersion implements Comparable<_ParsedVersion> {
  _ParsedVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
    this.preReleaseNum,
    this.buildNumber = 0,
  });

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;
  final int? preReleaseNum;
  final int buildNumber;

  static _ParsedVersion parse(String raw, {int? fallbackBuild}) {
    var text = raw.trim();
    int build = fallbackBuild ?? 0;

    if (text.contains('+')) {
      final parts = text.split('+');
      text = parts.first;
      final parsedBuild = int.tryParse(parts.last);
      if (parsedBuild != null) build = parsedBuild;
    }

    String? preRelease;
    int? preReleaseNum;

    if (text.contains('-')) {
      final parts = text.split('-');
      text = parts.first;
      final preStr = parts.sublist(1).join('-');
      // E.g. "beta.19" or "alpha.2" or "rc1"
      final numMatch = RegExp(r'(\d+)').firstMatch(preStr);
      if (numMatch != null) {
        preReleaseNum = int.tryParse(numMatch.group(1)!);
        preRelease = preStr.replaceAll(numMatch.group(1)!, '').replaceAll('.', '').trim();
      } else {
        preRelease = preStr;
      }
    }

    final nums = text.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final major = nums.isNotEmpty ? nums[0] : 0;
    final minor = nums.length > 1 ? nums[1] : 0;
    final patch = nums.length > 2 ? nums[2] : 0;

    return _ParsedVersion(
      major: major,
      minor: minor,
      patch: patch,
      preRelease: preRelease,
      preReleaseNum: preReleaseNum,
      buildNumber: build,
    );
  }

  @override
  int compareTo(_ParsedVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);

    // SemVer: 1.0.0 > 1.0.0-beta
    final hasPre = preRelease != null || preReleaseNum != null;
    final otherHasPre = other.preRelease != null || other.preReleaseNum != null;

    if (hasPre && !otherHasPre) return -1;
    if (!hasPre && otherHasPre) return 1;

    if (hasPre && otherHasPre) {
      final prComp = (preRelease ?? '').compareTo(other.preRelease ?? '');
      if (prComp != 0) return prComp;
      final num1 = preReleaseNum ?? 0;
      final num2 = other.preReleaseNum ?? 0;
      if (num1 != num2) return num1.compareTo(num2);
    }

    return buildNumber.compareTo(other.buildNumber);
  }
}
