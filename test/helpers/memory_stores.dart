/// In-memory stand-ins for the app's platform stores.
///
/// The app's stores are backed by the Android Keystore and by preferences;
/// a test needs neither. These fakes were copy-pasted into several test
/// files, and a change to the [SessionStore] interface meant changing each
/// copy — so they live here, once.
library;

import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session.dart';

/// A session store that hands out one session and remembers it.
///
/// The read has to *establish* a session, and establishing one needs
/// credentials: most tests are about what the app does with the data, not
/// about what it does without a session.
class MemorySessionStore implements SessionStore {
  StoredSession? _session;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      Credentials(studentId: accountId, password: 'not-a-real-password');

  @override
  Future<void> writeCredentials(
    AccountId accountId,
    Credentials credentials,
  ) async {}

  @override
  Future<StoredSession?> readSession(AccountId accountId) async => _session;

  @override
  Future<void> writeSession(StoredSession session) async => _session = session;

  @override
  Future<void> deleteSession(AccountId accountId) async => _session = null;

  @override
  Future<void> purge(AccountId accountId) async => _session = null;
}

/// A solver that never answers, so the login path is never taken.
class NoSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => null;
}

/// An in-memory plain store.
class MemoryPlainStore implements PlainStore {
  final Map<String, Object> values = {};

  @override
  Future<String?> readString(String key) async => values[key] as String?;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<int?> readInt(String key) async => values[key] as int?;

  @override
  Future<void> writeInt(String key, int value) async => values[key] = value;

  @override
  Future<bool?> readBool(String key) async => values[key] as bool?;

  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}

/// An in-memory credential store.
class MemorySecureStore implements SecureCredentialStore {
  final Map<String, Credentials> values = {};

  @override
  Future<Credentials?> read(AccountId accountId) async => values[accountId];

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async =>
      values[accountId] = credentials;

  @override
  Future<void> delete(AccountId accountId) async => values.remove(accountId);

  @override
  Future<List<AccountId>> listAccountIds() async =>
      values.keys.toList()..sort();
}
