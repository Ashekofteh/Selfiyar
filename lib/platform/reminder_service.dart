/// The reminder service: builds the digest, posts the notification, and keeps
/// the alarms armed.
///
/// ## Offline-first, by design
///
/// The digest is built from the **local meal store**, not from the portal. A
/// reminder must fire whether or not the phone has a network connection, and
/// logging into the portal for every notification would be slow, would burn
/// radio time, and would make the app's behaviour depend on a third party's
/// uptime.
///
/// The live portal check is opt-in (the product owner's decision), and when it
/// is on, the digest is reconciled against the portal before it is sent.
library;

import 'dart:async';

import '../core/meal/local_meal_store.dart';
import '../core/meal/models.dart';
import '../core/shared/next_week.dart';
import '../core/reminder/nudge_schedule.dart';
import '../core/reminder/reminder.dart';
import '../core/reminder/reminder_compose.dart';
import '../core/shared/time.dart';
import 'platform_bridge.dart';

/// A scheduled reminder slot.
class ScheduledReminder {
  const ScheduledReminder({
    required this.slot,
    required this.time,
    required this.pays,
  });

  final ReminderSlot slot;

  /// The fire time, portal-local.
  final ClockTime time;

  /// The notification id, so a reminder can be replaced rather than stacked.
  final int pays;
}

/// Delivers the reminders.
class ReminderService {
  ReminderService({required this.bridge, required this.mealStore});

  final PlatformBridge bridge;
  final LocalMealStore mealStore;

  /// The notification ids, one per slot, so a re-post replaces the old one.
  static const int _lunchNotificationId = 4101;
  static const int _eveningNotificationId = 4102;
  static const int _nudgeNotificationId = 4103;

  /// The alarm request codes.
  static const int _lunchAlarm = 4201;
  static const int _eveningAlarm = 4202;
  static const int _nudgeAlarm = 4203;

  /// The payload the nudge alarm carries.
  ///
  /// The nudge is not a slot, so it needs its own name: the native receiver
  /// tells a reminder from a hunt wake-up, and the Dart side tells a nudge
  /// from a digest.
  static const String nudgePayload = 'nudge';

  /// Arms the alarms for the configured slots.
  ///
  /// Cancels first, so a removed or retimed slot does not leave a stale alarm
  /// behind to fire at the wrong time.
  Future<void> schedule(ReminderConfig config, {ServerClock? clock}) async {
    await armSlot(ReminderSlot.lunch, config);
    await armSlot(ReminderSlot.evening, config);
    if (clock != null) {
      await armNudge(config, clock);
    } else {
      await bridge.cancelAlarm(_nudgeAlarm);
    }
  }

  /// The next time [time] occurs, today if it is still ahead, else tomorrow.
  ///
  /// Uses the device's local clock. The alarm is only a *reminder to look*, not
  /// a purchase decision, so minute-level drift is harmless — unlike the
  /// reservation cutoff, which the domain core computes from the server clock.
  static DateTime _nextOccurrence(ClockTime time, DateTime now) {
    final today = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    return today.isAfter(now) ? today : today.add(const Duration(days: 1));
  }

  /// The payload the alarm carries, and the slot it names.
  ///
  /// The payload is how a fired alarm says *which* reminder to deliver: the
  /// native receiver cannot read the configuration, and the Dart side has
  /// exactly two slots. So the alarm says "lunch" or "evening", and the
  /// delivery reads the configuration for itself.
  static String? payloadFor(ReminderSlot slot) {
    switch (slot) {
      case ReminderSlot.lunch:
        return 'lunch';
      case ReminderSlot.evening:
        return 'evening';
    }
  }

  /// The slot a payload names, or null when the payload is not one of ours.
  ///
  /// A payload the app does not recognise is ignored rather than guessed at:
  /// the platform also uses this channel for the hunt's own wake-up.
  static ReminderSlot? slotFor(String? payload) {
    switch (payload) {
      case 'lunch':
        return ReminderSlot.lunch;
      case 'evening':
        return ReminderSlot.evening;
      default:
        return null;
    }
  }

  /// Arms the alarms for a slot.
  ///
  /// Separate from [schedule] so a fired alarm can re-arm **its own** slot for
  /// tomorrow without touching the other one.
  Future<void> armSlot(ReminderSlot slot, ReminderConfig config) async {
    final slotConfig = slot == ReminderSlot.lunch
        ? config.lunch
        : config.evening;
    final requestCode = slot == ReminderSlot.lunch
        ? _lunchAlarm
        : _eveningAlarm;

    await bridge.cancelAlarm(requestCode);
    if (!config.isSlotActive(slot) || !slotConfig.enabled) return;

    await bridge.scheduleAlarm(
      requestCode: requestCode,
      triggerAt: _nextOccurrence(slotConfig.time, DateTime.now()),
      payload: payloadFor(slot),
    );
  }

  /// Builds and posts the digest for [slot].
  ///
  /// Returns the text that was posted, or null when there was nothing to say.
  Future<NotificationText?> deliver(
    ReminderSlot slot, {
    required ReminderConfig config,
    required Map<AccountId, String> accountNames,
  }) async {
    final accounts = config.accountsFor(slot);
    if (accounts.isEmpty) return null;

    // The digest is about **one day**, not about every meal the account
    // holds.
    //
    // The mirror holds a fortnight: today's meals, tomorrow's, and the rest of
    // the week. A digest that listed all of them would say "you have 17
    // lunches" — which is both useless and alarming, and the section heading
    // would name one date while the body listed another. (Seen on the device:
    // the heading read "پنج‌شنبه ۳۰ مهر" and the body listed every lunch in
    // the mirror.)
    //
    // So the meals are scoped to the day the reminder fires for. The evening
    // slot covers dinner tonight and breakfast tomorrow, because they are
    // collected together — so it spans two days, and the composer groups them
    // by slot.
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final meals = <HeldMealDigest>[];
    for (final accountId in accounts) {
      final held = mealStore.forAccount(accountId);
      if (held.isEmpty) continue;
      meals.addAll(
        held
            .where((m) => _isOnDay(m, slot, today, tomorrow))
            .map(
              (m) => HeldMealDigest(
                accountId: accountId,
                displayName: accountNames[accountId] ?? accountId,
                date: m.date,
                slot: m.slot,
                dishName: m.dishName,
                hallName: m.hallName,
                priceRial: m.priceRial,
              ),
            ),
      );
    }

    // An empty slot is still worth a notification. Staying silent made a
    // broken reminder look exactly like a reminder with nothing to say, so
    // the student could miss a meal they never knew they had not reserved.
    // `composeReminderText` renders the explicit no-meal message for an empty
    // list, in the same wording as the native delivery path.
    final text = composeReminderText(slot: slot, meals: meals, now: now);

    await bridge.postNotification(
      id: slot == ReminderSlot.lunch
          ? _lunchNotificationId
          : _eveningNotificationId,
      title: text.title,
      body: text.body,
      deepLink: 'reminder://${slot.name}',
    );

    return text;
  }

  /// Whether the meal belongs to the day this reminder fires for.
  ///
  /// The lunch slot is about **today**. The evening slot is about **tonight
  /// and tomorrow morning**, because dinner and the next day's breakfast are
  /// collected together — losing one means losing both.
  static bool _isOnDay(
    StoredMeal meal,
    ReminderSlot slot,
    DateTime today,
    DateTime tomorrow,
  ) {
    final date = DateTime.utc(meal.date.year, meal.date.month, meal.date.day);

    switch (slot) {
      case ReminderSlot.lunch:
        return meal.slot == MealSlot.lunch && date == today;
      case ReminderSlot.evening:
        if (meal.slot == MealSlot.dinner) return date == today;
        if (meal.slot == MealSlot.breakfast) return date == tomorrow;
        return false;
    }
  }

  /// Posts the next-week nudge, if the week is not fully booked.
  ///
  /// The nudge asks the user to reserve the coming week's meals before the
  /// Thursday 17:00 wall — the deadline that costs them the weekend.
  ///
  /// ## Why it reads the portal, not the mirror
  ///
  /// The mirror holds what the account **holds**. The nudge asks what it
  /// does **not** hold, and the difference matters: a mirror that is a week
  /// stale cannot tell "not booked" from "not read yet", and a nudge built on
  /// a stale mirror would demand a reservation the account has already made.
  ///
  /// So the check reads the portal for each selected account, and the gap
  /// detection is the domain's — the same [detectNextWeekGaps] the tests
  /// cover.
  ///
  /// ## Why a complete week is silent
  ///
  /// A notification the user learns to ignore is worse than no notification.
  /// The six check times are **checks**, not guaranteed fires: each one reads
  /// the state and speaks only if something is still unbooked. A user who
  /// books everything on Wednesday gets one notification and then silence.
  Future<bool> deliverNudge({
    required ReminderConfig config,
    required Map<AccountId, String> accountNames,
    required Map<AccountId, List<Reservation>> reservationsByAccount,
    required NextWeekStatus status,
  }) async {
    if (!config.nextWeekNudgeEnabled) return false;

    if (config.accountIds.isEmpty) return false;

    // Nothing unbooked: stay silent, and let the check that follows go quiet
    // too. This is what keeps the alert meaningful.
    if (status.isComplete) return false;

    final text = composeNudgeNotification(status);

    await bridge.postNotification(
      id: _nudgeNotificationId,
      title: text.title,
      body: text.body,
      deepLink: 'reminder://nudge',
    );
    return true;
  }

  /// Arms the next nudge check.
  ///
  /// Six checks, one alarm at a time: each fired check arms the next one, and
  /// the last one arms nothing — the window is over by then, and the deadline
  /// has either been met or missed.
  ///
  /// ## The clock may be unsynced
  ///
  /// A cold start has no server time yet: the clock only syncs from a portal
  /// response's `Date` header, and the app may arm its alarms before its first
  /// request. The clock's own `portalNow` **throws** when it is unsynced, so
  /// the device's time is used as a stand-in — the nudge's checks are
  /// wall-clock times, and the difference between the device's timezone and
  /// the portal's is at most a few hours, which cannot move a check across
  /// the window's own edges.
  ///
  /// A failed arm is not fatal: the check is re-armed on the next fire and on
  /// the next configuration change, so a nudge that could not be armed today
  /// is armed tomorrow rather than lost.
  Future<bool> armNudge(ReminderConfig config, ServerClock clock) async {
    await bridge.cancelAlarm(_nudgeAlarm);

    if (!config.nextWeekNudgeEnabled) return false;
    if (config.accountIds.isEmpty) return false;

    final synced = clock.isSynced;
    final now = synced ? clock.portalNow : DateTime.now();
    final today = synced
        ? clock.portalTodayUtc
        : DateTime.utc(now.year, now.month, now.day);

    final fireAt = nextNudgeFireUtc(now: now, today: today);
    if (fireAt == null) {
      // The window has passed: the 16:30 check was the last one, and the
      // 17:00 deadline with it.
      return false;
    }

    await bridge.scheduleAlarm(
      requestCode: _nudgeAlarm,
      triggerAt: fireAt,
      payload: nudgePayload,
    );
    return true;
  }
}
