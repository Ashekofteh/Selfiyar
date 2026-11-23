import 'package:bahonar_nut/adapter/cullinan/cullinan_basket_buy.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The default date the GET serves, which is deliberately not the date the
/// hunt wants: that is what forces the date-filter postback.
const _defaultDate = '1405/08/06';
const _wantedDate = '1405/08/07';

Session _session({String id = 's1'}) => Session(
  account: 'a1',
  cookies: {'ASP.NET_SessionId': id},
  establishedAt: DateTime.utc(2026, 10, 28),
);

/// A minimal buy page with the parts the parser and the viewstate cache use.
String _buyPage({
  required String date,
  required String viewState,
  required String eventValidation,
}) =>
    '''
<html><body>
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewState" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN" />
<input type="hidden" name="__EVENTVALIDATION" id="__EVENTVALIDATION" value="$eventValidation" />
<input type="text" id="ctl00_cphMain_txtDate" value="$date" />
<table id="grdFoodBasketReservation">
<tr>
<td>1</td>
<td>ناهار</td>
<td>$date</td>
<td>
<input type="checkbox" name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$chkReserve" />
<select name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$drpSelf">
<option value="-1">انتخاب</option>
<option selected="selected" value="1">مرکزی برادران</option>
</select>
<select name="ctl00\$cphMain\$grdFoodBasketReservation\$ctl02\$drpFood">
<option value="-1">انتخاب</option>
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

const _loginPage =
    '<html><body><input name="txtUsernamePlain" id="txtUsernamePlain" />'
    '</body></html>';

/// A fake portal that records the requests and can fail one post on demand.
class _BasketServer {
  final List<String> methods = [];
  final List<http.Request> raw = [];

  int _postCount = 0;

  /// When set, the next POST answers with this HTTP status instead of a page.
  int? nextPostStatus;

  /// When true, the next POST answers with a WebForms error page and HTTP 200.
  bool nextPostErrorPage = false;

  /// When true, the next POST answers with the login form.
  bool bounceNextPost = false;

  http.Client client() => MockClient((request) async {
    raw.add(request);
    methods.add(request.method);

    if (request.method == 'GET') {
      return _html(
        _buyPage(
          date: _defaultDate,
          viewState: 'VS-GET',
          eventValidation: 'EV-GET',
        ),
      );
    }

    if (bounceNextPost) {
      bounceNextPost = false;
      return _html(_loginPage);
    }

    if (nextPostErrorPage) {
      nextPostErrorPage = false;
      return _html('<html><body>Runtime Error</body></html>');
    }

    final status = nextPostStatus;
    if (status != null) {
      nextPostStatus = null;
      return _html('<html><body>Runtime Error</body></html>', status: status);
    }

    _postCount++;
    final fields = Uri.splitQueryString(request.body);
    final date = fields[r'ctl00$cphMain$txtDate'] ?? _wantedDate;
    return _html(
      _buyPage(
        date: date,
        viewState: 'VS-POST-$_postCount',
        eventValidation: 'EV-POST-$_postCount',
      ),
    );
  });

  static http.Response _html(String body, {int status = 200}) => http.Response(
    body,
    status,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );
}

void main() {
  late _BasketServer server;
  late CullinanBasketBuy area;

  setUp(() {
    server = _BasketServer();
    area = CullinanBasketBuy(
      transport: PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: server.client(),
      ),
      clock: () => DateTime.utc(2026, 10, 28),
    );
  });

  group('fetchBasket request count', () {
    test(
      'the first read warms the cache, then each poll is one POST',
      () async {
        final first = await area.fetchBasket(_session(), cursor: _wantedDate);

        expect(first.listings, hasLength(1));
        expect(server.methods, ['GET', 'POST']);
        // The date filter used the state the GET rendered, including the event
        // validation the page carried.
        expect(server.raw[1].body, contains('VS-GET'));
        expect(server.raw[1].body, contains('EV-GET'));
        expect(server.raw[1].body, contains('txtDate=1405%2F08%2F07'));

        final second = await area.fetchBasket(_session(), cursor: _wantedDate);

        expect(second.listings, hasLength(1));
        expect(server.methods, [
          'GET',
          'POST',
          'POST',
        ], reason: 'a warm cache must not spend a GET on every poll');
        // The second POST carried the state from the *first post's response*,
        // not the stale GET state.
        expect(server.raw[2].body, contains('VS-POST-1'));
        expect(server.raw[2].body, contains('EV-POST-1'));
      },
    );

    test(
      'a stale cached state falls back to one fresh GET and retries once',
      () async {
        await area.fetchBasket(_session(), cursor: _wantedDate);
        expect(server.methods, ['GET', 'POST']);

        // The portal rejects the cached viewstate on the next poll.
        server.nextPostStatus = 500;

        final recovered = await area.fetchBasket(
          _session(),
          cursor: _wantedDate,
        );

        expect(recovered.listings, hasLength(1));
        expect(server.methods, [
          'GET',
          'POST',
          'POST',
          'GET',
          'POST',
        ], reason: 'one failed POST, one fresh GET, one retry — and no more');
        // The retry used the state from the fresh GET.
        expect(server.raw[4].body, contains('VS-GET'));
      },
    );

    test(
      'a 200 error page is treated as stale, not as an empty market',
      () async {
        await area.fetchBasket(_session(), cursor: _wantedDate);
        expect(server.methods, ['GET', 'POST']);

        // ASP.NET renders a rejected viewstate as a 200 page, so the status
        // alone would let this through as "no listings".
        server.nextPostErrorPage = true;

        final recovered = await area.fetchBasket(
          _session(),
          cursor: _wantedDate,
        );

        expect(recovered.listings, hasLength(1));
        expect(server.methods, ['GET', 'POST', 'POST', 'GET', 'POST']);
      },
    );

    test('a login bounce clears the cache and throws', () async {
      await area.fetchBasket(_session(), cursor: _wantedDate);
      expect(server.methods, ['GET', 'POST']);

      server.bounceNextPost = true;
      await expectLater(
        () => area.fetchBasket(_session(), cursor: _wantedDate),
        throwsA(isA<LoginRejectedException>()),
      );
      expect(server.methods, ['GET', 'POST', 'POST']);

      // The next read must re-establish the state, proving the bounce did not
      // leave the old (dead-session) viewstate in the cache.
      await area.fetchBasket(_session(), cursor: _wantedDate);
      expect(server.methods, ['GET', 'POST', 'POST', 'GET', 'POST']);
    });

    test('state is bound to the session that produced it', () async {
      await area.fetchBasket(_session(id: 's1'), cursor: _wantedDate);
      expect(server.methods, ['GET', 'POST']);

      // A different ASP.NET session cannot post the first session's viewstate.
      await area.fetchBasket(_session(id: 's2'), cursor: _wantedDate);
      expect(server.methods, ['GET', 'POST', 'GET', 'POST']);
    });
  });

  group('claim request count and cached-state fast-path (1-RTT claim)', () {
    test(
      'claim reuses cached page from fetchBasket without issuing an extra GET',
      () async {
        final page = await area.fetchBasket(_session(), cursor: _wantedDate);
        expect(page.listings, hasLength(1));
        expect(server.methods, ['GET', 'POST']);

        // Clear recorded methods to specifically measure claim RTT
        server.methods.clear();
        server.raw.clear();

        await area.claim(_session(), page.listings.first.id);

        // Only 1 purchase POST is sent, 0 GET requests! (1 RTT claim)
        expect(server.methods, ['POST']);
        expect(server.raw.first.body, contains('VS-POST-1'));
      },
    );

    test('claim without prior cache falls back to fresh page read', () async {
      await area.claim(_session(), '2026-10-28|lunch|1|62742');
      // Without cache: GET default page, then date filter POST, then purchase POST
      expect(server.methods, contains('GET'));
    });

    test('claim returns ClaimRejected when response is an ASP.NET error page', () async {
      final page = await area.fetchBasket(_session(), cursor: _wantedDate);
      server.methods.clear();
      server.nextPostErrorPage = true;

      final result = await area.claim(_session(), page.listings.first.id);
      expect(result, isA<ClaimRejected>());
      expect((result as ClaimRejected).reason, contains('خطای فرم سامانه دانشگاه'));
    });
  });
}
