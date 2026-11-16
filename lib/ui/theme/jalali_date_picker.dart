/// A date picker in the Jalali calendar.
///
/// ## Why this exists
///
/// Flutter's own [MaterialLocalizations] has no Persian calendar, so
/// `showDatePicker` under the `fa` locale renders a **Gregorian** calendar
/// with Persian digits and Persian weekday names: "دوشنبه ۱۹ اکتبر ۲۰۲۶".
/// That is a hybrid no Iranian reader has ever seen — the portal itself dates
/// everything in Jalali, and so does the rest of this app.
///
/// So the calendar is drawn here, on top of the app's own verified
/// [toJalali] / [fromJalali] conversion.
///
/// The conversion is the authority. The month lengths come from
/// [jalaliMonthLength], which is checked against that conversion for two
/// hundred years — see `persian_test.dart`. A calendar that disagrees with
/// the conversion would render a day that does not exist.
library;

import 'package:flutter/material.dart';

import '../../core/shared/persian.dart';

/// The weekday names, abbreviated to fit a calendar column.
///
/// A Persian calendar's weekday headers are conventionally the first letter
/// of the name — "ش ی د س چ ب ج" — precisely because the full names do not
/// fit a seventh of the width.
///
/// Indexed by [DateTime.weekday], like [persianWeekdays]: Monday is 1 and
/// Sunday is 7.
const List<String> _shortWeekdays = [
  '',
  'د', // Monday
  'س', // Tuesday
  'چ', // Wednesday
  'پ', // Thursday
  'ج', // Friday
  'ش', // Saturday
  'ی', // Sunday
];

/// Shows a Jalali calendar and returns the chosen date.
///
/// Returns null if the user dismisses the picker. [initial] is the date the
/// calendar opens on; [first] and [last] bound what can be chosen.
///
/// [isSelectable] narrows the range further, for the days inside the range
/// that are nevertheless unavailable — a day the dining halls are closed, say.
/// A day it rejects is drawn disabled, the same as a day outside the range.
Future<DateTime?> showJalaliDatePicker({
  required BuildContext context,
  required DateTime initial,
  required DateTime first,
  required DateTime last,
  bool Function(DateTime date)? isSelectable,
  String helpText = 'انتخاب تاریخ',
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (context) => _JalaliDatePickerDialog(
      initial: initial,
      first: first,
      last: last,
      isSelectable: isSelectable,
      helpText: helpText,
    ),
  );
}

/// The picker dialog.
class _JalaliDatePickerDialog extends StatefulWidget {
  const _JalaliDatePickerDialog({
    required this.initial,
    required this.first,
    required this.last,
    required this.isSelectable,
    required this.helpText,
  });

  final DateTime initial;
  final DateTime first;
  final DateTime last;
  final bool Function(DateTime date)? isSelectable;
  final String helpText;

  @override
  State<_JalaliDatePickerDialog> createState() =>
      _JalaliDatePickerDialogState();
}

class _JalaliDatePickerDialogState extends State<_JalaliDatePickerDialog> {
  late JalaliDate _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();

    // The initial date can be outside the range — a stored configuration
    // naming a date the portal no longer serves. Opening on it would show a
    // month of entirely disabled days, so the calendar opens on the nearest
    // date it can actually offer.
    _selected = _clampToRange(widget.initial);
    _month = toJalali(_selected);
  }

  /// The first of the month being shown.
  DateTime get _monthStart =>
      fromJalali(JalaliDate(_month.year, _month.month, 1));

  /// The day of the week the month starts on.
  ///
  /// The Jalali week begins on Saturday, and [DateTime.weekday] has Sunday as
  /// its first day, so the two are offset: a month starting on Wednesday
  /// leaves four columns empty (Saturday, Sunday, Monday, Tuesday).
  int get _leadingBlanks => (_monthStart.weekday + 1) % 7;

  /// The [DateTime.weekday] of the column at index [i].
  ///
  /// Index 0 is the **first** column of the week, which in the Persian week
  /// is Saturday. The layout is right-to-left, so the first column is the
  /// rightmost one on screen.
  ///
  /// [DateTime.weekday] runs Monday=1 … Sunday=7, and Saturday is 6, so the
  /// week runs 6, 7, 1, 2, 3, 4, 5 from the first column.
  static int _weekdayAt(int i) {
    const order = [6, 7, 1, 2, 3, 4, 5];
    return order[i % 7];
  }

  void _shiftMonth(int months) {
    var year = _month.year;
    var month = _month.month + months;
    while (month > 12) {
      month -= 12;
      year++;
    }
    while (month < 1) {
      month += 12;
      year--;
    }
    setState(() => _month = JalaliDate(year, month, 1));
  }

  /// Whether the calendar may move a month in [months]' direction.
  ///
  /// A month entirely outside the range has nothing to offer, so the arrow is
  /// disabled rather than letting the user wander into a blank grid.
  bool _canShift(int months) {
    final shifted = _shiftedMonth(months);
    final start = fromJalali(shifted);
    final length = jalaliMonthLength(shifted.year, shifted.month);
    final end = fromJalali(JalaliDate(shifted.year, shifted.month, length));

    return !end.isBefore(_dayOnly(widget.first)) &&
        !start.isAfter(_dayOnly(widget.last));
  }

  /// The month [months] away from the one being shown.
  JalaliDate _shiftedMonth(int months) {
    var year = _month.year;
    var month = _month.month + months;
    while (month > 12) {
      month -= 12;
      year++;
    }
    while (month < 1) {
      month += 12;
      year--;
    }
    return JalaliDate(year, month, 1);
  }

  /// The nearest date inside the range.
  DateTime _clampToRange(DateTime date) {
    final first = _dayOnly(widget.first);
    final last = _dayOnly(widget.last);
    if (date.isBefore(first)) return first;
    if (date.isAfter(last)) return last;
    return _dayOnly(date);
  }

  bool _isSelectable(DateTime date) {
    if (date.isBefore(_dayOnly(widget.first))) return false;
    if (date.isAfter(_dayOnly(widget.last))) return false;
    return widget.isSelectable?.call(date) ?? true;
  }

  static DateTime _dayOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = jalaliMonthLength(_month.year, _month.month);
    final days = List.generate(length, (i) => i + 1);

    return AlertDialog(
      title: Text(widget.helpText),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // The first child of an RTL row is the *rightmost* one, so this
                // is the previous-month button.
                //
                // The chevrons carry `matchTextDirection`, so Flutter mirrors
                // them under RTL — which would point both arrows inward, at the
                // month name, and make a calendar whose arrows point the wrong
                // way. Forcing LTR on the icon draws the glyph as authored:
                // the right-hand arrow points right, the left-hand one left.
                IconButton(
                  onPressed: _canShift(-1) ? () => _shiftMonth(-1) : null,
                  icon: const Icon(
                    Icons.chevron_right,
                    textDirection: TextDirection.ltr,
                  ),
                  tooltip: 'ماه قبل',
                ),
                Expanded(
                  child: Text(
                    '${persianMonths[_month.month]} ${toPersianDigits(_month.year)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: _canShift(1) ? () => _shiftMonth(1) : null,
                  icon: const Icon(
                    Icons.chevron_left,
                    textDirection: TextDirection.ltr,
                  ),
                  tooltip: 'ماه بعد',
                ),
              ],
            ),
            const SizedBox(height: 4),
            // The weekday headers. The Jalali week starts on Saturday, and
            // [DateTime.weekday] has Sunday first, so the list is rotated.
            //
            // The names are shortened: "سه‌شنبه" does not fit a seventh of
            // the width without wrapping, and a header that wraps onto two
            // lines pushes the whole grid down.
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Center(
                      child: Text(
                        _shortWeekdays[_weekdayAt(i)],
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.4,
              children: [
                for (var i = 0; i < _leadingBlanks; i++)
                  const SizedBox.shrink(),
                for (final day in days)
                  _DayCell(
                    day: day,
                    selected: _sameDay(
                      fromJalali(JalaliDate(_month.year, _month.month, day)),
                      _selected,
                    ),
                    enabled: _isSelectable(
                      fromJalali(JalaliDate(_month.year, _month.month, day)),
                    ),
                    onTap: () => Navigator.of(context).pop(
                      fromJalali(JalaliDate(_month.year, _month.month, day)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('لغو'),
        ),
      ],
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// One day in the calendar grid.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final int day;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? theme.colorScheme.primary : null,
        ),
        child: Text(
          toPersianDigits(day),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected
                ? theme.colorScheme.onPrimary
                : enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.3),
            fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
