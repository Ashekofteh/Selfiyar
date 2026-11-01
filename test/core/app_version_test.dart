import 'package:test/test.dart';

import 'package:bahonar_nut/core/app_version.dart';

void main() {
  group('AppReleaseInfo', () {
    test('parses from version.json format', () {
      final json = {
        'version': '1.0.0-beta.20',
        'build_number': 20,
        'release_title': 'نسخه آزمایشی بتا ۲۰',
        'release_notes': 'بهبودهای کلی در عملکرد',
        'release_url': 'https://github.com/Ashekofteh/Selfiyar/releases/tag/v1.0.0-beta.20',
        'published_at': '2026-11-01T12:00:00Z',
        'assets': {
          'android': 'https://example.com/app.apk',
          'windows': 'https://example.com/app.zip',
        },
      };

      final info = AppReleaseInfo.fromJson(json);

      expect(info.version, '1.0.0-beta.20');
      expect(info.buildNumber, 20);
      expect(info.releaseTitle, 'نسخه آزمایشی بتا ۲۰');
      expect(info.releaseNotes, 'بهبودهای کلی در عملکرد');
      expect(info.assets['android'], 'https://example.com/app.apk');
      expect(info.assets['windows'], 'https://example.com/app.zip');
      expect(info.publishedAt, DateTime.utc(2026, 11, 1, 12, 0, 0));
    });

    test('parses from GitHub release API response', () {
      final json = {
        'tag_name': 'v1.0.0-beta.20',
        'name': 'Release 20',
        'body': 'Notes here',
        'html_url': 'https://github.com/Ashekofteh/Selfiyar/releases/tag/v1.0.0-beta.20',
        'published_at': '2026-11-01T12:00:00Z',
        'assets': [
          {
            'name': 'selfiyar-beta.apk',
            'browser_download_url': 'https://example.com/selfiyar-beta.apk',
          },
          {
            'name': 'selfiyar-windows-x64.zip',
            'browser_download_url': 'https://example.com/selfiyar-windows-x64.zip',
          },
          {
            'name': 'selfiyar-linux-x64.tar.gz',
            'browser_download_url': 'https://example.com/selfiyar-linux-x64.tar.gz',
          },
          {
            'name': 'selfiyar-macos.zip',
            'browser_download_url': 'https://example.com/selfiyar-macos.zip',
          },
          {
            'name': 'selfiyar-ios.ipa',
            'browser_download_url': 'https://example.com/selfiyar-ios.ipa',
          },
        ],
      };

      final info = AppReleaseInfo.fromGitHubRelease(json);
      expect(info.version, '1.0.0-beta.20');
      expect(info.assets['android'], 'https://example.com/selfiyar-beta.apk');
      expect(info.assets['windows'], 'https://example.com/selfiyar-windows-x64.zip');
      expect(info.assets['linux'], 'https://example.com/selfiyar-linux-x64.tar.gz');
      expect(info.assets['macos'], 'https://example.com/selfiyar-macos.zip');
      expect(info.assets['ios'], 'https://example.com/selfiyar-ios.ipa');
    });
  });

  group('isNewerVersion', () {
    test('identifies newer pre-release numbers', () {
      expect(
        isNewerVersion(current: '1.0.0-beta.19', candidate: '1.0.0-beta.20'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.0.0-beta.20', candidate: '1.0.0-beta.19'),
        isFalse,
      );
      expect(
        isNewerVersion(current: '1.0.0-beta.19', candidate: '1.0.0-beta.19'),
        isFalse,
      );
    });

    test('final release is newer than pre-release with same major.minor.patch', () {
      expect(
        isNewerVersion(current: '1.0.0-beta.19', candidate: '1.0.0'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.0.0', candidate: '1.0.0-beta.19'),
        isFalse,
      );
    });

    test('identifies higher major, minor, or patch', () {
      expect(
        isNewerVersion(current: '1.0.0', candidate: '1.0.1'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.0.0', candidate: '1.1.0'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.0.0', candidate: '2.0.0'),
        isTrue,
      );
      expect(
        isNewerVersion(current: '1.2.0', candidate: '1.1.9'),
        isFalse,
      );
    });

    test('tolerates leading v prefix', () {
      expect(
        isNewerVersion(current: 'v1.0.0-beta.19', candidate: 'v1.0.0-beta.20'),
        isTrue,
      );
    });

    test('uses build numbers when versions match', () {
      expect(
        isNewerVersion(current: '1.0.0+19', candidate: '1.0.0+20'),
        isTrue,
      );
      expect(
        isNewerVersion(
          current: '1.0.0',
          candidate: '1.0.0',
          currentBuild: 19,
          candidateBuild: 20,
        ),
        isTrue,
      );
    });
  });
}
