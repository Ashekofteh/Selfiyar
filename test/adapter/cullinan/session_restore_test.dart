import 'package:bahonar_nut/adapter/cullinan/cullinan_client.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The jar is filled by the portal's responses, so a session **restored from
/// storage** — which was never a response — starts with an empty jar. Every
/// request would then go out unauthenticated, the portal would answer with the
/// login page, and the read would be reported as an expired session rather
/// than as a session that was never applied.
void main() {
  group('a restored session', () {
    test('its cookies reach the request', () async {
      final sent = <String?>[];
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          sent.add(request.headers['cookie']);
          return http.Response('<html></html>', 200);
        }),
      );
      final client = CullinanPortalClient(transport: transport);

      await client.fetchReservations(
        Session(
          account: 'a1',
          cookies: const {
            'ASP.NET_SessionId': 'stored-session',
            '__AntiXsrfToken': 'stored-token',
          },
          establishedAt: DateTime.utc(2026, 10, 20),
        ),
      );

      expect(sent, isNotEmpty);
      for (final cookie in sent) {
        expect(cookie, contains('ASP.NET_SessionId=stored-session'));
        expect(cookie, contains('__AntiXsrfToken=stored-token'));
      }
    });

    test('the cookies survive the read', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          return http.Response('<html></html>', 200);
        }),
      );
      final client = CullinanPortalClient(transport: transport);

      await client.fetchReservations(
        Session(
          account: 'a1',
          cookies: const {'ASP.NET_SessionId': 'stored-session'},
          establishedAt: DateTime.utc(2026, 10, 20),
        ),
      );

      expect(
        transport.jars.jarFor('a1').cookies['ASP.NET_SessionId'],
        'stored-session',
      );
    });

    test('the cookies are not sent for another account', () async {
      final sent = <String?>[];
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          sent.add(request.headers['cookie']);
          return http.Response('<html></html>', 200);
        }),
      );
      final client = CullinanPortalClient(transport: transport);

      await client.fetchReservations(
        Session(
          account: 'a1',
          cookies: const {'ASP.NET_SessionId': 'session-of-a1'},
          establishedAt: DateTime.utc(2026, 10, 20),
        ),
      );
      await client.fetchReservations(
        Session(
          account: 'a2',
          cookies: const {'ASP.NET_SessionId': 'session-of-a2'},
          establishedAt: DateTime.utc(2026, 10, 20),
        ),
      );

      expect(sent.first, contains('session-of-a1'));
      expect(sent.first, isNot(contains('session-of-a2')));
      expect(sent.last, contains('session-of-a2'));
      expect(sent.last, isNot(contains('session-of-a1')));
    });
  });
}
