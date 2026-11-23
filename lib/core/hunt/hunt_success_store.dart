/// Persistence for successful hunt records.
library;

import 'dart:convert';
import '../meal/models.dart';
import '../shared/platform_stores.dart';
import 'hunt_success.dart';

/// Persists the last successful hunt for each account.
abstract class HuntSuccessStore {
  /// Loads the last successful hunt for [accountId], or null if none.
  Future<HuntSuccess?> load(AccountId accountId);

  /// Saves a successful hunt for its account, replacing any previous record.
  Future<void> save(HuntSuccess success);

  /// Clears the recorded success for [accountId] (e.g. on user dismissal).
  Future<void> remove(AccountId accountId);
}

/// PlainStore-backed implementation of [HuntSuccessStore].
class PreferencesHuntSuccessStore implements HuntSuccessStore {
  PreferencesHuntSuccessStore(this._store);

  final PlainStore _store;

  static String _key(AccountId accountId) => 'hunt.success.$accountId';

  @override
  Future<HuntSuccess?> load(AccountId accountId) async {
    final raw = await _store.readString(_key(accountId));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return HuntSuccess.fromJson(accountId, decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(HuntSuccess success) async {
    final raw = jsonEncode(success.toJson());
    await _store.writeString(_key(success.accountId), raw);
  }

  @override
  Future<void> remove(AccountId accountId) async {
    await _store.remove(_key(accountId));
  }
}
