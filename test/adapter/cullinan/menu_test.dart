import 'dart:convert';

import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The hunt's setup reads the **official weekly menu**, not the marketplace.
///
/// The portal answers two different questions with two different pages:
///
///  * the **weekly menu** (`Reservation.aspx`) names the halls that *serve* a
///    meal and the dishes the university offers for it;
///  * the **buy page** (`FoodBasketBuy.aspx`) names the halls that have
///    *released* a meal into the marketplace.
///
/// The marketplace's hall list is a strict **subset** of the menu's, so a
/// hunt built from the marketplace cannot name a hall that has not yet
/// released anything — which is exactly the hall a hunt needs to name,
/// because the market fills up *during* the hunt window.
///
/// These tests pin the behaviour with markup written inline, so they run on a
/// fresh clone. The markup is the shape the live portal was verified to
/// render (see `captures/70_reservation_hub.html`).
void main() {
  // A weekly-menu page, in the portal's own markup shape.
  //
  // The `drpSelf` dropdown carries **every** hall that serves the meal, with
  // the selected one marked — not just the selected one. That is the whole
  // point: the app must be able to offer the hall the account has not chosen.
  String menuPage({
    required String dateLabel,
    required String selfOptions,
    required String foodOptions,
    bool disabled = false,
  }) =>
      '''
<html><body>
<table id="cphMain_grdReservationLunch">
  <tr>
    <td>
      <input id="cphMain_grdReservationLunch_chkReserve_1" type="checkbox"
        name="ctl00\$cphMain\$grdReservationLunch\$ctl03\$chkReserve"
        ${disabled ? 'disabled="disabled"' : ''} />
    </td>
    <td>$dateLabel</td>
    <td>
      <select name="ctl00\$cphMain\$grdReservationLunch\$ctl03\$drpSelf"
              id="cphMain_grdReservationLunch_drpSelf_1">
        $selfOptions
      </select>
    </td>
    <td>
      <select name="ctl00\$cphMain\$grdReservationLunch\$ctl03\$drpFood"
              id="cphMain_grdReservationLunch_drpFood_1">
        $foodOptions
      </select>
    </td>
    <td><span>0</span></td>
  </tr>
</table>
</body></html>
''';

  const twoHalls = '''
        <option selected="selected" value="1">مرکزی برادران</option>
        <option value="2">فنی برادران</option>''';

  const oneHall = '''
        <option selected="selected" value="1">مرکزی برادران</option>''';

  const twoDishes = '''
        <option selected="selected" value="62738">چلو اکبرجوجه,دوغ 500000 ریال</option>
        <option value="62740">چلو گوشت,ماست 500000 ریال</option>''';

  group('the weekly menu', () {
    test(
      'names every hall that serves the meal, not just the selected one',
      () {
        final html = menuPage(
          dateLabel: 'سه شنبه 1405/07/28',
          selfOptions: twoHalls,
          foodOptions: twoDishes,
        );

        final menus = CullinanParser.parseMenu(
          html,
          DateTime.utc(2026, 10, 20),
        );

        expect(menus, hasLength(1));
        final menu = menus.first;

        // Both halls, in the portal's own order. The selected one is the first
        // because the portal marks it, but the *other* one is the one a hunt
        // could not name before this fix.
        expect(menu.halls.map((h) => h.id), ['1', '2']);
        expect(menu.halls.map((h) => h.name), ['مرکزی برادران', 'فنی برادران']);
      },
    );

    test('a day served in one hall names only that hall', () {
      final html = menuPage(
        dateLabel: 'پنجشنبه 1405/07/30',
        selfOptions: oneHall,
        foodOptions: twoDishes,
      );

      final menus = CullinanParser.parseMenu(html, DateTime.utc(2026, 10, 22));

      expect(menus.single.halls.map((h) => h.id), ['1']);
    });

    test('the dishes carry the official price for that date and slot', () {
      final html = menuPage(
        dateLabel: 'سه شنبه 1405/07/28',
        selfOptions: twoHalls,
        foodOptions: twoDishes,
      );

      final menu = CullinanParser.parseMenu(
        html,
        DateTime.utc(2026, 10, 20),
      ).single;

      expect(menu.dishes.map((d) => d.id), ['62738', '62740']);
      expect(menu.dishes.map((d) => d.name), [
        'چلو اکبرجوجه,دوغ',
        'چلو گوشت,ماست',
      ]);
      expect(menu.dishes.every((d) => d.priceRial == 500000), isTrue);
    });

    test('the dishes are the same in every hall, so no pairing is built', () {
      final html = menuPage(
        dateLabel: 'سه شنبه 1405/07/28',
        selfOptions: twoHalls,
        foodOptions: twoDishes,
      );

      final menu = CullinanParser.parseMenu(
        html,
        DateTime.utc(2026, 10, 20),
      ).single;

      // One dish list, one hall list. The menu is not a per-hall map of
      // dishes, because the portal does not publish it that way: every hall
      // serves the same food for that meal.
      expect(menu.dishes, hasLength(2));
      expect(menu.halls, hasLength(2));
    });

    test('a locked date is reported as not reservable', () {
      final html = menuPage(
        dateLabel: 'سه شنبه 1405/07/28',
        selfOptions: twoHalls,
        foodOptions: twoDishes,
        disabled: true,
      );

      final menu = CullinanParser.parseMenu(
        html,
        DateTime.utc(2026, 10, 20),
      ).single;

      expect(menu.reservable, isFalse);
    });

    test('a day the portal does not serve produces no menu', () {
      final html = menuPage(
        dateLabel: 'سه شنبه 1405/07/28',
        selfOptions: twoHalls,
        foodOptions: twoDishes,
      );

      expect(
        CullinanParser.parseMenu(html, DateTime.utc(2026, 10, 25)),
        isEmpty,
      );
    });

    test('a row with no service renders "-" and produces no menu', () {
      final html = menuPage(
        dateLabel: 'جمعه 1405/08/01',
        selfOptions: '<option selected="selected" value="-1">-</option>',
        foodOptions: '<option selected="selected" value="-1">-</option>',
      );

      expect(
        CullinanParser.parseMenu(html, DateTime.utc(2026, 10, 23)),
        isEmpty,
      );
    });
  });

  group('the client reads the menu', () {
    /// A transport that serves [pages] in order, one per request.
    PortalTransport serving(List<String> pages, {List<String>? sentBodies}) {
      var index = 0;
      return PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && sentBodies != null) {
            sentBodies.add(request.body);
          }
          final body = pages[index < pages.length ? index : pages.length - 1];
          index++;
          return _page(body);
        }),
      );
    }

    final session = Session(
      account: 'a1',
      cookies: const {'ASP.NET_SessionId': 's1'},
      establishedAt: DateTime.utc(2026, 10, 20),
    );

    test('a date in the current week needs no postback', () async {
      final transport = serving([
        menuPage(
          dateLabel: 'سه شنبه 1405/07/28',
          selfOptions: twoHalls,
          foodOptions: twoDishes,
        ),
      ]);

      final client = CullinanPortalClient(transport: transport);
      final menus = await client.fetchMenu(session, DateTime.utc(2026, 10, 20));

      expect(menus.single.halls.map((h) => h.id), ['1', '2']);
    });

    test(
      'a date in the next week is found by the next-week postback',
      () async {
        // The weekly menu is one page per week. The first page covers the
        // current week; the target date is in the next one, which is reached
        // by posting `imgbtnNextWeek`.
        final sent = <String>[];
        final transport = serving([
          menuPage(
            dateLabel: 'سه شنبه 1405/07/28',
            selfOptions: twoHalls,
            foodOptions: twoDishes,
          ),
          menuPage(
            dateLabel: 'چهارشنبه 1405/08/06',
            selfOptions: twoHalls,
            foodOptions: twoDishes,
          ),
        ], sentBodies: sent);

        final client = CullinanPortalClient(transport: transport);
        final menus = await client.fetchMenu(
          session,
          DateTime.utc(2026, 10, 28),
        );

        expect(menus, hasLength(1));
        expect(menus.single.date, DateTime.utc(2026, 10, 28));
        expect(menus.single.halls.map((h) => h.id), ['1', '2']);

        // The postback is the navigation the portal expects, and it carries
        // the page's own viewstate.
        expect(sent, hasLength(1));
        expect(sent.single, contains('imgbtnNextWeek'));
        expect(sent.single, contains('__VIEWSTATE'));
      },
    );

    test('a read that finds nothing in either week returns no menu', () async {
      final transport = serving([
        menuPage(
          dateLabel: 'سه شنبه 1405/07/28',
          selfOptions: twoHalls,
          foodOptions: twoDishes,
        ),
        menuPage(
          dateLabel: 'سه شنبه 1405/08/05',
          selfOptions: twoHalls,
          foodOptions: twoDishes,
        ),
      ]);

      final client = CullinanPortalClient(transport: transport);
      final menus = await client.fetchMenu(session, DateTime.utc(2026, 11, 20));

      expect(menus, isEmpty);
    });

    test('the session cookies reach the request', () async {
      final sent = <String?>[];
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          sent.add(request.headers['cookie']);
          return _page(
            menuPage(
              dateLabel: 'سه شنبه 1405/07/28',
              selfOptions: twoHalls,
              foodOptions: twoDishes,
            ),
          );
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      await client.fetchMenu(session, DateTime.utc(2026, 10, 20));

      expect(sent.single, contains('ASP.NET_SessionId=s1'));
    });
  });
}

/// A response carrying Persian text.
///
/// The body goes in as bytes: `http.Response`'s string constructor assumes
/// Latin-1, and the portal's pages are UTF-8.
http.Response _page(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);
