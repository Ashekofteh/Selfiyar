import 'dart:io';

import 'package:test/test.dart';

/// Guards the architectural invariant from spec §3.1: the domain core is
/// platform-agnostic and must never import Flutter or `dart:ui`.
///
/// The core is tested with plain `dart test` rather than `flutter_test`, which
/// already means a Flutter import would fail to compile. This test adds a direct
/// source check so the violation is reported with a clear message and a path,
/// rather than as a confusing analysis error.
void main() {
  group('domain core purity', () {
    final coreDir = Directory('lib/core');

    test('lib/core exists', () {
      expect(coreDir.existsSync(), isTrue);
    });

    test('no core file imports package:flutter or dart:ui', () {
      if (!coreDir.existsSync()) return;

      final offenders = <String>[];
      final importPattern = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""");

      for (final entity in coreDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;

        for (final line in entity.readAsLinesSync()) {
          final match = importPattern.firstMatch(line);
          if (match == null) continue;
          final target = match.group(1)!;
          if (target.startsWith('package:flutter') || target == 'dart:ui') {
            offenders.add('${entity.path}: $target');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'domain core must stay platform-agnostic (spec §3.1). '
            'Offending imports:\n${offenders.join('\n')}',
      );
    });

    test(
      'no core file imports dart:io (platform I/O belongs in transport)',
      () {
        if (!coreDir.existsSync()) return;

        final offenders = <String>[];
        final importPattern = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""");

        for (final entity in coreDir.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          for (final line in entity.readAsLinesSync()) {
            final match = importPattern.firstMatch(line);
            if (match == null) continue;
            if (match.group(1) == 'dart:io') {
              offenders.add('${entity.path}: dart:io');
            }
          }
        }

        expect(
          offenders,
          isEmpty,
          reason:
              'core must not perform I/O directly:\n${offenders.join('\n')}',
        );
      },
    );
  });

  group('test tree mirrors lib', () {
    // The refactor moved lib/ into feature and layer directories. Tests that
    // stay at the old paths still compile, but they stop being discoverable
    // next to the code they cover, and new modules tend to arrive without a
    // test directory at all. This guard makes the mirroring explicit so a
    // future move of lib/ has to move its tests in the same change.
    test('every lib directory has a matching test directory', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue);

      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! Directory) continue;

        final relative = entity.path
            .substring(libDir.path.length + 1)
            .replaceAll('\\', '/');
        if (!Directory('test/$relative').existsSync()) {
          offenders.add('lib/$relative -> missing test/$relative');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'test/ must mirror the lib/ directory tree so every module '
            'has a home for its tests. Missing directories:\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
