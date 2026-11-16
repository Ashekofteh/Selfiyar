import 'package:bahonar_nut/transport/cookie_jar.dart';
import 'package:test/test.dart';

void main() {
  group('account isolation', () {
    test('two accounts never share cookies', () {
      final store = CookieJarStore();
      store.jarFor('a1').setCookie('ASP.NET_SessionId=one; path=/; HttpOnly');
      store.jarFor('a2').setCookie('ASP.NET_SessionId=two; path=/; HttpOnly');

      expect(store.jarFor('a1').cookies['ASP.NET_SessionId'], 'one');
      expect(store.jarFor('a2').cookies['ASP.NET_SessionId'], 'two');
    });

    test('the cookie header carries only that account\'s cookies', () {
      final store = CookieJarStore();
      store.jarFor('a1').setCookie('ASP.NET_SessionId=one; path=/');
      store.jarFor('a1').setCookie('keyId=k; path=/');
      store.jarFor('a2').setCookie('ASP.NET_SessionId=two; path=/');

      final header = store.jarFor('a1').cookieHeader!;
      expect(header, contains('ASP.NET_SessionId=one'));
      expect(header, isNot(contains('two')));
    });

    test('an empty jar produces no cookie header', () {
      final store = CookieJarStore();
      expect(store.jarFor('a1').cookieHeader, isNull);
    });

    test('removing a jar leaves the others intact', () {
      final store = CookieJarStore();
      store.jarFor('a1').setCookie('a=1; path=/');
      store.jarFor('a2').setCookie('b=2; path=/');

      store.remove('a1');
      expect(store.existingJar('a1'), isNull);
      expect(store.existingJar('a2')!.cookies['b'], '2');
    });
  });

  group('cookie parsing', () {
    test('keeps the value and ignores the attributes', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('ASP.NET_SessionId=abc123; path=/; HttpOnly; secure');
      expect(jar.cookies['ASP.NET_SessionId'], 'abc123');
    });

    test('records the anti-forgery token the portal sets after login', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('__AntiXsrfToken=tok123; path=/; HttpOnly');
      expect(jar.cookies['__AntiXsrfToken'], 'tok123');
    });

    test('an empty value deletes the cookie', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('a=1; path=/');
      jar.setCookie('a=; path=/');
      expect(jar.cookies.containsKey('a'), isFalse);
    });

    test('a past expiry deletes the cookie', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('a=1; path=/');
      jar.setCookie('a=1; path=/; Expires=Sun, 18 Oct 2020 18:08:43 GMT');
      expect(jar.cookies.containsKey('a'), isFalse);
    });

    test('a future expiry keeps the cookie', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('a=1; path=/');
      jar.setCookie('a=1; path=/; Expires=Sun, 18 Oct 2035 18:08:43 GMT');
      expect(jar.cookies['a'], '1');
    });

    test('a malformed header is ignored rather than throwing', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('garbage-without-equals');
      jar.setCookie('=novalue');
      expect(jar.cookies, isEmpty);
    });

    test('a later Set-Cookie replaces an earlier value for the same name', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('a=1; path=/');
      jar.setCookie('a=2; path=/');
      expect(jar.cookies['a'], '2');
    });
  });

  group('HTTP date parsing', () {
    test('parses the RFC 1123 format the portal sends', () {
      final parsed = HttpDateParser.parse('Sun, 18 Oct 2026 18:08:43 GMT');
      expect(parsed, DateTime.utc(2026, 10, 18, 18, 8, 43));
    });

    test('parses the two-digit-year legacy format', () {
      final parsed = HttpDateParser.parse('Sunday, 18-Oct-26 18:08:43 GMT');
      expect(parsed, DateTime.utc(2026, 10, 18, 18, 8, 43));
    });

    test('parses the asctime-style format', () {
      final parsed = HttpDateParser.parse('Sun Oct 18 18:08:43 2026');
      expect(parsed, DateTime.utc(2026, 10, 18, 18, 8, 43));
    });

    test('throws on an unrecognisable date', () {
      expect(
        () => HttpDateParser.parse('not a date at all'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('restoring a persisted session', () {
    test('replaceAll restores the whole jar', () {
      final jar = AccountCookieJar('a1');
      jar.replaceAll(const {
        'ASP.NET_SessionId': 'sid',
        'keyId': 'k',
        '__AntiXsrfToken': 'tok',
      });
      expect(jar.cookies.length, 3);
      expect(jar.cookies['__AntiXsrfToken'], 'tok');
    });

    test('replaceAll replaces rather than merges', () {
      final jar = AccountCookieJar('a1');
      jar.setCookie('old=1; path=/');
      jar.replaceAll(const {'new': '2'});
      expect(jar.cookies.containsKey('old'), isFalse);
      expect(jar.cookies['new'], '2');
    });
  });
}
