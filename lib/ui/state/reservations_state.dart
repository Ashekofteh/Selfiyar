/// The reservation and ledger part of the app's state.
///
/// This controller owns the local mirror the reminders read (the meals and
/// bookable menus), the dashboard's transaction history and its filter, the
/// Food Basket sale markers, and the issued forgot-card slips.
///
/// It reads the account list through callbacks rather than owning it, because
/// identity lives in [SessionState] — and the two must not hold two copies of
/// the same truth.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/auth/account.dart';
import '../../core/finance/spend_summary.dart';
import '../../core/meal/local_meal_store.dart';
import '../../core/meal/local_menu_store.dart';
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../core/shared/persian.dart';
import '../../core/shared/platform_stores.dart';
import '../../core/shared/time.dart';

/// Meals, menus, transactions, basket sales, and forgot receipts.
class ReservationsState extends ChangeNotifier {
  ReservationsState({
    required this.mealStore,
    required this.menuStore,
    required this.plainStore,
    required this.clock,
    required this.accounts,
    required this.accountFor,
    this._transactions = const [],
  });

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

  final PlainStore? plainStore;
  final ServerClock? clock;

  /// The saved accounts, as the session controller holds them.
  final List<SavedAccount> Function() accounts;

  /// Resolves an account id, as the session controller does.
  final SavedAccount? Function(AccountId) accountFor;

  // ------------------------------------------------------------ reservations

  AccountId? _selectedReservationsAccountId;

  /// The account currently active for viewing and booking reservations.
  AccountId? get selectedReservationsAccountId =>
      _selectedReservationsAccountId;

  /// Selects the account for viewing and booking reservations.
  void selectReservationsAccount(AccountId accountId) {
    if (_selectedReservationsAccountId == accountId) return;
    _selectedReservationsAccountId = accountId;
    notifyListeners();
  }

  /// Forgets the selected reservations account when it is deleted.
  void clearSelectedReservationsAccountIf(AccountId accountId) {
    if (_selectedReservationsAccountId == accountId) {
      _selectedReservationsAccountId = null;
    }
  }

  /// The meals held for one account, newest first.
  List<StoredMeal> mealsFor(AccountId accountId) =>
      mealStore.forAccount(accountId);

  /// Tells the UI that cached menus have changed.
  void menusChanged() {
    notifyListeners();
  }

  /// Tells the UI that the shared meal store changed.
  ///
  /// The store is a plain value type shared with the platform layer, so it
  /// cannot notify on its own. The platform writes it and calls this; the
  /// screens that read it redraw.
  void mealsChanged() {
    pruneBasketSales();
    notifyListeners();
  }

  // ------------------------------------------------------------- transactions

  List<Transaction> _transactions;

  /// The transactions the dashboard is computed from.
  List<Transaction> get transactions => _transactions;

  SpendFilter _spendFilter = const SpendFilter();
  SpendSummary? _cachedSpendSummary;

  SpendFilter get spendFilter => _spendFilter;

  /// The accounts selected in the dashboard's account filter.
  Set<AccountId> get selectedAccountIds => _spendFilter.accountIds;

  /// The meal slots selected in the dashboard's slot filter.
  Set<MealSlot> get selectedSlots => _spendFilter.slots;

  /// The computed spend summary, honouring the current filter.
  SpendSummary get spendSummary {
    if (_cachedSpendSummary != null) return _cachedSpendSummary!;

    // Resolve filter's accountIds to include both id and studentId for all
    // selected accounts, ensuring robust matching regardless of transaction
    // ID representation.
    final effectiveAccountIds = <AccountId>{};
    for (final id in _spendFilter.accountIds) {
      effectiveAccountIds.add(id);
      final acc = accountFor(id);
      if (acc != null) {
        effectiveAccountIds.add(acc.studentId);
      }
      for (final a in accounts()) {
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

  Transaction _normalizeTransaction(
    Transaction t, {
    AccountId? fallbackAccountId,
  }) {
    if (accounts().any((a) => a.id == t.accountId)) {
      return t;
    }
    for (final a in accounts()) {
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

  /// Rewrites transactions whose account id is a student id to the saved
  /// account's id.
  void normalizeTransactions() {
    if (_transactions.isEmpty || accounts().isEmpty) return;
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

  /// Prunes transactions older than [retentionDays] (default 28 days / 4
  /// weeks).
  static List<Transaction> pruneTransactions(
    List<Transaction> transactions,
    DateTime now, {
    int retentionDays = 28,
  }) {
    final cutoff = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: retentionDays));
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
    unawaited(_persistTransactions());
  }

  /// Updates the transactions for a single account, preserving other
  /// accounts' transactions.
  void updateTransactionsForAccount(
    AccountId accountId,
    List<Transaction> accountTransactions,
  ) {
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
    unawaited(_persistTransactions());
  }

  /// Loads the persisted transaction history and merges it with any supplied
  /// at construction.
  Future<void> loadTransactions() async {
    final store = plainStore;
    if (store == null) return;

    final rawTx = await store.readString(StoreKeys.transactions);
    if (rawTx == null || rawTx.isEmpty) return;

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
            '${t.accountId}|${t.date}|${t.slot?.name}|${t.type}|${t.foodName}|${t.amountRial}',
          ))
            t,
      ];
      _transactions = [..._transactions, ...toAdd];
    }
    normalizeTransactions();
  }

  // ------------------------------------------------------------ spend filter

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
        (referenceDate == null ||
            _spendFilter.referenceDate == referenceDate)) {
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

  // ------------------------------------------------------------ basket sales

  /// Active Food Basket sale listings, keyed by
  /// `"$accountId|${date.year}-${date.month}-${date.day}|${slot.name}"`.
  final Set<String> _basketSales = {};
  final Map<String, ({String dishName, int priceRial})> _basketSaleDetails = {};

  Set<String> get basketSales => Set.unmodifiable(_basketSales);

  ({String dishName, int priceRial})? basketSaleDetailsFor(String key) =>
      _basketSaleDetails[key];

  void Function()? onBasketSalesChanged;
  void Function(
    String key,
    AccountId accountId,
    DateTime date,
    MealSlot slot,
    String dishName,
    int priceRial,
  )?
  onBasketMealSold;

  static String basketSaleKey(
    AccountId accountId,
    DateTime date,
    MealSlot slot,
  ) => '$accountId|${date.year}-${date.month}-${date.day}|${slot.name}';

  bool isListedInBasket(AccountId accountId, DateTime date, MealSlot slot) {
    return _basketSales.contains(basketSaleKey(accountId, date, slot));
  }

  void markListedInBasket(
    AccountId accountId,
    DateTime date,
    MealSlot slot, {
    String? dishName,
    int? priceRial,
  }) {
    final key = basketSaleKey(accountId, date, slot);
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

    unawaited(_persistBasketSales());
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  void unmarkListedInBasket(AccountId accountId, DateTime date, MealSlot slot) {
    final key = basketSaleKey(accountId, date, slot);
    _basketSales.remove(key);
    _basketSaleDetails.remove(key);
    unawaited(_persistBasketSales());
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  void unmarkListedInBasketByKey(String key) {
    _basketSales.remove(key);
    _basketSaleDetails.remove(key);
    unawaited(_persistBasketSales());
    notifyListeners();
    onBasketSalesChanged?.call();
  }

  Future<void> loadBasketSales() async {
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

  /// Drops sale markers whose meal is no longer held, reporting the sold ones.
  void pruneBasketSales() {
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

      // If the meal is no longer held in mealStore, it was either sold or
      // pruned.
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
      unawaited(_persistBasketSales());
      onBasketSalesChanged?.call();
    }
  }

  // --------------------------------------------------------- forgot receipts

  /// Issued forgot-card receipt codes, keyed by
  /// `"$accountId|${date.year}-${date.month}-${date.day}|${slot.name}"`.
  final Map<String, String> _forgotReceipts = {};

  Map<String, String> get forgotReceipts => Map.unmodifiable(_forgotReceipts);

  static String forgotReceiptKey(
    AccountId accountId,
    DateTime date,
    MealSlot slot,
  ) => '$accountId|${date.year}-${date.month}-${date.day}|${slot.name}';

  /// Returns the cached receipt code for the given account and meal, if
  /// already issued.
  String? receiptCodeFor(AccountId accountId, DateTime date, MealSlot slot) {
    return _forgotReceipts[forgotReceiptKey(accountId, date, slot)];
  }

  /// Records and persists an issued receipt code, notifying listeners.
  void recordReceipt(
    AccountId accountId,
    DateTime date,
    MealSlot slot,
    String code,
  ) {
    _forgotReceipts[forgotReceiptKey(accountId, date, slot)] = code;
    unawaited(_persistForgotReceipts());
    notifyListeners();
  }

  Future<void> loadForgotReceipts() async {
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
    await store.writeString(
      StoreKeys.forgotReceipts,
      jsonEncode(_forgotReceipts),
    );
  }

  // ----------------------------------------------------------- account purge

  /// Removes everything this controller holds for a deleted account.
  Future<void> removeAccountData(
    AccountId accountId, {
    String? studentId,
  }) async {
    clearSelectedReservationsAccountIf(accountId);
    _spendFilter = _spendFilter.copyWith(
      accountIds: _spendFilter.accountIds
          .where((id) => id != accountId)
          .toSet(),
    );
    _transactions = _transactions.where((t) {
      if (t.accountId == accountId) return false;
      if (studentId != null && t.accountId == studentId) return false;
      return true;
    }).toList();
    _basketSales.removeWhere((key) => key.startsWith('$accountId|'));
    _basketSaleDetails.removeWhere((key, _) => key.startsWith('$accountId|'));
    await _persistBasketSales();
    onBasketSalesChanged?.call();
    _forgotReceipts.removeWhere((key, _) => key.startsWith('$accountId|'));
    await _persistForgotReceipts();
    _cachedSpendSummary = null;
    await _persistTransactions();
    notifyListeners();
  }
}
