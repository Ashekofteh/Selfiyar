library;

import 'dart:convert';

/// Application state, held in one place and shared by the screens.
///
/// Deliberately a plain [ChangeNotifier] rather than a state-management
/// package: the app has one store, and a framework would be more moving parts
/// than the problem needs. The domain logic lives in `lib/core` and is unit
/// tested there; this class only holds the results and forwards intent.

import 'package:flutter/material.dart';
import '../core/bank_card.dart';
import '../core/bank_card_store.dart';

import '../core/account.dart';
import '../core/account_store.dart';
import '../core/hunt_config.dart';
import '../core/hunt_schedule.dart';
import '../core/hunt_store.dart';
import '../core/local_meal_store.dart';
import '../core/local_menu_store.dart';
import '../core/models.dart';
import '../core/platform_stores.dart';
import '../core/portal.dart';
import '../core/reminder.dart';
import '../core/session.dart';
import '../core/spend_summary.dart';
import '../core/persian.dart';
import '../core/time.dart';

/// The app's shared state.
class AppState extends ChangeNotifier {
  AppState({
    required this.accountStore,
    required this.reminderConfigStore,
    this.huntConfigStore,
    this.credentialStore,
    this.bankCardStore,
    this.plainStore,
    this.clock,
    LocalMealStore? mealStore,
    LocalMenuStore? menuStore,
    this._transactions = const [],
    this._themeMode = ThemeMode.system,
  })  : mealStore = mealStore ?? LocalMealStore(),
        menuStore = menuStore ?? LocalMenuStore() {
    _normalizeTransactions();
  }

  /// Where saved accounts are persisted.
  final AccountStore accountStore;

  /// Where the reminder configuration is persisted.
  final ReminderConfigStore reminderConfigStore;

  /// Where the hunt configuration is persisted.
  ///
  /// Null when the app has no plain store for it — in tests, or before the
  /// platform layer is wired. A hunt then simply does not persist.
  final HuntConfigStore? huntConfigStore;

  /// Where credentials are persisted, encrypted. Null when the app has no
  /// secure store — in tests, or before the platform layer is wired.
  final SecureCredentialStore? credentialStore;
  final BankCardStore? bankCardStore;
  final PlainStore? plainStore;
  final ServerClock? clock;

  ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;

  /// Changes the application theme mode and persists it.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final store = plainStore;
    if (store != null) {
      final name = switch (mode) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      };
      await store.writeString(StoreKeys.themeMode, name);
    }
  }

  bool _hasAvailableUpdate = false;
  bool get hasAvailableUpdate => _hasAvailableUpdate;

  void setHasAvailableUpdate(bool value) {
    if (_hasAvailableUpdate != value) {
      _hasAvailableUpdate = value;
      notifyListeners();
    }
  }

  /// The local mirror of what the student holds. The reminders read from here,
  /// so they work offline.
  ///
  /// **The same instance the sync writes and the reminders read.** It is
  /// injected rather than created here, so there is exactly one mirror in the
  /// app: three separate ones meant the reservations screen and the digest
  /// looked at a store nothing ever filled.
  final LocalMealStore mealStore;

  /// The local persistent mirror of weekly bookable menus.
  final LocalMenuStore menuStore;

  bool _isOffline = false;
  bool get isOffline => _isOffline;
  bool get isOnline => !_isOffline;

  void setOffline(bool offline) {
    if (_isOffline != offline) {
      _isOffline = offline;
      notifyListeners();
    }
  }

  /// Notifies screens that cached menus have changed.
  void menusChanged() {
    notifyListeners();
  }

  List<SavedAccount> _accounts = const [];
  ReminderConfig _reminderConfig = const ReminderConfig();
  List<Transaction> _transactions = const [];

  /// The hunt configuration, per account.
  final Map<AccountId, HuntConfig> _huntConfigs = {};

  /// The account whose hunt the screen is editing.
  AccountId? _activeHuntAccount;

  /// Whether a hunt is running.
  bool _huntRunning = false;

  /// The last pre-flight verdict, as the user-facing text.
  String? _huntPreflightSummary;
  String? _huntPreflightRefusal;

  /// Why the hunt could not be switched **on**, when it could not.
  ///
  /// Separate from [huntPreflightRefusal] because it is a different moment:
  /// the pre-flight refusal is the answer to "start the hunt now", while this
  /// is the answer to "let the hunt start by itself later". A hunt can be
  /// refused one and allowed the other — a window that has already closed
  /// cannot be armed, but a manual start inside a window the student is
  /// looking at is fine.
  String? _huntEnableRefusal;

  /// The hunt's schedule, per account.
  ///
  /// What the wake-up was armed for, and whether it was armed at all. The
  /// screen shows it, because the card claims the hunt starts by itself — and
  /// a claim without a time is a claim the student cannot check.
  final Map<AccountId, HuntScheduleResult> _huntSchedules = {};

  /// The dashboard's filter. Multi-select on both dimensions.
  SpendFilter _spendFilter = const SpendFilter();

  bool _loaded = false;
  String? _error;

  /// The balance per account, in Rial, as last read from the portal.
  final Map<AccountId, int> _balances = {};

  /// The result of the last sync, per account.
  final Map<AccountId, String> _syncErrors = {};

  bool _syncing = false;

  // ------------------------------------------------------------- accessors

  bool get isLoaded => _loaded;
  String? get error => _error;

  List<SavedAccount> get accounts => _accounts;
  ReminderConfig get reminderConfig => _reminderConfig;
  SpendFilter get spendFilter => _spendFilter;

  /// The account whose hunt the screen is editing.
  AccountId? get activeHuntAccount => _activeHuntAccount;

  /// The configuration of the account's hunt, or null when it has none.
  HuntConfig? get activeHuntConfig =>
      _activeHuntAccount == null ? null : _huntConfigs[_activeHuntAccount];

  /// The configuration of a named account's hunt, or null when it has none.
  ///
  /// Needed by the path that starts a hunt the **platform** asked for: the
  /// request names the account, and the account's configuration is where its
  /// dishes, halls and rate live.
  HuntConfig? huntConfigFor(AccountId accountId) => _huntConfigs[accountId];

  /// The last pre-flight verdict: what the hunt would buy, when it is ready.
  String? get huntPreflightSummary => _huntPreflightSummary;

  /// Why the hunt was refused, when it was.
  String? get huntPreflightRefusal => _huntPreflightRefusal;

  /// Why the hunt could not be switched on, when it could not.
  String? get huntEnableRefusal => _huntEnableRefusal;

  /// Records why the hunt could not be switched on, or clears it.
  void setHuntEnableRefusal(String? refusal) {
    _huntEnableRefusal = refusal;
    notifyListeners();
  }

  /// Whether a hunt is running.
  bool get huntRunning => _huntRunning;

  /// The schedule of the account's hunt, when there is one.
  ///
  /// Null when the account has no hunt configuration, or when the schedule
  /// has not been worked out yet.
  HuntScheduleResult? huntScheduleFor(AccountId accountId) =>
      _huntSchedules[accountId];

  /// Records the schedule that was armed for an account.
  void setHuntSchedule(AccountId accountId, HuntScheduleResult result) {
    _huntSchedules[accountId] = result;
    notifyListeners();
  }

  /// The transactions the dashboard is computed from.
  List<Transaction> get transactions => _transactions;

  SpendSummary? _cachedSpendSummary;

  /// The computed spend summary, honouring the current filter.
  SpendSummary get spendSummary {
    if (_cachedSpendSummary != null) return _cachedSpendSummary!;

    // Resolve filter's accountIds to include both id and studentId for all selected accounts,
    // ensuring robust matching regardless of transaction ID representation.
    final effectiveAccountIds = <AccountId>{};
    for (final id in _spendFilter.accountIds) {
      effectiveAccountIds.add(id);
      final acc = accountFor(id);
      if (acc != null) {
        effectiveAccountIds.add(acc.studentId);
      }
      for (final a in _accounts) {
        if (a.studentId == id) {
          effectiveAccountIds.add(a.id);
        }
      }
    }

    final effectiveFilter = effectiveAccountIds.isEmpty
        ? _spendFilter
        : _spendFilter.copyWith(accountIds: effectiveAccountIds);

    return _cachedSpendSummary = summarise(
      transactions: _transactions,
      filter: effectiveFilter,
    );
  }

  /// The accounts selected in the dashboard's account filter.
  Set<AccountId> get selectedAccountIds => _spendFilter.accountIds;

  /// The meal slots selected in the dashboard's slot filter.
  Set<MealSlot> get selectedSlots => _spendFilter.slots;

  /// The meals held for one account, newest first.
  List<StoredMeal> mealsFor(AccountId accountId) =>
      mealStore.forAccount(accountId);

  /// Finds the account with [accountId], if it exists.
  SavedAccount? accountFor(AccountId accountId) {
    for (final account in _accounts) {
      if (account.id == accountId) return account;
    }
    return null;
  }


  List<SavedBankCard> _savedBankCards = const [];

  /// The list of saved bank cards, newest first.
  List<SavedBankCard> get savedBankCards => List.unmodifiable(_savedBankCards);

  /// Saves or updates a bank card and updates state.
  Future<void> saveBankCard(SavedBankCard card) async {
    await bankCardStore?.saveCard(card);
    if (bankCardStore != null) {
      _savedBankCards = await bankCardStore!.loadCards();
    } else {
      final list = _savedBankCards.where((c) => c.cleanPan != card.cleanPan).toList();
      list.insert(0, card);
      _savedBankCards = list;
    }
    notifyListeners();
  }

  /// Removes a saved bank card by id.
  Future<void> deleteBankCard(String id) async {
    await bankCardStore?.deleteCard(id);
    if (bankCardStore != null) {
      _savedBankCards = await bankCardStore!.loadCards();
    } else {
      _savedBankCards = _savedBankCards.where((c) => c.id != id).toList();
    }
    notifyListeners();
  }

  // --------------------------------------------------------------- loading

  /// Loads the persisted state. Safe to call more than once.
  Future<void> load() async {
    _accounts = await accountStore.loadAll();
    _normalizeTransactions();
    _reminderConfig = await reminderConfigStore.load();
    await _loadHuntConfigs();
    await _loadBasketSales();
    _pruneBasketSales();
    await _loadForgotReceipts();
    if (bankCardStore != null) {
      _savedBankCards = await bankCardStore!.loadCards();
    }
    final store = plainStore;
    if (store != null) {
      final rawTx = await store.readString(StoreKeys.transactions);
      if (rawTx != null && rawTx.isNotEmpty) {
        final decoded = decodeTransactionList(rawTx);
        final now = clock?.portalTodayUtc ?? DateTime.now().toUtc();
        final pruned = pruneTransactions(decoded, now);
        if (_transactions.isEmpty) {
          _transactions = pruned;
        } else {
          final existingKeys = {
            for (final t in _transactions)
              '${t.accountId}|${t.date}|${t.slot?.name}|${t.type}|${t.foodName}|${t.amountRial}',
          };
          final toAdd = [
            for (final t in pruned)
              if (!existingKeys.contains(
                  '${t.accountId}|${t.date}|${t.slot?.name}|${t.type}|${t.foodName}|${t.amountRial}'))
                t,
          ];
          _transactions = [..._transactions, ...toAdd];
        }
        _normalizeTransactions();
      }
      final savedMode = await store.readString(StoreKeys.themeMode);
      if (savedMode == 'dark') {
        _themeMode = ThemeMode.dark;
      } else if (savedMode == 'light') {
        _themeMode = ThemeMode.light;
      } else if (savedMode == 'system') {
        _themeMode = ThemeMode.system;
      }
    }
    _loaded = true;
    notifyListeners();
    // The configuration is only readable once it has been loaded, so anything
    // derived from it — the reminder alarms — has to wait for this.
    //
    // Arming before the load would arm the *default* configuration, which
    // names no accounts, so no alarm would be set at all. The failure is
    // silent: the app looks fine and the reminders simply never fire.
    onLoaded?.call();
  }

  /// Called when the persisted state has finished loading.
  ///
  /// The shell uses this to arm the reminder alarms, which depend on the
  /// configuration that only exists after the load.
  ///
  /// The callback is invoked on **every** load, not once. A one-shot
  /// notification would be missed whenever the load finishes before the
  /// subscriber exists — which is the normal cold-start order, because the
  /// app root calls `load()` without awaiting it and the shell is built in
  /// the meantime. The subscriber therefore checks [isLoaded] as well, and
  /// this callback covers the other order.
  void Function()? onLoaded;

  /// Loads each account's hunt configuration.
  Future<void> _loadHuntConfigs() async {
    final store = huntConfigStore;
    if (store == null) return;

    for (final account in _accounts) {
      final config = await store.load(account.id);
      if (config != null) _huntConfigs[account.id] = config;
    }
  }

  /// Reloads all hunt configurations from persistent storage.
  ///
  /// Useful when resuming from background or after a headless hunt has executed.
  Future<void> reloadHuntConfigs() async {
    final store = huntConfigStore;
    if (store == null) return;

    var changed = false;
    for (final account in _accounts) {
      final config = await store.load(account.id);
      if (config != null) {
        final existing = _huntConfigs[account.id];
        if (existing == null ||
            existing.enabled != config.enabled ||
            existing.requestBudget != config.requestBudget) {
          _huntConfigs[account.id] = config;
          changed = true;
        }
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// Reloads the hunt configuration for a specific account.
  Future<void> reloadHuntConfig(AccountId accountId) async {
    final store = huntConfigStore;
    if (store == null) return;

    final config = await store.load(accountId);
    if (config != null) {
      _huntConfigs[accountId] = config;
      notifyListeners();
    }
  }

  Transaction _normalizeTransaction(Transaction t, {AccountId? fallbackAccountId}) {
    if (_accounts.any((a) => a.id == t.accountId)) {
      return t;
    }
    for (final a in _accounts) {
      if (a.studentId == t.accountId) {
        return Transaction(
          accountId: a.id,
          type: t.type,
          foodName: t.foodName,
          slot: t.slot,
          weekday: t.weekday,
          date: t.date,
          count: t.count,
          amountRial: t.amountRial,
        );
      }
    }
    if (fallbackAccountId != null) {
      return Transaction(
        accountId: fallbackAccountId,
        type: t.type,
        foodName: t.foodName,
        slot: t.slot,
        weekday: t.weekday,
        date: t.date,
        count: t.count,
        amountRial: t.amountRial,
      );
    }
    return t;
  }

  void _normalizeTransactions() {
    if (_transactions.isEmpty || _accounts.isEmpty) return;
    var changed = false;
    final updated = <Transaction>[];
    for (final t in _transactions) {
      final normalized = _normalizeTransaction(t);
      if (normalized.accountId != t.accountId) {
        changed = true;
      }
      updated.add(normalized);
    }
    if (changed) {
      _transactions = updated;
      _cachedSpendSummary = null;
    }
  }

  /// Prunes transactions older than [retentionDays] (default 28 days / 4 weeks).
  static List<Transaction> pruneTransactions(
    List<Transaction> transactions,
    DateTime now, {
    int retentionDays = 28,
  }) {
    final cutoff = DateTime.utc(now.year, now.month, now.day)
        .subtract(Duration(days: retentionDays));
    return transactions.where((t) {
      final d = parseJalaliDate(t.date);
      if (d == null) return true;
      final civil = DateTime.utc(d.year, d.month, d.day);
      return !civil.isBefore(cutoff);
    }).toList();
  }

  Future<void> _persistTransactions() async {
    final store = plainStore;
    if (store == null) return;
    try {
      await store.writeString(
        StoreKeys.transactions,
        encodeTransactionList(_transactions),
      );
    } catch (_) {}
  }

  /// Replaces the transaction history, e.g. after a live read.
  void setTransactions(List<Transaction> transactions) {
    final now = clock?.portalTodayUtc ?? DateTime.now().toUtc();
    _transactions = pruneTransactions([
      for (final t in transactions) _normalizeTransaction(t),
    ], now);
    _cachedSpendSummary = null;
    notifyListeners();
    _persistTransactions();
  }

  /// Updates the transactions for a single account, preserving other accounts' transactions.
  void updateTransactionsForAccount(AccountId accountId, List<Transaction> accountTransactions) {
    final acc = accountFor(accountId);
    final studentId = acc?.studentId;

    final normalized = [
      for (final t in accountTransactions)
        _normalizeTransaction(t, fallbackAccountId: accountId),
    ];

    final remaining = _transactions.where((t) {
      if (t.accountId == accountId) return false;
      if (studentId != null && t.accountId == studentId) return false;
      return true;
    }).toList();

    final now = clock?.portalTodayUtc ?? DateTime.now().toUtc();
    _transactions = pruneTransactions([...remaining, ...normalized], now);
    _cachedSpendSummary = null;
    notifyListeners();
    _persistTransactions();
  }

  /// Active Food Basket sale listings, keyed by `"$accountId|${date.year}-${date.month}-${date.day}|${slot.name}"`.
  final Set<String> _basketSales = {};
  final Map<String, ({String dishName, int priceRial})> _basketSaleDetails = {};

  Set<String> get basketSales => Set.unmodifiable(_basketSales);

  ({String dishName, int priceRial})? basketSaleDetailsFor(String key) =>
      _basketSaleDetails[key];

  void Function()? onBasketSalesChanged;
  void Function(String key, AccountId accountId, DateTime date, MealSlot slot,
      String dishName, int priceRial)? onBasketMealSold;

  static String _basketSaleKey(AccountId accountId, DateTime date, MealSlot slot) =>
      '$accountId|${date.year}-${date.month}-${date.day}|${slot.name}';

  bool isListedInBasket(AccountId accountId, DateTime date, MealSlot slot) {
    return _basketSales.contains(_basketSaleKey(accountId, date, slot));
  }

  void markListedInBasket(
    AccountId accountId,
    DateTime date,
    MealSlot slot, {
    String? dishName,
    int? priceRial,
  }) {
    final key = _basketSaleKey(accountId, date, slot);
    _basketSales.add(key);

    var resolvedDishName = dishName;
    var resolvedPriceRial = priceRial;
    if (resolvedDishName == null || resolvedPriceRial == null) {
      final held = mealStore.find(accountId, date, slot);
      resolvedDishName ??= held?.dishName ?? 'غذا';
      resolvedPriceRial ??= held?.priceRial ?? 0;
    }
    _basketSaleDetails[key] = (
      dishName: resolvedDishName,
      priceRial: resolvedPriceRial,
    );

    _persistBasketSales();
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  void unmarkListedInBasket(AccountId accountId, DateTime date, MealSlot slot) {
    final key = _basketSaleKey(accountId, date, slot);
    _basketSales.remove(key);
    _basketSaleDetails.remove(key);
    _persistBasketSales();
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  void unmarkListedInBasketByKey(String key) {
    _basketSales.remove(key);
    _basketSaleDetails.remove(key);
    _persistBasketSales();
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  Future<void> _loadBasketSales() async {
    final store = plainStore;
    if (store == null) return;
    final raw = await store.readString(StoreKeys.basketSales);
    if (raw != null && raw.isNotEmpty) {
      final list = raw.split(',').where((s) => s.isNotEmpty);
      _basketSales.addAll(list);
    }
    final rawDetails = await store.readString(StoreKeys.basketSaleDetails);
    if (rawDetails != null && rawDetails.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawDetails) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (entry.value is Map) {
            final m = entry.value as Map;
            _basketSaleDetails[entry.key] = (
              dishName: m['dishName']?.toString() ?? '',
              priceRial: (m['priceRial'] as num?)?.toInt() ?? 0,
            );
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _persistBasketSales() async {
    final store = plainStore;
    if (store == null) return;
    await store.writeString(StoreKeys.basketSales, _basketSales.join(','));

    final map = <String, Map<String, dynamic>>{};
    for (final entry in _basketSaleDetails.entries) {
      map[entry.key] = {
        'dishName': entry.value.dishName,
        'priceRial': entry.value.priceRial,
      };
    }
    await store.writeString(StoreKeys.basketSaleDetails, jsonEncode(map));
  }

  void _pruneBasketSales() {
    if (_basketSales.isEmpty) return;
    final toRemove = <String>[];
    for (final key in _basketSales) {
      final parts = key.split('|');
      if (parts.length != 3) {
        toRemove.add(key);
        continue;
      }
      final accId = parts[0];
      final dateParts = parts[1].split('-').map(int.parse).toList();
      final date = DateTime.utc(dateParts[0], dateParts[1], dateParts[2]);
      final slot = MealSlot.values.byName(parts[2]);

      // If the meal is no longer held in mealStore, it was either sold or pruned
      if (mealStore.find(accId, date, slot) == null) {
        toRemove.add(key);
        if (!isMealDistributionPassed(date, slot, clock: clock)) {
          final details = _basketSaleDetails[key];
          final dishName = details?.dishName ?? 'غذا';
          final priceRial = details?.priceRial ?? 0;
          onBasketMealSold?.call(key, accId, date, slot, dishName, priceRial);
        }
      }
    }
    if (toRemove.isNotEmpty) {
      _basketSales.removeAll(toRemove);
      for (final k in toRemove) {
        _basketSaleDetails.remove(k);
      }
      _persistBasketSales();
      onBasketSalesChanged?.call();
    }
  }

  /// Issued forgot-card receipt codes, keyed by `"$accountId|${date.year}-${date.month}-${date.day}|${slot.name}"`.
  final Map<String, String> _forgotReceipts = {};

  Map<String, String> get forgotReceipts => Map.unmodifiable(_forgotReceipts);

  static String _forgotReceiptKey(AccountId accountId, DateTime date, MealSlot slot) =>
      '$accountId|${date.year}-${date.month}-${date.day}|${slot.name}';

  /// Returns the cached receipt code for the given account and meal, if already issued.
  String? receiptCodeFor(AccountId accountId, DateTime date, MealSlot slot) {
    return _forgotReceipts[_forgotReceiptKey(accountId, date, slot)];
  }

  /// Records and persists an issued receipt code, notifying listeners.
  void recordReceipt(AccountId accountId, DateTime date, MealSlot slot, String code) {
    _forgotReceipts[_forgotReceiptKey(accountId, date, slot)] = code;
    _persistForgotReceipts();
    notifyListeners();
  }

  Future<void> _loadForgotReceipts() async {
    final store = plainStore;
    if (store == null) return;
    final raw = await store.readString(StoreKeys.forgotReceipts);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          _forgotReceipts[entry.key] = entry.value.toString();
        }
      } catch (_) {}
    }
  }

  Future<void> _persistForgotReceipts() async {
    final store = plainStore;
    if (store == null) return;
    await store.writeString(StoreKeys.forgotReceipts, jsonEncode(_forgotReceipts));
  }

  /// Tells the UI that the shared meal store changed.
  ///
  /// The store is a plain value type shared with the platform layer, so it
  /// cannot notify on its own. The platform writes it and calls this; the
  /// screens that read it redraw.
  void mealsChanged() {
    _pruneBasketSales();
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
    _normalizeTransactions();
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

  int _idCounter = 0;

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

  /// Deletes an account.
  ///
  /// The credentials go too: leaving a password behind for an account the
  /// user deleted would be a privacy failure.
  Future<void> removeAccount(AccountId accountId) async {
    final acc = accountFor(accountId);
    final studentId = acc?.studentId;
    await accountStore.remove(accountId);
    await credentialStore?.delete(accountId);
    if (_selectedReservationsAccountId == accountId) {
      _selectedReservationsAccountId = null;
    }
    _spendFilter = _spendFilter.copyWith(
      accountIds: _spendFilter.accountIds.where((id) => id != accountId).toSet(),
    );
    _transactions = _transactions.where((t) {
      if (t.accountId == accountId) return false;
      if (studentId != null && t.accountId == studentId) return false;
      return true;
    }).toList();
    _basketSales.removeWhere((key) => key.startsWith('$accountId|'));
    _basketSaleDetails.removeWhere((key, _) => key.startsWith('$accountId|'));
    _persistBasketSales();
    onBasketSalesChanged?.call();
    _forgotReceipts.removeWhere((key, _) => key.startsWith('$accountId|'));
    _persistForgotReceipts();
    _accounts = await accountStore.loadAll();
    _cachedSpendSummary = null;
    await _persistTransactions();
    notifyListeners();
  }

  // -------------------------------------------------------------- reminders

  /// Saves the reminder configuration.
  Future<void> saveReminderConfig(ReminderConfig config) async {
    _reminderConfig = config;
    await reminderConfigStore.save(config);
    // The alarms are derived from the configuration, so a change has to
    // re-arm them. A slot the user switched off must stop firing, and a slot
    // they switched on must start: the alarm and the setting the user sees
    // are the same thing, and they must not drift apart.
    onReminderConfigChanged?.call(config);
    notifyListeners();
  }

  /// Called after the reminder configuration changes, so the alarms can be
  /// re-armed.
  ///
  /// The state owns the configuration; the platform owns the alarms. The
  /// platform layer sets this.
  void Function(ReminderConfig config)? onReminderConfigChanged;

  /// Toggles an account's participation in the reminders.
  Future<void> toggleReminderAccount(AccountId accountId) async {
    final next = Set<AccountId>.from(_reminderConfig.accountIds);
    if (!next.remove(accountId)) next.add(accountId);
    await saveReminderConfig(_reminderConfig.copyWith(accountIds: next));
  }

  /// Toggles an account's participation in the weekend reservation nudge.
  Future<void> toggleNudgeAccount(AccountId accountId) async {
    final current = _reminderConfig.nudgeAccountIds ?? _reminderConfig.accountIds;
    final next = Set<AccountId>.from(current);
    if (!next.remove(accountId)) next.add(accountId);
    await saveReminderConfig(_reminderConfig.copyWith(nudgeAccountIds: next));
  }

  /// Sets or clears dismissal of the next-week reservation reminder for a specific week.
  Future<void> setNudgeWeekDismissal(DateTime? weekSaturday) async {
    await saveReminderConfig(
      _reminderConfig.copyWith(
        dismissedNudgeWeekSaturday: weekSaturday,
        clearDismissedNudge: weekSaturday == null,
      ),
    );
  }

  // -------------------------------------------------------------------- hunt

  AccountId? _selectedReservationsAccountId;

  /// The account currently active for viewing and booking reservations.
  AccountId? get selectedReservationsAccountId =>
      _selectedReservationsAccountId ?? _activeHuntAccount;

  /// Selects the account for viewing and booking reservations.
  void selectReservationsAccount(AccountId accountId) {
    if (_selectedReservationsAccountId == accountId) return;
    _selectedReservationsAccountId = accountId;
    _activeHuntAccount = accountId;
    notifyListeners();
  }

  /// Selects the account whose hunt the screen shows.
  void selectHuntAccount(AccountId accountId) {
    if (_activeHuntAccount == accountId) return;
    _activeHuntAccount = accountId;
    // The verdict belongs to the previous account's configuration, so it is
    // cleared rather than shown against the wrong one.
    _huntPreflightSummary = null;
    _huntPreflightRefusal = null;
    notifyListeners();
  }

  /// Saves the hunt configuration for a specific account.
  Future<void> saveHuntConfigFor(AccountId accountId, HuntConfig config) async {
    _huntConfigs[accountId] = config;
    await huntConfigStore?.save(accountId, config);
    if (_activeHuntAccount == accountId) {
      _huntPreflightSummary = null;
      _huntPreflightRefusal = null;
      _huntEnableRefusal = null;
    }
    notifyListeners();
    onHuntConfigChanged?.call(accountId, config);
  }

  /// Saves the hunt configuration for the active account.
  Future<void> saveHuntConfig(HuntConfig config) async {
    final accountId = _activeHuntAccount;
    if (accountId == null) return;
    await saveHuntConfigFor(accountId, config);
  }

  /// Called after a hunt configuration changes, so the wake-up can be re-armed.
  ///
  /// The state owns the configuration; the platform owns the alarms. The
  /// platform layer sets this.
  void Function(AccountId accountId, HuntConfig config)? onHuntConfigChanged;

  /// Records the pre-flight verdict for the hunt.
  void setHuntPreflight({String? summary, String? refusal}) {
    _huntPreflightSummary = summary;
    _huntPreflightRefusal = refusal;
    notifyListeners();
  }

  /// Records whether a hunt is running.
  void setHuntRunning(bool value) {
    _huntRunning = value;
    notifyListeners();
  }

  // --------------------------------------------------------------- filtering

  /// Toggles an account in the dashboard's filter.
  void toggleSpendAccount(AccountId accountId) {
    _spendFilter = _spendFilter.toggleAccount(accountId);
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Toggles a meal slot in the dashboard's filter.
  void toggleSpendSlot(MealSlot slot) {
    _spendFilter = _spendFilter.toggleSlot(slot);
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Clears the dashboard's filter, back to showing everything.
  void clearSpendFilter() {
    _spendFilter = const SpendFilter();
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Sets the dashboard's time period (all, week, month).
  void setSpendPeriod(SpendPeriodType periodType, {DateTime? referenceDate}) {
    if (_spendFilter.periodType == periodType &&
        (referenceDate == null || _spendFilter.referenceDate == referenceDate)) {
      return;
    }
    _spendFilter = _spendFilter.copyWith(
      periodType: periodType,
      weekOffset: 0,
      monthOffset: 0,
      referenceDate: referenceDate ?? _spendFilter.referenceDate,
    );
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Sets the week offset for the week filter.
  void setSpendWeekOffset(int offset) {
    if (_spendFilter.weekOffset == offset) return;
    _spendFilter = _spendFilter.withWeekOffset(offset);
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Sets the month offset for the month filter.
  void setSpendMonthOffset(int offset) {
    if (_spendFilter.monthOffset == offset) return;
    _spendFilter = _spendFilter.withMonthOffset(offset);
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// Sets the reference anchor date for week/month calculations.
  void setSpendReferenceDate(DateTime? date) {
    if (_spendFilter.referenceDate == date) return;
    _spendFilter = _spendFilter.copyWith(referenceDate: date);
    _cachedSpendSummary = null;
    notifyListeners();
  }

  /// The balance last read for [accountId], in Rial.
  int? balanceFor(AccountId accountId) => _balances[accountId];

  /// The error from the last sync of [accountId], if it failed.
  String? syncErrorFor(AccountId accountId) => _syncErrors[accountId];

  /// Whether a sync is in progress.
  bool get isSyncing => _syncing;

  /// Records a balance read from the portal.
  void setBalance(AccountId accountId, int balanceRial) {
    _balances[accountId] = balanceRial;
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
