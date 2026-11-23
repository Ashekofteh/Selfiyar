/// Application state, held in one place and shared by the screens.
///
/// Deliberately plain [ChangeNotifier]s rather than a state-management
/// package: the app has one composition root, and a framework would be more
/// moving parts than the problem needs. The domain logic lives in `lib/core`
/// and is unit tested there; this layer only holds the results and forwards
/// intent.
///
/// ## Shape
///
/// The state is split by domain, and each domain is its own notifier:
///
///  * [SessionState] — accounts, credentials, balances, sync status;
///  * [ReservationsState] — meals, menus, transactions, basket sales, slips;
///  * [HuntState] — hunt configuration, run status, schedules;
///  * [RemindersState] — the reminder configuration.
///
/// [AppState] is the composition root. It owns the app-shell state that is not
/// a domain (the theme, the offline flag, the update badge, the loaded flag),
/// creates the controllers, forwards every call, and re-broadcasts their
/// notifications. Screens can keep listening to [AppState] as before, or
/// listen to a single controller when that is all they need.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/auth/account.dart';
import '../core/auth/account_store.dart';
import '../core/auth/session.dart';
import '../core/finance/bank_card.dart';
import '../core/finance/bank_card_store.dart';
import '../core/finance/spend_summary.dart';
import '../core/hunt/hunt_config.dart';
import '../core/hunt/hunt_schedule.dart';
import '../core/hunt/hunt_store.dart';
import '../core/hunt/snipe.dart';
import '../core/meal/local_meal_store.dart';
import '../core/meal/local_menu_store.dart';
import '../core/meal/models.dart';
import '../core/portal/portal.dart';
import '../core/reminder/reminder.dart';
import '../core/shared/platform_stores.dart';
import '../core/shared/time.dart';
import 'state/hunt_state.dart';
import 'state/reminders_state.dart';
import 'state/reservations_state.dart';
import 'state/session_state.dart';

/// The app's shared state.
class AppState extends ChangeNotifier {
  AppState({
    required AccountStore accountStore,
    required ReminderConfigStore reminderConfigStore,
    HuntConfigStore? huntConfigStore,
    HuntSuccessStore? huntSuccessStore,
    SecureCredentialStore? credentialStore,
    this.bankCardStore,
    this.plainStore,
    ServerClock? clock,
    LocalMealStore? mealStore,
    LocalMenuStore? menuStore,
    List<Transaction> transactions = const [],
    this._themeMode = ThemeMode.system,
  }) : _clock = clock,
       mealStore = mealStore ?? LocalMealStore(),
       menuStore = menuStore ?? LocalMenuStore() {
    // ignore: prefer_initializing_formals
    session = SessionState(
      accountStore: accountStore,
      credentialStore: credentialStore,
    );
    reservations = ReservationsState(
      mealStore: this.mealStore,
      menuStore: this.menuStore,
      plainStore: plainStore,
      clock: clock,
      accounts: () => session.accounts,
      accountFor: session.accountFor,
      transactions: transactions,
    );
    hunt = HuntState(
      configStore: huntConfigStore,
      successStore: huntSuccessStore ??
          (plainStore != null ? PreferencesHuntSuccessStore(plainStore!) : null),
      accounts: () => session.accounts,
    );
    reminders = RemindersState(configStore: reminderConfigStore);

    session.addListener(notifyListeners);
    reservations.addListener(notifyListeners);
    hunt.addListener(notifyListeners);
    reminders.addListener(notifyListeners);

    reservations.normalizeTransactions();
  }

  // ------------------------------------------------------------ controllers

  /// Accounts, credentials, balances, and sync status.
  late final SessionState session;

  /// Meals, menus, transactions, basket sales, and forgot receipts.
  late final ReservationsState reservations;

  /// Hunt configuration and live run state.
  late final HuntState hunt;

  /// Reminder configuration and account toggles.
  late final RemindersState reminders;

  // -------------------------------------------------------- app-shell state

  /// Where saved accounts are persisted.
  AccountStore get accountStore => session.accountStore;

  /// Where the reminder configuration is persisted.
  ReminderConfigStore get reminderConfigStore => reminders.configStore;

  /// Where the hunt configuration is persisted.
  ///
  /// Null when the app has no plain store for it — in tests, or before the
  /// platform layer is wired. A hunt then simply does not persist.
  HuntConfigStore? get huntConfigStore => hunt.configStore;

  /// Where credentials are persisted, encrypted. Null when the app has no
  /// secure store — in tests, or before the platform layer is wired.
  SecureCredentialStore? get credentialStore => session.credentialStore;

  final BankCardStore? bankCardStore;
  final PlainStore? plainStore;
  ServerClock? _clock;
  ServerClock? get clock => _clock;
  set clock(ServerClock? c) {
    _clock = c;
    reservations.clock = c;
  }

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

  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Loads the persisted state. Safe to call more than once.
  Future<void> load() async {
    try {
      await session.loadAccounts();
    } catch (_) {}

    try {
      reservations.normalizeTransactions();
      await reminders.load();
      await hunt.loadConfigs();
      await hunt.loadSuccesses();
      await reservations.loadBasketSales();
      reservations.pruneBasketSales();
      await reservations.loadForgotReceipts();
      if (bankCardStore != null) {
        _savedBankCards = await bankCardStore!.loadCards();
      }
      await reservations.loadTransactions();
      final store = plainStore;
      if (store != null) {
        final savedMode = await store.readString(StoreKeys.themeMode);
        if (savedMode == 'dark') {
          _themeMode = ThemeMode.dark;
        } else if (savedMode == 'light') {
          _themeMode = ThemeMode.light;
        } else if (savedMode == 'system') {
          _themeMode = ThemeMode.system;
        }
      }
    } catch (_) {}

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

  // ------------------------------------------------------------- accounts

  List<SavedAccount> get accounts => session.accounts;

  String? get error => session.error;

  /// Finds the account with [accountId], if it exists.
  SavedAccount? accountFor(AccountId accountId) =>
      session.accountFor(accountId);

  /// Adds an account, or updates the one with the same student ID.
  Future<void> upsertAccount({
    required String studentId,
    String? alias,
    String? profileName,
  }) async {
    await session.upsertAccount(
      studentId: studentId,
      alias: alias,
      profileName: profileName,
    );
    reservations.normalizeTransactions();
  }

  /// Stores the credentials for an account, encrypted.
  ///
  /// The password goes only to the secure store — never to the account list
  /// and never to the plain store, where the rest of the account data lives.
  Future<void> saveCredentials(AccountId accountId, Credentials credentials) =>
      session.saveCredentials(accountId, credentials);

  /// Whether an account has stored credentials.
  Future<bool> hasCredentials(AccountId accountId) =>
      session.hasCredentials(accountId);

  /// Sets or clears an account's alias.
  Future<void> setAlias(AccountId accountId, String? alias) =>
      session.setAlias(accountId, alias);

  /// Records the profile name learned from the portal.
  Future<void> setProfileName(AccountId accountId, String name) =>
      session.setProfileName(accountId, name);

  /// Deletes an account and everything belonging to it.
  ///
  /// The credentials go too: leaving a password behind for an account the
  /// user deleted would be a privacy failure.
  Future<void> removeAccount(AccountId accountId) async {
    final acc = session.accountFor(accountId);
    final studentId = acc?.studentId;
    await session.removeAccount(accountId);
    await reservations.removeAccountData(accountId, studentId: studentId);
  }

  // --------------------------------------------------------- reservations

  /// The account currently active for viewing and booking reservations.
  AccountId? get selectedReservationsAccountId =>
      reservations.selectedReservationsAccountId ?? hunt.activeHuntAccount;

  /// Selects the account for viewing and booking reservations.
  void selectReservationsAccount(AccountId accountId) {
    reservations.selectReservationsAccount(accountId);
    hunt.selectHuntAccount(accountId);
  }

  /// The meals held for one account, newest first.
  List<StoredMeal> mealsFor(AccountId accountId) =>
      reservations.mealsFor(accountId);

  /// Notifies screens that cached menus have changed.
  void menusChanged() => reservations.menusChanged();

  /// Tells the UI that the shared meal store changed.
  ///
  /// The store is a plain value type shared with the platform layer, so it
  /// cannot notify on its own. The platform writes it and calls this; the
  /// screens that read it redraw.
  void mealsChanged() => reservations.mealsChanged();

  // ---------------------------------------------------------- transactions

  /// The transactions the dashboard is computed from.
  List<Transaction> get transactions => reservations.transactions;

  /// The computed spend summary, honouring the current filter.
  SpendSummary get spendSummary => reservations.spendSummary;

  /// The dashboard's filter.
  SpendFilter get spendFilter => reservations.spendFilter;

  /// The accounts selected in the dashboard's account filter.
  Set<AccountId> get selectedAccountIds => reservations.selectedAccountIds;

  /// The meal slots selected in the dashboard's slot filter.
  Set<MealSlot> get selectedSlots => reservations.selectedSlots;

  /// Prunes transactions older than [retentionDays] (default 28 days / 4
  /// weeks).
  static List<Transaction> pruneTransactions(
    List<Transaction> transactions,
    DateTime now, {
    int retentionDays = 28,
  }) => ReservationsState.pruneTransactions(
    transactions,
    now,
    retentionDays: retentionDays,
  );

  /// Replaces the transaction history, e.g. after a live read.
  void setTransactions(List<Transaction> transactions) =>
      reservations.setTransactions(transactions);

  /// Updates the transactions for a single account, preserving other
  /// accounts' transactions.
  void updateTransactionsForAccount(
    AccountId accountId,
    List<Transaction> accountTransactions,
  ) =>
      reservations.updateTransactionsForAccount(accountId, accountTransactions);

  /// Toggles an account in the dashboard's filter.
  void toggleSpendAccount(AccountId accountId) =>
      reservations.toggleSpendAccount(accountId);

  /// Toggles a meal slot in the dashboard's filter.
  void toggleSpendSlot(MealSlot slot) => reservations.toggleSpendSlot(slot);

  /// Clears the dashboard's filter, back to showing everything.
  void clearSpendFilter() => reservations.clearSpendFilter();

  /// Sets the dashboard's time period (all, week, month).
  void setSpendPeriod(SpendPeriodType periodType, {DateTime? referenceDate}) =>
      reservations.setSpendPeriod(periodType, referenceDate: referenceDate);

  /// Sets the week offset for the week filter.
  void setSpendWeekOffset(int offset) =>
      reservations.setSpendWeekOffset(offset);

  /// Sets the month offset for the month filter.
  void setSpendMonthOffset(int offset) =>
      reservations.setSpendMonthOffset(offset);

  /// Sets the reference anchor date for week/month calculations.
  void setSpendReferenceDate(DateTime? date) =>
      reservations.setSpendReferenceDate(date);

  // ---------------------------------------------------------- basket sales

  Set<String> get basketSales => reservations.basketSales;

  ({String dishName, int priceRial})? basketSaleDetailsFor(String key) =>
      reservations.basketSaleDetailsFor(key);

  void Function()? get onBasketSalesChanged =>
      reservations.onBasketSalesChanged;
  set onBasketSalesChanged(void Function()? value) =>
      reservations.onBasketSalesChanged = value;

  void Function(
    String key,
    AccountId accountId,
    DateTime date,
    MealSlot slot,
    String dishName,
    int priceRial,
  )?
  get onBasketMealSold => reservations.onBasketMealSold;
  set onBasketMealSold(
    void Function(
      String key,
      AccountId accountId,
      DateTime date,
      MealSlot slot,
      String dishName,
      int priceRial,
    )?
    value,
  ) => reservations.onBasketMealSold = value;

  bool isListedInBasket(AccountId accountId, DateTime date, MealSlot slot) =>
      reservations.isListedInBasket(accountId, date, slot);

  void markListedInBasket(
    AccountId accountId,
    DateTime date,
    MealSlot slot, {
    String? dishName,
    int? priceRial,
  }) => reservations.markListedInBasket(
    accountId,
    date,
    slot,
    dishName: dishName,
    priceRial: priceRial,
  );

  void unmarkListedInBasket(
    AccountId accountId,
    DateTime date,
    MealSlot slot,
  ) => reservations.unmarkListedInBasket(accountId, date, slot);

  void unmarkListedInBasketByKey(String key) =>
      reservations.unmarkListedInBasketByKey(key);

  // -------------------------------------------------------- forgot receipts

  Map<String, String> get forgotReceipts => reservations.forgotReceipts;

  /// Returns the cached receipt code for the given account and meal, if
  /// already issued.
  String? receiptCodeFor(AccountId accountId, DateTime date, MealSlot slot) =>
      reservations.receiptCodeFor(accountId, date, slot);

  /// Records and persists an issued receipt code, notifying listeners.
  void recordReceipt(
    AccountId accountId,
    DateTime date,
    MealSlot slot,
    String code,
  ) => reservations.recordReceipt(accountId, date, slot, code);

  // ------------------------------------------------------------ bank cards

  List<SavedBankCard> _savedBankCards = const [];

  /// The list of saved bank cards, newest first.
  List<SavedBankCard> get savedBankCards => List.unmodifiable(_savedBankCards);

  /// Saves or updates a bank card and updates state.
  Future<void> saveBankCard(SavedBankCard card) async {
    await bankCardStore?.saveCard(card);
    if (bankCardStore != null) {
      _savedBankCards = await bankCardStore!.loadCards();
    } else {
      final list = _savedBankCards
          .where((c) => c.cleanPan != card.cleanPan)
          .toList();
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

  // -------------------------------------------------------------- reminders

  ReminderConfig get reminderConfig => reminders.config;

  /// Saves the reminder configuration.
  Future<void> saveReminderConfig(ReminderConfig config) =>
      reminders.save(config);

  void Function(ReminderConfig config)? get onReminderConfigChanged =>
      reminders.onReminderConfigChanged;
  set onReminderConfigChanged(void Function(ReminderConfig config)? value) =>
      reminders.onReminderConfigChanged = value;

  /// Toggles an account's participation in the reminders.
  Future<void> toggleReminderAccount(AccountId accountId) =>
      reminders.toggleAccount(accountId);

  /// Toggles an account's participation in the weekend reservation nudge.
  Future<void> toggleNudgeAccount(AccountId accountId) =>
      reminders.toggleNudgeAccount(accountId);

  /// Sets or clears dismissal of the next-week reservation reminder for a
  /// specific week.
  Future<void> setNudgeWeekDismissal(DateTime? weekSaturday) =>
      reminders.setNudgeWeekDismissal(weekSaturday);

  // ------------------------------------------------------------------ hunt

  /// The account whose hunt the screen is editing.
  AccountId? get activeHuntAccount => hunt.activeHuntAccount;

  /// The configuration of the account's hunt, or null when it has none.
  HuntConfig? get activeHuntConfig => hunt.activeHuntConfig;

  /// The configuration of a named account's hunt, or null when it has none.
  ///
  /// Needed by the path that starts a hunt the **platform** asked for: the
  /// request names the account, and the account's configuration is where its
  /// dishes, halls and rate live.
  HuntConfig? huntConfigFor(AccountId accountId) =>
      hunt.huntConfigFor(accountId);

  /// The last pre-flight verdict: what the hunt would buy, when it is ready.
  String? get huntPreflightSummary => hunt.huntPreflightSummary;

  /// Why the hunt was refused, when it was.
  String? get huntPreflightRefusal => hunt.huntPreflightRefusal;

  /// Why the hunt could not be switched on, when it could not.
  String? get huntEnableRefusal => hunt.huntEnableRefusal;

  /// Records why the hunt could not be switched on, or clears it.
  void setHuntEnableRefusal(String? refusal) => hunt.setEnableRefusal(refusal);

  /// Whether a hunt is running.
  bool get huntRunning => hunt.huntRunning;

  /// Whether a hunt is running for [accountId].
  bool isHuntRunning(AccountId accountId) => hunt.isHuntRunning(accountId);

  /// The live status of the currently running hunt, or null when idle.
  SnipeRunStatus? get huntStatus => hunt.huntStatus;

  /// The live status of the running hunt for [accountId], or null when idle.
  SnipeRunStatus? huntStatusFor(AccountId accountId) =>
      hunt.huntStatusFor(accountId);

  /// The store that persists hunt success records.
  HuntSuccessStore? get huntSuccessStore => hunt.successStore;

  /// The schedule of the account's hunt, when there is one.
  HuntScheduleResult? huntScheduleFor(AccountId accountId) =>
      hunt.huntScheduleFor(accountId);

  /// Records the schedule that was armed for an account.
  void setHuntSchedule(AccountId accountId, HuntScheduleResult result) =>
      hunt.setSchedule(accountId, result);

  /// Selects the account whose hunt the screen shows.
  void selectHuntAccount(AccountId accountId) =>
      hunt.selectHuntAccount(accountId);

  /// Saves the hunt configuration for a specific account.
  Future<void> saveHuntConfigFor(AccountId accountId, HuntConfig config) =>
      hunt.saveConfigFor(accountId, config);

  /// Saves the hunt configuration for the active account.
  Future<void> saveHuntConfig(HuntConfig config) => hunt.saveConfig(config);

  /// Called after a hunt configuration changes, so the wake-up can be
  /// re-armed.
  ///
  /// The state owns the configuration; the platform owns the alarms. The
  /// platform layer sets this.
  void Function(AccountId accountId, HuntConfig config)?
  get onHuntConfigChanged => hunt.onHuntConfigChanged;
  set onHuntConfigChanged(
    void Function(AccountId accountId, HuntConfig config)? value,
  ) => hunt.onHuntConfigChanged = value;

  /// Records the pre-flight verdict for the hunt.
  void setHuntPreflight({String? summary, String? refusal}) =>
      hunt.setPreflight(summary: summary, refusal: refusal);

  /// Records whether a hunt is running, optionally specifying [accountId].
  void setHuntRunning(bool value, [AccountId? accountId]) =>
      hunt.setRunning(value, accountId);

  /// Updates the live status of the running hunt, optionally specifying [accountId].
  void setHuntStatus(SnipeRunStatus? status, [AccountId? accountId]) =>
      hunt.setStatus(status, accountId);

  /// The last successful hunt for the active account, if any.
  HuntSuccess? get lastHuntSuccess => hunt.lastSuccess;

  /// The last successful hunt for [accountId], if any.
  HuntSuccess? lastHuntSuccessFor(AccountId accountId) =>
      hunt.lastSuccessFor(accountId);

  /// Reloads the last successful hunt for [accountId].
  Future<void> reloadHuntSuccess(AccountId accountId) =>
      hunt.reloadSuccess(accountId);

  /// Dismisses the last successful hunt for [accountId].
  Future<void> dismissHuntSuccess(AccountId accountId) =>
      hunt.dismissSuccess(accountId);

  /// Reloads all hunt configurations from persistent storage.
  ///
  /// Useful when resuming from background or after a headless hunt has
  /// executed.
  Future<void> reloadHuntConfigs() => hunt.reloadConfigs();

  /// Reloads the hunt configuration for a specific account.
  Future<void> reloadHuntConfig(AccountId accountId) =>
      hunt.reloadConfig(accountId);

  // ------------------------------------------------------------- sync state

  /// The balance last read for [accountId], in Rial.
  int? balanceFor(AccountId accountId) => session.balanceFor(accountId);

  /// When [accountId]'s balance was last read **from the portal**.
  ///
  /// A locally adjusted balance has no timestamp: an estimate must never be
  /// mistaken for a fresh reading by the booking path.
  DateTime? balanceReadAtFor(AccountId accountId) =>
      session.balanceReadAtFor(accountId);

  /// The error from the last sync of [accountId], if it failed.
  String? syncErrorFor(AccountId accountId) => session.syncErrorFor(accountId);

  /// Whether a sync is in progress.
  bool get isSyncing => session.isSyncing;

  /// Records a balance read from the portal.
  ///
  /// [fromPortal] is false for a **local adjustment** — the optimistic
  /// subtraction after a booking, or the addition after a cancel. Only a real
  /// portal reading counts as fresh, because the booking path trusts a fresh
  /// figure instead of re-reading it.
  void setBalance(
    AccountId accountId,
    int balanceRial, {
    bool fromPortal = true,
  }) => session.setBalance(accountId, balanceRial, fromPortal: fromPortal);

  /// Records a failed sync.
  void setSyncError(AccountId accountId, String error) =>
      session.setSyncError(accountId, error);

  /// Sets the syncing flag.
  void setSyncing(bool value) => session.setSyncing(value);

  /// Reports a transient error to the user.
  void setError(String? message) => session.setError(message);

  @override
  void dispose() {
    session.removeListener(notifyListeners);
    reservations.removeListener(notifyListeners);
    hunt.removeListener(notifyListeners);
    reminders.removeListener(notifyListeners);
    session.dispose();
    reservations.dispose();
    hunt.dispose();
    reminders.dispose();
    super.dispose();
  }
}
