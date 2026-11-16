/// Renders digests and nudge status into notification text.
///
/// Both functions here are **pure**: no clock, no I/O, no Flutter. The message
/// the user reads is the deliverable of this whole subsystem, so it is generated
/// by a pure function and asserted directly in tests rather than verified by
/// eyeballing a rendered notification.
///
/// Every string is Persian, matching the app's Persian-first RTL design.
library;

import '../meal/models.dart';
import '../shared/next_week.dart';
import '../shared/persian.dart';
import 'reminder.dart';
import '../shared/time.dart';

/// Maximum gaps listed in a nudge body before truncating.
///
/// A notification body is not a scrollable report; the detail screen shows all.
const int maxGapsListed = 5;

/// One held meal, as the offline reminder needs it.
///
/// Deliberately flat: the reminder reads the **local store**, so it must not
/// depend on a live portal read, and it must not need a session.
class HeldMealDigest {
  const HeldMealDigest({
    required this.accountId,
    required this.displayName,
    required this.date,
    required this.slot,
    this.dishName,
    this.hallName,
    this.priceRial,
  });

  final AccountId accountId;
  final String displayName;
  final DateTime date;
  final MealSlot slot;
  final String? dishName;
  final String? hallName;
  final int? priceRial;
}

/// Renders the offline daily reminder.
///
/// This is the message the product owner described: what each selected account
/// is collecting, by meal, with the dish and the hall.
///
/// Sections are grouped by meal, in the order the portal serves them. An account
/// with nothing in a section is simply absent from it, because the section
/// lists only what is actually held.
NotificationText composeReminderText({
  required ReminderSlot slot,
  required List<HeldMealDigest> meals,
  required DateTime now,
}) {
  final covered = _slotsFor(slot);
  final title = switch (slot) {
    ReminderSlot.lunch => '🍽 یادآور ناهار',
    ReminderSlot.evening => '🌙 یادآور شام',
  };

  final sections = <String>[];
  for (final mealSlot in covered) {
    final inSlot = meals.where((m) => m.slot == mealSlot).toList();
    if (inSlot.isEmpty) continue;

    final header = _reminderSectionHeader(mealSlot, inSlot, now);
    final lines = inSlot.map((m) {
      final dish = m.dishName ?? _mealName(mealSlot);
      final hall = m.hallName;
      return hall == null
          ? '• ${m.displayName} — $dish'
          : '• ${m.displayName} — $dish — $hall';
    });
    sections.add('$header\n${lines.join('\n')}');
  }

  final body = sections.isEmpty
      ? composeEmptyReminderText(slot: slot).body
      : sections.join('\n\n');

  final multiAccount = formatMultiAccountNotification(meals);

  return NotificationText(
    title: title,
    body: body,
    summary: '${toPersianDigits(meals.length)} وعده',
    multiAccountText: multiAccount.isNotEmpty ? multiAccount : null,
  );
}

/// Renders the reminder that says nothing is reserved for [slot].
///
/// A silent reminder is indistinguishable from a broken app. When the slot is
/// enabled and every selected account is empty, the student is told explicitly
/// which meal they have not reserved — in the same wording the native delivery
/// path uses.
NotificationText composeEmptyReminderText({required ReminderSlot slot}) {
  final title = switch (slot) {
    ReminderSlot.lunch => '🍽 یادآور ناهار',
    ReminderSlot.evening => '🌙 یادآور شام',
  };
  final body = switch (slot) {
    ReminderSlot.lunch => 'امروز هیچ وعده رزروشده‌ای برای ناهار ندارید.',
    ReminderSlot.evening =>
      'امروز هیچ وعده رزروشده‌ای برای شام یا صبحانه فردا ندارید.',
  };
  return NotificationText(title: title, body: body, summary: 'رزروی ثبت نشده');
}

/// Renders the multi-account reminder text:
/// `با اکانت علی غذای a را رزرو داری - با اکانت رضا غذای b را رزرو داری`
String formatMultiAccountNotification(List<HeldMealDigest> meals) {
  if (meals.isEmpty) return '';
  return meals
      .map(
        (m) =>
            'با اکانت ${m.displayName} غذای ${m.dishName ?? _mealName(m.slot)} را رزرو داری',
      )
      .join(' - ');
}

/// Renders the next-week nudge.
///
/// [accountNames] is the list of accounts that are **missing** at least one
/// meal. The message says which, and when the deadline is.
NotificationText composeNudgeText({
  required List<String> accountNames,
  required DateTime now,
}) {
  final names = accountNames.isEmpty ? 'حساب شما' : accountNames.join('، ');
  final body =
      'وعده‌های هفته آینده هنوز کامل رزرو نشده‌اند.\n'
      '$names\n'
      'مهلت رزرو: پنجشنبه ساعت ۲۰:۰۰';

  return NotificationText(
    title: '📅 یادآور رزرو هفته آینده',
    body: body,
    summary: '${toPersianDigits(accountNames.length)} حساب نیازمند بررسی',
  );
}

String _reminderSectionHeader(
  MealSlot slot,
  List<HeldMealDigest> meals,
  DateTime now,
) {
  final date = meals.first.date;
  final dateLabel = formatPersianDate(date);
  return switch (slot) {
    MealSlot.breakfast => '🍳 صبحانه ($dateLabel):',
    MealSlot.lunch => '🍽 ناهار ($dateLabel):',
    MealSlot.dinner => '🌙 شام ($dateLabel):',
  };
}

String _mealName(MealSlot slot) => switch (slot) {
  MealSlot.breakfast => 'صبحانه',
  MealSlot.lunch => 'ناهار',
  MealSlot.dinner => 'شام',
};

/// Renders a daily reminder digest.
///
/// Section rules:
///   * A meal section lists only accounts holding that reservation.
///   * A meal with no reservations anywhere omits its whole section.
///   * If every covered slot is empty, the body says so explicitly rather than
///     rendering an empty-looking notification that reads as a bug.
///   * Unchecked accounts are always named at the end. A briefing that looks
///     complete but is missing a line is the one unacceptable outcome.
NotificationText composeNotification(ReminderDigest digest) {
  final coveredSlots = _slotsFor(digest.slot);
  final title = _titleFor(digest);

  final sections = <String>[];
  for (final slot in coveredSlots) {
    final section = _sectionFor(digest, slot);
    if (section != null) sections.add(section);
  }

  final buffer = StringBuffer();
  if (sections.isEmpty) {
    buffer.write('امروز هیچ وعده رزروشده‌ای ندارید.');
  } else {
    buffer.write(sections.join('\n\n'));
  }

  final failureLine = _failureLine(digest.failures);
  if (failureLine != null) {
    buffer.write('\n\n$failureLine');
  }

  return NotificationText(
    title: title,
    body: buffer.toString(),
    summary: _summaryFor(digest, coveredSlots),
  );
}

/// Renders the next-week reservation nudge.
///
/// Callers must only invoke this when a gap exists; a complete week is meant to
/// be silent, and that decision belongs to the caller, not here.
NotificationText composeNudgeNotification(NextWeekStatus status) {
  final buffer = StringBuffer();

  buffer.write('هنوز برای هفته آینده رزرو نکرده‌اید.\n');

  final weekLabel =
      '${toJalali(status.weekStart).dayMonth} تا ${toJalali(status.weekEnd).dayMonth}';
  buffer.write('هفته آینده: $weekLabel\n');

  final deadlineLine = _deadlineLine(status);
  if (deadlineLine != null) buffer.write('$deadlineLine\n');

  buffer.write('\n');

  final shown = status.gaps.take(maxGapsListed).toList();
  for (final gap in shown) {
    buffer.write('• ${_gapLine(gap)}\n');
  }
  if (status.gaps.length > maxGapsListed) {
    final remaining = status.gaps.length - maxGapsListed;
    buffer.write('و ${toPersianDigits(remaining)} وعده دیگر\n');
  }

  final failureLine = _failureLine(status.failures);
  if (failureLine != null) {
    buffer.write('\n$failureLine');
  }

  return NotificationText(
    title: '📅 یادآوری رزرو هفته آینده',
    body: buffer.toString().trimRight(),
    summary: '${toPersianDigits(status.gaps.length)} وعده رزرو نشده است',
  );
}

/// Renders the message posted when a reminder could not run at all.
NotificationText composeFailureNotification({
  required ReminderSlot slot,
  required String reason,
}) => NotificationText(
  title: '⚠️ یادآوری انجام نشد',
  body: 'یادآوری امروز اجرا نشد.\n$reason',
);

// --- internals ---

Set<MealSlot> _slotsFor(ReminderSlot slot) => switch (slot) {
  ReminderSlot.lunch => const {MealSlot.lunch},
  ReminderSlot.evening => const {MealSlot.dinner, MealSlot.breakfast},
};

String _titleFor(ReminderDigest digest) => switch (digest.slot) {
  ReminderSlot.lunch => '🍽 یادآوری ناهار امروز',
  ReminderSlot.evening => '🌙 یادآوری شام امروز',
};

String? _sectionFor(ReminderDigest digest, MealSlot slot) {
  final entries = digest.itemsForSlot(slot);
  if (entries.isEmpty) return null;

  final header = _sectionHeader(digest, slot);
  final lines = <String>[];
  for (final (account, item) in entries) {
    lines.add('• ${account.displayName} — ${item.dishName} — ${item.hallName}');
  }
  return '$header\n${lines.join('\n')}';
}

String _sectionHeader(ReminderDigest digest, MealSlot slot) {
  final date = digest.accounts
      .expand((a) => a.items)
      .where((i) => i.slot == slot)
      .map((i) => i.date)
      .fold<DateTime?>(
        null,
        (latest, d) => latest == null || d.isAfter(latest) ? d : latest,
      );

  final dateLabel = date == null ? '' : formatPersianDate(date);

  return switch (slot) {
    MealSlot.breakfast =>
      '🍳 صبحانه فردا ($dateLabel) — همراه شام امروز تحویل می‌گیرید:',
    MealSlot.lunch => '🍽 ناهار ($dateLabel):',
    MealSlot.dinner => '🌙 شام ($dateLabel):',
  };
}

String? _failureLine(List<ReminderFailure> failures) {
  if (failures.isEmpty) return null;
  final names = failures.map((f) => f.displayName).join('، ');
  return '⚠️ بررسی نشد: $names';
}

String? _summaryFor(ReminderDigest digest, Set<MealSlot> slots) {
  var count = 0;
  for (final slot in slots) {
    count += digest.itemsForSlot(slot).length;
  }
  if (count == 0) return 'رزروی ثبت نشده';
  return '${toPersianDigits(count)} وعده رزرو شده';
}

String? _deadlineLine(NextWeekStatus status) {
  // The deadline is the portal's own cutoff (20:00 local), so it is rendered
  // from ClockTime.cutoff rather than hardcoded a second time.
  final time = formatClockTimePersian(
    ClockTime.cutoff.hour,
    ClockTime.cutoff.minute,
  );
  return 'مهلت اولین وعده: ${persianWeekdays[status.deadline.weekday]} ساعت $time';
}

String _gapLine(BookingGap gap) {
  final meal = switch (gap.slot) {
    MealSlot.breakfast => 'صبحانه',
    MealSlot.lunch => 'ناهار',
    MealSlot.dinner => 'شام',
  };
  final date = toJalali(gap.date);
  final dayLabel = '${toPersianDigits(date.day)} ${date.monthName}';
  return '$dayLabel — $meal: رزرو نشده';
}
