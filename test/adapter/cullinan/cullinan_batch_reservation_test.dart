import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
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

  final dish1 = const MenuOption(
    id: '101',
    name: 'چلو جوجه کباب',
    priceRial: 500000,
  );
  final dish2 = const MenuOption(
    id: '102',
    name: 'چلو قورمه سبزی',
    priceRial: 400000,
  );
  final dishDinner = const MenuOption(
    id: '201',
    name: 'ماکارونی',
    priceRial: 300000,
  );

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
    String? balanceLabel,
  }) {
    return '''
<html><body>
${balanceLabel == null ? '' : '<label id="lblCredit">$balanceLabel</label>'}
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

  /// The week before [buildWeekHtml]: it carries the same grids for dates the
  /// next-week batch does not target, and it is what the server answers a
  /// write with (the server always re-renders its default week).
  String buildCurrentWeekHtml() {
    return '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="CURRENT_VS" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN_VS" />
<table id="cphMain_grdReservationBreakfast"></table>
<table id="cphMain_grdReservationLunch">
  ${rowHtml('grdReservationLunch', 2, '1405/07/25', optionId: '101', hallId: '1')}
</table>
<table id="cphMain_grdReservationDinner">
  ${rowHtml('grdReservationDinner', 2, '1405/07/25', optionId: '201', hallId: '1')}
</table>
<input type="submit" name="ctl00\$cphMain\$btnSaveLunch" value="ذخیره" id="cphMain_btnSaveLunch" />
<input type="submit" name="ctl00\$cphMain\$btnSaveDinner" value="ذخیره" id="cphMain_btnSaveDinner" />
</body></html>
''';
  }

  group('CullinanPortalClient.reserveAll', () {
    test(
      'returns empty list for empty offerings without network call',
      () async {
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
      },
    );

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
      expect(
        body['ctl00\$cphMain\$grdReservationLunch\$ctl2\$chkReserve'],
        'on',
      );
      expect(
        body['ctl00\$cphMain\$grdReservationLunch\$ctl3\$chkReserve'],
        'on',
      );

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
      expect(
        reservations.any((r) => r.slot == MealSlot.lunch && r.date == satDate),
        isTrue,
      );
      expect(
        reservations.any((r) => r.slot == MealSlot.lunch && r.date == sunDate),
        isTrue,
      );
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
      expect(
        postBodies[1].containsKey('ctl00\$cphMain\$btnSaveDinner'),
        isTrue,
      );

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

    test(
      'reuses the write response as the next slot\'s form and the confirmation',
      () async {
        var getCount = 0;
        final posts = <Map<String, String>>[];

        final inner = MockClient((request) async {
          if (request.method == 'GET') {
            getCount++;
            return http.Response(buildWeekHtml(), 200, headers: htmlHeaders);
          }
          posts.add(Map<String, String>.from(request.bodyFields));
          return http.Response(
            buildWeekHtml(satLunchHeld: true, satDinnerHeld: true),
            200,
            headers: htmlHeaders,
          );
        });

        final transport = PortalTransport(
          httpClient: inner,
          baseUri: Uri.parse('https://dining.example.ac.ir'),
        );
        final client = CullinanPortalClient(transport: transport);

        final reservations = await client.reserveAll(session, [
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
        ]);

        expect(
          getCount,
          1,
          reason:
              'the initial GET opens the week; the write responses carry the '
              'form for the next slot and the confirmation, so no extra read '
              'is needed',
        );
        expect(posts, hasLength(2), reason: 'one write per meal slot');
        expect(
          posts[1][r'ctl00$cphMain$grdReservationLunch$ctl2$chkReserve'],
          'on',
          reason:
              'the dinner POST must re-post the lunch checkbox the first '
              'write just booked — an absent ASP.NET checkbox reads as '
              'unchecked, which would cancel lunch',
        );
        expect(
          posts[1][r'ctl00$cphMain$grdReservationDinner$ctl2$chkReserve'],
          'on',
          reason: 'the dinner row is the one this write intends to book',
        );
        expect(reservations, hasLength(2));
      },
    );

    test(
      're-reads the form when a write response loses the row it just booked',
      () async {
        var getCount = 0;
        var lunchHeld = false;
        var dinnerHeld = false;
        final posts = <Map<String, String>>[];

        final inner = MockClient((request) async {
          if (request.method == 'GET') {
            getCount++;
            return http.Response(
              buildWeekHtml(satLunchHeld: lunchHeld, satDinnerHeld: dinnerHeld),
              200,
              headers: htmlHeaders,
            );
          }

          final body = Map<String, String>.from(request.bodyFields);
          posts.add(body);

          if (body.containsKey(r'ctl00$cphMain$btnSaveLunch')) {
            lunchHeld = true;
            // The write landed, but the response is a partial page that lost
            // the just-booked lunch row. Reusing it for dinner would post
            // lunch as unchecked and cancel it.
            return http.Response(
              buildWeekHtml(satLunchHeld: false, satDinnerHeld: dinnerHeld),
              200,
              headers: htmlHeaders,
            );
          }
          if (body.containsKey(r'ctl00$cphMain$btnSaveDinner')) {
            dinnerHeld = true;
          }
          return http.Response(
            buildWeekHtml(satLunchHeld: lunchHeld, satDinnerHeld: dinnerHeld),
            200,
            headers: htmlHeaders,
          );
        });

        final transport = PortalTransport(
          httpClient: inner,
          baseUri: Uri.parse('https://dining.example.ac.ir'),
        );
        final client = CullinanPortalClient(transport: transport);

        final reservations = await client.reserveAll(session, [
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
        ]);

        expect(
          getCount,
          2,
          reason:
              'the partial write response is not a valid form for the next '
              'slot, so one fresh read is spent before the second write',
        );
        expect(posts, hasLength(2), reason: 'still one write per meal slot');
        expect(
          posts[1][r'ctl00$cphMain$grdReservationLunch$ctl2$chkReserve'],
          'on',
          reason:
              'the fresh form carries the lunch the first write booked, so '
              'the dinner POST keeps it checked instead of cancelling it',
        );
        expect(reservations, hasLength(2));
      },
    );

    test(
      'reaches a next-week batch with one GET and one navigation per write',
      () async {
        var getCount = 0;
        var lunchHeld = false;
        var dinnerHeld = false;
        final posts = <Map<String, String>>[];

        final inner = MockClient((request) async {
          if (request.method == 'GET') {
            getCount++;
            return http.Response(
              buildCurrentWeekHtml(),
              200,
              headers: htmlHeaders,
            );
          }

          final body = Map<String, String>.from(request.bodyFields);
          posts.add(body);

          if (body['__EVENTTARGET']?.isNotEmpty == true) {
            return http.Response(
              buildWeekHtml(satLunchHeld: lunchHeld, satDinnerHeld: dinnerHeld),
              200,
              headers: htmlHeaders,
            );
          }

          // A write is answered with the server's default (current) week.
          if (body.containsKey(r'ctl00$cphMain$btnSaveLunch')) lunchHeld = true;
          if (body.containsKey(r'ctl00$cphMain$btnSaveDinner')) {
            dinnerHeld = true;
          }
          return http.Response(
            buildCurrentWeekHtml(),
            200,
            headers: htmlHeaders,
          );
        });

        final transport = PortalTransport(
          httpClient: inner,
          baseUri: Uri.parse('https://dining.example.ac.ir'),
        );
        final client = CullinanPortalClient(transport: transport);

        final reservations = await client.reserveAll(session, [
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
        ]);

        final writes = posts
            .where((body) => body.keys.any((key) => key.contains('btnSave')))
            .toList();

        expect(
          getCount,
          1,
          reason:
              'the initial GET is enough: the next week is reached by '
              'navigation, and the write responses carry the viewstate for '
              'the next navigation',
        );
        expect(
          writes,
          hasLength(2),
          reason: 'one write per meal slot, and no reads between them',
        );
        expect(
          posts,
          hasLength(5),
          reason:
              'three navigations (grouping, between the writes, and the '
              'confirmation) plus the two writes',
        );
        for (final write in writes) {
          expect(
            write['__VIEWSTATE'],
            'WEEK_VS',
            reason: 'a next-week write must carry the TARGET week\'s viewstate',
          );
        }
        expect(reservations, hasLength(2));
      },
    );

    test(
      'refuses the whole batch from the page balance before the first write',
      () async {
        var getCount = 0;
        var postCount = 0;

        final inner = MockClient((request) async {
          if (request.method == 'GET') {
            getCount++;
            return http.Response(
              buildWeekHtml(balanceLabel: '50,000 ریال'),
              200,
              headers: htmlHeaders,
            );
          }
          postCount++;
          return http.Response(buildWeekHtml(), 200, headers: htmlHeaders);
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

        await expectLater(
          client.reserveAll(session, offerings, requiredBalanceRial: 900000),
          throwsA(
            isA<InsufficientBalanceException>()
                .having((e) => e.balanceRial, 'balanceRial', 50000)
                .having((e) => e.deficitRial, 'deficitRial', 850000),
          ),
        );

        expect(getCount, 1);
        expect(
          postCount,
          0,
          reason: 'the balance is checked before the first write',
        );
      },
    );

    test('books many days of one slot with a single write when the balance covers them', () async {
      var getCount = 0;
      final posts = <Map<String, String>>[];

      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          return http.Response(
            buildWeekHtml(balanceLabel: '1,000,000 ریال'),
            200,
            headers: htmlHeaders,
          );
        }
        posts.add(Map<String, String>.from(request.bodyFields));
        return http.Response(
          buildWeekHtml(satLunchHeld: true, sunLunchHeld: true),
          200,
          headers: htmlHeaders,
        );
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      final reservations = await client.reserveAll(session, [
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
      ], requiredBalanceRial: 900000);

      expect(getCount, 1);
      expect(
        posts,
        hasLength(1),
        reason:
            'both days live in the lunch grid, so the site books them with '
            'one save — and so does the batch',
      );
      expect(
        posts.single.keys,
        containsAll([
          r'ctl00$cphMain$grdReservationLunch$ctl2$chkReserve',
          r'ctl00$cphMain$grdReservationLunch$ctl3$chkReserve',
        ]),
      );
      expect(reservations, hasLength(2));
    });

    test('refuses a batch when the page does not report a balance', () async {
      var postCount = 0;
      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            buildWeekHtml(), // no lblCredit
            200,
            headers: htmlHeaders,
          );
        }
        postCount++;
        return http.Response(buildWeekHtml(), 200, headers: htmlHeaders);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      await expectLater(
        client.reserveAll(session, [
          MealOffering(
            date: satDate,
            slot: MealSlot.lunch,
            hall: hallCentral,
            option: dish1,
            reservable: true,
          ),
        ], requiredBalanceRial: 500000),
        throwsA(isA<PortalUnreachableException>()),
      );
      expect(
        postCount,
        0,
        reason: 'a batch must never be sent on a balance that was not read',
      );
    });

    test('refuses a batch when the balance label is unparseable', () async {
      var postCount = 0;
      final inner = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            buildWeekHtml(balanceLabel: 'نامشخص'),
            200,
            headers: htmlHeaders,
          );
        }
        postCount++;
        return http.Response(buildWeekHtml(), 200, headers: htmlHeaders);
      });

      final transport = PortalTransport(
        httpClient: inner,
        baseUri: Uri.parse('https://dining.example.ac.ir'),
      );
      final client = CullinanPortalClient(transport: transport);

      await expectLater(
        client.reserveAll(session, [
          MealOffering(
            date: satDate,
            slot: MealSlot.lunch,
            hall: hallCentral,
            option: dish1,
            reservable: true,
          ),
        ], requiredBalanceRial: 500000),
        throwsA(isA<PortalUnreachableException>()),
      );
      expect(postCount, 0);
    });
  });
}
