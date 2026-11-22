/// The hunt part of the app's state: per-account configuration, the active
/// account, the live run status, and the schedules armed for it.
library;

import 'package:flutter/foundation.dart';

import '../../core/auth/account.dart';
import '../../core/hunt/hunt_config.dart';
import '../../core/hunt/hunt_schedule.dart';
import '../../core/hunt/hunt_store.dart';
import '../../core/hunt/snipe.dart';
import '../../core/meal/models.dart';

/// Hunt configuration and live run state.
class HuntState extends ChangeNotifier {
  HuntState({this.configStore, required this.accounts});

  /// Where the hunt configuration is persisted.
  ///
  /// Null when the app has no plain store for it — in tests, or before the
  /// platform layer is wired. A hunt then simply does not persist.
  final HuntConfigStore? configStore;

  /// The saved accounts, as the session controller holds them.
  final List<SavedAccount> Function() accounts;

  /// The hunt configuration, per account.
  final Map<AccountId, HuntConfig> _huntConfigs = {};

  /// The account whose hunt the screen is editing.
  AccountId? _activeHuntAccount;

  /// Whether a hunt is running.
  bool _huntRunning = false;

  /// The live status of the currently running hunt, when one is active.
  SnipeRunStatus? _huntStatus;

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

  // ------------------------------------------------------------- accessors

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

  /// Whether a hunt is running.
  bool get huntRunning => _huntRunning;

  /// The live status of the currently running hunt, or null when idle.
  SnipeRunStatus? get huntStatus => _huntStatus;

  /// The schedule of the account's hunt, when there is one.
  ///
  /// Null when the account has no hunt configuration, or when the schedule
  /// has not been worked out yet.
  HuntScheduleResult? huntScheduleFor(AccountId accountId) =>
      _huntSchedules[accountId];

  // --------------------------------------------------------------- loading

  /// Loads each account's hunt configuration.
  Future<void> loadConfigs() async {
    final store = configStore;
    if (store == null) return;

    for (final account in accounts()) {
      try {
        final config = await store.load(account.id);
        if (config != null) _huntConfigs[account.id] = config;
      } catch (_) {}
    }
  }

  /// Reloads all hunt configurations from persistent storage.
  ///
  /// Useful when resuming from background or after a headless hunt has
  /// executed.
  Future<void> reloadConfigs() async {
    final store = configStore;
    if (store == null) return;

    var changed = false;
    for (final account in accounts()) {
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
  Future<void> reloadConfig(AccountId accountId) async {
    final store = configStore;
    if (store == null) return;

    final config = await store.load(accountId);
    if (config != null) {
      _huntConfigs[accountId] = config;
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- selection

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

  // ------------------------------------------------------------- writes

  /// Saves the hunt configuration for a specific account.
  Future<void> saveConfigFor(AccountId accountId, HuntConfig config) async {
    _huntConfigs[accountId] = config;
    await configStore?.save(accountId, config);
    if (_activeHuntAccount == accountId) {
      _huntPreflightSummary = null;
      _huntPreflightRefusal = null;
      _huntEnableRefusal = null;
    }
    notifyListeners();
    onHuntConfigChanged?.call(accountId, config);
  }

  /// Saves the hunt configuration for the active account.
  Future<void> saveConfig(HuntConfig config) async {
    final accountId = _activeHuntAccount;
    if (accountId == null) return;
    await saveConfigFor(accountId, config);
  }

  /// Called after a hunt configuration changes, so the wake-up can be
  /// re-armed.
  ///
  /// The state owns the configuration; the platform owns the alarms. The
  /// platform layer sets this.
  void Function(AccountId accountId, HuntConfig config)? onHuntConfigChanged;

  // ---------------------------------------------------------------- verdict

  /// Records why the hunt could not be switched on, or clears it.
  void setEnableRefusal(String? refusal) {
    _huntEnableRefusal = refusal;
    notifyListeners();
  }

  /// Records the pre-flight verdict for the hunt.
  void setPreflight({String? summary, String? refusal}) {
    _huntPreflightSummary = summary;
    _huntPreflightRefusal = refusal;
    notifyListeners();
  }

  /// Records whether a hunt is running.
  void setRunning(bool value) {
    _huntRunning = value;
    if (!value) {
      _huntStatus = null;
    }
    notifyListeners();
  }

  /// Updates the live status of the running hunt.
  void setStatus(SnipeRunStatus? status) {
    _huntStatus = status;
    notifyListeners();
  }

  /// Records the schedule that was armed for an account.
  void setSchedule(AccountId accountId, HuntScheduleResult result) {
    _huntSchedules[accountId] = result;
    notifyListeners();
  }
}
