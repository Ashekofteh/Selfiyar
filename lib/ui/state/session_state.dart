/// The account and session-facing part of the app's state.
///
/// This controller owns the saved accounts, their encrypted credentials, the
/// last balance read for each, and the sync/error flags. It deliberately knows
/// nothing about meals or hunts: those are separate controllers, and the
/// composition root ([AppState]) coordinates the places where removing an
/// account has to touch more than one of them.
library;

import 'package:flutter/foundation.dart';

import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/session.dart';
import '../../core/meal/models.dart';
import '../../core/shared/platform_stores.dart';

/// Accounts, credentials, balances, and sync status.
class SessionState extends ChangeNotifier {
  SessionState({required this.accountStore, this.credentialStore});

  /// Where saved accounts are persisted.
  final AccountStore accountStore;

  /// Where credentials are persisted, encrypted. Null when the app has no
  /// secure store — in tests, or before the platform layer is wired.
  final SecureCredentialStore? credentialStore;

  List<SavedAccount> _accounts = const [];
  String? _error;
  final Map<AccountId, int> _balances = {};
  final Map<AccountId, DateTime> _balanceReadAt = {};
  final Map<AccountId, String> _syncErrors = {};
  bool _syncing = false;
  int _idCounter = 0;

  // ------------------------------------------------------------- accessors

  List<SavedAccount> get accounts => _accounts;
  String? get error => _error;

  /// The balance last read for [accountId], in Rial.
  int? balanceFor(AccountId accountId) => _balances[accountId];

  /// When [balanceFor] was last refreshed, in UTC.
  ///
  /// The booking path uses this to decide whether the figure is fresh enough
  /// to check a price against without a second portal read. A balance that is
  /// merely *known* is not enough: the cutoff is the portal's, and so is the
  /// balance.
  DateTime? balanceReadAtFor(AccountId accountId) => _balanceReadAt[accountId];

  /// The error from the last sync of [accountId], if it failed.
  String? syncErrorFor(AccountId accountId) => _syncErrors[accountId];

  /// Whether a sync is in progress.
  bool get isSyncing => _syncing;

  /// Finds the account with [accountId], if it exists.
  SavedAccount? accountFor(AccountId accountId) {
    for (final account in _accounts) {
      if (account.id == accountId) return account;
    }
    return null;
  }

  // --------------------------------------------------------------- loading

  /// Loads the persisted accounts. Safe to call more than once.
  Future<void> loadAccounts() async {
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  // --------------------------------------------------------------- accounts

  /// Adds an account, or updates the one with the same student ID.
  Future<void> upsertAccount({
    required String studentId,
    String? alias,
    String? profileName,
  }) async {
    final trimmedId = studentId.trim();
    if (trimmedId.isEmpty) {
      _error = 'شماره دانشجویی نمی‌تواند خالی باشد.';
      notifyListeners();
      return;
    }

    final existing = _accounts
        .where((a) => a.studentId == trimmedId)
        .cast<SavedAccount?>()
        .firstWhere((_) => true, orElse: () => null);

    final account = SavedAccount(
      id: existing?.id ?? _newAccountId(),
      studentId: trimmedId,
      alias: alias,
      profileName: profileName ?? existing?.profileName,
      addedAt: existing?.addedAt ?? DateTime.now(),
      lastLoginAt: existing?.lastLoginAt,
    );

    await accountStore.save(account);
    _accounts = await accountStore.loadAll();
    _error = null;
    notifyListeners();
  }

  /// Generates an id for a new account.
  ///
  /// A counter, not a timestamp: two accounts added within the same
  /// microsecond would otherwise collide, and the second would silently
  /// overwrite the first. That is not a theoretical concern — a widget test
  /// runs with a frozen clock, and two rapid taps on a real device can land in
  /// the same microsecond.
  String _newAccountId() {
    _idCounter++;
    return 'acc-${DateTime.now().microsecondsSinceEpoch}-$_idCounter';
  }

  /// Stores the credentials for an account, encrypted.
  ///
  /// The password goes only to the secure store — never to the account list
  /// and never to the plain store, where the rest of the account data lives.
  Future<void> saveCredentials(
    AccountId accountId,
    Credentials credentials,
  ) async {
    await credentialStore?.write(accountId, credentials);
    notifyListeners();
  }

  /// Whether an account has stored credentials.
  Future<bool> hasCredentials(AccountId accountId) async =>
      await credentialStore?.read(accountId) != null;

  /// Sets or clears an account's alias.
  Future<void> setAlias(AccountId accountId, String? alias) async {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return;

    final updated = _accounts[index].withAlias(alias);
    await accountStore.save(updated);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  /// Records the profile name learned from the portal.
  Future<void> setProfileName(AccountId accountId, String name) async {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return;

    final updated = _accounts[index].withProfileName(name);
    await accountStore.save(updated);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  /// Deletes an account and its stored credentials.
  ///
  /// The credentials go too: leaving a password behind for an account the
  /// user deleted would be a privacy failure. The rest of the account's data
  /// lives in other controllers and is cleaned up by [AppState.removeAccount].
  Future<void> removeAccount(AccountId accountId) async {
    await accountStore.remove(accountId);
    await credentialStore?.delete(accountId);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  // ---------------------------------------------------------- sync results

  /// Records a balance, and whether it came from the portal.
  ///
  /// Only a **portal reading** stamps [balanceReadAtFor], because the booking
  /// path treats that timestamp as proof the figure can stand in for a
  /// pre-write balance read. A local adjustment — the optimistic subtraction
  /// after a booking, or the addition after a cancel — is not a reading: it
  /// must not make an estimate look like the portal's own answer.
  void setBalance(
    AccountId accountId,
    int balanceRial, {
    bool fromPortal = true,
  }) {
    _balances[accountId] = balanceRial;
    if (fromPortal) {
      _balanceReadAt[accountId] = DateTime.now().toUtc();
    } else {
      _balanceReadAt.remove(accountId);
    }
    _syncErrors.remove(accountId);
    notifyListeners();
  }

  /// Records a failed sync.
  void setSyncError(AccountId accountId, String error) {
    _syncErrors[accountId] = error;
    notifyListeners();
  }

  /// Sets the syncing flag.
  void setSyncing(bool value) {
    _syncing = value;
    notifyListeners();
  }

  /// Reports a transient error to the user.
  void setError(String? message) {
    _error = message;
    notifyListeners();
  }
}
