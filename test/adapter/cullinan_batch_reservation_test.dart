import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(
    account: '400123456',
    cookies: const {'ASP.NET_SessionId': 'live-session'},
    establishedAt: DateTime.utc(2026, 10, 20),
  );

  final satDate = DateTime.utc(2026, 10, 24);
  final sunDate = DateTime.utc(2026, 10, 25);

  final hallCentral = const Hall(id: '1', name: 'مرکزی');
  final hallEng = const Hall(id: '2', name: 'مهندسی');

  final dish1 = const MenuOption(id: '101', name: 'چلو جوجه کباب', priceRial: 500000);
  final dish2 = const MenuOption(id: '102', name: 'چلو قورمه سبزی', priceRial: 400000);
  final dishDinner = const MenuOption(id: '201', name: 'ماکارونی', priceRial: 300000);

  const htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

  String rowHtml(
    String grid,
    int index,
    String jalali, {
    bool held = false,
    bool disabled = false,
    String optionId = '101',
    String hallId = '1',
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
      <td>شنبه $jalali</td>
      <td><select name="$name\$drpSelf">
        <option ${hallId == '1' ? 'selected="selected"' : ''} value="1">مرکزی</option>
        <option ${hallId == '2' ? 'selected="selected"' : ''} value="2">مهندسی</option>
      </select></td>
      <td><select name="$name\$drpFood">
        <option ${optionId == '101' ? 'selected="selected"' : ''} value="101">چلو جوجه کباب 500000 ریال</option>
        <option ${optionId == '102' ? 'selected="selected"' : ''} value="102">چلو قورمه سبزی 400000 ریال</option>
        <option ${optionId == '201' ? 'selected="selected"' : ''} value="201">ماکارونی 300000 ریال</option>
      </select></td>
      <td><select name="$name\$drpFoodCount">
        <option selected="selected" value="1">1</option>
      </select></td>
      <td>0</td>
      <td>${held ? '500000 ریال' : '0'}</td>
      <td>$icon</td>
    </tr>''';
  }

  String buildWeekHtml({
    bool satLunchHeld = false,
    bool sunLunchHeld = false,
    bool satDinnerHeld = false,
    bool satLunchDisabled = false,
    bool sunLunchDisabled = false,
  }) {
    return '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="WEEK_VS" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN_VS" />
<table id="cphMain_grdReservationBreakfast"></table>
<table id="cphMain_grdReservationLunch">
  ${rowHtml('grdReservationLunch', 2, '1405/08/02', held: satLunchHeld, disabled: satLunchDisabled, optionId: '101', hallId: '1')}
  ${rowHtml('grdReservationLunch', 3, '1405/08/03', held: sunLunchHeld, disabled: sunLunchDisabled, optionId: '102', hallId: '2')}
</table>
<table id="cphMain_grdReservationDinner">
  ${rowHtml('grdReservationDinner', 2, '1405/08/02', held: satDinnerHeld, optionId: '201', hallId: '1')}
</table>
<input type="submit" name="ctl00\$cphMain\$btnSaveLunch" value="ذخیره" id="cphMain_btnSaveLunch" />
<input type="submit" name="ctl00\$cphMain\$btnSaveDinner" value="ذخیره" id="cphMain_btnSaveDinner" />
</body></html>
''';
  }

  group('CullinanPortalClient.reserveAll', () {
    test('returns empty list for empty offerings without network call', () async {
      var requestsMade = 0;
      final inner = MockClient((_) async {
        requestsMade++;
        return http.Response('', 200, headers: htmlHeaders);
      });
      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final result = await client.reserveAll(session, const []);
      expect(result, isEmpty);
      expect(requestsMade, 0);
    });

    test('batches multiple offerings for the same meal slot into a single WebForms POST', () async {
      final postBodies = <Map<String, String>>[];
      var getCount = 0;

      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          final held = getCount > 1;
          return http.Response(
            buildWeekHtml(satLunchHeld: held, sunLunchHeld: held),
            200,
            headers: htmlHeaders,
          );
        }

        if (request.method == 'POST') {
          postBodies.add(Map<String, String>.from(request.bodyFields));
          return http.Response(
            buildWeekHtml(satLunchHeld: true, sunLunchHeld: true),
            200,
            headers: htmlHeaders,
          );
        }

        return http.Response('Not Found', 404);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final offerings = [
        MealOffering(
          date: satDate,
          slot: MealSlot.lunch,
          hall: hallCentral,
          option: dish1,
          reservable: true,
        ),
        MealOffering(
          date: sunDate,
          slot: MealSlot.lunch,
          hall: hallEng,
          option: dish2,
          reservable: true,
        ),
      ];

      final reservations = await client.reserveAll(session, offerings);

      // Verify exactly ONE POST was made for both lunches
      expect(postBodies.length, 1);
      final body = postBodies.first;

      // Both checkboxes checked
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl2\$chkReserve'], 'on');
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl3\$chkReserve'], 'on');

      // Both halls and dishes set correctly
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl2\$drpSelf'], '1');
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl2\$drpFood'], '101');
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl3\$drpSelf'], '2');
      expect(body['ctl00\$cphMain\$grdReservationLunch\$ctl3\$drpFood'], '102');

      // Save button for lunch was submitted
      expect(body['ctl00\$cphMain\$btnSaveLunch'], 'ذخیره');
      expect(body.containsKey('ctl00\$cphMain\$btnSaveDinner'), isFalse);

      // Both confirmed
      expect(reservations.length, 2);
      expect(reservations.any((r) => r.slot == MealSlot.lunch && r.date == satDate), isTrue);
      expect(reservations.any((r) => r.slot == MealSlot.lunch && r.date == sunDate), isTrue);
    });

    test('submits separate POSTs when offerings span different meal slots (Lunch and Dinner)', () async {
      final postBodies = <Map<String, String>>[];
      var getCount = 0;

      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          final isConfirmed = getCount > 2;
          return http.Response(
            buildWeekHtml(
              satLunchHeld: isConfirmed,
              satDinnerHeld: isConfirmed,
            ),
            200,
            headers: htmlHeaders,
          );
        }

        if (request.method == 'POST') {
          postBodies.add(Map<String, String>.from(request.bodyFields));
          return http.Response(
            buildWeekHtml(satLunchHeld: true, satDinnerHeld: true),
            200,
            headers: htmlHeaders,
          );
        }

        return http.Response('Not Found', 404);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final offerings = [
        MealOffering(
          date: satDate,
          slot: MealSlot.lunch,
          hall: hallCentral,
          option: dish1,
          reservable: true,
        ),
        MealOffering(
          date: satDate,
          slot: MealSlot.dinner,
          hall: hallCentral,
          option: dishDinner,
          reservable: true,
        ),
      ];

      final reservations = await client.reserveAll(session, offerings);

      // Exactly 2 POSTs: 1 for lunch and 1 for dinner
      expect(postBodies.length, 2);
      expect(postBodies[0].containsKey('ctl00\$cphMain\$btnSaveLunch'), isTrue);
      expect(postBodies[1].containsKey('ctl00\$cphMain\$btnSaveDinner'), isTrue);

      expect(reservations.length, 2);
    });

    test('throws ReservationLockedException when offering date is disabled/locked by server', () async {
      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            buildWeekHtml(satLunchDisabled: true, satLunchHeld: false),
            200,
            headers: htmlHeaders,
          );
        }

        if (request.method == 'POST') {
          return http.Response(
            buildWeekHtml(satLunchDisabled: true, satLunchHeld: false),
            200,
            headers: htmlHeaders,
          );
        }

        return http.Response('Not Found', 404);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final offerings = [
        MealOffering(
          date: satDate,
          slot: MealSlot.lunch,
          hall: hallCentral,
          option: dish1,
          reservable: true,
        ),
      ];

      expect(
        () => client.reserveAll(session, offerings),
        throwsA(isA<ReservationLockedException>()),
      );
    });

    test('returns confirmed reservations when some offerings succeed while another offering is locked by server', () async {
      var getCount = 0;
      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          final isConfirmed = getCount > 1;
          return http.Response(
            buildWeekHtml(
              satLunchHeld: isConfirmed,
              satLunchDisabled: false,
              sunLunchHeld: false,
              sunLunchDisabled: true,
            ),
            200,
            headers: htmlHeaders,
          );
        }

        if (request.method == 'POST') {
          return http.Response(
            buildWeekHtml(
              satLunchHeld: true,
              satLunchDisabled: false,
              sunLunchHeld: false,
              sunLunchDisabled: true,
            ),
            200,
            headers: htmlHeaders,
          );
        }

        return http.Response('Not Found', 404);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final offerings = [
        MealOffering(
          date: satDate,
          slot: MealSlot.lunch,
          hall: hallCentral,
          option: dish1,
          reservable: true,
        ),
        MealOffering(
          date: sunDate,
          slot: MealSlot.lunch,
          hall: hallEng,
          option: dish2,
          reservable: true,
        ),
      ];

      final reservations = await client.reserveAll(session, offerings);

      // Saturday was booked and confirmed; Sunday was locked.
      // Saturday MUST be returned so it is not discarded or untracked!
      expect(reservations.length, 1);
      expect(reservations.first.date, satDate);
      expect(reservations.first.slot, MealSlot.lunch);
    });
  });
}
