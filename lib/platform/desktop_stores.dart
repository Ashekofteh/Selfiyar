/// Desktop implementations of [PlainStore] and [SecureCredentialStore].
///
/// Backed by persistent files stored in the OS-appropriate user application
/// data directory (AppData on Windows, Application Support on macOS, XDG on Linux).
library;

import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import '../core/platform_stores.dart';
import '../core/session.dart';

/// Returns the OS-appropriate storage directory for desktop platforms.
Directory defaultDesktopStorageDirectory() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return Directory('$appData${Platform.pathSeparator}BahonarNut');
    }
  } else if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(
        '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}BahonarNut',
      );
    }
  } else if (Platform.isLinux) {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'];
    final base = xdg ?? (home != null ? '$home/.local/share' : null);
    if (base != null && base.isNotEmpty) {
      return Directory('$base${Platform.pathSeparator}bahonar_nut');
    }
  } else if (Platform.isIOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(
        '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}BahonarNut',
      );
    }
  }

  // Fallback for tests or sandbox environments
  return Directory('.bahonar_nut');
}

/// A [PlainStore] backed by a JSON file on desktop systems.
class FilePlainStore implements PlainStore {
  FilePlainStore({Directory? directory})
      : _dir = directory ?? defaultDesktopStorageDirectory();

  final Directory _dir;
  Map<String, dynamic>? _cache;
  File? _file;

  File get _storeFile =>
      _file ??= File('${_dir.path}${Platform.pathSeparator}preferences.json');

  Future<Map<String, dynamic>> _ensureLoaded() async {
    if (_cache != null) return _cache!;

    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }

    final file = _storeFile;
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          _cache = Map<String, dynamic>.from(decoded);
          return _cache!;
        }
      } catch (_) {
        // Corrupt file, fall back to empty map
      }
    }

    _cache = <String, dynamic>{};
    return _cache!;
  }

  Future<void> _persist() async {
    final map = await _ensureLoaded();
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final file = _storeFile;
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(jsonEncode(map), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  @override
  Future<String?> readString(String key) async {
    final map = await _ensureLoaded();
    final val = map[key];
    return val is String ? val : null;
  }

  @override
  Future<void> writeString(String key, String? value) async {
    final map = await _ensureLoaded();
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
    await _persist();
  }

  @override
  Future<int?> readInt(String key) async {
    final map = await _ensureLoaded();
    final val = map[key];
    return val is int ? val : null;
  }

  @override
  Future<void> writeInt(String key, int value) async {
    final map = await _ensureLoaded();
    map[key] = value;
    await _persist();
  }

  @override
  Future<bool?> readBool(String key) async {
    final map = await _ensureLoaded();
    final val = map[key];
    return val is bool ? val : null;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    final map = await _ensureLoaded();
    map[key] = value;
    await _persist();
  }

  @override
  Future<void> remove(String key) async {
    final map = await _ensureLoaded();
    map.remove(key);
    await _persist();
  }

  @override
  Future<Set<String>> keys() async {
    final map = await _ensureLoaded();
    return map.keys.toSet();
  }
}

/// A [SecureCredentialStore] backed by a protected credentials file on desktop.
class FileSecureStore implements SecureCredentialStore {
  FileSecureStore({Directory? directory})
      : _dir = directory ?? defaultDesktopStorageDirectory();

  final Directory _dir;
  Map<AccountId, Credentials>? _cache;
  File? _file;

  File get _storeFile =>
      _file ??= File('${_dir.path}${Platform.pathSeparator}credentials.dat');

  Future<Map<AccountId, Credentials>> _ensureLoaded() async {
    if (_cache != null) return _cache!;

    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }

    final file = _storeFile;
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final jsonStr = utf8.decode(base64.decode(raw.trim()));
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          final result = <AccountId, Credentials>{};
          for (final entry in decoded.entries) {
            final val = entry.value;
            if (val is Map<String, dynamic>) {
              final studentId = val['studentId'];
              final password = val['password'];
              if (studentId is String && password is String) {
                result[entry.key] = Credentials(
                  studentId: studentId,
                  password: password,
                );
              }
            }
          }
          _cache = result;
          return _cache!;
        }
      } catch (_) {
        // Corrupt file, fall back to empty cache
      }
    }

    _cache = <AccountId, Credentials>{};
    return _cache!;
  }

  Future<void> _persist() async {
    final map = await _ensureLoaded();
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final file = _storeFile;
    final tempFile = File('${file.path}.tmp');

    final jsonMap = <String, dynamic>{};
    for (final entry in map.entries) {
      jsonMap[entry.key] = {
        'studentId': entry.value.studentId,
        'password': entry.value.password,
      };
    }

    final encoded = base64.encode(utf8.encode(jsonEncode(jsonMap)));
    await tempFile.writeAsString(encoded, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  @override
  Future<Credentials?> read(AccountId accountId) async {
    final map = await _ensureLoaded();
    return map[accountId];
  }

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async {
    final map = await _ensureLoaded();
    map[accountId] = credentials;
    await _persist();
  }

  @override
  Future<void> delete(AccountId accountId) async {
    final map = await _ensureLoaded();
    map.remove(accountId);
    await _persist();
  }

  @override
  Future<List<AccountId>> listAccountIds() async {
    final map = await _ensureLoaded();
    return map.keys.toList();
  }

  Map<String, String>? _stringCache;
  File? _vaultFile;

  File get _vaultStoreFile =>
      _vaultFile ??= File('${_dir.path}${Platform.pathSeparator}vault.dat');

  Future<Map<String, String>> _ensureVaultLoaded() async {
    if (_stringCache != null) return _stringCache!;
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final file = _vaultStoreFile;
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final jsonStr = utf8.decode(base64.decode(raw.trim()));
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          _stringCache = decoded.map((k, v) => MapEntry(k, v.toString()));
          return _stringCache!;
        }
      } catch (_) {}
    }
    _stringCache = <String, String>{};
    return _stringCache!;
  }

  Future<void> _persistVault() async {
    final map = await _ensureVaultLoaded();
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final file = _vaultStoreFile;
    final tempFile = File('${file.path}.tmp');
    final encoded = base64.encode(utf8.encode(jsonEncode(map)));
    await tempFile.writeAsString(encoded, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<String?> readString(String key) async {
    final map = await _ensureVaultLoaded();
    return map[key];
  }

  Future<void> writeString(String key, String value) async {
    final map = await _ensureVaultLoaded();
    map[key] = value;
    await _persistVault();
  }

  Future<void> deleteString(String key) async {
    final map = await _ensureVaultLoaded();
    map.remove(key);
    await _persistVault();
  }
}
