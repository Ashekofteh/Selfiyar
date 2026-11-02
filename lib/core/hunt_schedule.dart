/// When a hunt actually runs: the date its window belongs to, and the instant
/// the hunt should wake up.
///
/// ## Why the window needs a date, not just a time of day
///
/// A hunt's window is a *time of day* — "from 16:30 to 20:30". That is enough
/// to decide **how hard** to poll, but not enough to decide **when to start**.
/// A hunt set up on Wednesday morning for *Friday's* dinner has a window that
/// opens on Friday, not on Wednesday — but a time-of-day window read on
/// Wednesday says "16:30 is later today, so the window is still to come", and
/// the hunt would burn its request budget against a market it can never buy
/// from.
///
/// So the window is resolved against a **collection date**, and the resolution
/// has one wrinkle the portal's own calendar imposes:
///
/// **Breakfast is collected with the previous evening's dinner.** A hunt for
/// Friday's breakfast has to be in the market on *Thursday* evening, because
/// that is when the meal is released and taken. The offset is therefore
/// derived from the serving calendar rather than assumed, and the
/// [ServiceCalendar] already encodes it: Thursday has no dinner, so Friday has
/// no breakfast, and Saturday has no breakfast because Friday has no dinner.
///
/// ## Why the wake instant is the window's *start*
///
/// The hunt is worth running from the moment the window opens — every minute
/// before the first listing appears is a minute of not winning it. So the
/// wake instant is the window's start on the collection date, in the portal's
/// own timezone: a portal-local wall-clock time is a UTC instant only once the
/// portal's offset is subtracted, and getting that wrong by 3½ hours would
/// start the hunt before the market opens.
library;

import 'models.dart';
import 'service_calendar.dart';
import 'time.dart';

/// The schedule of one hunt: when it wakes up, and when it gives up.
class HuntSchedule {
  const HuntSchedule({
    required this.collectionDate,
    required this.wakeAtUtc,
    required this.windowEndUtc,
  });

  /// The civil date, in the portal's frame, on which the hunt's window falls.
  ///
  /// This is the **collection date**: the day the meal is actually taken. For
  /// a breakfast it is the day *before* the target date, because the
  /// breakfast is collected with the previous evening's dinner.
  final DateTime collectionDate;

  /// The instant the hunt should wake up, in UTC.
  final DateTime wakeAtUtc;

  /// The instant the hunt's window closes, in UTC.
  ///
  /// The window's end on the collection date. The hunt gives up here even if
  /// it has not bought anything, because after this the market is closed for
  /// that meal.
  final DateTime windowEndUtc;

  @override
  String toString() => 'HuntSchedule(collection $collectionDate, '
      'wake $wakeAtUtc, end $windowEndUtc)';
}

/// Derives a hunt's schedule from its target and its window.
abstract final class HuntSchedules {
  /// The collection date for a target date and meal slot.
  ///
  /// ## The rule
  ///
  ///  * **breakfast** is collected with the *previous* evening's dinner, so it
  ///    is collected on the day before the target date;
  ///  * **lunch** and **dinner** are collected on the target date itself.
  ///
  /// ## Why the calendar is consulted
  ///
  /// The rule is not a constant offset, because the *serving* calendar decides
  /// it: Thursday has no dinner, so Friday has no breakfast to collect. A
  /// breakfast whose collection day is a day the halls serve no dinner does not
  /// exist, and the hunt has nothing to buy — so the schedule is null and the
  /// screen says so, rather than the hunt waiting for a window that can never
  /// open.
  ///
  /// A target date that is null has no schedule: the target is resolved at
  /// setup time, and a hunt without a date cannot be scheduled.
  static DateTime? collectionDate({
    required DateTime? targetDate,
    required MealSlot slot,
    ServiceCalendar calendar = const ServiceCalendar(),
  }) {
    final date = targetDate;
    if (date == null) return null;

    final day = DateTime.utc(date.year, date.month, date.day);

    if (slot != MealSlot.breakfast) return day;

    // Breakfast is collected the evening before, with that day's dinner.
    final evening = day.subtract(const Duration(days: 1));

    // If the halls serve no dinner that evening, there is no breakfast to
    // collect — so the breakfast does not exist and there is nothing to hunt.
    if (!calendar.isServedOn(evening, MealSlot.dinner)) return null;

    return evening;
  }

  /// The schedule for a hunt.
  ///
  /// The result carries a **status**, because "the hunt cannot run" has more
  /// than one reason and the screen has to say which:
  ///
  ///  * [HuntScheduleStatus.noTargetDate] — the hunt has no date, so there is
  ///    nothing to aim at;
  ///  * [HuntScheduleStatus.mealNotServed] — the meal does not exist on that
  ///    date (a breakfast whose collection evening serves no dinner, a dinner
  ///    on a Thursday, anything at all on a Friday);
  ///  * [HuntScheduleStatus.windowOpen] — the window has already **opened**,
  ///    so the wake instant is in the past and the hunt starts at once;
  ///  * [HuntScheduleStatus.windowPassed] — the window has already closed, so
  ///    the hunt has missed its moment and there is nothing left to wait for;
  ///  * [HuntScheduleStatus.windowInvalid] — the window ends before it starts,
  ///    so it can never open.
  ///
  /// The last three are not the same, and none of them is the first of them:
  /// a hunt whose window has closed needs a new target, a hunt whose window is
  /// open **right now** starts immediately rather than at a time already gone,
  /// and a hunt that was never scheduled needs a target too — but the student
  /// has to be told which, because "your hunt will not run" with no reason is a
  /// dead end.
  ///
  /// ## Why an opened window is its own status, and not `scheduled`
  ///
  /// A hunt armed for an instant that has already passed is not a schedule, it
  /// is an alarm that fires the moment it is set. Reporting it as `scheduled`
  /// with a start time in the past is what let the screen claim «در ساعت ۱۶:۳۰
  /// شروع میشود» at 18:11 — a claim the student could check and find false.
  /// So an opened window is reported as [HuntScheduleStatus.windowOpen], the
  /// screen says the hunt starts *now*, and the caller decides whether an
  /// immediate start is what it wants (a first arm: yes; a re-arm: no — see
  /// [rearmFor]).
  ///
  /// ## The unsynced clock
  ///
  /// [clockIsSynced] says whether [nowUtc] is the **portal's** time. When it
  /// is not, the caller is passing the device's time as a stand-in, and the
  /// device's timezone may be anything at all — so the question "has the
  /// window already closed?" cannot be answered from it.
  ///
  /// So an unsynced clock never produces [HuntScheduleStatus.windowPassed].
  /// The hunt is scheduled instead, and the alarm fires: if the window has in
  /// fact passed, the hunt's own date-aware window check refuses it, and the
  /// refusal is visible. Cancelling the alarm instead would make the hunt
  /// silently never run — the exact failure F83 is about.
  static HuntScheduleResult scheduleFor({
    required DateTime? targetDate,
    required MealSlot slot,
    required ClockTime windowStart,
    required ClockTime windowEnd,
    required DateTime nowUtc,
    bool clockIsSynced = true,
    ServiceCalendar calendar = const ServiceCalendar(),
  }) {
    // A window that never opens is not a schedule.
    if (windowEnd <= windowStart) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.windowInvalid,
      );
    }

    if (targetDate == null) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.noTargetDate,
      );
    }

    // A meal the halls do not serve on that date does not exist, whatever its
    // collection day would be. The breakfast rule below is the one case where
    // the collection day *differs* from the target; this is the case where the
    // meal is simply not on. A dinner on a Thursday, or anything at all on a
    // Friday, is a hunt for a listing the portal will never publish — so it is
    // refused here rather than armed, fired, and refused again by the engine.
    final targetDay = DateTime.utc(
      targetDate.year,
      targetDate.month,
      targetDate.day,
    );
    if (!calendar.isServedOn(targetDay, slot)) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.mealNotServed,
      );
    }

    final collection = collectionDate(
      targetDate: targetDate,
      slot: slot,
      calendar: calendar,
    );
    if (collection == null) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.mealNotServed,
      );
    }

    // The window's instants on the collection date, in the portal's timezone.
    final wakeAt = _portalInstant(collection, windowStart);
    final windowEnds = _portalInstant(collection, windowEnd);

    // The window has closed, or the collection day is already past.
    //
    // This is not "schedule it for tomorrow": the window belongs to the
    // collection date, and the meal it is for is released in that window. A
    // hunt that wakes tomorrow would be polling a market that no longer
    // carries the meal — spending the request budget to find nothing.
    final portalNow = nowUtc.add(ServerClock.portalUtcOffset);
    final today = DateTime.utc(
      portalNow.year,
      portalNow.month,
      portalNow.day,
    );
    if (clockIsSynced &&
        (collection.isBefore(today) || windowEnds.isBefore(nowUtc))) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.windowPassed,
      );
    }

    // The window has **opened** but not yet closed: the wake instant is in the
    // past, so there is no future moment to arm for.
    //
    // This is a distinct outcome, not a schedule with a past instant. An alarm
    // set for an instant already gone fires at once, so reporting this as
    // `scheduled` armed an immediate wake-up while the screen claimed a start
    // time that had already passed (found on the device: 16:30 claimed at
    // 18:11). The caller decides what an immediate start means — a first arm
    // honours it, a re-arm refuses it — so the status carries the fact and the
    // policy stays with the caller.
    //
    // The schedule rides along even though [HuntScheduleResult.isScheduled] is
    // false, because the first arm needs the instant: an alarm for a moment
    // already gone fires at once, which is exactly the "start hunting now" the
    // student asked for by switching it on inside the window. The instant is
    // still the window's *start*, so the caller has the window's true bounds
    // and can tell "open" from "closing".
    if (clockIsSynced && !wakeAt.isAfter(nowUtc)) {
      return HuntScheduleResult(
        status: HuntScheduleStatus.windowOpen,
        schedule: HuntSchedule(
          collectionDate: collection,
          wakeAtUtc: wakeAt,
          windowEndUtc: windowEnds,
        ),
      );
    }

    return HuntScheduleResult(
      status: HuntScheduleStatus.scheduled,
      schedule: HuntSchedule(
        collectionDate: collection,
        wakeAtUtc: wakeAt,
        windowEndUtc: windowEnds,
      ),
    );
  }

  /// A portal-local wall-clock time on [day], as a UTC instant.
  ///
  /// The portal's offset is subtracted, because a wall-clock time in the
  /// portal's timezone is a *later* instant than the same digits read as UTC.
  static DateTime _portalInstant(DateTime day, ClockTime time) => DateTime.utc(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ).subtract(ServerClock.portalUtcOffset);

  /// The schedule for a **re-arm**: the same hunt, armed again after a run.
  ///
  /// ## Why this is not [scheduleFor]
  ///
  /// A hunt's window belongs to a collection date, and the hunt is armed to
  /// wake up when that window **opens**. So a window that has already opened
  /// is a window the hunt has had its chance at — and arming into it again
  /// starts the hunt *immediately*.
  ///
  /// That is the difference between the two arms, and it matters in the
  /// dangerous direction. The first arm is the student's own action: a window
  /// that is open now is a window they mean to hunt in, so it fires at once.
  /// A re-arm is automatic, and the run it follows has just ended — usually
  /// because the hunt **refused** (no credit, no session) or ran out of its
  /// request budget. Re-arming into the same open window would start the hunt
  /// again immediately, and it would refuse again, and again: a tight loop of
  /// wake-ups, each one a round of portal requests, for as long as the window
  /// stayed open.
  ///
  /// That is exactly what the request budget exists to prevent, so a re-arm
  /// asks only for a window that is still **ahead**. When the wake instant
  /// has passed, the result is [HuntScheduleStatus.windowOpen]: the hunt is
  /// over for this window, and the student chooses a new date.
  ///
  /// ## The clock must be synced
  ///
  /// The comparison is between the wake instant — a portal-derived instant —
  /// and "now". So "now" has to be the portal's now, and an unsynced clock
  /// cannot supply it. The caller checks that, because only the caller knows
  /// whether the clock is trusted. Here the clock is declared synced, because
  /// the caller would not have called a re-arm at all with a clock it does not
  /// trust.
  ///
  /// ## How this differs from the first arm, mechanically
  ///
  /// Both derive the same [HuntScheduleResult] — the difference is entirely in
  /// what the *caller* does with it. An opened window is
  /// [HuntScheduleStatus.windowOpen], and [HuntScheduleResult.isScheduled] is
  /// false for it, so a caller that arms only what `isScheduled` is true arms
  /// nothing. The first arm deliberately arms it anyway (see
  /// `HuntScheduleService.arm`): an alarm set for an instant already gone fires
  /// at once, which is the immediate start the student asked for by switching
  /// the hunt on inside its window.
  static HuntScheduleResult rearmFor({
    required DateTime? targetDate,
    required MealSlot slot,
    required ClockTime windowStart,
    required ClockTime windowEnd,
    required DateTime nowUtc,
    ServiceCalendar calendar = const ServiceCalendar(),
  }) =>
      scheduleFor(
        targetDate: targetDate,
        slot: slot,
        windowStart: windowStart,
        windowEnd: windowEnd,
        nowUtc: nowUtc,
        clockIsSynced: true,
        calendar: calendar,
      );
}

/// Why a hunt is or is not scheduled.
enum HuntScheduleStatus {
  /// The hunt has a schedule, and the wake instant is known.
  scheduled,

  /// The hunt is switched off, so it must not run at all.
  ///
  /// Not a fault: this is the student's decision. It is a status rather than
  /// an absence, because the screen has to say *why* the hunt will not start.
  disabled,

  /// The hunt has no target date, so there is nothing to aim at.
  noTargetDate,

  /// The meal is not served on the target date, so there is nothing to buy.
  mealNotServed,

  /// The window has already closed. The hunt has missed its moment.
  windowPassed,

  /// The window has already **opened**: the wake instant is in the past.
  ///
  /// Distinct from [windowPassed] because the two call for different things: a
  /// window that has closed is over and cannot be hunted at all, while a window
  /// that is open right now is one the hunt can still use. It is also distinct
  /// from [scheduled], and this is the distinction the device got wrong: a
  /// result that carries a start time **in the past** is not a schedule, and
  /// reporting it as one produced a card claiming «در ساعت ۱۶:۳۰ شروع میشود»
  /// at 18:11.
  ///
  /// ## What each arm does with it
  ///
  ///  * the **first arm** (the student's own switch) treats it as "start now":
  ///    it arms the instant, which is in the past, so the alarm fires at once.
  ///    That is what switching a hunt on inside its window means.
  ///  * the **re-arm** (automatic, after a run) refuses it. Arming into an open
  ///    window would restart the hunt the instant it ended — and it ended
  ///    usually because it refused, so the loop repeats for as long as the
  ///    window stays open.
  ///
  /// [HuntScheduleResult.schedule] is present for this status, because the first
  /// arm needs the instant to arm; [HuntScheduleResult.isScheduled] is false,
  /// because "will it start by itself at a named future time" is not what this
  /// means.
  windowOpen,

  /// The window ends before it starts, so it can never open.
  windowInvalid,

  /// The portal's time is unknown, so the window's instant is unknown.
  ///
  /// A schedule is a comparison between "when the window opens" and "now",
  /// and both have to be in the portal's frame. Without a synced clock the
  /// second one is only the device's idea of the time, which may be anything
  /// at all — and a hunt armed against it can fire at once.
  ///
  /// So an unsynced clock produces no schedule. It is a status rather than an
  /// absence, because the screen has to say **why** the hunt will not start
  /// and a student can act on "the clock is not synced" (open the app, let it
  /// sync) but not on silence.
  clockUnsynced,
}

/// The outcome of scheduling a hunt.
class HuntScheduleResult {
  const HuntScheduleResult({required this.status, this.schedule});

  /// Why the hunt is or is not scheduled.
  final HuntScheduleStatus status;

  /// The schedule, when there is one.
  ///
  /// Present for [HuntScheduleStatus.scheduled] **and** for
  /// [HuntScheduleStatus.windowOpen] — an open window still has a start and an
  /// end, and the first arm needs the instant. Absent for every other status,
  /// which describes a hunt that has no schedule at all.
  final HuntSchedule? schedule;

  /// Whether the hunt will start by itself at a named, **future** instant.
  ///
  /// False for [HuntScheduleStatus.windowOpen] even though it carries a
  /// schedule: a window that is already open does not "start later", it starts
  /// the moment an alarm set for its (past) start instant fires. A caller that
  /// arms only what is scheduled here therefore arms nothing for it — which is
  /// the re-arm's correct behaviour.
  bool get isScheduled =>
      status == HuntScheduleStatus.scheduled && schedule != null;

  /// Whether the hunt's window is open right now.
  ///
  /// The first arm arms it immediately; the re-arm refuses it. See
  /// [HuntScheduleStatus.windowOpen].
  bool get isOpenNow => status == HuntScheduleStatus.windowOpen;

  @override
  String toString() => 'HuntScheduleResult($status, $schedule)';
}
