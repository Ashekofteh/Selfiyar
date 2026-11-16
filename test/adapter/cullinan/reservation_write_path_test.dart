import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The weekly reservation write path, pinned against the portal's real shape.
///
/// ## Why these tests exist
///
/// The write path failed in four distinct ways, and three of them cost the
/// student money:
///
///   * **A next-week booking booked nothing.** The post went against the
///     current week's viewstate, and the viewstate is what decides which
///     week's rows a post affects (F12). The target's row was never in the
///     posted state.
///   * **A booking cancelled the account's other meals.** An ASP.NET checkbox
///     absent from a POST reads as *unchecked*, so posting one row presented
///     every other held row as unchecked.
///   * **A cancel booked unwanted meals.** The portal echoes the checkbox
///     state it was posted, so a row that was never charged comes back
///     `checked`; re-posting that checkbox **books** it (F13).
///   * **A phantom row read as a held meal.** `checked` is not "held", so the
///     app believed it held meals it did not.
///
/// Each test below is checked to fail without its fix.
///
/// ## The dates
///
/// The portal labels its rows in Jalali. The two weeks used here are the ones
/// the live captures carry:
///
///   * current week — `1405/07/25` (2026-10-17) .. `1405/08/01`
///   * next week — `1405/08/02` (2026-10-24) .. `1405/08/08`
///
/// ## The cancel target
///
/// The cancel used to name its meal with a string, `<date>|<slot>`, and the
/// adapter parsed it back. The parse fell through to a default slot when the
/// string did not match, and the app cancelled the **wrong meal** while
/// reporting success (F65). The target is now a [MealRef] — a value — so
/// there is nothing left to misparse.
final _lunchTarget = MealRef(
  date: DateTime.utc(2026, 10, 25),
  slot: MealSlot.lunch,
);

void main() {
  final session = Session(
    account: 'a1',
    cookies: const {'ASP.NET_SessionId': 's1'},
    establishedAt: DateTime.utc(2026, 10, 20),
  );

  /// 1405/08/03 — a next-week date.
  final nextWeekDate = DateTime.utc(2026, 10, 25);

  /// A grid row.
  ///
  /// [held] renders the row the way the portal renders a genuine reservation:
  /// checked, with the green «رزرو شده» icon and a non-zero amount.
  /// [echoed] renders the way it renders a row it merely checked — checked,
  /// but with no icon and no amount.
  String row(
    String grid,
    int index,
    String jalali, {
    bool held = false,
    bool echoed = false,
    bool disabled = false,
    String option = '62738',
  }) {
    final name = 'ctl00\$cphMain\$$grid\$ctl$index';
    final checkbox =
        '<input type="checkbox" name="$name\$chkReserve" '
        '${held || echoed ? 'checked="checked" ' : ''}'
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
      <td>شنبه $jalali</td>
      <td><select name="$name\$drpSelf">
        <option selected="selected" value="1">مرکزی برادران</option>
        <option value="2">فنی برادران</option>
      </select></td>
      <td><select name="$name\$drpFood">
        <option selected="selected" value="$option">چلو اکبرجوجه 500000 ریال</option>
      </select></td>
      <td><select name="$name\$drpFoodCount">
        <option selected="selected" value="1">1</option>
      </select></td>
      <td>0</td>
      <td>${held ? '500000 ریال' : '0'}</td>
      <td>$icon</td>
    </tr>''';
  }

  /// A whole week's page, with its three grids.
  String weekPage(
    List<String> breakfastRows,
    List<String> lunchRows,
    List<String> dinnerRows, {
    String viewstate = 'VSTATE',
  }) =>
      '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewstate" />
<table id="cphMain_grdReservationBreakfast">${breakfastRows.join()}</table>
<table id="cphMain_grdReservationLunch">${lunchRows.join()}</table>
<table id="cphMain_grdReservationDinner">${dinnerRows.join()}</table>
</body></html>
''';

  /// The current week — 1405/07/25 .. 1405/08/01.
  ///
  /// Everything in it is locked: the current week's dates are past their
  /// cutoff.
  String currentWeek() => weekPage(
        [row('grdReservationBreakfast', 2, '1405/07/25', disabled: true)],
        [row('grdReservationLunch', 2, '1405/07/25', disabled: true)],
        [row('grdReservationDinner', 2, '1405/07/25', disabled: true)],
      );

  /// The next week — 1405/08/02 .. 1405/08/08.
  ///
  /// It carries four rows that matter:
  ///
  ///   * `ctl02` breakfast @ 1405/08/02 — free
  ///   * `ctl03` lunch @ 1405/08/03 — free, and the **target** of the booking
  ///   * `ctl04` dinner @ 1405/08/04 — **genuinely held**, another meal of
  ///     the same account
  ///   * `ctl05` breakfast @ 1405/08/05 — merely **echoed** as checked, and
  ///     never charged
  String nextWeek({
    String lunchTarget = '1405/08/03',
    bool lunchHeld = false,
    bool dinnerHeld = true,
    bool breakfastEchoed = true,
  }) =>
      weekPage(
        [
          row('grdReservationBreakfast', 2, '1405/08/02'),
          row('grdReservationBreakfast', 5, '1405/08/05', echoed: breakfastEchoed),
        ],
        [
          row('grdReservationLunch', 3, lunchTarget, held: lunchHeld),
        ],
        [
          row('grdReservationDinner', 4, '1405/08/04', held: dinnerHeld),
        ],
        viewstate: 'VSTATE2',
      );

  /// The bodies of the **write** posts — the ones that carry a save button.
  ///
  /// The next-week navigation is also a POST, but it carries no save button
  /// and changes nothing on the account, so it is not a write.
  List<String> writes(List<String> bodies) =>
      bodies.where((b) => b.contains('btnSave')).toList(growable: false);

  /// A transport that serves [pages] in order, one per request.
  PortalTransport serving(
    List<String> pages, {
    List<String>? sentBodies,
    List<String>? requestUrls,
    SyncedServerClock? clock,
  }) {
    var index = 0;
    return PortalTransport(
      baseUri: Uri.parse('https://nut.uk.ac.ir/'),
      clock: clock,
      httpClient: MockClient((request) async {
        requestUrls?.add('${request.method} ${request.url}');
        if (request.method == 'POST' && sentBodies != null) {
          sentBodies.add(request.body);
        }
        final body = pages[index < pages.length ? index : pages.length - 1];
        index++;
        return http.Response(body, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );
  }

  group('F13 - "checked" is not "held"', () {
    test('a row that only echoes checked is not a reservation', () {
      final html = weekPage(
        [row('grdReservationBreakfast', 2, '1405/08/03', echoed: true)],
        [],
        [],
      );

      expect(
        CullinanParser.parseReservations(html),
        isEmpty,
        reason: 'an echoed row was never charged, so the account does not '
            'hold it',
      );
    });

    test('a genuinely held row is a reservation', () {
      final html = weekPage(
        [row('grdReservationBreakfast', 2, '1405/08/03', held: true)],
        [],
        [],
      );

      final reservations = CullinanParser.parseReservations(html);
      expect(reservations, hasLength(1));
      expect(reservations.single.date, nextWeekDate);
      expect(reservations.single.slot, MealSlot.breakfast);
    });
  });

  group('a next-week booking', () {
    test('posts against the week that carries the target', () async {
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(), // GET: the current week
          nextWeek(), // POST: navigate to next week
          currentWeek(), // POST: the write, answered with the default week
          currentWeek(), // GET: the confirmation re-read
          nextWeek(lunchHeld: true), // POST: navigate again for confirmation
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      final reservation = await client.reserve(
        session,
        MealOffering(
          date: nextWeekDate,
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(
              id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
          reservable: true,
        ),
      );

      expect(reservation.date, nextWeekDate);

      final post = writes(sent).single;
      expect(
        post,
        contains('VSTATE2'),
        reason: 'the post must carry the TARGET week\'s viewstate — the '
            'viewstate is what decides which week a post affects (F12)',
      );
      expect(
        post,
        contains(r'grdReservationLunch%24ctl3%24chkReserve=on'),
        reason: 'the target row must be checked in the posted state',
      );
    });
  });

  group('a booking', () {
    test('does not cancel the account\'s other meals', () async {
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(),
          nextWeek(),
          currentWeek(),
          currentWeek(),
          nextWeek(lunchHeld: true),
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      await client.reserve(
        session,
        MealOffering(
          date: nextWeekDate,
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(
              id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
          reservable: true,
        ),
      );

      final post = writes(sent).single;
      expect(
        post,
        contains(r'grdReservationDinner%24ctl4%24chkReserve=on'),
        reason: 'the account\'s held dinner must survive the booking — an '
            'absent checkbox reads as unchecked, which cancels it',
      );
    });

    test('does not book the meals it did not intend to', () async {
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(),
          nextWeek(),
          currentWeek(),
          currentWeek(),
          nextWeek(lunchHeld: true),
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      await client.reserve(
        session,
        MealOffering(
          date: nextWeekDate,
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(
              id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
          reservable: true,
        ),
      );

      final post = writes(sent).single;
      expect(
        post,
        isNot(contains(r'grdReservationBreakfast%24ctl5%24chkReserve=on')),
        reason: 'an echoed row is not a reservation, and re-posting its '
            'checkbox would BOOK a meal the student never asked for',
      );
    });
  });

  group('a cancel', () {
    test('does not book the meals it merely echoes', () async {
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(),
          nextWeek(),
          currentWeek(),
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      await client.cancel(session, _lunchTarget);

      final post = writes(sent).single;
      expect(
        post,
        isNot(contains(r'grdReservationBreakfast%24ctl5%24chkReserve=on')),
        reason: 're-posting an echoed checkbox would BOOK the breakfast — the '
            'exact opposite of what a cancel is for',
      );
      expect(
        post,
        isNot(contains(r'grdReservationLunch%24ctl3%24chkReserve=on')),
        reason: 'the target row\'s checkbox must be omitted, which is how it '
            'is unchecked',
      );
    });

    test('posts against the week that carries the target', () async {
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(),
          nextWeek(),
          currentWeek(),
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      await client.cancel(session, _lunchTarget);

      final post = writes(sent).single;
      expect(
        post,
        contains('VSTATE2'),
        reason: 'the post must carry the target week\'s viewstate, or it '
            'cancels nothing',
      );
    });
  });

  group('the outcome of a cancel', () {
    test('a confirmed cancel is a success', () async {
      // The portal no longer holds the target after the save, so the read
      // back shows it gone.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        nextWeek(lunchHeld: false),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(outcome, isA<CancelSucceeded>());
    });

    test('a cancel the portal ignored is a refusal, not a success', () async {
      // The live case (F63): a **locked** date is refused silently. The post
      // is discarded, the response is a plain 200, and the target is still
      // held when the portal is read back. Reporting a success here is what
      // made the app hide a meal the student still held.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        nextWeek(lunchHeld: true),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(
        outcome,
        isA<CancelRefused>(),
        reason: 'the meal is still held, so the cancel did not happen',
      );
    });

    test('a meal the portal merely echoes is not a held meal', () async {
      // An echoed row is `checked` but carries no icon and no amount, so it
      // is not a reservation (F13). Reading it back as "still held" would
      // report a refusal for a cancel that worked.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        nextWeek(lunchHeld: false, dinnerHeld: true),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(outcome, isA<CancelSucceeded>());
    });
  });

  group('F65 - the cancel reported a success it never earned', () {
    test('a read-back page with no row for the day says nothing', () async {
      // The live failure: the app cancelled a **breakfast** and reported
      // success, while the portal kept it. Two things went wrong together.
      //
      // The first was the *target*: the meal used to travel as a string,
      // `<date>|<slot>`, and the adapter parsed the slot back out of it. The
      // string carried `MealSlot.breakfast` — Dart's enum `toString()` — while
      // the parser matched `slot.name`, `breakfast`. The match failed and the
      // parse fell through to a default: **lunch**.
      //
      // So the cancel unheld the lunch row, and the read-back then looked for
      // a lunch that was not there, found no row, and read that silence as
      // "the meal is gone".
      //
      // The second was the read-back itself: a page that carries **no row at
      // all** for the day says nothing about the meal, and reading it as a
      // release is what emptied the mirror (F65). It has to be ambiguous.
      //
      // This page carries no lunch row at all, so it cannot speak about the
      // lunch meal.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        weekPage(
          [row('grdReservationBreakfast', 3, '1405/08/03', held: true)],
          [],
          [],
          viewstate: 'VSTATE2',
        ),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(
        outcome,
        isA<CancelAmbiguous>(),
        reason: 'a page with no row for the day cannot say the meal is '
            'gone, and an unverified cancel must not empty the mirror',
      );
    });

    test('a read-back page that carries the row reports the release', () async {
      // The counterpart: when the page **does** carry the row, and the row is
      // no longer held, the cancel really did land and the outcome is a
      // success. A read-back that refused to believe the portal would make
      // every cancel look ambiguous, and the student could never give a meal
      // back.
      final transport = serving([
        currentWeek(),
        nextWeek(),
        currentWeek(),
        nextWeek(lunchHeld: false, dinnerHeld: true),
      ]);

      final client = CullinanPortalClient(transport: transport);

      final outcome = await client.cancel(session, _lunchTarget);

      expect(outcome, isA<CancelSucceeded>());
    });

    test('the cancel targets the slot it was asked for', () async {
      // The target is a value now, so it cannot be parsed into the wrong
      // slot. This checks the request that goes out: the breakfast grid's
      // save button, and the breakfast row's checkbox left out.
      final sent = <String>[];
      final transport = serving(
        [
          currentWeek(),
          nextWeek(),
          currentWeek(),
          nextWeek(),
        ],
        sentBodies: sent,
      );

      final client = CullinanPortalClient(transport: transport);

      await client.cancel(
        session,
        MealRef(date: DateTime.utc(2026, 10, 25), slot: MealSlot.breakfast),
      );

      final post = writes(sent).single;
      expect(
        post,
        contains('btnSaveBreakfast'),
        reason: 'a breakfast is saved through the breakfast grid\'s button',
      );
      expect(
        post,
        isNot(contains('btnSaveLunch')),
        reason: 'the lunch grid must not be saved, or the lunch meal would '
            'be touched by a breakfast cancel',
      );
    });
  });

  group('the bookable menus', () {
    test('keep every meal of a day, not just the first', () async {
      // A day serves three meals. A set keyed by the date alone keeps only
      // the first, and the other two vanish.
      final clock = SyncedServerClock(
        localNowUtc: () => DateTime.utc(2026, 10, 20, 12),
      );
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 20, 12),
        roundTrip: Duration.zero,
        localReceivedAt: DateTime.utc(2026, 10, 20, 12),
      );

      final transport = serving(
        [
          weekPage(
            [row('grdReservationBreakfast', 2, '1405/08/03')],
            [row('grdReservationLunch', 2, '1405/08/03')],
            [row('grdReservationDinner', 2, '1405/08/03')],
          ),
        ],
        clock: clock,
      );

      final client = CullinanPortalClient(transport: transport);
      final read = await client.fetchBookableMenus(session);

      expect(
        read.menus.map((m) => m.slot).toSet(),
        MealSlot.values.toSet(),
        reason: 'breakfast, lunch and dinner are all servable that day',
      );
    });
  });
}
