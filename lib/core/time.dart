/// Time handling for the Food Basket app.
///
/// The portal's servers define the reservation cutoff, so every cutoff decision
/// must be made against *server* time, never the device clock. Android device
/// clocks drift and users change timezones by hand; computing "20:00 two days
/// prior" locally on a skewed clock produces either false refusals (locking a
/// meal the student could still book) or early snipes (a burst of rejected
/// requests that looks exactly like an attack).
library;

import 'models.dart' show MealSlot;

/// A time of day with no date and no timezone.
///
/// Deliberately not Flutter's `TimeOfDay`: this library must stay pure Dart so
/// the domain remains testable on the VM (see README / spec §3.1).
class ClockTime implements Comparable<ClockTime> {
  const ClockTime(int hour, int minute)
      : assert(hour >= 0 && hour < 24, 'hour must be 0..23'),
        assert(minute >= 0 && minute < 60, 'minute must be 0..59'),
        minutesSinceMidnight = hour * 60 + minute;

  const ClockTime.fromMinutes(int minutes)
      : assert(minutes >= 0 && minutes < 1440, 'minutes must be 0..1439'),
        minutesSinceMidnight = minutes;

  final int minutesSinceMidnight;

  int get hour => minutesSinceMidnight ~/ 60;
  int get minute => minutesSinceMidnight % 60;

  /// The portal's reservation cutoff: 20:00 local.
  static const ClockTime cutoff = ClockTime(20, 0);

  @override
  int compareTo(ClockTime other) =>
      minutesSinceMidnight.compareTo(other.minutesSinceMidnight);

  bool operator <(ClockTime other) => compareTo(other) < 0;
  bool operator <=(ClockTime other) => compareTo(other) <= 0;
  bool operator >(ClockTime other) => compareTo(other) > 0;
  bool operator >=(ClockTime other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.minutesSinceMidnight == minutesSinceMidnight;

  @override
  int get hashCode => minutesSinceMidnight.hashCode;

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Server clock. All cutoff logic derives from here.
///
/// Implementations obtain "now" from the portal (HTTP `Date` headers, corrected
/// for round-trip latency). A device-clock fallback is deliberately absent: if
/// the clock is not synced, callers must refuse to run auto-reserve rather than
/// guess.
abstract class ServerClock {
  /// Server's current instant, as UTC.
  DateTime get nowUtc;

  /// True once at least one sync has succeeded.
  bool get isSynced;

  /// How old the last successful sync is. Callers decide staleness policy.
  Duration get staleness;

  /// Days between the target meal date and its reservation deadline.
  ///
  /// Regulation 2091: reservations close at 20:00 on the day that is *two*
  /// calendar days before the meal date.
  static const int cutoffDaysBefore = 2;

  /// The portal's timezone offset. Iran abolished daylight saving in 2022, so
  /// UTC+3:30 applies year-round. Held as a constant to keep the arithmetic
  /// explicit and easy to revisit if DST is ever reinstated.
  static const Duration portalUtcOffset = Duration(hours: 3, minutes: 30);
}

/// A [`ServerClock`] backed by an explicit instant plus a sync timestamp.
///
/// Tests drive this directly; the live adapter feeds it from response headers.
class FixedServerClock implements ServerClock {
  FixedServerClock({required DateTime serverNowUtc, required this.syncedAt})
      : nowUtc = serverNowUtc.toUtc(),
        _syncAge = DateTime.now().toUtc().difference(syncedAt);

  /// Convenience for tests: a clock that believes it was synced just now.
  factory FixedServerClock.now(DateTime serverNowUtc) =>
      FixedServerClock(serverNowUtc: serverNowUtc, syncedAt: DateTime.now().toUtc());

  @override
  final DateTime nowUtc;

  final DateTime syncedAt;
  final Duration _syncAge;

  @override
  bool get isSynced => true;

  @override
  Duration get staleness => _syncAge;
}

/// A [`ServerClock`] whose time the test moves.
///
/// The hunt's behaviour depends on the passage of time: it waits for its
/// window to open, and it stops when the window closes. A clock frozen at one
/// instant cannot exercise either, so a test that needs the transition drives
/// this clock instead.
///
/// It is in `lib/core` rather than in the test tree because the engine's
/// behaviour over time is a *domain* property, and a test double for a domain
/// property belongs next to the property.
class MovableServerClock implements ServerClock {
  MovableServerClock(DateTime serverNowUtc)
      : _nowUtc = serverNowUtc.toUtc(),
        _syncedAt = DateTime.now().toUtc();

  DateTime _nowUtc;
  final DateTime _syncedAt;

  /// Moves the clock forward.
  void advance(Duration d) => _nowUtc = _nowUtc.add(d);

  /// Moves the clock to an absolute instant.
  void set(DateTime serverNowUtc) => _nowUtc = serverNowUtc.toUtc();

  @override
  DateTime get nowUtc => _nowUtc;

  @override
  bool get isSynced => true;

  @override
  Duration get staleness => DateTime.now().toUtc().difference(_syncedAt);
}

/// A [`ServerClock`] kept in step with the portal by observing its responses.
///
/// The portal sends a standard RFC 1123 `Date` header. Treating that as the
/// server's time *at the moment the response was generated*, and correcting for
/// half the observed round trip, gives an estimate good to well under a second
/// on a normal connection — far tighter than the minute-level precision the
/// 20:00 cutoff needs.
///
/// The local clock is injected so the class is testable without waiting for real
/// time to pass. Nothing here reads `DateTime.now()` implicitly.
class SyncedServerClock implements ServerClock {
  SyncedServerClock({DateTime Function()? localNowUtc})
      : _localNowUtc = localNowUtc ?? (() => DateTime.now().toUtc());

  final DateTime Function() _localNowUtc;

  /// serverTime - localTime, established by the most recent sync.
  Duration? _offset;

  /// Local instant of the most recent sync.
  DateTime? _lastSyncLocalUtc;

  @override
  bool get isSynced => _offset != null;

  @override
  Duration get staleness {
    final last = _lastSyncLocalUtc;
    if (last == null) return Duration.zero;
    return _localNowUtc().difference(last);
  }

  @override
  DateTime get nowUtc {
    final offset = _offset;
    if (offset == null) {
      throw StateError(
        'ServerClock is not synced. Callers must check isSynced before reading '
        'time: guessing here would produce a briefing about the wrong day.',
      );
    }
    return _localNowUtc().add(offset);
  }

  /// Records an observation from a portal response.
  ///
  /// The portal sends a `Date` header on every response, so the clock does not
  /// need a request of its own: any response is an opportunity to sync. A
  /// response with no `Date` header is simply not an observation, and is
  /// ignored rather than treated as a failure — the next response will carry
  /// one.
  ///
  /// [serverDateUtc] is the parsed `Date` header, [roundTrip] the measured time
  /// from sending the request to receiving the response, and [localReceivedAt]
  /// the local instant the response arrived.
  void observe({
    DateTime? serverDateUtc,
    required Duration roundTrip,
    required DateTime localReceivedAt,
  }) {
    if (serverDateUtc == null) return;
    syncFrom(
      serverDateUtc: serverDateUtc,
      roundTrip: roundTrip,
      localReceivedAt: localReceivedAt,
    );
  }

  /// Records a sync from a response.
  ///
  /// [serverDateUtc] is the parsed `Date` header, [roundTrip] the measured time
  /// from sending the request to receiving the response, and [localReceivedAt]
  /// the local instant the response arrived.
  void syncFrom({
    required DateTime serverDateUtc,
    required Duration roundTrip,
    required DateTime localReceivedAt,
  }) {
    // The header reflects when the server generated the response, which was
    // roughly half a round trip ago.
    final estimatedServerNow =
        serverDateUtc.add(Duration(microseconds: roundTrip.inMicroseconds ~/ 2));
    _offset = estimatedServerNow.difference(localReceivedAt);
    _lastSyncLocalUtc = localReceivedAt;
  }

  /// Discards the sync, so callers stop trusting this clock.
  ///
  /// Used when the app is backgrounded for a long time, where an offset measured
  /// hours ago may no longer hold.
  void invalidate() {
    _offset = null;
    _lastSyncLocalUtc = null;
  }

  /// The current offset, for diagnostics. Null when never synced.
  Duration? get offset => _offset;
}

/// Cutoff arithmetic. Pure functions over a [ServerClock], so tests can pin the
/// boundary exactly.
extension ReservationCutoff on ServerClock {
  /// `nowUtc` expressed as the portal's local wall clock.
  DateTime get portalNow =>
      nowUtc.add(ServerClock.portalUtcOffset);

  /// The date-only "today" as the portal sees it.
  ///
  /// Built with `DateTime.utc` deliberately: this is a *civil date* in the
  /// portal's frame, and using `DateTime(...)` (local) would re-introduce the
  /// device timezone we are trying to escape.
  DateTime get portalTodayUtc => DateTime.utc(
        portalNow.year,
        portalNow.month,
        portalNow.day,
      );

  /// The instant reservations lock for [targetDate].
  ///
  /// [targetDate] is a civil date (its time component is ignored). Returns a UTC
  /// instant corresponding to 20:00 portal-local, two days before the target.
  DateTime reservationLockTimeUtc(DateTime targetDate) {
    // 20:00 portal-local == 20:00 - 3:30 == 16:30 UTC on the same civil day.
    final lockDayUtc = DateTime.utc(
      targetDate.year,
      targetDate.month,
      targetDate.day - ServerClock.cutoffDaysBefore,
    );
    return DateTime.utc(
      lockDayUtc.year,
      lockDayUtc.month,
      lockDayUtc.day,
      ClockTime.cutoff.hour,
      0,
    ).subtract(ServerClock.portalUtcOffset);
  }

  /// True when reservations for [targetDate] are closed.
  bool isLocked(DateTime targetDate) =>
      !nowUtc.isBefore(reservationLockTimeUtc(targetDate));

  /// Still reservable?
  bool isReservable(DateTime targetDate) => !isLocked(targetDate);

  /// The first civil date beyond the cutoff wall — the earliest meal the student
  /// could still reserve today.
  ///
  /// If now is before today's 20:00 cutoff, the day after tomorrow is still open;
  /// once the cutoff passes, it rolls forward one more day.
  DateTime firstReservableDate() {
    final today = portalTodayUtc;
    final candidate = DateTime.utc(today.year, today.month, today.day + ServerClock.cutoffDaysBefore);
    return isReservable(candidate)
        ? candidate
        : DateTime.utc(candidate.year, candidate.month, candidate.day + 1);
  }

  /// Minutes until [targetDate] locks. Negative once locked.
  int minutesUntilLock(DateTime targetDate) =>
      reservationLockTimeUtc(targetDate).difference(nowUtc).inMinutes;
}

/// The distribution / collection date for a meal.
///
/// Breakfast is distributed the evening before with dinner (day - 1),
/// whereas lunch and dinner are distributed on the meal date itself.
DateTime mealDistributionDate(DateTime mealDate, MealSlot slot) {
  final day = DateTime.utc(mealDate.year, mealDate.month, mealDate.day);
  if (slot == MealSlot.breakfast) {
    return day.subtract(const Duration(days: 1));
  }
  return day;
}

/// The end of distribution for each meal slot on its collection date.
///
/// Both dinner and tomorrow's breakfast are distributed together in the evening
/// until 20:30 portal-local time. Lunch is distributed until 15:30.
ClockTime distributionEndFor(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => const ClockTime(20, 30),
      MealSlot.lunch => const ClockTime(15, 30),
      MealSlot.dinner => const ClockTime(20, 30),
    };

/// Checks locally whether the distribution hour for a meal has passed.
///
/// Tomorrow's breakfast is distributed with today's dinner (ending at 20:30
/// on the day prior to the breakfast). Lunch ends at 15:30 on the meal date,
/// and dinner ends at 20:30 on the meal date.
bool isMealDistributionPassed(
  DateTime mealDate,
  MealSlot slot, {
  ServerClock? clock,
  DateTime? now,
}) {
  final DateTime portalNow;
  if (clock != null && clock.isSynced) {
    portalNow = clock.portalNow;
  } else {
    portalNow = (now ?? DateTime.now()).toUtc().add(ServerClock.portalUtcOffset);
  }

  final todayUtc = DateTime.utc(portalNow.year, portalNow.month, portalNow.day);
  final distDayUtc = mealDistributionDate(mealDate, slot);

  if (distDayUtc.isBefore(todayUtc)) return true;
  if (distDayUtc.isAfter(todayUtc)) return false;

  final current = ClockTime(portalNow.hour, portalNow.minute);
  return current > distributionEndFor(slot);
}