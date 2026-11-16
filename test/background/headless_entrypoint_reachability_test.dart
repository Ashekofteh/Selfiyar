import 'dart:io';

import 'package:test/test.dart';

/// Guards the one thing a headless entrypoint needs that nothing else does:
/// **being in the program at all**.
///
/// The native side starts a hunt by naming a library and a function as plain
/// strings:
///
/// ```kotlin
/// DartEntrypoint(bundlePath,
///     "package:bahonar_nut/background/hunt_entrypoint.dart", "main")
/// ```
///
/// The Dart compiler cannot see a name that only exists inside a Kotlin string
/// literal. A library no Dart file imports is never compiled into the app, so
/// the call asks the VM for something that is not there — in the background, at
/// the hunt's window, where there is no screen and nobody to notice.
///
/// That is not hypothetical: the first APK built with the headless engine had
/// `DefaultSnipeEngine` in its kernel blob four times and `runHeadlessHunt`
/// zero times. The import in `main.dart` is the edge that fixes it, and this
/// test is what keeps somebody from tidying that import away as unused.
void main() {
  group('headless hunt entrypoint reachability', () {
    const entrypointPath = 'lib/background/hunt_entrypoint.dart';

    test('lib/background/hunt_entrypoint.dart exists', () {
      expect(File(entrypointPath).existsSync(), isTrue);
    });

    test('main.dart reaches the entrypoint through imports', () {
      final entrypoint = _normalise(File(entrypointPath).absolute.path);
      final reached = _reachableFrom('lib/main.dart');

      expect(
        reached,
        contains(entrypoint),
        reason:
            'lib/main.dart must transitively import $entrypointPath. '
            'The native side names this library as a string; without a Dart '
            'import the compiler never sees it, and a background hunt fails '
            'with "library not found" at the moment it is supposed to run.',
      );
    });

    test('the entrypoint function is marked as a VM entry point', () {
      // An import puts the library in the program; the annotation is what
      // keeps the function — and everything it reaches — alive through
      // tree-shaking in a release build, where nothing else calls it.
      final source = File(entrypointPath).readAsStringSync();
      final annotated = RegExp(
        r"@pragma\(\s*'vm:entry-point'\s*\)\s*\n\s*void\s+main\s*\(",
      );

      expect(
        annotated.hasMatch(source),
        isTrue,
        reason:
            'main() in $entrypointPath must be annotated '
            "@pragma('vm:entry-point'), or a release build tree-shakes it.",
      );
    });

    test('the native side names the same library and function', () {
      // The two halves are joined by a string, so nothing type-checks them
      // against each other. This is the only place they are compared.
      const enginePath =
          'android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/BackgroundHuntEngine.kt';
      final engine = File(enginePath);
      if (!engine.existsSync()) return; // Not an Android checkout.

      final source = engine.readAsStringSync();
      expect(
        source,
        contains('package:bahonar_nut/background/hunt_entrypoint.dart'),
        reason: 'The Kotlin entrypoint library must match $entrypointPath.',
      );
    });
  });

  group('headless reminder sync entrypoint reachability', () {
    const entrypointPath = 'lib/background/reminder_entrypoint.dart';

    test('lib/background/reminder_entrypoint.dart exists', () {
      expect(File(entrypointPath).existsSync(), isTrue);
    });

    test('main.dart reaches the entrypoint through imports', () {
      final entrypoint = _normalise(File(entrypointPath).absolute.path);
      final reached = _reachableFrom('lib/main.dart');

      expect(
        reached,
        contains(entrypoint),
        reason:
            'lib/main.dart must transitively import $entrypointPath. '
            'The native engine names this library as a string; without a Dart '
            'import the release build tree-shakes it, and a closed-app reminder '
            'sync fails with "library not found".',
      );
    });

    test('the native side names the same library and function', () {
      const enginePath =
          'android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/ReminderSyncEngine.kt';
      final engine = File(enginePath);
      if (!engine.existsSync()) return; // Not an Android checkout.

      final source = engine.readAsStringSync();
      expect(
        source,
        contains('package:bahonar_nut/background/reminder_entrypoint.dart'),
        reason: 'The Kotlin entrypoint library must match $entrypointPath.',
      );
      expect(
        source,
        contains('ENTRYPOINT_FUNCTION = "main"'),
        reason: 'The native side must call the entrypoint\'s main().',
      );
    });

    test('the headless entrypoint does not post the reminder itself', () {
      // The native delivery path owns the notification, the pending record
      // and the re-arm. A second poster here would double-notify.
      final source = File(entrypointPath).readAsStringSync();
      expect(source, isNot(contains('postNotification')));
      expect(source, contains('notifyReminderSyncFinished'));
    });
  });
}

/// Every `lib/` file reachable from [startPath] by following imports.
///
/// Both forms are followed: relative imports, and `package:bahonar_nut/…`
/// imports, which resolve back into `lib/`. A path that does not exist is
/// skipped rather than failing — this walk is about reachability, and the
/// compiler is the authority on whether a path is valid.
Set<String> _reachableFrom(String startPath) {
  final visited = <String>{};
  final queue = <String>[_normalise(File(startPath).absolute.path)];

  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    if (!visited.add(path)) continue;

    final file = File(path);
    if (!file.existsSync()) continue;

    for (final uri in _importsOf(file)) {
      final resolved = _resolve(uri, path);
      if (resolved != null && !visited.contains(resolved)) {
        queue.add(resolved);
      }
    }
  }

  return visited;
}

/// The import URIs a file names.
Iterable<String> _importsOf(File file) {
  final pattern = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""");
  final uris = <String>[];

  for (final line in file.readAsLinesSync()) {
    final match = pattern.firstMatch(line);
    if (match != null) uris.add(match.group(1)!);
  }

  return uris;
}

/// Resolves an import [uri] relative to the file that contains it.
///
/// Returns null for anything that does not live under `lib/` — `dart:`,
/// `package:flutter`, and other packages are not this walk's business.
String? _resolve(String uri, String fromPath) {
  if (uri.startsWith('dart:')) return null;

  const selfPackage = 'package:bahonar_nut/';
  String target;
  if (uri.startsWith(selfPackage)) {
    target = 'lib/${uri.substring(selfPackage.length)}';
  } else if (uri.startsWith('package:')) {
    return null;
  } else {
    final dir = File(fromPath).parent.path;
    target = '$dir/$uri';
  }

  return _normalise(File(target).absolute.path);
}

/// A stable, separator-insensitive form of [path].
String _normalise(String path) => path.replaceAll('\\', '/');
