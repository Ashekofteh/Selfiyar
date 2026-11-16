/// Persistence for the account list and the reminder configuration.
///
/// The contract is deliberately small and synchronous-looking, but the
/// implementations are async because the real ones touch the platform
/// keystore and the disk.
///
/// **Credentials never live here.** A [SavedAccount] holds an id, a student ID
/// and a display name — no password. The password is held by the
/// [SessionStore] in `session.dart`, encrypted at rest. Keeping them apart
/// means the account list can be stored in plain preferences without any risk,
/// and there is only one place that has to be careful.
library;

import 'account.dart';
import '../hunt/hunt_config.dart';
import '../hunt/hunt_store.dart';
import '../meal/models.dart';
import '../reminder/reminder.dart';

/// Persistence for saved accounts.
abstract class AccountStore {
  Future<List<SavedAccount>> loadAll();

  Future<void> save(SavedAccount account);

  /// Removes the account and everything belonging to it.
  ///
  /// Deleting an account must be complete: the account, its credentials, its
  /// sessions and its stored meals. A half-deleted account that still holds
  /// credentials is a privacy problem.
  Future<void> remove(AccountId accountId);
}

/// Persistence for the reminder configuration.
abstract class ReminderConfigStore {
  Future<ReminderConfig> load();

  Future<void> save(ReminderConfig config);
}

/// An in-memory account store, for tests and for the first run before the
/// platform store is wired up.
class InMemoryAccountStore implements AccountStore {
  final Map<AccountId, SavedAccount> _accounts = {};

  @override
  Future<List<SavedAccount>> loadAll() async => _accounts.values.toList();

  @override
  Future<void> save(SavedAccount account) async {
    _accounts[account.id] = account;
  }

  @override
  Future<void> remove(AccountId accountId) async {
    _accounts.remove(accountId);
  }
}

/// An in-memory reminder config store.
class InMemoryReminderConfigStore implements ReminderConfigStore {
  ReminderConfig _config = const ReminderConfig();

  @override
  Future<ReminderConfig> load() async => _config;

  @override
  Future<void> save(ReminderConfig config) async {
    _config = config;
  }
}

/// An in-memory hunt config store, one configuration per account.
class InMemoryHuntConfigStore implements HuntConfigStore {
  final Map<AccountId, HuntConfig> _configs = {};

  @override
  Future<HuntConfig?> load(AccountId accountId) async => _configs[accountId];

  @override
  Future<void> save(AccountId accountId, HuntConfig config) async {
    _configs[accountId] = config;
  }

  @override
  Future<void> remove(AccountId accountId) async {
    _configs.remove(accountId);
  }
}
