import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The reservation read must cover **every week a student can hold a meal in**.
///
/// ## The live defect this pins
///
/// Measured live on 2026-10-21 against the real portal:
///
///   * The portal lets a student reserve into the **following week**. The
///     rows two weeks out are every one of them `disabled`; the rows of the
///     week ahead are editable.
///   * The account held a breakfast on 1405/08/03 (2026-10-25) — in week
///     **one**, not week zero.
///   * A read of the current week alone returned **6** reservations. The
///     portal held **7**.
///
/// The seventh was the next-week breakfast, and the read missed it. That is
/// not a cosmetic gap: the mirror falls back to the ledger for a meal the
/// grid did not report, and the ledger records a weekly reservation and a
/// Food Basket purchase the same way — so the meal was filed as an
/// **irreversible basket purchase**. The table showed «خریداری شده» with no
/// cancel button on a meal the portal would have let the student give back,
/// and the one-meal pre-flight check could not see that the slot was taken.
///
/// So the read walks forward a week, and the tests below hold it to that.
final _lunchTarget = MealRef(
  date: DateTime.utc(2026, 10, 18),
  slot: MealSlot.lunch,
);

void main() {
  final session = Session(
    account: 'a1',
    cookies: const {'ASP.NET_SessionId': 's1'},
    establishedAt: DateTime.utc(2026, 10, 20),
  );

  /// 1405/08/03 — a **next-week** date (week one).
  final nextWeekDate = DateTime.utc(2026, 10, 25);

  /// A grid row.
  ///
  /// [held] renders the row the way the portal renders a genuine reservation:
  /// checked, with the green «رزرو شده» icon and a non-zero amount.
  String row(
    String grid,
    int index,
    String jalali, {
    bool held = false,
    bool disabled = false,
    String option = '62725',
  }) {
    final name = 'ctl00\$cphMain\$$grid\$ctl$index';
    final checkbox =
        '<input type="checkbox" name="$name\$chkReserve" '
        '${held ? 'checked="checked" ' : ''}'
        '${disabled ? 'disabled="disabled" ' : ''}/>';

    final icon = held
        ? '<img id="cphMain_${grid}_imgStaus_$index" title="رزرو شده" '
            'src="../Images/Icon/AcceptGreen16.png" />'
        : disabled
            ? '<img id="cphMain_${grid}_imgStaus_$index" title="غیرفعال" '
                'src="../Images/Icon/lock24.png" />'
            : '';

    return '''
    <tr>
      <td>$checkbox</td>
      <td>یکشنبه $jalali</td>
      <td><select name="$name\$drpSelf">
        <option selected="selected" value="1">مرکزی برادران</option>
      </select></td>
      <td><select name="$name\$drpFood">
        <option selected="selected" value="$option">پنیر/خیار/نان 150000 ریال</option>
      </select></td>
      <td><select name="$name\$drpFoodCount">
        <option selected="selected" value="1">1</option>
      </select></td>
      <td>0</td>
      <td>${held ? '150000 ریال' : '0'}</td>
      <td>$icon</td>
    </tr>''';
  }

  /// A whole week's page, with its three grids.
  String weekPage(
    List<String> breakfastRows,
    List<String> lunchRows, {
    String viewstate = 'VSTATE',
  }) =>
      '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewstate" />
<table id="cphMain_grdReservationBreakfast">${breakfastRows.join()}</table>
<table id="cphMain_grdReservationLunch">${lunchRows.join()}</table>
</body></html>
''';

  /// The current week — 1405/07/25 .. 1405/08/01, entirely locked.
  String currentWeek() => weekPage(
        [row('grdReservationBreakfast', 2, '1405/07/29', disabled: true)],
        [row('grdReservationLunch', 2, '1405/07/29', disabled: true)],
      );

  /// The next week — 1405/08/02 .. 1405/08/08, and it carries the meal the
  /// account holds: a breakfast on 1405/08/03.
  ///
  /// ## Why the lunch grid carries a row
  ///
  /// The portal renders **a row per day in every slot grid**, not just the
  /// days that have a meal in them. Verified live on 2026-10-21: the lunch
  /// grid of 1405/08/02 .. 1405/08/08 carries a row for 1405/08/03 — not
  /// checked, no amount, no icon — because that is what the portal does.
  ///
  /// That matters, because the cancel's read-back asks the page whether the
  /// meal is still there. A grid with no row for the day at all says
  /// **nothing** about the meal, and a read-back that read that silence as
  /// "cancelled" is what let a cancel report a success it never earned
  /// (F65). So the fixture renders the real shape, and the read-back has to
  /// cope with a page that genuinely has no such row.
  String nextWeek({bool breakfastHeld = true}) => weekPage(
        [
          row('grdReservationBreakfast', 3, '1405/08/03', held: breakfastHeld),
        ],
        [row('grdReservationLunch', 3, '1405/08/03')],
        viewstate: 'VSTATE2',
      );

  /// A transport that serves [pages] in order, one per request.
  PortalTransport serving(
    List<String> pages, {
    List<String>? requestUrls,
  }) {
    var index = 0;
    return PortalTransport(
      baseUri: Uri.parse('https://nut.uk.ac.ir/'),
      httpClient: MockClient((request) async {
        requestUrls?.add('${request.method} ${request.url}');
        final body = pages[index < pages.length ? index : pages.length - 1];
        index++;
        return http.Response(body, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );
  }

  group('the reservation read', () {
    test('covers the week the portal holds the meal in', () async {
      // The live case: the account holds a next-week breakfast, and a read of
      // the current week alone does not see it.
      final transport = serving([
        currentWeek(),
        nextWeek(),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final reservations = await client.fetchReservations(session);

      expect(
        reservations.any((r) =>
            r.date.year == nextWeekDate.year &&
            r.date.month == nextWeekDate.month &&
            r.date.day == nextWeekDate.day &&
            r.slot == MealSlot.breakfast),
        isTrue,
        reason: 'the meal the student holds next week must be read, or the '
            'app files it as an irreversible basket purchase and refuses the '
            'one-meal check',
      );
    });

    test('reads both weeks', () async {
      final urls = <String>[];
      final transport = serving(
        [currentWeek(), nextWeek()],
        requestUrls: urls,
      );

      final client = CullinanPortalClient(transport: transport);
      await client.fetchReservations(session);

      expect(urls, hasLength(2),
          reason: 'one read for the current week, one for the week ahead');
      expect(urls.last, startsWith('POST'),
          reason: 'the week ahead is reached by posting the next-week '
              'navigation, which carries no save button and changes nothing');
    });

    test('reports a meal it does not hold as not held', () async {
      // The next week's row is checked but carries no icon and no amount, so
      // it is an echo rather than a reservation (F13).
      final transport = serving([
        currentWeek(),
        nextWeek(breakfastHeld: false),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final reservations = await client.fetchReservations(session);

      expect(reservations, isEmpty,
          reason: 'a row that is only echoed is not a meal the student holds');
    });

    test('a meal in both weeks is counted once', () async {
      // The two pages are parsed separately, but a meal is identified by its
      // (date, slot), so a date that somehow appears on both is one meal.
      final duplicated = weekPage(
        [row('grdReservationBreakfast', 2, '1405/07/29', held: true)],
        [],
      );

      final transport = serving([
        duplicated,
        duplicated,
      ]);

      final client = CullinanPortalClient(transport: transport);

      final reservations = await client.fetchReservations(session);

      expect(reservations, hasLength(1));
    });

    test('a session that has expired is reported, not read as empty', () async {
      // The portal answers an expired session with the login page. Read as a
      // page of grids, that page has no rows — so the account would look like
      // it holds nothing, and the mirror would be emptied (F: session 12).
      final transport = serving([
        '<html><body><input id="txtUsernamePlain" /></body></html>',
        currentWeek(),
      ]);

      final client = CullinanPortalClient(transport: transport);

      expect(
        () => client.fetchReservations(session),
        throwsA(isA<LoginRejectedException>()),
      );
    });
  });

  group('the read and the write agree on which week a meal is in', () {
    test('a next-week meal is still held after a cancel of another week',
        () async {
      // The cancel posts against the week that carries its target. The
      // confirmation read-back must therefore look at that same week — and a
      // meal in a different week must not be mistaken for the target.
      //
      // So the target is the next week's **lunch**, which the page carries as
      // a row that is not held, while the next week's **breakfast** is
      // genuinely held. The read-back must report the lunch as released and
      // must not be fooled by the held breakfast sitting in the same week.
      final transport = serving([
        currentWeek(), // GET: the current week
        nextWeek(), // POST: navigate to the week ahead
        currentWeek(), // POST: the cancel, answered with the default week
        nextWeek(breakfastHeld: true), // GET: the confirmation re-read
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(
        session,
        MealRef(date: nextWeekDate, slot: MealSlot.lunch),
      );

      expect(outcome, isA<CancelSucceeded>(),
          reason: 'the lunch row is on the page and is not held, so the '
              'cancel landed; the held breakfast beside it is a different '
              'meal and must not be mistaken for the target');
    });

    test('a meal no page carries is ambiguous, not a success', () async {
      // The other half of the same coin. The cancel targets a date that no
      // page carries — the read-back cannot speak about it, so it must not
      // claim the meal is gone (F65). A cancel that reports a success it
      // could not verify empties the mirror for a meal the student may still
      // hold.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        nextWeek(breakfastHeld: true),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(
        outcome,
        isA<CancelAmbiguous>(),
        reason: 'no page carries a lunch row for that day, so the portal '
            'cannot be said to have released anything',
      );
    });
  });
}
