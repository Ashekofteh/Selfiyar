import 'dart:io';

import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:test/test.dart';

/// The live capture (2026-10-19) showed that a **locked date is refused
/// silently**: the server ignores the post with no error label, no alert box,
/// and no state change. The response page is indistinguishable from the page
/// that was posted, except that the row's checkbox is still `disabled`.
///
/// That distinction matters for the adapter: without it, "the post did not
/// take effect" is indistinguishable from a transport failure, and a caller
/// would retry a date that can never be booked.
void main() {
  final recon = Directory('recon');
  final captures = Directory('captures');

  String? read(Directory dir, String name) {
    if (!dir.existsSync()) return null;
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  group('locked rows are recognised from the server-rendered page', () {
    test(
      'the capture made today shows 1405/07/28 locked and 1405/07/30 open',
      () {
        // Captured 2026-10-19. 1405/07/28's cutoff (20:00 on 1405/07/26) had
        // passed three days earlier, so it is locked; 1405/07/30's cutoff is
        // 1405/07/28 20:00, which had not yet arrived.
        final html = read(captures, '05_reservation_page.html');
        if (html == null) return;

        final disabled = _checkedDisabledRows(html, 'grdReservationLunch');
        expect(disabled, contains('1405/07/28'));
        expect(disabled, isNot(contains('1405/07/30')));

        final editable = _editableRows(html, 'grdReservationLunch');
        expect(editable, contains('1405/07/30'));
        expect(editable, isNot(contains('1405/07/28')));
      },
    );

    test('the lock frontier moved forward one day between the two captures', () {
      // The 2026-10-18 capture (recon) had 1405/07/25..07/30 editable, with
      // 07/31+ locked. One day later, 07/25..07/29 are locked and 07/30 is
      // the only open row. The cutoff is 20:00 two days prior, so the frontier
      // advances by exactly one day each day - observed twice, on two days.
      final yesterday = read(recon, 'reservation.html');
      final today = read(captures, '05_reservation_page.html');
      if (yesterday == null || today == null) return;

      final editableYesterday = _editableRows(yesterday, 'grdReservationLunch');
      final editableToday = _editableRows(today, 'grdReservationLunch');

      expect(
        editableYesterday,
        contains('1405/07/28'),
        reason: 'on 2026-10-18 the 28th had not yet locked',
      );
      expect(
        editableToday,
        isNot(contains('1405/07/28')),
        reason: 'on 2026-10-19 the 28th had locked',
      );
      expect(editableYesterday, contains('1405/07/30'));
      expect(editableToday, contains('1405/07/30'));
    });

    test('the next week is fully editable except Friday', () {
      final html = read(captures, '23_week1.html');
      if (html == null) return;

      final editable = _editableRows(html, 'grdReservationLunch');
      expect(editable, contains('1405/08/02'));
      expect(editable, contains('1405/08/05'));
      // Friday 1405/08/08 has no service, so its row is disabled.
      expect(editable, isNot(contains('1405/08/08')));
    });

    test('a week with no published menu has no editable rows', () {
      // 1405/08/09 onwards is beyond the publish horizon: every row renders '-'.
      final html = read(captures, '23_week2.html');
      if (html == null) return;

      expect(_editableRows(html, 'grdReservationLunch'), isEmpty);
    });
  });

  group('the refusal is silent', () {
    test('the refused response carries no error message', () {
      final html = read(captures, '11_reserve_response_hall1.html');
      if (html == null) return;

      // The server's error channel is cphMain_alertBoxValue. A locked row
      // bypasses it entirely, which is why the adapter must not wait for an
      // error before concluding the post failed.
      final alert = _textById(html, 'cphMain_alertBoxValue');
      expect(alert, isNull);
    });

    test('the request and the response agree that the row is locked', () {
      final request = read(captures, '05_reservation_page.html');
      final response = read(captures, '11_reserve_response_hall1.html');
      if (request == null || response == null) return;

      expect(
        _checkedDisabledRows(request, 'grdReservationLunch'),
        _checkedDisabledRows(response, 'grdReservationLunch'),
        reason: 'a refused post leaves the grid unchanged',
      );
    });
  });

  group('ReservationLockedException', () {
    test('carries the date and slot it refused', () {
      final target = DateTime.utc(2026, 10, 20);
      final exception = ReservationLockedException(
        'مهلت رزرو این تاریخ به پایان رسیده است.',
        date: target,
        slot: MealSlot.lunch,
      );
      expect(exception.date, target);
      expect(exception.slot, MealSlot.lunch);
      expect(exception.toString(), contains('ReservationLockedException'));
    });
  });
}

/// The dates whose row is rendered `disabled`.
List<String> _checkedDisabledRows(String html, String gridId) {
  final rows = _rows(html, gridId);
  return rows.where((r) => r.disabled).map((r) => r.label).toList();
}

/// The dates whose row is editable.
List<String> _editableRows(String html, String gridId) {
  final rows = _rows(html, gridId);
  return rows.where((r) => !r.disabled).map((r) => r.label).toList();
}

class _Row {
  _Row(this.label, this.disabled);
  final String label;
  final bool disabled;
}

List<_Row> _rows(String html, String gridId) {
  final table = RegExp(
    '<table[^>]*id="[^"]*${RegExp.escape(gridId)}"[^>]*>(.*?)</table>',
    dotAll: true,
  ).firstMatch(html);
  if (table == null) return const [];

  final out = <_Row>[];
  for (final m in RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    dotAll: true,
  ).allMatches(table.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(
      r'<td[^>]*>(.*?)</td>',
      dotAll: true,
    ).allMatches(raw).map((c) => c.group(1)!).toList();
    if (cells.length < 4) continue;

    final label = cells[1]
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // The label is `<weekday> <yyyy/mm/dd>`; the date part is the identity.
    final date = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(label)?.group(0);
    if (date == null) continue;

    final cb = RegExp(
      r'<input[^>]*type="checkbox"[^>]*>',
      dotAll: true,
    ).firstMatch(raw);
    out.add(_Row(date, (cb?.group(0) ?? '').contains('disabled')));
  }
  return out;
}

String? _textById(String html, String id) {
  final m = RegExp(
    'id="[^"]*${RegExp.escape(id)}"[^>]*>(.*?)<',
    dotAll: true,
  ).firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
