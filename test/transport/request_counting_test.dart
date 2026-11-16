import 'package:bahonar_nut/core/portal/request_ledger.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The transport is the only place that knows how many requests were sent.
///
/// The request budget is the last line of defence against a ban, and it used
/// to count *polls* — but a poll is one or two requests, so the backstop was
/// letting through twice the traffic it was written to allow. These tests pin
/// that the count is the truth: the number of requests that actually went out.
void main() {
  group('the transport counts what it sends', () {
    test('a GET is one request', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
      );

      await transport.get('a1', '/Reservation/Reservation.aspx');

      expect(transport.ledger.spentFor('a1'), 1);
      expect(transport.ledger.totalFor('a1'), 1);
    });

    test('a POST is one request', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
      );

      await transport.post('a1', '/Reservation/Reservation.aspx', body: {'a': 'b'});

      expect(transport.ledger.spentFor('a1'), 1);
    });

    test('a redirect hop is counted — the portal sees it too', () async {
      // The portal answers a successful login with a 302 to the reservation
      // hub. That second request reaches the portal exactly like the first,
      // so a count that ignored it would be counting what the *app* asked
      // for rather than what the portal received.
      var calls = 0;
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              '',
              302,
              headers: {'location': '/Reservation/Reservation.aspx'},
            );
          }
          return http.Response('<html></html>', 200);
        }),
      );

      await transport.get('a1', '/');

      expect(calls, 2, reason: 'the redirect was really followed');
      expect(transport.ledger.spentFor('a1'), 2,
          reason: 'and both requests were really sent');
    });

    test('a failed request is still counted', () async {
      // A request that times out reached the portal and was answered late.
      // It is exactly the sort of request that makes a pattern look odd, so
      // it must count.
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => throw const SocketishError()),
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        transport.get('a1', '/x'),
        throwsA(isA<TransportException>()),
      );

      expect(transport.ledger.spentFor('a1'), 1,
          reason: 'a request that failed still reached the portal');
    });

    test('the accounts are counted apart', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
      );

      await transport.get('a1', '/x');
      await transport.get('a2', '/x');
      await transport.get('a1', '/x');

      expect(transport.ledger.spentFor('a1'), 2);
      expect(transport.ledger.spentFor('a2'), 1);
    });

    test('the query string is not written into the record', () async {
      // The ledger is a record that may be read back and shown, and a query
      // can carry a token.
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
      );

      await transport.get('a1', '/x?token=secret');

      expect(transport.ledger.history.single.path, '/x');
    });
  });

  group('the ledger is shared', () {
    test('the transport and its owner see the same count', () async {
      final ledger = RequestLedger();
      final transport = PortalTransport(
        baseUri: Uri.parse('https://example.test/'),
        httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
        ledger: ledger,
      );

      await transport.get('a1', '/x');

      expect(ledger.spentFor('a1'), 1);
      expect(identical(transport.ledger, ledger), isTrue);
    });
  });
}

/// A failure that is not a timeout, so the transport's catch path is taken.
class SocketishError implements Exception {
  const SocketishError();

  @override
  String toString() => 'SocketishError: the socket went away';
}
