import 'dart:io';

import 'package:test/test.dart';

/// Regression tests for the Food Basket purchase, from the live purchase
/// executed 2026-10-19 (option 62738, چلو اکبرجوجه, hall Central, 500,000
/// Rial).
///
/// The `recon/` and `captures/` directories are git-ignored, so these skip
/// cleanly when they are absent.
void main() {
  String? read(String name) {
    for (final dir in ['recon', 'captures']) {
      final file = File('$dir/$name');
      if (file.existsSync()) return file.readAsStringSync();
    }
    return null;
  }

  group('F17 - a basket purchase lands only in the ledger', () {
    test('the weekly reservation grid is unchanged by the purchase', () {
      final before = read('70_reservation_hub.html');
      final after = read('84_weekly_after.html');
      if (before == null || after == null) return;

      // The lunch row for 1405/07/28, before and after.
      final beforeRow = _weeklyRow(before, 'grdReservationLunch', '1405/07/28');
      final afterRow = _weeklyRow(after, 'grdReservationLunch', '1405/07/28');
      if (beforeRow == null || afterRow == null) return;

      expect(afterRow.checked, beforeRow.checked,
          reason: 'the purchase did not make the weekly row checked');
      expect(afterRow.amount, beforeRow.amount,
          reason: 'the purchase did not charge the weekly row');
    });

    test('the purchase appears as a ledger row', () {
      final before = read('80_ledger_before.html');
      final after = read('85_ledger_after.html');
      if (before == null || after == null) return;

      // The full history lives in the detail sub-grids (F20).
      final beforeRows = _detailRows(before);
      final afterRows = _detailRows(after);

      expect(beforeRows.any((r) => r.contains('اکبرجوجه')), isFalse);
      expect(afterRows.any((r) => r.contains('اکبرجوجه')), isTrue,
          reason: 'the purchase is recorded in the transaction ledger');
      expect(afterRows.any((r) => r.contains('1405/07/28')), isTrue);
    });
  });

  group('F20 - the ledger main grid holds only the newest transaction', () {
    test('the main grid has one row, the detail sub-grids have the history', () {
      final html = read('85_ledger_after.html');
      if (html == null) return;

      expect(_mainGridRows(html).length, 1,
          reason: 'the main grid shows only the most recent transaction');

      final detail = _detailRows(html);
      expect(detail.length, greaterThan(1),
          reason: 'the full history lives in the detail sub-grids');
      expect(detail.any((r) => r.contains('اکبرجوجه')), isTrue);
    });

    test('the newest ledger row is the purchase', () {
      final html = read('85_ledger_after.html');
      if (html == null) return;

      final main = _mainGridRows(html);
      expect(main.single, contains('اکبرجوجه'));
      expect(main.single, contains('1405/07/28'));
    });
  });

  group('the buy grid after a purchase', () {
    test('the purchased row is checked, disabled, and charged', () {
      final html = read('86_buy_page_after.html');
      if (html == null) return;

      final rows = _buyRows(html);
      final lunch = rows['ناهار'];
      if (lunch == null) return;

      expect(lunch.checked, isTrue);
      expect(lunch.disabled, isTrue);
      expect(lunch.amount, '500000',
          reason: 'the amount is the reliable "this was bought" signal');
    });

    test('the other rows are untouched', () {
      final html = read('86_buy_page_after.html');
      if (html == null) return;

      final rows = _buyRows(html);
      final breakfast = rows['صبحانه'];
      if (breakfast != null) {
        expect(breakfast.checked, isFalse);
        expect(breakfast.amount, '0');
      }
    });
  });

  group('F18 - the cutoff governs reserving, not buying', () {
    test('the same date is locked on the weekly grid but buyable on the basket',
        () {
      final weekly = read('70_reservation_hub.html');
      final basket = read('81_buy_page_1405_07_28.html');
      if (weekly == null || basket == null) return;

      final weeklyRow = _weeklyRow(weekly, 'grdReservationLunch', '1405/07/28');
      if (weeklyRow != null) {
        expect(weeklyRow.disabled, isTrue,
            reason: 'the weekly grid refused this date');
      }

      final basketLunch = _buyRows(basket)['ناهار'];
      if (basketLunch != null) {
        expect(basketLunch.disabled, isFalse,
            reason: 'the basket accepted the same date');
      }
    });
  });

  group('F19 - the hall column lists the halls offering the meal', () {
    test('the lunch row offered only Central for Akbar Joojeh', () {
      final html = read('81_buy_page_1405_07_28.html');
      if (html == null) return;

      // The lunch row's hall dropdown had exactly one option: 1=مرکزی برادران.
      final lunchHalls = _hallOptions(html, 'ناهار');
      if (lunchHalls == null) return;

      expect(lunchHalls, contains('1'));
      expect(lunchHalls, isNot(contains('2')),
          reason: 'Engineering did not offer this meal on this date');
    });
  });
}

/// A row of the weekly reservation grid.
class _WeeklyRow {
  _WeeklyRow(this.checked, this.disabled, this.amount);
  final bool checked;
  final bool disabled;
  final String amount;
}

_WeeklyRow? _weeklyRow(String html, String gridId, String date) {
  final t = RegExp(
    '<table[^>]*id="[^"]*${RegExp.escape(gridId)}"[^>]*>(.*?)</table>',
    dotAll: true,
  ).firstMatch(html);
  if (t == null) return null;

  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
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
    final tag = cb?.group(0) ?? '';
    return _WeeklyRow(
      tag.contains('checked'),
      tag.contains('disabled'),
      _text(cells[6]),
    );
  }
  return null;
}

/// The buy grid's rows, keyed by meal name.
Map<String, _BuyRow> _buyRows(String html) {
  final out = <String, _BuyRow>{};
  final t = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return out;

  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 8) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final tag = cb?.group(0) ?? '';
    out[_text(cells[1])] = _BuyRow(
      tag.contains('checked'),
      tag.contains('disabled'),
      _text(cells[6]),
    );
  }
  return out;
}

class _BuyRow {
  _BuyRow(this.checked, this.disabled, this.amount);
  final bool checked;
  final bool disabled;
  final String amount;
}

/// The hall ids offered on a given meal row of the buy grid.
List<String>? _hallOptions(String html, String meal) {
  final t = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return null;

  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 8) continue;
    if (_text(cells[1]) != meal) continue;

    final sel = RegExp(r'<select[^>]*name="[^"]*drpSelf"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    if (sel == null) return null;

    return RegExp(r'<option[^>]*value="([^"]*)"', dotAll: true)
        .allMatches(sel.group(1)!)
        .map((o) => o.group(1)!)
        .toList();
  }
  return null;
}

/// The transaction rows in the main grid.
List<String> _mainGridRows(String html) {
  final t = RegExp('<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <String>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(m.group(1)!)
        .map((c) => _text(c.group(1)!))
        .toList();
    if (cells.isNotEmpty && cells.first.isNotEmpty) out.add(cells.join(' | '));
  }
  return out;
}

/// The transaction rows across all detail sub-grids.
List<String> _detailRows(String html) {
  final out = <String>[];
  for (final id
      in RegExp(r'id="(cphMain_grdContent_grdDetail_\d+)"').allMatches(html)) {
    final t = RegExp(
      '<table[^>]*id="${id.group(1)!}"[^>]*>(.*?)</table>',
      dotAll: true,
    ).firstMatch(html);
    if (t == null) continue;
    for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
        .allMatches(t.group(1)!)) {
      final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
          .allMatches(m.group(1)!)
          .map((c) => _text(c.group(1)!))
          .toList();
      if (cells.isNotEmpty && cells.first.isNotEmpty) out.add(cells.join(' | '));
    }
  }
  return out;
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
