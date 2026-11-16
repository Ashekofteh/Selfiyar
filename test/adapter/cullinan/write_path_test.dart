import 'dart:io';

import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';import 'package:test/test.dart';

/// Regression tests for the write path, encoding what the live captures
/// established. These are the facts that cost a cycle each to learn, so they
/// are pinned here rather than left in a findings document.
///
/// The `recon/` and `captures/` directories are git-ignored, so the tests skip
/// cleanly when they are absent.
void main() {
  String? read(String name) {
    for (final dir in ['recon', 'captures']) {
      final file = File('$dir/$name');
      if (file.existsSync()) return file.readAsStringSync();
    }
    return null;
  }

  group('F13 - "checked" is not "held"', () {
    test('a booked row has a non-zero amount and the reserved icon', () {
      final html = read('52_book_response.html');
      if (html == null) return;

      final grid = _grid(html, 'grdReservationBreakfast');
      final row = _rowFor(grid, '1405/08/03');
      if (row == null) return;

      expect(row.checked, isTrue, reason: 'the booked row renders checked');
      expect(row.amount, greaterThan(0),
          reason: 'a genuinely held meal has a non-zero amount');
      expect(row.reservedIcon, isTrue,
          reason: 'a genuinely held meal carries the رزرو شده icon');
    });

    test('rows that merely echo "checked" have zero amount and no icon', () {
      final html = read('52_book_response.html');
      if (html == null) return;

      // The booking POST also set the lunch and dinner rows' checkboxes, so
      // the response renders them checked — but they were never charged.
      for (final gridId in ['grdReservationLunch', 'grdReservationDinner']) {
        final row = _rowFor(_grid(html, gridId), '1405/08/03');
        if (row == null) continue;
        expect(row.checked, isTrue,
            reason: 'the portal echoes the posted checkbox state');
        expect(row.amount, 0,
            reason: 'an echoed row was never charged');
        expect(row.reservedIcon, isFalse,
            reason: 'an echoed row carries no reserved icon');
      }
    });
  });

  group('F15 - the price lives in the option text', () {
    test('the amount cell is 0 for an unbooked row', () {
      final html = read('60_week_with_booking.html');
      if (html == null) return;

      final grid = _grid(html, 'grdReservationLunch');
      final row = _rowFor(grid, '1405/08/02');
      if (row == null) return;

      expect(row.amount, 0,
          reason: 'an unbooked row shows 0 in the amount cell');
      expect(row.foodOptions, isNotEmpty,
          reason: 'the price is in the food option text instead');
      expect(row.foodOptions.first, contains('ریال'),
          reason: 'the option text carries the price');
    });
  });

  group('the reservation write path', () {
    test('the grid control name index is the ROW position, not the date', () {
      // The same names appear in every week, which is why the viewstate
      // decides which week a post affects.
      final thisWeek = read('05_reservation_page.html');
      final nextWeek = read('50_next_week.html');
      if (thisWeek == null || nextWeek == null) return;

      final namesThisWeek = _checkboxNames(thisWeek);
      final namesNextWeek = _checkboxNames(nextWeek);
      expect(namesThisWeek, isNotEmpty);
      expect(namesNextWeek, namesThisWeek,
          reason: 'control names are identical across weeks');
    });

    test('the name index and the id index differ', () {
      // `$ctl05$chkReserve` vs `chkReserve_3`: the name counts data rows, the
      // id counts rendered rows including the header. Parsing must use `name`,
      // because that is what the POST sends.
      final html = read('05_reservation_page.html');
      if (html == null) return;

      final mismatch = _findNameIdMismatch(html);
      expect(mismatch, isNotNull,
          reason: 'the capture should contain rows where the two indices differ');
      expect(mismatch!.nameIndex, isNot(mismatch.idIndex));
    });

    test('a locked row is disabled and a live row is not', () {
      final html = read('05_reservation_page.html');
      if (html == null) return;

      final grid = _grid(html, 'grdReservationLunch');
      final locked = _rowFor(grid, '1405/07/28');
      final open = _rowFor(grid, '1405/07/30');

      if (locked != null) {
        expect(locked.disabled, isTrue,
            reason: '1405/07/28 was past its cutoff');
      }
      if (open != null) {
        expect(open.disabled, isFalse,
            reason: '1405/07/30 had not yet reached its cutoff');
      }
    });
  });

  group('the cancel', () {
    test('the cancel response still shows the pre-refund balance', () {
      // The refund is applied after the page renders, so the response of the
      // cancel POST shows the OLD balance. Asserting on it would have
      // "failed" a perfectly good cancel.
      final html = read('62_cancel_response.html');
      if (html == null) return;

      expect(_credit(html), 350000,
          reason: 'the cancel response renders before the refund lands');
    });

    test('a fresh read shows the original balance, with the meal refunded', () {
      final html = read('63_after_cancel_fresh_read.html');
      if (html == null) return;

      expect(_credit(html), 500000,
          reason: 'the original balance, with the 150,000 refunded');
    });

    test('after the cancel the target week holds nothing', () {
      final html = read('62_cancel_response.html');
      if (html == null) return;

      final held = CullinanParser.parseReservations(html)
          .where((r) => r.date == DateTime.utc(2026, 10, 25))
          .toList();
      expect(held, isEmpty);
    });
  });
}

/// A parsed grid row, with the fields the write path cares about.
class _Row {
  _Row({
    required this.date,
    required this.checked,
    required this.disabled,
    required this.amount,
    required this.reservedIcon,
    required this.foodOptions,
  });

  final String date;
  final bool checked;
  final bool disabled;
  final int amount;
  final bool reservedIcon;
  final List<String> foodOptions;
}

String _grid(String html, String gridId) {
  final m = RegExp(
    '<table[^>]*id="[^"]*${RegExp.escape(gridId)}"[^>]*>(.*?)</table>',
      dotAll: true)
      .firstMatch(html);
  return m?.group(1) ?? '';
}

_Row? _rowFor(String gridBody, String date) {
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(gridBody)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 7) continue;

    final label = _text(cells[1]);
    if (!label.contains(date)) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final cbTag = cb?.group(0) ?? '';
    final amount =
        int.tryParse(_text(cells[6]).replaceAll(RegExp(r'\D'), '')) ?? 0;

    final food = RegExp(r'<select[^>]*name="[^"]*drpFood"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final options = <String>[];
    if (food != null) {
      for (final o in RegExp(r'<option[^>]*>(.*?)</option>', dotAll: true)
          .allMatches(food.group(1)!)) {
        options.add(_text(o.group(1)!));
      }
    }

    return _Row(
      date: date,
      checked: cbTag.contains('checked'),
      disabled: cbTag.contains('disabled'),
      amount: amount,
      reservedIcon: raw.contains('imgStaus'),
      foodOptions: options,
    );
  }
  return null;
}

List<String> _checkboxNames(String html) {
  final names = <String>[];
  for (final m in RegExp(r'<input[^>]*type="checkbox"[^>]*name="([^"]+)"', dotAll: true)
      .allMatches(html)) {
    names.add(m.group(1)!);
  }
  names.sort();
  return names;
}

/// The name index and the id index of one checkbox, for comparison.
class _Mismatch {
  _Mismatch(this.nameIndex, this.idIndex);
  final String nameIndex;
  final String idIndex;
}

_Mismatch? _findNameIdMismatch(String html) {
  for (final m in RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
      .allMatches(html)) {
    final tag = m.group(0)!;
    final name = RegExp(r'name="([^"]*chkReserve)"').firstMatch(tag)?.group(1);
    final id = RegExp(r'id="([^"]*chkReserve_\d+)"').firstMatch(tag)?.group(1);
    if (name == null || id == null) continue;

    final nameIndex = RegExp(r'\$(ctl\d+)\$').firstMatch(name)?.group(1);
    final idIndex = RegExp(r'_(\d+)$').firstMatch(id)?.group(1);
    if (nameIndex == null || idIndex == null) continue;
    if (nameIndex != idIndex) return _Mismatch(nameIndex, idIndex);
  }
  return null;
}

int? _credit(String html) {
  final m = RegExp('<label[^>]*id="lblCredit"[^>]*>(.*?)</label>', dotAll: true)
      .firstMatch(html);
  if (m == null) return null;
  return int.tryParse(_text(m.group(1)!).replaceAll(RegExp(r'\D'), ''));
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
