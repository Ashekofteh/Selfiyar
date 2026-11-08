/// The persistence contracts the platform layer implements.
///
/// These live in `lib/core` so the *shape* of persistence is testable on the
/// VM, and so the platform layer has nothing to decide — it only does what
/// these say.
///
/// ## What is secret and what is not
///
/// Only **credentials** are secret. The account list (student ids, aliases) and
/// the reminder configuration are not, so they are stored as ordinary
/// preferences. Putting them behind the Keystore would add cost and latency
/// without adding any protection, and would make them harder to inspect when
/// something goes wrong.
library;

import 'dart:convert';

import 'account.dart';
import 'account_store.dart';
import 'hunt_config.dart';
import 'hunt_store.dart';
import 'local_meal_store.dart';
import 'meal_invariant.dart';
import 'models.dart';
import 'reminder.dart';
import 'session.dart';
import 'time.dart';

/// A store for credentials, encrypted at rest.
///
/// The platform implementation must use the Android Keystore. A password in
/// plain SharedPreferences on a phone is a password anyone with the file can
/// read.
abstract class SecureCredentialStore {
  /// The credentials for [accountId], or null when there are none.
  Future<Credentials?> read(AccountId accountId);

  /// Stores (or replaces) the credentials for [accountId].
  Future<void> write(AccountId accountId, Credentials credentials);

  /// Removes the credentials for [accountId].
  Future<void> delete(AccountId accountId);

  /// The account ids that have credentials stored.
  Future<List<AccountId>> listAccountIds();
}

/// A store for the account list and the reminder configuration.
///
/// Not secret, so a plain key-value store is appropriate.
abstract class PlainStore {
  /// Reads a string value.
  Future<String?> readString(String key);

  /// Writes a string value. A null value removes the key.
  Future<void> writeString(String key, String? value);

  /// Reads an integer value.
  Future<int?> readInt(String key);

  /// Writes an integer value.
  Future<void> writeInt(String key, int value);

  /// Reads a boolean value.
  Future<bool?> readBool(String key);

  /// Writes a boolean value.
  Future<void> writeBool(String key, bool value);

  /// Removes a key.
  Future<void> remove(String key);

  /// Every key currently stored.
  Future<Set<String>> keys();
}

/// The keys used in the plain store.
///
/// Namespaced so a future addition cannot collide with an existing one.
abstract final class StoreKeys {
  static const accountPrefix = 'account.';
  static const reminderConfig = 'reminder.config';
  static const liveCheckEnabled = 'reminder.liveCheck';
  static const purchaseInFlight = 'purchase.inFlight';
  static const lastSyncAt = 'sync.lastAt';
  static const huntPrefix = 'hunt.';
  static const themeMode = 'settings.themeMode';
  static const basketSales = 'basket.sales';
  static const basketSaleDetails = 'basket.saleDetails';
  static const forgotReceipts = 'receipts.forgot';
  static const menuBookable = 'menus.bookable';

  /// The key holding one account's record.
  static String account(AccountId id) => '$accountPrefix$id';

  /// The key holding one account's hunt configuration.
  static String hunt(AccountId id) => '$huntPrefix$id';
}

/// An account store built on a [PlainStore].
///
/// The serialisation lives here, in pure Dart, so it can be tested without
/// Android. The platform layer only has to provide key-value storage.
class PreferencesAccountStore implements AccountStore {
  PreferencesAccountStore(this._store);

  final PlainStore _store;

  @override
  Future<List<SavedAccount>> loadAll() async {
    final out = <SavedAccount>[];
    for (final key in await _store.keys()) {
      if (!key.startsWith(StoreKeys.accountPrefix)) continue;
      final raw = await _store.readString(key);
      if (raw == null) continue;
      final account = decodeAccount(raw);
      if (account != null) out.add(account);
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  Future<void> save(SavedAccount account) async {
    await _store.writeString(
      StoreKeys.account(account.id),
      encodeAccount(account),
    );
  }

  @override
  Future<void> remove(AccountId accountId) async {
    await _store.remove(StoreKeys.account(accountId));
  }
}

/// A reminder config store built on a [PlainStore].
class PreferencesReminderConfigStore implements ReminderConfigStore {
  PreferencesReminderConfigStore(this._store);

  final PlainStore _store;

  @override
  Future<ReminderConfig> load() async {
    final raw = await _store.readString(StoreKeys.reminderConfig);
    if (raw == null) return const ReminderConfig();
    return decodeReminderConfig(raw) ?? const ReminderConfig();
  }

  @override
  Future<void> save(ReminderConfig config) async {
    await _store.writeString(StoreKeys.reminderConfig, encodeReminderConfig(config));
  }
}

/// A hunt configuration store built on a [PlainStore].
///
/// One hunt per account, so the key is account-scoped. The configuration is
/// not secret — it names dishes and halls, not credentials — so a plain store
/// is appropriate.
class PreferencesHuntConfigStore implements HuntConfigStore {
  PreferencesHuntConfigStore(this._store);

  final PlainStore _store;

  @override
  Future<HuntConfig?> load(AccountId accountId) async {
    final raw = await _store.readString(StoreKeys.hunt(accountId));
    if (raw == null) return null;
    return decodeHuntConfig(raw);
  }

  @override
  Future<void> save(AccountId accountId, HuntConfig config) async {
    await _store.writeString(
      StoreKeys.hunt(accountId),
      encodeHuntConfig(config),
    );
  }

  @override
  Future<void> remove(AccountId accountId) async {
    await _store.remove(StoreKeys.hunt(accountId));
  }
}

/// A session store whose *cookies* are kept in the plain store but whose
/// credentials go to the secure one.
///
/// The distinction matters: a session cookie is a bearer credential and must be
/// protected, but it is also large and churns, so it does not belong in the
/// same place as a long-lived password.
class PlatformSessionStore implements SessionStore {
  PlatformSessionStore({
    required this.secureStore,
    required this.plainStore,
  });

  final SecureCredentialStore secureStore;
  final PlainStore plainStore;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) =>
      secureStore.read(accountId);

  @override
  Future<void> writeCredentials(
    AccountId accountId,
    Credentials credentials,
  ) =>
      secureStore.write(accountId, credentials);

  @override
  Future<StoredSession?> readSession(AccountId accountId) async {
    final raw = await plainStore.readString('session.$accountId');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return StoredSession(
        accountId: accountId,
        cookies: (decoded['cookies'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString())),
        establishedAt:
            DateTime.parse(decoded['establishedAt'] as String).toUtc(),
      );
    } catch (_) {
      // A corrupt session is not an error worth surfacing: the manager simply
      // logs in again, which is the normal path after an app update.
      return null;
    }
  }

  @override
  Future<void> writeSession(StoredSession session) async {
    await plainStore.writeString(
      'session.${session.accountId}',
      jsonEncode({
        'cookies': session.cookies,
        'establishedAt': session.establishedAt.toIso8601String(),
      }),
    );
  }

  @override
  Future<void> deleteSession(AccountId accountId) =>
      plainStore.remove('session.$accountId');

  @override
  Future<void> purge(AccountId accountId) async {
    await deleteSession(accountId);
    await secureStore.delete(accountId);
  }
}

/// Serialises an account to a single-line JSON string.
String encodeAccount(SavedAccount account) => jsonEncode({
      'id': account.id,
      'studentId': account.studentId,
      'alias': account.alias,
      'profileName': account.profileName,
      'addedAt': account.addedAt?.toIso8601String(),
      'lastLoginAt': account.lastLoginAt?.toIso8601String(),
    });

/// Reads an account back. Returns null for anything unreadable.
SavedAccount? decodeAccount(String raw) {
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return SavedAccount(
      id: decoded['id'] as String,
      studentId: decoded['studentId'] as String,
      alias: decoded['alias'] as String?,
      profileName: decoded['profileName'] as String?,
      addedAt: _parseDate(decoded['addedAt']),
      lastLoginAt: _parseDate(decoded['lastLoginAt']),
    );
  } catch (_) {
    return null;
  }
}

/// Serialises the reminder configuration.
String encodeReminderConfig(ReminderConfig config) => jsonEncode({
      'masterEnabled': config.masterEnabled,
      'accountIds': config.accountIds.toList(),
      'lunch': _encodeSlot(config.lunch),
      'evening': _encodeSlot(config.evening),
      'nextWeekNudgeEnabled': config.nextWeekNudgeEnabled,
      'liveCheckEnabled': config.liveCheckEnabled,
      'excludedFromSlot': config.excludedFromSlot.map(
        (slot, ids) => MapEntry(slot.name, ids.toList()),
      ),
      'nudgeAccountIds': config.nudgeAccountIds?.toList(),
      'dismissedNudgeWeekSaturday': config.dismissedNudgeWeekSaturday?.toIso8601String(),
    });

/// Reads the reminder configuration back, or null when unreadable.
ReminderConfig? decodeReminderConfig(String raw) {
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return ReminderConfig(
      masterEnabled: decoded['masterEnabled'] as bool? ?? true,
      accountIds: (decoded['accountIds'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toSet(),
      lunch: _decodeSlot(decoded['lunch'], ReminderSlotConfig.lunchDefault),
      evening: _decodeSlot(decoded['evening'], ReminderSlotConfig.eveningDefault),
      nextWeekNudgeEnabled: decoded['nextWeekNudgeEnabled'] as bool? ?? true,
      liveCheckEnabled: decoded['liveCheckEnabled'] as bool? ?? false,
      excludedFromSlot: (decoded['excludedFromSlot'] as Map<String, dynamic>?)
              ?.map(
                (slot, ids) => MapEntry(
                  ReminderSlot.values.firstWhere(
                    (s) => s.name == slot,
                    orElse: () => ReminderSlot.lunch,
                  ),
                  (ids as List<dynamic>).map((e) => e.toString()).toSet(),
                ),
              ) ??
          const {},
      nudgeAccountIds: (decoded['nudgeAccountIds'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toSet(),
      dismissedNudgeWeekSaturday: decoded['dismissedNudgeWeekSaturday'] != null
          ? DateTime.tryParse(decoded['dismissedNudgeWeekSaturday'] as String)
          : null,
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _encodeSlot(ReminderSlotConfig config) => {
      'enabled': config.enabled,
      'time': '${config.time.hour}:${config.time.minute}',
      'covers': config.covers.map((s) => s.name).toList(),
    };

ReminderSlotConfig _decodeSlot(Object? raw, ReminderSlotConfig fallback) {
  if (raw is! Map<String, dynamic>) return fallback;
  final timeText = raw['time'] as String? ?? '';
  final parts = timeText.split(':');
  final hour = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
  final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
  final covers = (raw['covers'] as List<dynamic>? ?? const [])
      .map((e) => MealSlot.values.where((s) => s.name == e.toString()))
      .where((list) => list.isNotEmpty)
      .map((list) => list.first)
      .toSet();

  return ReminderSlotConfig(
    slot: fallback.slot,
    time: (hour != null && minute != null)
        ? ClockTime(hour, minute)
        : fallback.time,
    enabled: raw['enabled'] as bool? ?? fallback.enabled,
    covers: covers.isEmpty ? fallback.covers : covers,
  );
}

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// Serialises the locally cached meals.
///
/// The cache is what makes the reminders work offline, so it must survive a
/// restart. A meal that has passed is still written — the retention policy
/// prunes it — because pruning is a decision made at read time, not a reason to
/// risk losing the write.
String encodeMealList(List<StoredMeal> meals) => jsonEncode(
      meals
          .map((m) => {
                'accountId': m.accountId,
                'date': m.date.toIso8601String(),
                'slot': m.slot.name,
                'source': m.source.name,
                'capturedAt': m.capturedAt.toIso8601String(),
                'optionId': m.optionId,
                'dishName': m.dishName,
                'hallName': m.hallName,
                'priceRial': m.priceRial,
                'isConsumed': m.isConsumed,
              })
          .toList(),
    );

/// Reads the locally cached meals back, skipping anything unreadable.
List<StoredMeal> decodeMealList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];

  final out = <StoredMeal>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    try {
      out.add(StoredMeal(
        accountId: entry['accountId'] as String,
        date: DateTime.parse(entry['date'] as String).toUtc(),
        slot: MealSlot.values.firstWhere(
          (s) => s.name == entry['slot'],
          orElse: () => MealSlot.lunch,
        ),
        source: MealSource.values.firstWhere(
          (s) => s.name == entry['source'],
          orElse: () => MealSource.weeklyReservation,
        ),
        capturedAt: DateTime.parse(entry['capturedAt'] as String).toUtc(),
        optionId: entry['optionId'] as String?,
        dishName: entry['dishName'] as String?,
        hallName: entry['hallName'] as String?,
        priceRial: entry['priceRial'] as int?,
        isConsumed: entry['isConsumed'] as bool? ?? false,
      ));
    } catch (_) {
      // One unreadable entry must not lose the rest.
    }
  }
  return out;
}

/// Serialises the locally cached bookable meal menus.
String encodeMenuList(List<MealMenu> menus) => jsonEncode(
      menus
          .map((m) => {
                'date': m.date.toIso8601String(),
                'slot': m.slot.name,
                'reservable': m.reservable,
                'halls': m.halls
                    .map((h) => {
                          'id': h.id,
                          'name': h.name,
                        })
                    .toList(),
                'dishes': m.dishes
                    .map((d) => {
                          'id': d.id,
                          'name': d.name,
                          'priceRial': d.priceRial,
                        })
                    .toList(),
              })
          .toList(),
    );

/// Reads the locally cached menus back, skipping anything unreadable.
List<MealMenu> decodeMenuList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];

    final out = <MealMenu>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
    try {
      final rawDate = DateTime.parse(entry['date'] as String);
      final date = DateTime.utc(rawDate.year, rawDate.month, rawDate.day);
      final slot = MealSlot.values.firstWhere(
        (s) => s.name == entry['slot'],
        orElse: () => MealSlot.lunch,
      );
      final reservable = entry['reservable'] as bool? ?? false;
      final hallsRaw = entry['halls'] as List<dynamic>? ?? const [];
      final halls = <Hall>[];
      for (final h in hallsRaw) {
        if (h is Map<String, dynamic>) {
          halls.add(Hall(
            id: h['id'] as String,
            name: h['name'] as String? ?? '',
          ));
        }
      }
      final dishesRaw = entry['dishes'] as List<dynamic>? ?? const [];
      final dishes = <MenuOption>[];
      for (final d in dishesRaw) {
        if (d is Map<String, dynamic>) {
          dishes.add(MenuOption(
            id: d['id'] as String,
            name: d['name'] as String? ?? '',
            priceRial: d['priceRial'] as int? ?? 0,
          ));
        }
      }
      out.add(MealMenu(
        date: date,
        slot: slot,
        reservable: reservable,
        halls: halls,
        dishes: dishes,
      ));
    } catch (_) {
      // One unreadable entry must not lose the rest.
    }
  }
    return out;
  } catch (_) {
    return const [];
  }
}

