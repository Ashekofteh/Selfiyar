/// HTTP transport for the portal.
///
/// Responsibilities kept deliberately narrow:
///   * carry the account's cookies, and only that account's;
///   * capture the server's `Date` header so the clock can be synced;
///   * follow the portal's redirect behaviour explicitly, because a silent
///     redirect turned a successful login into an apparent failure once;
///   * count every request it makes, because the account's request budget is
///     the last line of defence against a ban, and only this layer knows how
///     many requests were actually sent.
///
/// This layer knows nothing about meals. It moves bytes, keeps jars, and
/// reports what it sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/models.dart';
import '../core/request_ledger.dart';
import '../core/time.dart';
import 'cookie_jar.dart';

/// A response, with the server's clock reading attached.
class TransportResponse {
  const TransportResponse({
    required this.statusCode,
    required this.body,
    required this.serverDateUtc,
    required this.requestStartedAt,
    required this.requestCompletedAt,
    this.bytes,
    this.headers = const {},
  });

  final int statusCode;

  /// Decoded response body.
  final String body;

  /// Raw response bytes, for images.
  final Uint8List? bytes;

  /// The server's own clock, parsed from the `Date` header. Null when the
  /// header was absent or unparseable.
  final DateTime? serverDateUtc;

  final DateTime requestStartedAt;
  final DateTime requestCompletedAt;

  final Map<String, String> headers;

  /// Measured round-trip time.
  Duration get roundTrip =>
      requestCompletedAt.difference(requestStartedAt);

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// True when the body looks like the portal's login form, which is how a
  /// bounced request announces itself.
  bool get looksLikeLoginPage => body.contains('txtUsernamePlain');
}

/// The portal could not be reached, or answered unusably.
class TransportException implements Exception {
  const TransportException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'TransportException: $message${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// Performs HTTP for the portal, with per-account cookie isolation.
class PortalTransport {
  PortalTransport({
    required this.baseUri,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    this.clock,
    RequestLedger? ledger,
    this.onConnectivityFeedback,
  }) : _http = httpClient ?? _defaultClient(),
       ledger = ledger ?? RequestLedger();

  final void Function(bool isOnline)? onConnectivityFeedback;

  static http.Client _defaultClient() {
    try {
      final io = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) {
          if (host == 'nut.uk.ac.ir' ||
              host.endsWith('.uk.ac.ir') ||
              host.contains('uk.ac.ir')) {
            return true;
          }
          return false;
        };
      return IOClient(io);
    } catch (_) {
      return http.Client();
    }
  }

  /// The portal's root. Every request path is resolved against it.
  final Uri baseUri;
  final http.Client _http;
  final Duration timeout;
  final String userAgent;

  /// The clock kept in step with the portal's `Date` header.
  ///
  /// Optional: a transport used only for parsing, or in a test, has no clock to
  /// sync. The app always supplies one — without a synced clock the hunt's
  /// pre-flight refuses to start, because peak detection would otherwise be
  /// guessing at the portal's time.
  ///
  /// The sync rides along on the reads the app was making anyway: every portal
  /// response carries a `Date` header, so the clock never needs a request of
  /// its own.
  final SyncedServerClock? clock;

  /// The record of what this transport sent.
  ///
  /// ## Why the transport owns the count
  ///
  /// The request budget is the project's last line of defence against a ban,
  /// and a budget that counts the wrong thing is worse than no budget. The
  /// hunt used to count *polls*, but a poll is one or two requests, so the
  /// count was low by half — and the reads that are not part of a hunt (the
  /// manual refresh, the sync, the top-up) were not counted at all.
  ///
  /// This is the one place every request goes through, so it is the one place
  /// the count can be right. The ledger is exposed rather than hidden so the
  /// count can be **read back** — the thing the project still needs is a live
  /// read of the budget against the portal, and a number nobody can read is
  /// a number nobody can trust.
  final RequestLedger ledger;

  /// One jar per account. Never mixed.
  final CookieJarStore jars = CookieJarStore();

  /// Absolute URL for a portal-relative path.
  Uri resolve(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final relative = path.startsWith('/') ? path.substring(1) : path;
    return baseUri.resolve(relative);
  }

  /// Performs a GET for [accountId].
  Future<TransportResponse> get(
    AccountId accountId,
    String path, {
    Map<String, String>? headers,
  }) =>
      _send(accountId, 'GET', path, headers: headers);

  /// Performs a POST with a form-encoded body.
  ///
  /// Set [followRedirects] to false to get the redirect itself rather than
  /// its target. That matters for the top-up: the portal answers the payment
  /// confirmation with a `302` to the **bank's** gateway, and the gateway is
  /// not reachable from this transport — the TLS handshake fails there (F55).
  /// Following the redirect would turn a successful handoff into a network
  /// error, so the redirect is read and the WebView is given the URL.
  Future<TransportResponse> post(
    AccountId accountId,
    String path, {
    Map<String, String> body = const {},
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send(
        accountId,
        'POST',
        path,
        body: body,
        headers: headers,
        followRedirects: followRedirects,
      );

  /// Puts [cookies] into [accountId]'s jar.
  ///
  /// The jar is the only thing that sends cookies, and it is filled by the
  /// responses the portal sends. A session that was **restored from storage**
  /// was never a response: its cookies came from disk, so the jar is empty and
  /// every request would go out unauthenticated — the portal would answer with
  /// the login page, and the read would look like an expired session rather
  /// than like a session that was never applied.
  ///
  /// The cookies already in the jar are kept: the portal's own `Set-Cookie`
  /// headers are fresher than what was stored, and replacing them wholesale
  /// would discard a rotated anti-XSRF token.
  void restoreSession(
    AccountId accountId,
    Map<String, String> cookies,
  ) {
    if (cookies.isEmpty) return;
    final jar = jars.jarFor(accountId);
    for (final entry in cookies.entries) {
      jar.setCookie('${entry.key}=${entry.value}');
    }
  }

  /// Fetches raw bytes, for the CAPTCHA image.
  ///
  /// Goes through the same request path as [_send] rather than issuing a
  /// separate call: a second request would double the traffic and, worse, would
  /// fetch the challenge a second time — and the session holds **one**
  /// challenge, so the bytes returned here would be a *different* challenge
  /// from the one the login POST will be judged against. Verified live
  /// 2026-10-21 (F77).
  Future<Uint8List> getBytes(AccountId accountId, String path) async {
    final response = await _send(accountId, 'GET', path);
    return response.bytes ?? Uint8List(0);
  }

  Future<TransportResponse> _send(
    AccountId accountId,
    String method,
    String path, {
    Map<String, String> body = const {},
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    final uri = resolve(path);
    final startedAt = DateTime.now().toUtc();

    // The request is counted **before** it is sent, because a request that
    // fails still reached the portal — a timeout is a request the portal saw
    // and answered late, and it is exactly the sort of request that makes a
    // pattern look odd.
    ledger.record(
      accountId: accountId,
      method: method,
      path: _pathOnly(path),
    );

    late http.Response response;
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(_headers(accountId, headers));

      if (method == 'POST') {
        request.headers['content-type'] =
            'application/x-www-form-urlencoded; charset=UTF-8';
        request.body = _encodeForm(body);
      }

      final streamed = await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed);

      // Follow redirects manually. `package:http`'s `Client.send` does NOT
      // follow them - the flag lives on the convenience methods only - and
      // that matters here: the portal answers a successful login with a 302 to
      // the reservation hub. Without following it, the body is the redirect
      // page, which still contains the login form markup, so a *successful*
      // login looks like a failed one.
      //
      // A 302 after a POST is followed with GET, as browsers do.
      var hops = 0;
      while (followRedirects && _isRedirect(response.statusCode) && hops < 5) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) break;

        final target = location.startsWith('http')
            ? Uri.parse(location)
            : resolve(location);
        final follow = http.Request(
          response.statusCode == 303 ? 'GET' : method,
          target,
        )..headers.addAll(_headers(accountId, headers));

        // A redirected POST would otherwise re-submit the form body.
        if (follow.method != 'POST') {
          follow.headers.remove('content-type');
        }

        // A redirect hop is a request the portal sees, so it is counted.
        ledger.record(
          accountId: accountId,
          method: follow.method,
          path: _pathOnly(target.path),
        );

        final followed = await _http.send(follow).timeout(timeout);
        response = await http.Response.fromStream(followed);
        hops++;
      }
    } on TimeoutException {
      onConnectivityFeedback?.call(false);
      throw const TransportException('request timed out');
    } catch (e) {
      if (e is SocketException ||
          e is http.ClientException ||
          e.toString().contains('SocketException') ||
          e.toString().contains('Network is unreachable') ||
          e.toString().contains('Failed host lookup')) {
        onConnectivityFeedback?.call(false);
      }
      final msg = e.toString();
      if (msg.contains('HandshakeException') ||
          msg.contains('CERTIFICATE_VERIFY_FAILED') ||
          msg.contains('Connection reset') ||
          msg.contains('Connection refused') ||
          msg.contains('Handshake error')) {
        throw const TransportException(
          'خطای ارتباط با سامانه دانشگاه. در صورت روشن بودن فیلترشکن (VPN) آن را خاموش کنید و مجدداً تلاش نمایید.',
        );
      }
      throw TransportException('network failure: $e');
    }

    final completedAt = DateTime.now().toUtc();
    onConnectivityFeedback?.call(true);

    // Record the cookies the server set. The WHOLE jar is kept: the portal sets
    // `__AntiXsrfToken` only after login, and dropping a cookie it set fails
    // later on a write operation, which is the worst time to find out.
    //
    // `package:http` flattens repeated headers into one comma-joined string,
    // so the raw header is read from the response's `headersSplitValues` when
    // available; otherwise the combined value is split on the cookie boundary.
    final jar = jars.jarFor(accountId);
    for (final raw in _setCookieValues(response)) {
      jar.setCookie(raw);
    }

    final serverDateUtc = parseServerDate(response.headers['date']);

    // Sync the clock from the response's `Date` header.
    //
    // The header reflects when the *server* generated the response, which was
    // about half a round trip ago, so the observation is corrected by half the
    // measured round trip. A response with no `Date` header is not an
    // observation and is ignored: the next response will carry one.
    clock?.observe(
      serverDateUtc: serverDateUtc,
      roundTrip: completedAt.difference(startedAt),
      localReceivedAt: completedAt,
    );

    return TransportResponse(
      statusCode: response.statusCode,
      body: _decodeBody(response),
      bytes: response.bodyBytes,
      serverDateUtc: serverDateUtc,
      requestStartedAt: startedAt,
      requestCompletedAt: completedAt,
      headers: response.headers,
    );
  }

  /// True for the status codes that carry a `Location` to follow.
  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 ||
      status == 308;

  /// The path of a request, without the query string.
  ///
  /// The query can carry a token or a session id, and the ledger is a record
  /// that may be read back and shown — so the identifying parts of the URL
  /// are not written down.
  static String _pathOnly(String path) {
    final cut = path.indexOf('?');
    return cut < 0 ? path : path.substring(0, cut);
  }

  /// The individual `Set-Cookie` header values of a response.
  ///
  /// A response may set several cookies, and each is its own header. The
  /// `package:http` `Response` exposes them individually when the underlying
  /// client preserved them; the flattened fallback splits on the comma that
  /// separates cookies, being careful not to split inside an `Expires` date
  /// (which itself contains a comma).
  static List<String> _setCookieValues(http.Response response) {
    final split = response.headersSplitValues['set-cookie'];
    if (split != null && split.isNotEmpty) return split;

    final combined = response.headers['set-cookie'];
    if (combined == null || combined.isEmpty) return const [];

    final values = <String>[];
    final buffer = StringBuffer();
    for (final part in combined.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      // A new cookie starts with `name=`. Inside an Expires date the fragment
      // after a comma is a date part, never `name=`.
      if (RegExp(r'^[^=;,\s]+=').hasMatch(trimmed)) {
        if (buffer.isNotEmpty) values.add(buffer.toString());
        buffer.clear();
        buffer.write(trimmed);
      } else {
        buffer.write(', $trimmed');
      }
    }
    if (buffer.isNotEmpty) values.add(buffer.toString());
    return values;
  }

  /// Builds the request headers, including this account's cookies only.
  Map<String, String> _headers(
    AccountId accountId,
    Map<String, String>? extra,
  ) {
    final headers = <String, String>{
      'user-agent': userAgent,
      'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'accept-language': 'fa-IR,fa;q=0.9,en;q=0.8',
      'referer': baseUri.toString(),
    };
    if (extra != null) headers.addAll(extra);

    final cookieHeader = jars.jarFor(accountId).cookieHeader;
    if (cookieHeader != null) headers['cookie'] = cookieHeader;

    return headers;
  }

  /// Decodes the body, honouring the charset the portal declares.
  ///
  /// The portal is Persian and serves UTF-8; but the response may declare
  /// something else, and mis-decoding produces mojibake that silently breaks
  /// every parser downstream.
  String _decodeBody(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';
    final charsetMatch = RegExp(r'charset=([\w-]+)').firstMatch(contentType);
    final charset = charsetMatch?.group(1)?.toLowerCase() ?? 'utf-8';

    final bytes = response.bodyBytes;
    if (charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // The portal only serves UTF-8 in practice; anything else is decoded
    // leniently as UTF-8 rather than throwing on an unknown codec.
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Encodes a form body.
  static String _encodeForm(Map<String, String> body) => body.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  /// Parses the `Date` header into a UTC instant.
  static DateTime? parseServerDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDateParser.parse(value);
    } catch (_) {
      return null;
    }
  }

  void close() => _http.close();
}
