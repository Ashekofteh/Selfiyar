import 'package:bahonar_nut/core/auth/account.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

/// An in-memory [PlainStore], so the storage format is tested without Android.
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

void main() {
  group('account serialisation', () {
    test('round-trips every field', () {
      final account = SavedAccount(
        id: 'a1',
        studentId: '400123456',
        alias: 'برادر',
        profileName: 'رضا شريفي',
        addedAt: DateTime.utc(2026, 10, 19, 12),
        lastLoginAt: DateTime.utc(2026, 10, 19, 13),
      );

      final decoded = decodeAccount(encodeAccount(account))!;
      expect(decoded.id, 'a1');
      expect(decoded.studentId, '400123456');
      expect(decoded.alias, 'برادر');
      expect(decoded.profileName, 'رضا شريفي');
      expect(decoded.addedAt, account.addedAt);
      expect(decoded.lastLoginAt, account.lastLoginAt);
    });

    test('survives a null alias and null dates', () {
      final account = SavedAccount(id: 'a1', studentId: '400123456');
      final decoded = decodeAccount(encodeAccount(account))!;
      expect(decoded.alias, isNull);
      expect(decoded.profileName, isNull);
      expect(decoded.addedAt, isNull);
    });

    test('returns null for unreadable data rather than throwing', () {
      expect(decodeAccount('not json'), isNull);
      expect(decodeAccount('{"id": 5}'), isNull);
    });
  });

  group('the account store on a plain store', () {
    test('saves and loads accounts', () async {
      final plain = MemoryPlainStore();
      final store = PreferencesAccountStore(plain);

      await store.save(const SavedAccount(id: 'a1', studentId: '400123456'));
      await store.save(const SavedAccount(id: 'a2', studentId: '401157013'));

      final loaded = await store.loadAll();
      expect(loaded, hasLength(2));
      expect(loaded.map((a) => a.id), containsAll(['a1', 'a2']));
    });

    test('removing an account takes it out', () async {
      final plain = MemoryPlainStore();
      final store = PreferencesAccountStore(plain);

      await store.save(const SavedAccount(id: 'a1', studentId: '400123456'));
      await store.remove('a1');
      expect(await store.loadAll(), isEmpty);
    });

    test('leaves other keys alone', () async {
      final plain = MemoryPlainStore();
      final store = PreferencesAccountStore(plain);
      await plain.writeString('reminder.config', '{}');

      await store.save(const SavedAccount(id: 'a1', studentId: '400123456'));
      expect(await plain.readString('reminder.config'), '{}');
    });
  });

  group('reminder config serialisation', () {
    test('round-trips the whole configuration', () {
      const config = ReminderConfig(
        masterEnabled: false,
        accountIds: {'a1', 'a2'},
        lunch: ReminderSlotConfig(
          slot: ReminderSlot.lunch,
          time: ClockTime(11, 15),
          enabled: false,
          covers: {MealSlot.lunch},
        ),
        evening: ReminderSlotConfig(
          slot: ReminderSlot.evening,
          time: ClockTime(17, 45),
          covers: {MealSlot.dinner, MealSlot.breakfast},
        ),
        nextWeekNudgeEnabled: false,
        liveCheckEnabled: true,
      );

      final decoded = decodeReminderConfig(encodeReminderConfig(config))!;
      expect(decoded.masterEnabled, isFalse);
      expect(decoded.accountIds, {'a1', 'a2'});
      expect(decoded.lunch.time.hour, 11);
      expect(decoded.lunch.time.minute, 15);
      expect(decoded.lunch.enabled, isFalse);
      expect(decoded.evening.time.hour, 17);
      expect(decoded.evening.time.minute, 45);
      expect(decoded.evening.covers, {MealSlot.dinner, MealSlot.breakfast});
      expect(decoded.nextWeekNudgeEnabled, isFalse);
      expect(decoded.liveCheckEnabled, isTrue);
    });

    test('the default configuration round-trips', () {
      const config = ReminderConfig();
      final decoded = decodeReminderConfig(encodeReminderConfig(config))!;
      expect(decoded.masterEnabled, config.masterEnabled);
      expect(decoded.lunch.time, config.lunch.time);
      expect(decoded.evening.time, config.evening.time);
      expect(decoded.liveCheckEnabled, isFalse);
    });

    test('the store persists and reloads', () async {
      final plain = MemoryPlainStore();
      final store = PreferencesReminderConfigStore(plain);

      expect(
        (await store.load()).masterEnabled,
        isTrue,
        reason: 'a fresh install gets the defaults',
      );

      await store.save(const ReminderConfig(masterEnabled: false));
      expect((await store.load()).masterEnabled, isFalse);
    });
  });

  group('the session store', () {
    test(
      'keeps credentials in the secure store and cookies in the plain one',
      () async {
        final secure = MemorySecureStore();
        final plain = MemoryPlainStore();
        final store = PlatformSessionStore(
          secureStore: secure,
          plainStore: plain,
        );

        await store.writeCredentials(
          'a1',
          const Credentials(studentId: '400123456', password: 'secret'),
        );
        await store.writeSession(
          StoredSession(
            accountId: 'a1',
            cookies: const {'ASP.NET_SessionId': 'abc'},
            establishedAt: DateTime.utc(2026, 10, 19),
          ),
        );

        // The password is in the secure store, never the plain one.
        expect((await secure.read('a1'))!.password, 'secret');
        for (final value in plain.values.values) {
          expect(value.toString(), isNot(contains('secret')));
        }

        // The session reads back.
        final session = await store.readSession('a1');
        expect(session!.cookies['ASP.NET_SessionId'], 'abc');
        expect(session.establishedAt, DateTime.utc(2026, 10, 19));
      },
    );

    test('purge removes both the session and the credentials', () async {
      final secure = MemorySecureStore();
      final plain = MemoryPlainStore();
      final store = PlatformSessionStore(
        secureStore: secure,
        plainStore: plain,
      );

      await store.writeCredentials(
        'a1',
        const Credentials(studentId: 'x', password: 'y'),
      );
      await store.writeSession(
        StoredSession(
          accountId: 'a1',
          cookies: const {},
          establishedAt: DateTime.utc(2026, 10, 19),
        ),
      );

      await store.purge('a1');
      expect(await secure.read('a1'), isNull);
      expect(await store.readSession('a1'), isNull);
    });

    test('a corrupt session reads as null rather than throwing', () async {
      final plain = MemoryPlainStore();
      final store = PlatformSessionStore(
        secureStore: MemorySecureStore(),
        plainStore: plain,
      );
      await plain.writeString('session.a1', 'garbage');
      expect(await store.readSession('a1'), isNull);
    });
  });
}
