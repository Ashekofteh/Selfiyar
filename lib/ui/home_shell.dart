import 'package:flutter/material.dart';

import '../core/account.dart';
import '../core/hunt_config.dart';
import '../core/hunt_schedule.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/pending_request.dart';
import '../core/portal.dart';
import '../core/preflight.dart';
import '../core/service_calendar.dart';
import '../core/session.dart'
    show SessionNeedsCaptcha, SessionReady, SessionUnavailable;
import '../core/session_manager.dart'
    show PortalUnreachableException, SessionUnavailableException;
import '../core/time.dart';
import '../core/top_up.dart';
import '../platform/hunt_service.dart';
import '../platform/platform_services.dart';
import '../platform/portal_sync.dart';
import '../platform/reminder_delivery.dart';
import '../platform/reminder_service.dart';
import '../platform/app_update_service.dart';
import '../platform/reservation_service.dart' show ReservationFailure;
import 'app_state.dart';
import 'screens/accounts_screen.dart';
import 'screens/onboarding_sheet.dart';
import 'screens/booking_sheet.dart';
import 'screens/captcha_dialog.dart';
import 'screens/dashboard_screen.dart';
import 'screens/hunt_screen.dart';
import 'screens/reminders_screen.dart';
import 'screens/reservations_screen.dart';
import 'package:flutter/services.dart';
import 'screens/top_up_gateway_screen.dart';
import 'screens/top_up_sheet.dart';
import 'reservation_table_model.dart';

/// The app's navigation shell.
///
/// A bottom navigation bar rather than a drawer: the app has four destinations
/// and a student checks it a few times a day, so the bar keeps them one tap away
/// instead of behind a menu.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.state,
    required this.services,
  });

  final AppState state;

  /// The platform services, so the screens can reach the portal.
  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// Reads the portal for the saved accounts and refreshes the local mirror.
  late final PortalSync _sync;

  /// Delivers a fired reminder alarm.
  late final ReminderDelivery _delivery;

  @override
  void initState() {
    super.initState();

    _sync = PortalSync(
      client: widget.services.client,
      sessions: widget.services.sessions,
      mealStore: widget.services.mealStore.store,
      // The mirror is shared with the UI and the reminder service, so a
      // change has to be persisted and the screens have to redraw.
      persist: widget.services.mealStore.persist,
      onMealsChanged: widget.state.mealsChanged,
    );

    _delivery = ReminderDelivery(
      service: widget.services.reminders,
      accounts: widget.state.accounts,
      clock: widget.services.clock,
      // The nudge asks what an account does not hold, so it needs a live read
      // rather than the mirror: a cache cannot tell "not booked" from "not
      // read yet".
      readReservations: (accountId) => widget.services.sessions
          .withSession(
            accountId,
            (session) => widget.services.client.fetchReservations(session),
          ),
      persist: widget.services.mealStore.persist,
    );

    // A configuration change re-arms the alarms, so the alarms always match
    // the settings the user sees.
    widget.state.onReminderConfigChanged = (config) {
      widget.services.reminders
          .schedule(config, clock: widget.services.clock)
          .catchError((_) {});
    };

    // A hunt configuration change re-arms that account's wake-up, so the
    // promise the hunt screen makes — «این شکار ... هنگام بازه زمانی خود شروع
    // می‌شود» — is kept in step with the settings the student can see.
    //
    // The callback carries the account, because the alarm is per account.
    widget.state.onHuntConfigChanged = (accountId, config) {
      _armHunt(accountId, config);
    };

    // The platform can ask for a hunt, or report that a reminder alarm fired.
    widget.services.bridge.onHuntRequested((payload) {
      if (!mounted) return;
      if (payload == 'refresh') {
        refreshFromPortal();
        return;
      }
      if (ReminderService.slotFor(payload) != null ||
          payload == ReminderService.nudgePayload) {
        _onReminderFired(payload);
        return;
      }
      // Anything else is the platform asking for a hunt, and the payload
      // names the account. The request is answered only if that account's
      // hunt is switched on — a hunt the student turned off must not start
      // because an alarm fired.
      //
      // The payload is checked against the known accounts rather than
      // assumed: this handler also carries the reboot (a null payload) and
      // the deep link of a tapped notification (a URI), and neither names an
      // account to hunt for.
      if (payload == null) return;
      if (!widget.state.accounts.any((a) => a.id == payload)) return;
      _answerHuntRequest(payload);
    });

    // The alarms are armed from the configuration, so they exist as soon as
    // the app starts. A reminder that only works after the user has opened
    // the app once is not a reminder.
    //
    // **After the load, not on the first frame.** The configuration lives on
    // disk and is read asynchronously, so arming on the first frame would use
    // the *default* configuration — which names no accounts, so no alarm
    // would be set. The failure is silent: the app looks healthy and the
    // reminders never fire.
    //
    // Both orders are handled. The load may finish before this shell is
    // built, or after — and the app root starts the load without awaiting it,
    // so "after" is the normal cold-start order. The callback covers the
    // second, and the check below covers the first.
    widget.state.onLoaded = () {
      if (mounted) {
        _armReminders();
        _armHunts();
        _deliverPending();
        _answerPendingRequests();
        _refreshBalancesQuietly();
        _checkUpdatesQuietly();
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkFirstRunOnboarding();
      if (widget.state.isLoaded) {
        _armReminders();
        _armHunts();
        _deliverPending();
        _answerPendingRequests();
        _refreshBalancesQuietly();
        _checkUpdatesQuietly();
      }
    });
  }

  @override
  void dispose() {
    widget.state.onReminderConfigChanged = null;
    widget.state.onHuntConfigChanged = null;
    widget.state.onLoaded = null;
    super.dispose();
  }

  /// Reads every account's balance once, at launch, without a prompt.
  ///
  /// ## Why this is not [refreshFromPortal]
  ///
  /// The student asked for the balance to be fresh whenever they open the app
  /// — it is the figure they judge a hunt against, and a balance from three
  /// days ago is the figure the hunt's own pre-flight will contradict the
  /// moment it wakes. But a launched app is not a student looking at a dialog:
  /// if the portal wants a CAPTCHA, [refreshFromPortal] would open a modal
  /// over whatever screen the app started on.
  ///
  /// So this path never prompts. The session is asked for with no solver
  /// fallback — `SessionManager.sync` returns `needsCaptcha` rather than
  /// stopping for an answer — and a result that needs one is left alone: the
  /// balance stays as it was, the student's own refresh (which *does* ask) is
  /// how they answer it, and nothing is reported as an error. A quiet failure
  /// that leaves a stale figure is better than a modal the student did not
  /// ask for.
  ///
  /// ## Why it does not touch the syncing flag
  ///
  /// That flag drives the refresh button's spinner. A quiet read that never
  /// prompted must not make the button look busy — the student would read it
  /// as "a refresh is running" and wait for a result that is not coming.
  /// Shows onboarding guide on first launch for brand new users.
  Future<void> _checkFirstRunOnboarding() async {
    try {
      final seen = await widget.services.plainStore.readBool('onboarding_completed') ?? false;
      if (seen) return;

      // If user already has accounts saved, they are an existing user who upgraded.
      // Silently mark as completed so we do not disrupt their daily food booking.
      if (widget.state.accounts.isNotEmpty) {
        await widget.services.plainStore.writeBool('onboarding_completed', true);
        return;
      }

      if (mounted) {
        showOnboardingGuide(
          context,
          plainStore: widget.services.plainStore,
          isFirstLaunch: true,
        );
      }
    } catch (_) {}
  }

    /// Checks for application updates silently in the background.
  ///
  /// Adheres to standard 24-hour rate limits and never displays disruptive modal popups.
  /// If a new version is available, it illuminates a subtle badge on the About icon.
  Future<void> _checkUpdatesQuietly() async {
    try {
      final result = await widget.services.updates.checkForUpdates(force: false);
      if (mounted && result.status == AppUpdateStatus.updateAvailable) {
        widget.state.setHasAvailableUpdate(true);
      }
    } catch (_) {
      // Quiet background check: never throw or disrupt the user
    }
  }

    Future<void> _refreshBalancesQuietly() async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final transactions = <Transaction>[];
    var allRead = true;

    for (final account in accounts) {
      if (!mounted) return;
      final result = await _sync.sync(account.id);
      if (!mounted) return;

      if (result.ok) {
        widget.state.setBalance(account.id, result.balanceRial ?? 0);
        if (result.profileName != null && result.profileName!.trim().isNotEmpty) {
          await widget.state.setProfileName(account.id, result.profileName!.trim());
        }
        transactions.addAll(result.transactions);
      } else {
        // A CAPTCHA was needed, or the read failed. The student is not being
        // asked, so this account is left as it was — and the transactions are
        // not recomputed, because a partial set would silently drop this
        // account's spending from the dashboard.
        allRead = false;
      }
    }

    // The dashboard's spend metric is computed from the transactions the sync
    // read. They are recorded only when **every** account was read, so a
    // skipped account cannot erase spending the app already knew about.
    if (allRead) widget.state.setTransactions(transactions);
  }

  /// Fetches the fresh balance for [accountId] directly from the portal and
  /// updates [widget.state], keeping the reservations header and accounts
  /// screen in exact sync.
  Future<void> _fetchAccountBalance(AccountId accountId) async {
    try {
      final balance = await widget.services.sessions.withSession(
        accountId,
        (session) => widget.services.client.fetchBalance(session),
      );
      if (mounted) {
        widget.state.setBalance(accountId, balance.amountRial);
        if (balance.profileName != null && balance.profileName!.trim().isNotEmpty) {
          await widget.state.setProfileName(accountId, balance.profileName!.trim());
        }
      }
    } catch (_) {
      try {
        final syncResult = await _sync.sync(accountId);
        if (syncResult.ok && mounted && syncResult.balanceRial != null) {
          widget.state.setBalance(accountId, syncResult.balanceRial!);
        }
      } catch (_) {}
    }
  }

  /// Arms the wake-up for every account that has a hunt.
  ///
  /// The alarm is derived from the configuration, so it is armed on **load**
  /// as well as on change: a hunt that was set up yesterday must still start
  /// by itself today, with the app closed and never opened since. And a
  /// reboot clears every alarm, so the re-arm after a reboot is the same
  /// call.
  Future<void> _armHunts() async {
    for (final account in widget.state.accounts) {
      final config = widget.state.huntConfigFor(account.id);
      if (config == null) continue;
      await _armHunt(account.id, config);
    }
  }

  /// Arms the wake-up for one account's hunt, and records the schedule.
  ///
  /// The result is recorded so the hunt screen can say **when** the hunt will
  /// start. A card that claims the hunt starts by itself, without saying
  /// when, is a claim the student cannot check — and the whole point of the
  /// switch is that they can.
  Future<void> _armHunt(AccountId accountId, HuntConfig config) async {
    try {
      final result = await widget.services.huntSchedule.arm(
        accountId: accountId,
        config: config,
        clock: widget.services.clock,
      );
      if (!mounted) return;
      widget.state.setHuntSchedule(accountId, result);
    } catch (_) {
      // The platform may not be ready, or the exact-alarm permission may not
      // be granted. The hunt screen states the permission situation, and a
      // failed arm must not take the app down with it.
    }
  }

  /// Answers the requests the platform made while the app was not running.
  ///
  /// ## Why this exists
  ///
  /// The platform can ask the Dart side to do things at moments when there is
  /// no Dart side to ask. A **hunt** wake-up fires from an alarm, and a
  /// **reboot** fires from `BootReceiver` — and at boot the process is by
  /// definition dead, so the reboot's signal could never arrive even in
  /// principle. Both were delivered through a channel that only exists while
  /// the activity is alive, so both were lost: the service started, posted
  /// its notification, and told nobody.
  ///
  /// The native side records them now, and this picks them up.
  ///
  /// ## The re-arm comes first
  ///
  /// The alarms are cleared by a reboot, so the re-arm is the request that
  /// must not be lost. And it is cheap — it needs no network and no session.
  /// The hunt is answered afterwards, and only if its account's configuration
  /// says the hunt is switched on: a hunt the student turned off must not be
  /// started by a wake-up they did not ask for.
  Future<void> _answerPendingRequests() async {
    final bridge = widget.services.bridge;

    List<String> entries;
    try {
      entries = await bridge.pendingRequests();
    } catch (_) {
      return;
    }
    if (entries.isEmpty) return;

    final answered = <String>[];

    for (final entry in entries) {
      final request = PendingRequest.parse(entry);
      if (request == null) continue;

      switch (request.kind) {
        case PendingRequestKind.rearm:
          // The alarms were cleared by the reboot; arm them again.
          await _armReminders();
          await _armHunts();
          answered.add(entry);

        case PendingRequestKind.hunt:
          if (await _answerHuntRequest(request.payload!)) {
            answered.add(entry);
          }
      }
    }

    // Only what was answered is cleared, so a request that was recorded and
    // then could not be carried out stays owed.
    if (answered.isEmpty) return;
    try {
      await bridge.clearPendingRequests(answered);
    } catch (_) {
      // A duplicate answer is better than a lost one.
    }
  }

  /// Starts the hunt the platform asked for.
  ///
  /// Returns whether the hunt was started. A request for an account with no
  /// hunt configuration, or with the hunt switched off, is **not** answered:
  /// there is nothing to start, and clearing the request would lose the fact
  /// that the platform asked.
  ///
  /// ## The record is cleared once the hunt is under way
  ///
  /// The native side records a hunt request **before** it looks for a Dart
  /// side, because it cannot know whether one will be there — that is the
  /// F75 safety net, and it is why a hunt survives the app dying between the
  /// alarm and the hand-over.
  ///
  /// So the record outlives the hand-over, and something has to clear it. If
  /// nothing did, the next launch would read the record and start the hunt a
  /// **second** time, for an account that has already been hunted — and
  /// because the two runs are separate, nothing would notice.
  ///
  /// So the side that acts clears the record. The headless engine does the
  /// same thing in the background entrypoint: the rule is the same, and both
  /// paths clear only their own account's entry.
  Future<bool> _answerHuntRequest(AccountId accountId) async {
    final config = widget.state.huntConfigFor(accountId);
    if (config == null) return false;
    if (!config.enabled) return false;

    final started = await _startHunt(accountId, config);

    if (!started) {
      // The pre-flight refused, or the screen went away. The platform's
      // foreground service is standing with nothing behind it, so it is
      // released here — the same rule the headless path follows, where the
      // service stops rather than sit on screen claiming to watch the basket.
      //
      // The record is left owed: the platform asked, and the answer was no.
      // Clearing it would lose the fact that a wake-up was missed, and the
      // next launch should try again once the reason is fixed.
      await _releaseHuntService();
      return false;
    }

    await _clearPendingHuntRequest(accountId);

    return true;
  }

  /// Clears the recorded hunt request for [accountId].
  ///
  /// A failure to clear is not worth failing the hunt over: the hunt has
  /// started, and a leftover record would only make the *next* launch repeat
  /// it — which is worse, but not as bad as not hunting at all.
  Future<void> _clearPendingHuntRequest(AccountId accountId) async {
    try {
      await widget.services.bridge.clearPendingRequests(
        [PendingRequest.hunt(accountId).entry],
      );
    } catch (_) {
      // A duplicate hunt is better than a lost one.
    }
  }

  /// Arms the reminder alarms for the current configuration.
  Future<void> _armReminders() async {
    try {
      await widget.services.reminders.schedule(
        widget.state.reminderConfig,
        clock: widget.services.clock,
      );
    } catch (_) {
      // The platform may not be ready, or the exact-alarm permission may not
      // be granted. The reminder screen states the permission situation, and a
      // failed arm must not take the app down with it.
    }
  }

  /// Delivers the reminders that were owed while the app was not running.
  ///
  /// The alarm fires when the app may not be running, and the digest is
  /// composed in Dart — so when the process was dead the alarm fired into
  /// nothing and the reminder was lost without a sound. The native side
  /// records the delivery, and this delivers it.
  ///
  /// It runs after the configuration is loaded, because the digest is
  /// composed against the configuration: delivering against the *default*
  /// configuration would name no accounts and say nothing, which is the same
  /// silence the bug produced.
  Future<void> _deliverPending() async {
    final bridge = widget.services.bridge;
    List<String> pending;
    try {
      pending = await bridge.pendingDeliveries();
    } catch (_) {
      return;
    }
    if (pending.isEmpty) return;

    _delivery
      ..config = widget.state.reminderConfig
      ..accounts = widget.state.accounts;

    final delivered = await _delivery.deliverPending(pending);

    // Only what was actually delivered is cleared. A delivery that failed
    // stays owed, so it is not lost by a transient failure.
    if (delivered.isNotEmpty) {
      try {
        await bridge.clearPendingDeliveries(delivered);
      } catch (_) {
        // The record is cleared on the next successful delivery anyway: a
        // duplicate digest is better than a lost one.
      }
    }
  }

  /// Delivers a reminder whose alarm fired.
  Future<void> _onReminderFired(String? payload) async {
    _delivery
      ..config = widget.state.reminderConfig
      ..accounts = widget.state.accounts;
    await _delivery.handleFire(payload);

    // The receiver records the payload before handing it over, so a live
    // fire has already left a copy of it owed. That copy is cleared here:
    // the digest has been delivered, and the next launch must not deliver it
    // a second time.
    if (payload == null) return;
    try {
      await widget.services.bridge.clearPendingDeliveries([payload]);
    } catch (_) {
      // A duplicate digest is better than a lost one.
    }
  }

  /// Reads the menu's dishes and halls for the hunt screen.
  ///
  /// The dishes and the halls come from the **official weekly menu**
  /// (`Reservation.aspx`), not from the marketplace (`FoodBasketBuy.aspx`).
  ///
  /// ## Why the menu and not the marketplace
  ///
  /// The portal answers two different questions with two different pages:
  ///
  ///  * the **weekly menu** names the halls that *serve* a meal, and the
  ///    dishes the university offers for it;
  ///  * the **buy page** names the halls that have *released* a meal into the
  ///    marketplace.
  ///
  /// The marketplace's hall list is a strict **subset** of the menu's: a
  /// hall appears there only once one of its students has released that
  /// meal. A list built from the marketplace therefore hides every hall that
  /// has not yet released anything — and a hall that has not released
  /// anything *yet* is exactly the one a hunt needs to be able to name,
  /// because the market fills up **during** the hunt window. A "prefer
  /// Central, fall back to Engineering" hunt that could not name Engineering
  /// would never use the fallback.
  ///
  /// The marketplace remains the source of **listings** — that is where a
  /// hunt's matching and claiming happen — and only there.
  ///
  /// The read is for the hunt's **target date**, because the menu is a
  /// per-date view: the portal publishes a different set of dishes every day.
  /// A hunt for tomorrow's dinner must show tomorrow's menu, not today's.
  ///
  /// The read **establishes a session** rather than reusing one that happens
  /// to be lying around. A hunt screen opened on a cold start would otherwise
  /// show an empty menu, and an empty menu looks exactly like a menu with
  /// nothing on it — a message the user would read as "no food that day"
  /// rather than "the app could not reach the portal".
  Future<void> loadMarket({DateTime? date}) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId = accounts.first.id;
    final targetDate = date ?? _currentHuntConfig?.targetDate ?? _defaultHuntTargetDate();

    // Remember what this read is for, so a later change of target knows the
    // list on screen is stale.
    _marketFor = _currentHuntConfig;


    try {
      final menus = await widget.services.sessions.withSession(
        accountId,
        (session) => widget.services.client.fetchMenu(session, targetDate),
      );
      if (!mounted) return;

      // The menu is read once per **date**, not per (date, slot): the page
      // carries all three meals for the day. So switching the meal slot
      // re-reads nothing — the other slots' halls and dishes are already
      // here.
      _applyMenu(menus);
    } on SessionUnavailableException catch (e) {
      _reportMarketError(e.reason);
    } on PortalUnreachableException catch (e) {
      // The portal could not be reached, and it says why. Swallowing that
      // would tell the user the menu is empty, when the truth is that the app
      // never reached the portal.
      _reportMarketError('ارتباط با سامانه برقرار نشد: ${e.message}');
    } catch (e) {
      _reportMarketError('خواندن منوی غذا از سامانه ممکن نشد.');
    }
  }

  /// Records a failed menu read, so the screen says why it is empty.
  void _reportMarketError(String message) {
    if (!mounted) return;
    setState(() {
      _marketDishes = const [];
      _marketHalls = const [];
      _menus = null;
      _marketError = message;
    });
  }

  /// Reads every account's balance and reservations from the portal.
  ///
  /// Explicit, and never a background poll: every request is a request
  /// pattern, and the portal is a shared resource.
  Future<void> refreshFromPortal() async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    widget.state.setSyncing(true);
    try {
      final transactions = <Transaction>[];
      for (final account in accounts) {
        final result = await _readAccount(account.id);
        if (!mounted) return;

        if (result.ok) {
          widget.state.setBalance(account.id, result.balanceRial ?? 0);
          if (result.profileName != null && result.profileName!.trim().isNotEmpty) {
            await widget.state.setProfileName(account.id, result.profileName!.trim());
          }
          transactions.addAll(result.transactions);
        } else {
          widget.state.setSyncError(account.id, result.error ?? 'خطای نامشخص');
        }
      }
      // The dashboard's spend metric is computed from the ledger, so it needs
      // the transactions the sync just read. Without them the chart was
      // permanently empty, whatever the portal said.
      widget.state.setTransactions(transactions);
    } finally {
      if (mounted) widget.state.setSyncing(false);
    }
  }

  /// Reads one account, asking the student for the CAPTCHA when it is needed.
  ///
  /// ## Why the answer is asked for twice
  ///
  /// The solver declined, so the student was asked and gave an answer. The
  /// login then succeeded — and the read that followed was **bounced** by the
  /// portal, because the session had been replaced while the student was
  /// reading. The read is retried with a fresh login, and that fresh login
  /// needs a CAPTCHA again.
  ///
  /// So a second question is legitimate, and the loop here handles it. The
  /// loop is bounded: the student can cancel, and a refusal ends it.
  ///
  /// ## Why the reported error is the last one
  ///
  /// The first sync's error says the solver could not read the code. That is
  /// true, and it is **no longer what happened** once the student answered.
  /// Reporting it would blame the app's own reader for a failure that came
  /// after the student did their part. So the error that reaches the screen
  /// is the one from the last attempt — the one that describes where things
  /// actually stopped.
  Future<AccountSyncResult> _readAccount(AccountId accountId) async {
    var result = await _sync.sync(accountId);
    if (!mounted) return result;

    // The solver declined and the portal wants the student to read the
    // CAPTCHA. That is not a dead end — it is a question — so the
    // student is asked, and the account is read again with their answer.
    var challenge = result.needsCaptcha;
    while (challenge != null) {
      final outcome = await _askForCaptcha(challenge);
      if (!mounted) return result;

      if (outcome.declined) {
        // The student gave up. The first error is the truthful one: the code
        // was never read.
        return result;
      }

      if (outcome.refusalReason != null) {
        // The portal refused the answer, and it said why. That reason is the
        // one the student can act on — a wrong password, or a portal that
        // could not be reached — so it is the one that is reported.
        return AccountSyncResult(
          accountId: accountId,
          ok: false,
          error: outcome.refusalReason,
        );
      }

      // The session is now live, so the read goes through.
      result = await _sync.sync(accountId);
      if (!mounted) return result;
      challenge = result.needsCaptcha;
    }

    return result;
  }

  /// Asks the student to read the CAPTCHA, and logs in with their answer.
  ///
  /// ## Why the outcome is not a bool
  ///
  /// Three things can happen, and they need different endings:
  ///
  ///  * the student **cancelled** — the app must not trap them in a dialog
  ///    they cannot leave, and the truthful report is the one that says the
  ///    code was never read;
  ///  * the portal **refused** the answer — the portal says why, and that
  ///    reason is the one the student can act on;
  ///  * the portal **rotated** the challenge — a fresh image comes back and
  ///    the student is asked again.
  ///
  /// A bool collapses the first two into "failed", and then the screen
  /// reports the *first* error — which blames the app's own reader for
  /// something that happened after the student did their part. That is what
  /// the device showed: «کد امنیتی به‌صورت خودکار خوانده نشد.» after a
  /// correct answer, with the real reason discarded.
  Future<_CaptchaOutcome> _askForCaptcha(SessionNeedsCaptcha challenge) async {
    final answer = await CaptchaDialog.show(
      context,
      imageBytes: challenge.imageBytes,
      previousAttempts: challenge.previousAttempts,
    );
    if (answer == null) return const _CaptchaOutcome.declined();

    // The session the image was fetched in is passed with the answer: the
    // portal judges the answer against that session, and it mints a new one
    // whenever it renders the login page. So an answer posted in the wrong
    // session is refused however correct the digits are.
    final result = await widget.services.sessions.loginWithCaptcha(
      challenge.accountId,
      answer,
      sessionId: challenge.sessionId,
    );

    if (result is SessionReady) return const _CaptchaOutcome.accepted();

    // A refused answer brings a **fresh** challenge, because the portal has
    // rotated the one the student answered. Showing the old image again
    // would invite the same wrong answer.
    if (result is SessionNeedsCaptcha) {
      if (!mounted) return const _CaptchaOutcome.declined();
      return _askForCaptcha(result);
    }

    // A plain refusal — a wrong password, or the portal unreachable. The
    // student has to fix that, and the sync reports it.
    return _CaptchaOutcome.refused(
      (result as SessionUnavailable).reason,
    );
  }

  /// Opens the booking screen, with the menu for the targetable dates.
  ///
  /// The menu is read for the whole week at once, because the weekly page
  /// carries a whole week of grids. Reading a page per date would mean
  /// seven reads — and fourteen once the week boundary is crossed — for a
  /// question one read answers.
  ///
  /// The read is also what fills the **table**: the reservations screen shows
  /// every meal that can still be acted on, and the menu is what says which
  /// of those are bookable.
  Future<void> _refreshTable({bool quiet = false, AccountId? targetAccount}) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId = targetAccount ??
        widget.state.selectedReservationsAccountId ??
        accounts.first.id;

    if (!quiet) widget.state.setSyncing(true);
    BookableMenus read = const BookableMenus(dates: [], menus: []);
    Object? failure;
    try {
      read = await widget.services.sessions.withSession(
        accountId,
        (session) => widget.services.client.fetchBookableMenus(session),
      );
    } catch (error) {
      failure = error;
    }

    try {
      final syncResult = quiet
          ? await _sync.sync(accountId)
          : await _readAccount(accountId);
      if (syncResult.ok) {
        widget.state.setBalance(accountId, syncResult.balanceRial ?? 0);
        if (syncResult.profileName != null && syncResult.profileName!.trim().isNotEmpty) {
          await widget.state.setProfileName(accountId, syncResult.profileName!.trim());
        }
        widget.state.updateTransactionsForAccount(accountId, syncResult.transactions);
      }
    } catch (_) {}

    await widget.services.mealStore.persist();
    widget.state.mealsChanged();

    if (mounted && !quiet) widget.state.setSyncing(false);
    if (!mounted) return;

    if (read.menus.isNotEmpty) {
      setState(() {
        _tableMenus = read.menus;
      });
    }

    if (!quiet && (failure != null || read.menus.isEmpty)) {
      if (failure != null) {
        _showBookingProblem(
          'ارتباط با سامانه برقرار نشد. اتصال را بررسی کنید و دوباره تلاش '
          'کنید.',
        );
      } else if (!widget.services.clock.isSynced) {
        _showBookingProblem(
          'ساعت سرور همگام نشد. اتصال سامانه را بررسی کنید و دوباره تلاش '
          'کنید.',
        );
      } else {
        _showBookingProblem('هنوز تاریخی برای رزرو در دسترس نیست.');
      }
    }
  }

  /// The menu the reservations table is drawn from.
  List<MealMenu> _tableMenus = const [];

  /// The (date, slot) an action is in flight for.
  String? _busyKey;

  /// Pending reservations waiting for payment completion.
  AccountId? _pendingBookingsAccount;
  List<MealOffering>? _pendingOfferingsToBook;

  /// Pending hunt activation waiting for payment completion.
  AccountId? _pendingHuntAccount;
  HuntConfig? _pendingHuntConfig;

  /// Opens the booking sheet for a (date, slot) the student tapped.
  Future<void> _bookMeal(DateTime date, MealSlot slot) async {
    MealMenu? menu;
    for (final candidate in _tableMenus) {
      if (candidate.date.year == date.year &&
          candidate.date.month == date.month &&
          candidate.date.day == date.day &&
          candidate.slot == slot) {
        menu = candidate;
        break;
      }
    }
    final accountId = widget.state.selectedReservationsAccountId ??
        (widget.state.accounts.isEmpty
            ? null
            : widget.state.accounts.first.id);
    if (menu == null && mounted) {
      await _refreshTable(quiet: true, targetAccount: accountId);
      for (final candidate in _tableMenus) {
        if (candidate.date.year == date.year &&
            candidate.date.month == date.month &&
            candidate.date.day == date.day &&
            candidate.slot == slot) {
          menu = candidate;
          break;
        }
      }
    }
    if (menu == null) return;
    if (accountId == null) return;

    final currentBalance = widget.state.balanceFor(accountId);
    final account = widget.state.accountFor(accountId);
    if (!mounted) return;

    await BookingSheet.show(
      context,
      menu: menu,
      accountName: account?.resolvedName,
      currentBalanceRial: currentBalance,
      onTopUp: (deficit) => _startTopUpFor(accountId, suggestedAmountRial: deficit),
      onBook: (offering) => _book(accountId, offering),
    );
  }

  /// Books an offering, and reports the outcome.
  Future<String?> _book(AccountId accountId, MealOffering offering) async {
    setState(() {
      _busyKey = '${offering.date.year}-${offering.date.month}-'
          '${offering.date.day}|${offering.slot.name}';
    });

    final outcome = await widget.services.reservations.reserve(
      accountId: accountId,
      offering: offering,
    );

    if (!mounted) return outcome.message;

    setState(() {
      _busyKey = null;
    });

    // The portal is the authority for what is held, so the mirror is read
    // back rather than patched locally. A booking that the portal accepted
    // but the mirror missed would show the student an empty reservations
    // screen, and a booking that failed would show a meal they do not have.
    await widget.services.mealStore.persist();
    widget.state.mealsChanged();
    if (outcome.succeeded) {
      final current = widget.state.balanceFor(accountId);
      if (current != null) {
        final price = outcome.reservation?.option.priceRial ?? offering.option.priceRial;
        final next = current - price;
        widget.state.setBalance(accountId, next > 0 ? next : 0);
      }
      _fetchAccountBalance(accountId);
      _refreshTable(quiet: true, targetAccount: accountId);
    }

    if (!mounted) return outcome.message;

    if (outcome.failure == ReservationFailure.insufficientFunds) {
      final deficit = outcome.deficitRial ?? offering.option.priceRial;
      final goToTopUp = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('کمبود موجودی حساب'),
          content: Text(
            'موجودی حساب شما برای رزرو این غذا کافی نیست.\n'
            'کسری موجودی: ${formatTomanPersian(deficit)}\n\n'
            'آیا مایلید برای افزایش اعتبار به صفحه پرداخت هدایت شوید؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('افزایش موجودی'),
            ),
          ],
        ),
      );

      if (goToTopUp == true && mounted) {
        _pendingBookingsAccount = accountId;
        _pendingOfferingsToBook = [offering];
        await _startTopUpFor(accountId, suggestedAmountRial: deficit);
      }
      return outcome.message;
    }

    if (!outcome.succeeded) {
      _showBookingProblem(outcome.message ?? 'رزرو انجام نشد.');
    }

    return outcome.message;
  }

  /// Starts a top-up for an account.
  ///
  /// ## The order of the steps
  ///
  /// 1. Read the top-up page: the balance, and the banks that work.
  /// 2. Show the sheet, where the amount is checked against the portal's
  ///    bounds — the portal's own refusal is silent (F56), so the app is the
  ///    only place the student can be told.
  /// 3. Mint the gateway token and open the bank's page in a WebView.
  /// 4. When the gateway returns to the portal, re-read the payment list and
  ///    the balance, and say what happened.
  Future<void> _startTopUp(SavedAccount account, {int? suggestedAmountRial}) async {
    final page = await widget.services.topUp.page(account.id);

    if (!mounted) return;

    if (page == null) {
      _showBookingProblem(
        'ارتباط با سامانه برقرار نشد. اتصال را بررسی کنید و دوباره تلاش '
        'کنید.',
      );
      return;
    }

    if (page.banks.isEmpty) {
      _showBookingProblem('درگاه پرداختی برای افزایش اعتبار در دسترس نیست.');
      return;
    }

    // The banks that work. The portal lists one that is not configured and
    // errors when it is used (F57), so it is not offered.
    final banks = _workingBanks(page.banks);

    if (banks.isEmpty) {
      _showBookingProblem('درگاه پرداختی برای افزایش اعتبار در دسترس نیست.');
      return;
    }

    var amountRial = 0;

    await TopUpSheet.show(
      context,
      balanceRial: page.balanceRial,
      banks: banks,
      suggestedAmounts: _topUpSuggestions(),
      initialAmountRial: suggestedAmountRial,
      savedCards: widget.state.savedBankCards,
      onSubmit: (amount, bank) async {
        amountRial = amount;
        return _beginTopUp(account, amount, bank);
      },
    );

    // The sheet closed. If the student got as far as the gateway, the
    // payment is settled when the gateway returns — which the gateway
    // screen reports back.
    if (amountRial == 0 || !mounted) {
      _pendingBookingsAccount = null;
      _pendingOfferingsToBook = null;
      _pendingHuntAccount = null;
      _pendingHuntConfig = null;
      return;
    }
  }

  /// The banks that actually work.
  ///
  /// The portal's second bank is not configured on the university's side and
  /// answers with a server error when it is used (F57). Offering it would
  /// be offering a button that cannot work, so it is dropped.
  List<TopUpBank> _workingBanks(List<TopUpBank> banks) {
    if (banks.length <= 1) return banks;

    // The first bank is the one the portal's own confirmation page proves
    // works; the rest are dropped.
    return [banks.first];
  }

  /// The amounts offered as one-tap chips.
  ///
  /// The meal prices, because the top-up is almost always about covering
  /// meals: a breakfast is 150,000 Rial and a lunch 350,000.
  List<int> _topUpSuggestions() => const [150000, 350000, 500000, 1000000];

  /// Mints the gateway token and opens the bank's page.
  Future<String?> _beginTopUp(
    SavedAccount account,
    int amountRial,
    TopUpBank bank,
  ) async {
    final outcome = await widget.services.topUp.begin(
      accountId: account.id,
      amountRial: amountRial,
      bank: bank,
    );

    if (!mounted) return outcome.message;

    if (!outcome.succeeded) {
      return outcome.message ?? 'افزایش اعتبار انجام نشد.';
    }

    final gateway = outcome.gateway!;
    final cookies = await widget.services.sessions.cookiesFor(account.id);

    if (!mounted) return null;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TopUpGatewayScreen(
          gateway: gateway,
          cookies: cookies,
          portalHost: Uri.parse(portalBaseUrl).host,
          savedCards: widget.state.savedBankCards,
          onSaveCard: widget.state.saveBankCard,
          onDeleteCard: widget.state.deleteBankCard,
          onReturned: () => _settleTopUp(account, amountRial),
        ),
      ),
    );

    if (mounted) {
      await _settleTopUp(account, amountRial);
    }
    return null;
  }

  /// Reads back what the portal says about the payment.
  Future<void> _settleTopUp(SavedAccount account, int amountRial) async {
    final report = await widget.services.topUp.settle(
      accountId: account.id,
      amountRial: amountRial,
    );

    if (!mounted) return;

    if (report.balanceRial != null) {
      widget.state.setBalance(account.id, report.balanceRial!);
    }

    final matched = report.matched;

    if (matched == null || !matched.status.isPaid) {
      _showTopUpPendingDialog(account, amountRial);
      return;
    }

    if (matched.status.isPaid) {
      // 1. Auto-arm pending hunt if payment was triggered from hunt deficit
      if (_pendingHuntAccount == account.id && _pendingHuntConfig != null) {
        final config = _pendingHuntConfig!;
        _pendingHuntAccount = null;
        _pendingHuntConfig = null;

        final armed = config.copyWith(enabled: true);
        await widget.state.saveHuntConfig(armed);
        _armHunt(account.id, armed);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'پرداخت با موفقیت انجام شد و سیستم شکار به طور خودکار فعال شد.',
              ),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }
        return;
      }

      // 2. Auto-reserve pending offerings if payment was triggered from reservation deficit
      if (_pendingBookingsAccount == account.id &&
          _pendingOfferingsToBook != null &&
          _pendingOfferingsToBook!.isNotEmpty) {
        final offerings = List.of(_pendingOfferingsToBook!);
        _pendingBookingsAccount = null;
        _pendingOfferingsToBook = null;

        var bookedCount = 0;
        for (final offering in offerings) {
          final outcome = await widget.services.reservations.reserve(
            accountId: account.id,
            offering: offering,
          );
          if (outcome.succeeded) {
            bookedCount++;
            final price = outcome.reservation?.option.priceRial ?? offering.option.priceRial;
            final current = widget.state.balanceFor(account.id);
            if (current != null) {
              final next = current - price;
              widget.state.setBalance(account.id, next > 0 ? next : 0);
            }
          }
        }
        await widget.services.mealStore.persist();
        widget.state.mealsChanged();
        if (bookedCount > 0) {
          _fetchAccountBalance(account.id);
          _refreshTable(quiet: true, targetAccount: account.id);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'پرداخت با موفقیت انجام شد و ${toPersianDigits(bookedCount)} وعده به طور خودکار رزرو شدند.',
              ),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }
        return;
      }

      _showBookingProblem(
        'پرداخت با موفقیت انجام شد و اعتبار حساب افزایش یافت.',
      );
      return;
    }

    if (matched.status.isPending) {
      _showBookingProblem(
        'پرداخت ثبت شد و در انتظار تأیید بانک است. کمی بعد بررسی کنید.',
      );
      return;
    }

    _showBookingProblem(
      matched.message ?? 'پرداخت انجام نشد. دوباره تلاش کنید.',
    );
  }

  void _showTopUpPendingDialog(SavedAccount account, int amountRial) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.info_outline, size: 36, color: Colors.orange),
        title: const Text('وضعیت پرداخت اینترنتی'),
        content: const Text(
          'در صورتی که مبلغ از کارت شما کسر شده اما هنوز در سامانه دانشگاه ثبت نشده است، نگران نباشید:\n\n'
          '۱. تأیید بانکی در سامانه دانشگاه ممکن است چند دقیقه طول بکشد. می‌توانید با دکمه «استعلام مجدد» وضعیت را دوباره بررسی کنید.\n\n'
          '۲. طبق قوانین شبکه شاپرک، هرگونه مبلغ کسرشده‌ای که به دلیل اختلال شبکه در سامانه ثبت نگردد، حداکثر ظرف ۷۲ ساعت (معمولاً چند ساعت) به صورت خودکار به همان کارت بانکی بازگشت داده می‌شود.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('متوجه شدم'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _settleTopUp(account, amountRial);
            },
            icon: const Icon(Icons.refresh),
            label: const Text('استعلام مجدد'),
          ),
        ],
      ),
    );
  }

  /// Cancels a held meal.
  Future<void> _cancelMeal(DateTime date, MealSlot slot) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId =
        widget.state.selectedReservationsAccountId ?? accounts.first.id;

    final held = widget.state.mealStore.find(accountId, date, slot);
    int? refundPrice = held?.priceRial;
    if (refundPrice == null) {
      for (final menu in _tableMenus) {
        if (menu.date.year == date.year &&
            menu.date.month == date.month &&
            menu.date.day == date.day &&
            menu.slot == slot) {
          if (menu.dishes.isNotEmpty) {
            refundPrice = menu.dishes.first.priceRial;
          }
          break;
        }
      }
    }

    setState(() {
      _busyKey = '${date.year}-${date.month}-${date.day}|${slot.name}';
    });

    final outcome = await widget.services.reservations.cancel(
      accountId: accountId,
      date: date,
      slot: slot,
    );

    if (!mounted) return;

    setState(() {
      _busyKey = null;
    });

    await widget.services.mealStore.persist();
    widget.state.mealsChanged();

    // The three outcomes are told apart, because they call for different
    // things from the student (F63).
    //
    // A **refusal** is the portal's rule, not a fault: the date has locked,
    // so the meal cannot be given back. The meal is still held, and the row
    // says so — nothing was lost, and nothing needs doing.
    switch (outcome) {
      case CancelSucceeded():
        final current = widget.state.balanceFor(accountId);
        if (current != null && refundPrice != null) {
          widget.state.setBalance(accountId, current + refundPrice);
        }
        _fetchAccountBalance(accountId);
        _refreshTable(quiet: true, targetAccount: accountId);
        _showBookingProblem('رزرو لغو شد.');
      case CancelRefused(reason: final reason):
        _showBookingProblem(reason);
      case CancelAmbiguous():
        _showBookingProblem(
          'لغو انجام شد ولی تایید نشد. به‌روزرسانی بزنید تا وضعیت رزرو '
          'مشخص شود.',
        );
    }
  }

  Future<void> _sellMeal(DateTime date, MealSlot slot) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId =
        widget.state.selectedReservationsAccountId ?? accounts.first.id;

    if (isMealDistributionPassed(date, slot, clock: widget.services.clock)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('مهلت توزیع و فروش این وعده در سبد غذایی به پایان رسیده است.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فروش در سبد غذایی'),
        content: const Text(
          'آیا مایلید این وعده را در سبد غذایی برای فروش بگذارید؟\n\n'
          'توجه: پس از ثبت در سبد، تا زمانی که غذا توسط شخص دیگری خریداری نشده باشد، می‌توانید آن را از سبد فروش خارج کنید.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('فروش در سبد'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _busyKey = '${date.year}-${date.month}-${date.day}|${slot.name}';
    });

    final outcome = await widget.services.reservations.listForSale(
      accountId: accountId,
      date: date,
      slot: slot,
    );

    if (!mounted) return;

    setState(() {
      _busyKey = null;
    });

    switch (outcome) {
      case SaleListingSucceeded(message: final message):
        widget.state.markListedInBasket(accountId, date, slot);
        _showBookingProblem(
          message ?? 'غذا با موفقیت در سبد غذایی برای فروش قرار گرفت.',
        );
        _refreshTable(targetAccount: accountId);
      case SaleListingRefused(reason: final reason):
        _showBookingProblem(reason);
      case SaleListingAmbiguous():
        _showBookingProblem(
          'ثبت در سبد انجام شد ولی تایید نشد. وضعیت را در سایت بررسی کنید.',
        );
    }
  }

  Future<void> _removeFromSell(DateTime date, MealSlot slot) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId =
        widget.state.selectedReservationsAccountId ?? accounts.first.id;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف از سبد فروش'),
        content: const Text(
          'آیا مایلید این وعده را از سبد فروش خارج کنید و به رزروهای عادی خود بازگردانید؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف از سبد'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _busyKey = '${date.year}-${date.month}-${date.day}|${slot.name}';
    });

    final outcome = await widget.services.reservations.removeFromSale(
      accountId: accountId,
      date: date,
      slot: slot,
    );

    if (!mounted) return;

    setState(() {
      _busyKey = null;
    });

    switch (outcome) {
      case SaleListingSucceeded(message: final message):
        widget.state.unmarkListedInBasket(accountId, date, slot);
        _showBookingProblem(
          message ?? 'غذا با موفقیت از سبد فروش خارج شد.',
        );
        _refreshTable(targetAccount: accountId);
      case SaleListingRefused(reason: final reason):
        if (reason.contains('فروخته') || reason.contains('یافت نشد')) {
          widget.state.unmarkListedInBasket(accountId, date, slot);
          _refreshTable(targetAccount: accountId);
        }
        _showBookingProblem(reason);
      case SaleListingAmbiguous():
        widget.state.unmarkListedInBasket(accountId, date, slot);
        _showBookingProblem(
          'عملیات حذف در سامانه انجام شد. لطفاً وضعیت را مجدداً بررسی فرمایید.',
        );
        _refreshTable(targetAccount: accountId);
    }
  }

  /// Books multiple offerings in sequence.
  Future<void> _batchBook(AccountId accountId, List<MealRow> rows) async {
    setState(() => _busyKey = 'batch');
    int succeeded = 0;
    int failed = 0;
    String? lastError;

    for (final row in rows) {
      MealMenu? matchingMenu;
      for (final m in _tableMenus) {
        if (m.date.year == row.date.year &&
            m.date.month == row.date.month &&
            m.date.day == row.date.day &&
            m.slot == row.slot) {
          matchingMenu = m;
          break;
        }
      }
      if (matchingMenu != null && matchingMenu.dishes.isNotEmpty) {
        final offering = MealOffering(
          date: row.date,
          slot: row.slot,
          hall: matchingMenu.halls.isNotEmpty
              ? matchingMenu.halls.first
              : const Hall(id: '1', name: 'مرکزی'),
          option: matchingMenu.dishes.first,
          reservable: true,
        );
        final outcome = await widget.services.reservations.reserve(
          accountId: accountId,
          offering: offering,
        );
        if (outcome.succeeded) {
          succeeded++;
          final price = outcome.reservation?.option.priceRial ?? offering.option.priceRial;
          final current = widget.state.balanceFor(accountId);
          if (current != null) {
            final next = current - price;
            widget.state.setBalance(accountId, next > 0 ? next : 0);
          }
        } else {
          failed++;
          lastError = outcome.message;
        }
      }
    }

    setState(() => _busyKey = null);
    await widget.services.mealStore.persist();
    widget.state.mealsChanged();
    if (succeeded > 0) {
      _fetchAccountBalance(accountId);
    }
    _refreshTable(quiet: true, targetAccount: accountId);

    if (mounted) {
      if (failed == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${toPersianDigits(succeeded)} وعده غذایی با موفقیت رزرو شد.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$succeeded وعده رزرو شد، $failed وعده ناموفق بود.${lastError != null ? " ($lastError)" : ""}',
            ),
            backgroundColor: Colors.amber.shade900,
          ),
        );
      }
    }
  }

  /// Books multiple offerings with specific student choices of dish and dining hall.
  Future<void> _batchBookOfferings(AccountId accountId, List<MealOffering> offerings) async {
    setState(() => _busyKey = 'batch');
    int succeeded = 0;
    int failed = 0;
    String? lastError;

    for (final offering in offerings) {
      final outcome = await widget.services.reservations.reserve(
        accountId: accountId,
        offering: offering,
      );
      if (outcome.succeeded) {
        succeeded++;
        final price = outcome.reservation?.option.priceRial ?? offering.option.priceRial;
        final current = widget.state.balanceFor(accountId);
        if (current != null) {
          final next = current - price;
          widget.state.setBalance(accountId, next > 0 ? next : 0);
        }
      } else {
        failed++;
        lastError = outcome.message;
      }
    }

    setState(() => _busyKey = null);
    await widget.services.mealStore.persist();
    widget.state.mealsChanged();
    if (succeeded > 0) {
      _fetchAccountBalance(accountId);
    }
    _refreshTable(quiet: true, targetAccount: accountId);

    if (mounted) {
      if (failed == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${toPersianDigits(succeeded)} وعده غذایی با موفقیت رزرو شد.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$succeeded وعده رزرو شد، $failed وعده ناموفق بود.${lastError != null ? " ($lastError)" : ""}',
            ),
            backgroundColor: Colors.amber.shade900,
          ),
        );
      }
    }
  }

  /// Says why a booking could not be started, on the screen the student is on.
  void _showBookingProblem(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      AccountsScreen(
        state: widget.state,
        services: widget.services,
        onRefresh: refreshFromPortal,
        onTopUp: _startTopUp,
        onAccountAdded: (account) {
          _refreshTable(quiet: true, targetAccount: account.id);
        },
      ),
      ReservationsScreen(
        state: widget.state,
        menus: _tableMenus,
        clock: widget.services.clock,
        busy: _busyKey != null,
        busyKey: _busyKey,
        onBook: _bookMeal,
        onCancel: _cancelMeal,
        onSell: _sellMeal,
        onRemoveFromSell: _removeFromSell,
        onForgotReceipt: _handleForgotReceipt,
        onBatchBookOfferings: (offerings) => _batchBookOfferings(
          widget.state.selectedReservationsAccountId ?? widget.state.accounts.first.id,
          offerings,
        ),
        onBatchBook: (rows) => _batchBook(
          widget.state.selectedReservationsAccountId ?? widget.state.accounts.first.id,
          rows,
        ),
        onTopUpOfferings: (deficit, offerings) => _handleReservationsTopUp(
          widget.state.selectedReservationsAccountId ?? widget.state.accounts.first.id,
          deficit,
          pendingOfferings: offerings,
        ),
        onTopUp: (deficit, {pendingRows}) => _handleReservationsTopUp(
          widget.state.selectedReservationsAccountId ?? widget.state.accounts.first.id,
          deficit,
          pendingRows: pendingRows,
        ),
        onRefresh: _refreshTable,
        onAccountChanged: (accountId) => _refreshTable(targetAccount: accountId),
      ),
      DashboardScreen(state: widget.state, clock: widget.services.clock),
      RemindersScreen(state: widget.state, bridge: widget.services.bridge),
      _huntScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) {
          setState(() => _index = index);
          // The market is read when the hunt is opened, not on every rebuild:
          // every read is a request pattern, and the market changes slowly
          // compared with a hunt's window.
          if (index == 4) loadMarket();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'حساب‌ها',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu),
            label: 'رزروها',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'مالی',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'یادآورها',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'شکار',
          ),
        ],
      ),
    );
  }

  /// The hunt screen, with the account picker and the live market read.
  Widget _huntScreen() {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final accounts = state.accounts;

        if (accounts.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('شکار')),
            body: const Center(child: Text('ابتدا یک حساب اضافه کنید.')),
          );
        }

        // The first account is the default, so the screen is never empty.
        final activeId = state.activeHuntAccount ?? accounts.first.id;
        if (state.activeHuntAccount == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) state.selectHuntAccount(activeId);
          });
        }

        // A hunt with no stored target starts on the portal's today, not the
        // The default date is the first servable date on or after today.
        final defaultDate = _defaultHuntTargetDate();

        final activeConfig = state.activeHuntConfig;
        final config = activeConfig == null
            ? HuntConfig(targetDate: defaultDate)
            : (activeConfig.targetDate == null
                ? activeConfig.copyWith(targetDate: defaultDate)
                : activeConfig);

        return HuntScreen(
          config: config,
          dishes: _marketDishes,
          halls: _marketHalls,
          marketError: _marketError,
          targetDates: _targetDates(),
          isRunning: state.huntRunning,
          schedule: state.huntScheduleFor(activeId),
          preflightSummary: state.huntPreflightSummary,
          preflightRefusal: state.huntPreflightRefusal,
          onConfigChanged: (updated) => _onConfigChanged(updated),
          onStart: () => _startHunt(activeId, config),
          onStop: () => _stopHunt(activeId),
          enableRefusal: state.huntEnableRefusal,
          onTopUp: _refusalNeedsTopUp
              ? () => _startTopUpFor(activeId)
              : null,
        );
      },
    );
  }

  /// The dishes the menu is offering, read from the weekly menu.
  ///
  /// Read once per date, when the hunt screen is opened: the menu changes
  /// slowly compared with a hunt's window, and every read is a request
  /// pattern.
  List<HuntDishOption> _marketDishes = const [];
  List<Hall> _marketHalls = const [];

  /// The whole menu that was read, for every meal slot of the target date.
  ///
  /// Held because the weekly page carries all three meals for the day, so
  /// changing the meal slot is answered from here — with no request.
  List<MealMenu>? _menus;

  /// Why the menu could not be read, when it could not.
  ///
  /// Null means the read succeeded. An empty dish list is ambiguous on its
  /// own — it reads as "there is no food that day" — so the failure is stated
  /// rather than left for the user to infer.
  String? _marketError;

  /// The hunt configuration the menu was last read for.
  ///
  /// Held so a stale read is not mistaken for a current one: the menu is
  /// read for a specific date, and a read for yesterday's must not be shown
  /// for today's.
  HuntConfig? _marketFor;

  /// The hunt configuration currently being edited.
  HuntConfig? get _currentHuntConfig => widget.state.activeHuntConfig;

  /// The dates the hunt may target.
  ///
  /// Starts from today (in portal time, falling back to local date if unsynced),
  /// covering 14 days, because the secondary market (Food Basket) allows purchasing
  /// meals for today and upcoming days as other students release them.
  List<DateTime> _targetDates() {
    final clock = widget.services.clock;
    final today = clock.isSynced ? clock.portalTodayUtc : DateTime.now().toUtc();
    final todayUtc = DateTime.utc(today.year, today.month, today.day);

    return List.generate(
      14,
      (i) => DateTime.utc(todayUtc.year, todayUtc.month, todayUtc.day + i),
    );
  }

  /// The first servable date for hunt, defaulting to today or the next servable day.
  DateTime _defaultHuntTargetDate([MealSlot slot = MealSlot.dinner]) {
    final clock = widget.services.clock;
    final today = clock.isSynced ? clock.portalTodayUtc : DateTime.now().toUtc();
    final todayUtc = DateTime.utc(today.year, today.month, today.day);

    final dates = _targetDates();
    if (dates.isNotEmpty) {
      return ServiceCalendar()
              .servableDates(dates, slot)
              .firstOrNull ??
          todayUtc;
    }
    return todayUtc;
  }

  /// Saves a changed hunt configuration, and re-reads the menu if the target
  /// date moved.
  ///
  /// The menu is a per-**date** view: the page carries all three meals for
  /// the day, so changing the meal slot needs no request — only a change of
  /// date does. The read is also skipped when only the rate changed, for the
  /// same reason: every read is a request the portal sees.
  Future<void> _onConfigChanged(HuntConfig updated) async {
    // Turning the hunt **on** is not an ordinary edit: it is the moment the
    // app promises to start a hunt by itself, hours from now, with the app
    // closed. So it is the moment to check that the promise can be kept —
    // before the flag is stored, not after the alarm has already fired.
    //
    // Every other change (date, window, meal, rate) is saved as before. Only
    // the off→on edge is gated.
    final turningOn = updated.enabled && !(_currentHuntConfig?.enabled ?? false);
    if (turningOn) {
      // True means "no objection": either the check passed, or the answer
      // arrived after the screen was gone and there is nothing to report.
      final allowed = await _confirmHuntEnable(updated);
      if (!mounted) return;
      if (!allowed) {
        // The flag is not stored, so the switch springs back and the screen
        // keeps saying why. Storing it and refusing afterwards would leave a
        // hunt that claims to be on with no alarm behind it — the exact state
        // the student cannot tell from a working one.
        return;
      }
    }

    widget.state.setHuntEnableRefusal(null);
    await widget.state.saveHuntConfig(updated);

    final dateMoved = !_sameDate(_marketFor?.targetDate, updated.targetDate);

    if (!dateMoved) {
      // The date is the same, so the menu we already hold still answers the
      // question — but the *slot* may have changed, and the list on screen
      // belongs to the slot. Redraw it from the menu we have.
      _applyMenu();
      return;
    }

    await loadMarket(date: updated.targetDate);
  }

  /// Whether the hunt may be switched on.
  ///
  /// Records the refusal and its kind on the state when it may not, so the
  /// screen can say why (and, for money, offer the top-up).
  ///
  /// ## Why the window is checked here at all
  ///
  /// An alarm set for an instant already gone fires **at once**. So a hunt
  /// enabled after its window opened starts immediately rather than at a
  /// claimed time — which is fine, and is what the student meant by switching
  /// it on inside the window. What is not fine is the case where there is no
  /// window left to start in at all:
  ///
  ///  * the window has **closed** — the meal it was for has been released and
  ///    taken, and the hunt can buy nothing;
  ///  * the meal is **not served** on that date (a dinner on a Thursday, a
  ///    Friday) — there is no listing the portal will ever publish.
  ///
  /// Both are refusals of the *schedule*, derived from the configuration alone,
  /// so they are decided before any request is made.
  ///
  /// ## Why the funds are checked here too
  ///
  /// The hunt spends money, and the balance is the one fact the student can
  /// act on before the window arrives. A hunt armed with a balance below the
  /// priority list's cost refuses the moment it wakes — hours later, with
  /// nobody looking at the screen. Refusing at the switch turns that into a
  /// message the student can fix now (top up), which is the difference between
  /// a silent failure and an actionable one.
  ///
  /// The check needs a live balance, so it costs a portal read. It runs **only
  /// when the switch goes on**, never while the rest of the form is edited.
  ///
  /// ## Only the checks that have something to judge
  ///
  /// The dish priority list is what the funds check is about, and a hunt being
  /// set up for the first time has an empty list — the student picks dishes
  /// *after* choosing the date. Refusing that would block the normal order of
  /// work, so the funds gate applies only when there is a priority list to pay
  /// for. The **Start** button's full pre-flight stays the authority on whether
  /// the hunt may run, with its no-preferences rule intact.
  Future<bool> _confirmHuntEnable(HuntConfig config) async {
    final schedule = widget.services.huntSchedule.scheduleFor(
      config,
      widget.services.clock,
    );

    // A hunt with no window left to start in is refused from the schedule
    // alone — no request, and the reason is one the student can act on by
    // changing the date.
    final scheduleRefusal = _windowRefusalFor(schedule.status);
    if (scheduleRefusal != null) {
      widget.state.setHuntEnableRefusal(scheduleRefusal);
      _enableNeedsTopUp = false;
      return false;
    }

    // Nothing selected yet: there is no cost to check and no dish to buy, so
    // the hunt may be switched on.
    if (config.dishPriority.isEmpty) return true;

    final accountId = widget.state.activeHuntAccount;
    if (accountId == null) return true;

    // Rule: If multiple dishes in priority, calculate deficit on the MORE EXPENSIVE dish
    var requiredCostRial = 0;
    for (final dish in config.dishPriority) {
      HuntDishOption? match;
      for (final d in _marketDishes) {
        if (d.name == dish.name) {
          match = d;
          break;
        }
      }
      final price = match?.priceRial ?? 350000;
      if (price > requiredCostRial) {
        requiredCostRial = price;
      }
    }

    final balance = widget.state.balanceFor(accountId) ?? 0;
    final deficitRial = requiredCostRial - balance;
    if (deficitRial > 0) {
      final goToTopUp = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('کمبود موجودی برای شکار'),
          content: Text(
            'موجودی شما ${formatTomanPersian(balance)} است و برای رزرو غذاهایی که در اولویت آورده‌اید کافی نیست.\n'
            'کسری موجودی: ${formatTomanPersian(deficitRial)}\n\n'
            'در صورتی که دو غذا در اولویت باشند، غذای گران‌تر مبنای محاسبه است.\n'
            'آیا مایلید برای افزایش اعتبار به صفحه پرداخت هدایت شوید؟ (پس از پرداخت، شکار به طور خودکار فعال می‌شود)',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('لغو فرایند'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('افزایش موجودی'),
            ),
          ],
        ),
      );

      if (goToTopUp == true && mounted) {
        _pendingHuntAccount = accountId;
        _pendingHuntConfig = config;
        await _startTopUpFor(accountId, suggestedAmountRial: deficitRial);
      }

      widget.state.setHuntEnableRefusal('کسری موجودی: ${formatTomanPersian(deficitRial)}');
      _enableNeedsTopUp = true;
      return false;
    }

    final rule = config.toRule(id: 'hunt-$accountId', account: accountId);
    final verdict = await widget.services.engine.preflight(rule, hunt: config);

    // The answer arrived after the screen went away: there is nobody to tell,
    // and blocking the store would leave the app in a state the student cannot
    // see. The Start button's pre-flight re-checks on the way in.
    if (!mounted) return true;

    if (verdict.passed) {
      _enableNeedsTopUp = false;
      return true;
    }

    widget.state.setHuntEnableRefusal(
      describePreflightFailures(verdict.failures),
    );
    _enableNeedsTopUp =
        verdict.failures.contains(PreflightFailure.insufficientFunds);
    return false;
  }

  /// Why a schedule cannot be switched on, or null when it can.
  String? _windowRefusalFor(HuntScheduleStatus status) {
    switch (status) {
      case HuntScheduleStatus.windowPassed:
        return 'بازه زمانی این شکار گذشته است. برای فعال‌سازی، تاریخ یا بازه '
            'زمانی را تغییر دهید.';
      case HuntScheduleStatus.mealNotServed:
        return 'این وعده در این تاریخ ارائه نمی‌شود، پس شکاری برای آن معنا '
            'ندارد. برای فعال‌سازی، تاریخ یا وعده را تغییر دهید.';
      case HuntScheduleStatus.noTargetDate:
        return 'برای فعال‌سازی خودکار، ابتدا تاریخ این وعده را انتخاب کنید.';
      case HuntScheduleStatus.windowInvalid:
        return 'بازه زمانی معتبر نیست: ساعت پایان باید پس از ساعت شروع باشد.';
      case HuntScheduleStatus.windowOpen:
      case HuntScheduleStatus.scheduled:
      case HuntScheduleStatus.disabled:
      case HuntScheduleStatus.clockUnsynced:
        // An open window starts at once — that is the student's own action, so
        // it is allowed. An unsynced clock is not a reason to refuse the
        // switch: the alarm falls back to the device clock and the screen says
        // the schedule is not yet known. Refusing here would make the hunt
        // hard to switch on before the first sync.
        return null;
    }
  }

  /// Whether the refusal that stopped the switch was about money.
  bool _enableNeedsTopUp = false;

  /// Whether the enable refusal currently shown is the money one.
  ///
  /// True only while an insufficient-funds refusal is the one on screen, so the
  /// screen offers "افزایش اعتبار" exactly when a top-up is what would fix it.
  bool get _refusalNeedsTopUp =>
      _enableNeedsTopUp && widget.state.huntEnableRefusal != null;

  /// Starts a top-up for [accountId], from the hunt screen's refusal.
  ///
  /// The account is looked up rather than assumed: the top-up flow needs the
  /// saved account, and the hunt screen's active account is an id.
  Future<void> _startTopUpFor(AccountId accountId, {int? suggestedAmountRial}) async {
    final account = widget.state.accounts
        .where((a) => a.id == accountId)
        .cast<SavedAccount?>()
        .firstWhere((_) => true, orElse: () => null);
    if (account == null) return;
    await _startTopUp(account, suggestedAmountRial: suggestedAmountRial);
  }

  Future<void> _handleReservationsTopUp(
    AccountId accountId,
    int deficitRial, {
    List<MealRow>? pendingRows,
    List<MealOffering>? pendingOfferings,
  }) async {
    if (pendingOfferings != null && pendingOfferings.isNotEmpty) {
      _pendingBookingsAccount = accountId;
      _pendingOfferingsToBook = pendingOfferings;
    } else if (pendingRows != null && pendingRows.isNotEmpty) {
      final offerings = <MealOffering>[];
      for (final row in pendingRows) {
        MealMenu? matchingMenu;
        for (final m in _tableMenus) {
          if (m.date.year == row.date.year &&
              m.date.month == row.date.month &&
              m.date.day == row.date.day &&
              m.slot == row.slot) {
            matchingMenu = m;
            break;
          }
        }
        if (matchingMenu != null && matchingMenu.dishes.isNotEmpty) {
          offerings.add(MealOffering(
            date: row.date,
            slot: row.slot,
            hall: matchingMenu.halls.isNotEmpty ? matchingMenu.halls.first : const Hall(id: '1', name: 'مرکزی'),
            option: matchingMenu.dishes.first,
            reservable: true,
          ));
        }
      }
      _pendingBookingsAccount = accountId;
      _pendingOfferingsToBook = offerings;
    }
    await _startTopUpFor(accountId, suggestedAmountRial: deficitRial);
  }

  String _mealSlotName(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'صبحانه',
        MealSlot.lunch => 'ناهار',
        MealSlot.dinner => 'شام',
      };

  Future<void> _handleForgotReceipt(
    DateTime date,
    MealSlot slot,
    String? dishName, [
    ReserveType reserveType = ReserveType.weekly,
  ]) async {
    final accountId = widget.state.selectedReservationsAccountId ??
        (widget.state.accounts.isEmpty ? null : widget.state.accounts.first.id);
    if (accountId == null) return;

    final account = widget.state.accounts.firstWhere((a) => a.id == accountId);

    // 1. If already issued and cached, display immediately with zero server calls.
    final cachedCode = widget.state.receiptCodeFor(accountId, date, slot);
    if (cachedCode != null) {
      await _showReceiptCodeDialog(
        code: cachedCode,
        account: account,
        date: date,
        slot: slot,
        dishName: dishName,
        isCached: true,
      );
      return;
    }

    // 2. Fresh request confirmation and distribution hours check
    if (isMealDistributionPassed(date, slot, clock: widget.services.clock)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('مهلت توزیع و دریافت فیش فراموشی برای این وعده به پایان رسیده است.'),
        ),
      );
      return;
    }

    final today = widget.services.clock.portalTodayUtc;
    final isToday = date.year == today.year && date.month == today.month && date.day == today.day;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('دریافت فیش فراموشی کارت'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('حساب: ${account.resolvedName}'),
            const SizedBox(height: 4),
            Text('وعده: ${_mealSlotName(slot)} - ${formatPersianDate(date)}'),
            if (dishName != null) ...[
              const SizedBox(height: 4),
              Text('غذا: $dishName'),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                slot == MealSlot.breakfast
                    ? 'ساعات مجاز دریافت فیش:\n• صبحانه: عصر روز قبل (۱۶:۳۰ تا ۲۰:۳۰)\n• ناهار: همان روز (۰۹:۰۰ تا ۱۵:۳۰)\n• شام: همان روز (۱۶:۳۰ تا ۲۰:۳۰)\nسقف دریافت فیش: ۲ بار در ماه برای هر وعده.'
                    : 'ساعات مجاز دریافت فیش:\n• ناهار: همان روز (۰۹:۰۰ تا ۱۵:۳۰)\n• شام: همان روز (۱۶:۳۰ تا ۲۰:۳۰)\n• صبحانه: عصر روز قبل (۱۶:۳۰ تا ۲۰:۳۰)\nسقف دریافت فیش: ۲ بار در ماه برای هر وعده.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            if (!isToday) ...[
              const SizedBox(height: 8),
              Text(
                'توجه: تاریخ این وعده با امروز یکسان نیست. سامانه دانشگاه معمولاً تنها در روز توزیع و در ساعات مجاز فیش صادر می‌کند.',
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.error,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.receipt_long, size: 18),
            label: const Text('دریافت فیش'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() {
      _busyKey = '${date.year}-${date.month}-${date.day}|${slot.name}';
    });

    final outcome = await widget.services.sessions.withSession(
      accountId,
      (session) => widget.services.client.requestForgotReceipt(
        session,
        date: date,
        slot: slot,
        reserveType: reserveType,
      ),
    );

    if (!mounted) return;

    setState(() {
      _busyKey = null;
    });

    if (outcome is ForgotReceiptSucceeded) {
      widget.state.recordReceipt(accountId, date, slot, outcome.code);
      if (!mounted) return;
      await _showReceiptCodeDialog(
        code: outcome.code,
        account: account,
        date: date,
        slot: slot,
        dishName: dishName,
        isCached: false,
      );
    } else if (outcome is ForgotReceiptRefused) {
      _showBookingProblem(outcome.reason);
    } else if (outcome is ForgotReceiptAmbiguous) {
      _showBookingProblem(outcome.diagnostic);
    }
  }

  /// Displays the forgot receipt code with copy and sharing options.
  Future<void> _showReceiptCodeDialog({
    required String code,
    required SavedAccount account,
    required DateTime date,
    required MealSlot slot,
    required String? dishName,
    required bool isCached,
  }) async {
    final slotName = _mealSlotName(slot);
    final persianDate = formatPersianDate(date);
    final dishLine = dishName != null ? '🍲 غذا: $dishName\n' : '';
    final shareText = 'سلام، کد فیش فراموشی من برای سلف دانشگاه:\n\n'
        '🔑 کد فیش: $code\n'
        '🍴 وعده: $slotName ($persianDate)\n'
        '$dishLine'
        '👤 حساب: ${account.resolvedName}\n\n'
        'لطفاً این غذا را برای من تحویل بگیر. ممنون!';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              isCached ? Icons.receipt : Icons.receipt_long,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(isCached ? 'مشاهده فیش فراموشی' : 'فیش فراموشی صادر شد'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCached)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 16, color: Theme.of(ctx).colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'این فیش قبلاً صادر شده است و بدون مصرف مجدد سقف ماهانه نمایش داده می‌شود.',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                'کد فیش فراموشی:',
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SelectableText(
                      code,
                      style: Theme.of(ctx).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('کد فیش کپی شد')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: 'کپی کد فیش',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'این کد را در دستگاه سلف وارد کنید یا اگر خودتان حضور ندارید، برای دوستتان ارسال کنید تا غذا را برایتان بگیرد.',
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _shareForgotReceipt(shareText, directSms: false),
                icon: const Icon(Icons.share, size: 18),
                label: const Text('ارسال با پیامک یا پیام‌رسان'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _shareForgotReceipt(shareText, directSms: true),
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: const Text('ارسال مستقیم با پیامک (SMS)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  /// Sends or shares the forgot receipt code via SMS or messaging apps.
  Future<void> _shareForgotReceipt(String text, {bool directSms = false}) async {
    try {
      if (directSms) {
        await widget.services.bridge.sendSms(text: text);
      } else {
        await widget.services.bridge.shareText(
          text: text,
          title: 'کد فیش فراموشی سلف',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('صفحه ارسال باز شد')),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('متن پیام برای ارسال در حافظه موقت (کلیپ‌بورد) کپی شد'),
          ),
        );
      }
    }
  }

  /// Redraws the dish and hall lists from a menu.
  ///
  /// The menu holds every meal slot for the day, so a change of slot is
  /// answered from the menu already in hand — no request.
  ///
  /// With no menu in hand there is nothing to redraw, and a failed read must
  /// keep saying *why* it failed: replacing the error with "no food on that
  /// day" would tell the user the portal has nothing, when the truth is that
  /// the app could not reach it.
  void _applyMenu([List<MealMenu>? menus]) {
    if (!mounted) return;

    final list = menus ?? _menus;
    if (list == null) return;

    _menus = list;

    final config = _currentHuntConfig;
    final targetSlot = config?.targetSlot;

    final choice = targetSlot == null
        ? null
        : MenuChoice.from(list, targetSlot);

    final halls = <Hall>[
      for (final hall in choice?.halls ?? const <HuntHall>[])
        Hall(id: hall.id, name: hall.name),
    ];
    final dishes = <HuntDishOption>[
      for (final dish in choice?.dishes ?? const <HuntDish>[])
        HuntDishOption(
          optionId: dish.optionId,
          name: dish.name,
          priceRial: dish.priceRial,
          halls: halls,
        ),
    ];

    setState(() {
      _marketDishes = dishes;
      _marketHalls = halls;
      _marketFor = config;
      _marketError = null;
    });
  }

  /// Whether two civil dates are the same day.
  static bool _sameDate(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Starts a hunt, after the pre-flight passes.
  ///
  /// ## Why this returns whether the hunt started
  ///
  /// On the **platform's** path the foreground service is already running
  /// before this is called: the alarm receiver starts it and *then* asks the
  /// Dart side. So an early return here — a declined risk acknowledgement, a
  /// failed pre-flight — used to leave the service up, posting
  /// «پایش سبد غذا» over a hunt that never ran. The device showed it: the
  /// notification from an 18:11 wake-up was still standing at 18:23, with
  /// nothing behind it.
  ///
  /// The caller that knows a service is standing is the one that can release
  /// it, so the outcome is reported rather than swallowed.
  Future<bool> _startHunt(AccountId accountId, HuntConfig config) async {
    final engine = widget.services.engine;
    final hunts = widget.services.hunts;

    // The ban risk is acknowledged before the hunt starts, not after: a rate
    // below ten seconds is a decision, and the decision is the user's.
    if (config.rate.needsRiskAcknowledgement && !config.riskAcknowledged) {
      final accepted = await confirmRiskAcknowledgement(
        context,
        interval: config.rate.peakInterval,
        projectedRequests: config.projectedRequests(),
      );
      if (!accepted) return false;
      await widget.state.saveHuntConfig(config.copyWith(riskAcknowledged: true));
    }

    final rule = config.toRule(id: 'hunt-$accountId', account: accountId);

    final verdict = await engine.preflight(rule, hunt: config);

    // The screen went away before the answer arrived. Nothing is started, and
    // the caller must release any service the platform started.
    if (!mounted) return false;

    if (!verdict.passed) {
      widget.state.setHuntPreflight(
        refusal: _describeFailures(verdict.failures),
      );
      return false;
    }

    widget.state.setHuntPreflight(summary: _describeReady(config));
    widget.state.setHuntRunning(true);

    // The listener must be in place before the hunt starts: the purchase
    // notification is posted from it, and a hunt that wins in its first
    // second must not find the listener missing.
    engine.listener = HuntNotifier(service: hunts, accountId: accountId);

    await hunts.start(accountId: accountId, config: config);
    return true;
  }

  /// Stops the hunt's foreground service, if one is running.
  ///
  /// Used on the paths where the platform started the service but the hunt
  /// could not run. A foreground service with no hunt behind it is a battery
  /// drain and a notification the student cannot clear.
  Future<void> _releaseHuntService() async {
    try {
      await widget.services.bridge.stopHuntService();
    } catch (_) {
      // The service releases itself when the process ends anyway.
    }
  }

  /// Stops a running hunt.
  Future<void> _stopHunt(AccountId accountId) async {
    await widget.services.hunts.stop(accountId);
    widget.state.setHuntRunning(false);
  }

  /// The Persian text for a pre-flight refusal.
  ///
  /// The text itself lives in `lib/core/preflight.dart`, because the same
  /// refusal is shown here and in a notification when the hunt ran headless —
  /// and two copies of it would drift, with the copy nobody is looking at
  /// being the one that matters most when the app is closed.
  String _describeFailures(List<PreflightFailure> failures) =>
      describePreflightFailures(failures);

  /// The Persian summary of a ready hunt.
  String _describeReady(HuntConfig config) {
    final dishes = config.dishPriority.map((d) => d.name).join('، ');
    final halls = config.hallPriority.isEmpty
        ? 'هر سلفی'
        : config.hallPriority.map((h) => h.name).join('، ');
    return 'آماده: $dishes — $halls — حدود '
        '${toPersianDigits(config.projectedRequests())} درخواست.';
  }
}

/// How a CAPTCHA question ended.
///
/// The three endings need three different reports, so they are three
/// different values rather than a bool. See [_HomeShellState._askForCaptcha].
class _CaptchaOutcome {
  const _CaptchaOutcome.accepted()
      : declined = false,
        refusalReason = null;

  const _CaptchaOutcome.declined()
      : declined = true,
        refusalReason = null;

  const _CaptchaOutcome.refused(String reason)
      : declined = false,
        refusalReason = reason;

  /// The student closed the dialog without answering.
  final bool declined;

  /// Why the portal refused the answer, when it did.
  final String? refusalReason;
}
