import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan/cullinan_forms.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart'
    show PortalUnreachableException;
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Resilience of the portal **reads**: the shapes that used to turn into an
/// empty mirror, a mislabelled basket date, or a wrong "today".
///
/// Every test here is about a `200` that is not an answer. The transport does
/// not throw on an HTTP error, ASP.NET answers a rejected viewstate with a
/// `200` error page, and a silent navigation postback answers with the page
/// it was already on. A read that trusts the status code interprets all three
/// as data.

final _session = Session(
  account: 'a1',
  cookies: const {'ASP.NET_SessionId': 's1'},
  establishedAt: DateTime.utc(2026, 11, 21),
);

/// A grid row, enough for the parsers used here.
String _row(String grid, int index, String jalali) {
  final name = 'ctl00\$cphMain\$$grid\$ctl$index';
  return '''
    <tr>
      <td><input type="checkbox" name="$name\$chkReserve" /></td>
      <td>یکشنبه $jalali</td>
      <td><select name="$name\$drpSelf">
        <option selected="selected" value="1">مرکزی برادران</option>
      </select></td>
      <td><select name="$name\$drpFood">
        <option selected="selected" value="62725">پنیر/خیار/نان 150000 ریال</option>
      </select></td>
      <td><select name="$name\$drpFoodCount">
        <option selected="selected" value="1">1</option>
      </select></td>
      <td>0</td>
      <td>0</td>
      <td></td>
    </tr>''';
}

/// A weekly reservation page carrying the three grids a real page has.
String _weekPage({
  required List<String> breakfastRows,
  String viewstate = 'VSTATE',
}) =>
    '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewstate" />
<table id="cphMain_grdReservationBreakfast">${breakfastRows.join()}</table>
<table id="cphMain_grdReservationLunch"></table>
<table id="cphMain_grdReservationDinner"></table>
</body></html>
''';

const _aspErrorPage = '''
<html><body>
<h1>Server Error in '/' Application.</h1>
<p>Runtime Error</p>
<p>Description: An application error occurred on the server.</p>
</body></html>
''';

/// A transport that serves [pages] in order, repeating the last one.
PortalTransport _serving(List<String> pages) {
  var index = 0;
  return PortalTransport(
    baseUri: Uri.parse('https://nut.uk.ac.ir/'),
    httpClient: MockClient((request) async {
      final body = pages[index < pages.length ? index : pages.length - 1];
      index++;
      return http.Response(
        body,
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }),
  );
}

const _buyPageDateField = '1405/09/01';

/// A buy page whose `txtDate` is [date].
String _buyPage(String date) =>
    '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="VS" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN" />
<input type="text" id="ctl00_cphMain_txtDate" value="$date" />
<table id="grdFoodBasketReservation">
<tr>
<td>1</td><td>ناهار</td><td>$date</td>
<td>
<input type="checkbox" name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$chkReserve" />
<select name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$drpSelf">
<option selected="selected" value="1">مرکزی برادران</option>
</select>
<select name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$drpFood">
<option selected="selected" value="62742">لوبیا پلو 350000 ریال</option>
</select>
<select name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$drpFoodCount">
<option selected="selected" value="1">1</option>
</select>
</td>
</tr>
</table>
</body></html>
''';

void main() {
  group('H3 - an ASP.NET error page is not an empty account', () {
    test('the reservation read refuses the error page', () async {
      final client = CullinanPortalClient(transport: _serving([_aspErrorPage]));

      expect(
        () => client.fetchReservations(_session),
        throwsA(isA<PortalUnreachableException>()),
        reason:
            'parsing the error page returns no rows, which the mirror would '
            'read as "the account holds nothing"',
      );
    });

    test('fetchMenu refuses the error page', () async {
      final client = CullinanPortalClient(transport: _serving([_aspErrorPage]));

      expect(
        () => client.fetchMenu(_session, DateTime.utc(2026, 11, 22)),
        throwsA(isA<PortalUnreachableException>()),
        reason: 'an error page must throw rather than clear the market',
      );
    });

    test('an error body carrying grid markup is still refused', () {
      final html = _weekPage(
        breakfastRows: [_row('grdReservationBreakfast', 2, '1405/09/01')],
      ).replaceFirst('<body>', '<body>Runtime Error');

      expect(CullinanForms.looksLikeReservationPage(html), isFalse);
    });

    test(
      'a silent next-week navigation is refused, not read as one week',
      () async {
        // The POST is answered with the same week. Merging it would say the
        // week ahead was read when it was not.
        final current = _weekPage(
          breakfastRows: [_row('grdReservationBreakfast', 2, '1405/08/03')],
        );
        final client = CullinanPortalClient(
          transport: _serving([current, current]),
        );

        expect(
          () => client.fetchReservations(_session),
          throwsA(isA<PortalUnreachableException>()),
          reason:
              'a next-week read that stayed on the current week is incomplete; '
              'the mirror must keep its previous contents',
        );
      },
    );

    test('fetchMenu refuses a silent next-week navigation no-op', () async {
      final current = _weekPage(
        breakfastRows: [_row('grdReservationBreakfast', 2, '1405/08/03')],
      );
      final client = CullinanPortalClient(
        transport: _serving([current, current]),
      );

      expect(
        () => client.fetchMenu(_session, DateTime.utc(2026, 11, 29)),
        throwsA(isA<PortalUnreachableException>()),
      );
    });

    test(
      'the bookable menus are partial when next week cannot be read',
      () async {
        final current = _weekPage(
          breakfastRows: [_row('grdReservationBreakfast', 2, '1405/08/03')],
        );
        final client = CullinanPortalClient(
          transport: _serving([current, _aspErrorPage]),
        );

        final read = await client.fetchBookableMenus(_session);

        expect(read.menus, isNotEmpty, reason: 'the current week was read');
        expect(
          read.partial,
          isTrue,
          reason: 'an unread next week is unknown, not "no food is served"',
        );
      },
    );

    test('a complete two-week read is not partial', () async {
      final current = _weekPage(
        breakfastRows: [_row('grdReservationBreakfast', 2, '1405/08/03')],
      );
      final next = _weekPage(
        breakfastRows: [_row('grdReservationBreakfast', 2, '1405/08/10')],
        viewstate: 'VSTATE2',
      );
      final client = CullinanPortalClient(transport: _serving([current, next]));

      final read = await client.fetchBookableMenus(_session);

      expect(read.partial, isFalse);
      expect(read.menus.map((m) => m.date).toSet(), hasLength(2));
    });
  });

  group('L1 - today is the Tehran day, not the UTC day', () {
    test('01:00 Tehran is still the Tehran date', () {
      // 21:30 UTC on 2026-11-21 is 01:00 on 2026-11-22 in Tehran (UTC+3:30).
      final instantUtc = DateTime.utc(2026, 11, 21, 21, 30);

      expect(
        CullinanForms.todayJalali(instantUtc),
        CullinanForms.jalaliOf(DateTime.utc(2026, 11, 22)),
        reason: 'the portal\'s date filter must not be a day behind',
      );
      expect(
        CullinanForms.todayJalali(instantUtc),
        isNot(CullinanForms.jalaliOf(DateTime.utc(2026, 11, 21))),
        reason: 'the UTC civil date is the previous day at this instant',
      );
    });

    test('a normal daytime instant still answers its Tehran date', () {
      // 12:00 UTC is 15:30 Tehran, the same civil day.
      final instantUtc = DateTime.utc(2026, 11, 22, 12);

      expect(
        CullinanForms.todayJalali(instantUtc),
        CullinanForms.jalaliOf(DateTime.utc(2026, 11, 22)),
      );
    });
  });

  group('L3 - the basket postback answer is for the requested date', () {
    test(
      'a filter response for another date is rejected, not parsed',
      () async {
        // The GET serves its default date; every POST silently ignores the
        // filter and serves that same date again. Parsing those rows under the
        // requested date would label them with a date they do not carry.
        final client = CullinanPortalClient(
          transport: _serving([_buyPage(_buyPageDateField)]),
        );

        final page = await client.fetchBasket(_session, cursor: '1405/09/05');

        expect(
          page.listings,
          isEmpty,
          reason:
              'a response whose txtDate does not match the request must not '
              'produce listings for the requested date',
        );
      },
    );

    test('a matching filter response is parsed normally', () async {
      final client = CullinanPortalClient(
        transport: _serving([_buyPage(_buyPageDateField)]),
      );

      final page = await client.fetchBasket(
        _session,
        cursor: _buyPageDateField,
      );

      expect(page.listings, hasLength(1));
      expect(page.listings.single.slot, MealSlot.lunch);
    });

    test(
      'a degraded buy page with no viewstate and wrong date returns empty',
      () async {
        final degradedWrongDate = _buyPage(_buyPageDateField).replaceAll(
          RegExp(r'<input[^>]*__VIEWSTATE[^>]*>'),
          '',
        );
        final client = CullinanPortalClient(
          transport: _serving([degradedWrongDate]),
        );

        final page = await client.fetchBasket(_session, cursor: '1405/09/05');
        expect(page.listings, isEmpty);
      },
    );
  });
}
