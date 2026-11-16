/// Per-account cookie jars.
///
/// The isolation rule is absolute: **one account's cookies must never be sent
/// with another account's request.** The app manages several students' meals
/// on one phone, and a crossed cookie jar would mean one student's session
/// acting on another's meal — spending the wrong person's money on the wrong
/// person's food. That is a correctness bug and a privacy bug, and it is far
/// easier to prevent here than to diagnose later.
library;

import '../core/meal/models.dart';

/// A cookie jar scoped to one account.
class AccountCookieJar {
  AccountCookieJar(this.accountId);

  final AccountId accountId;

  final Map<String, String> _cookies = {};

  /// The cookies, as name -> value.
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  /// The `Cookie` header value, or null when the jar is empty.
  String? get cookieHeader {
    if (_cookies.isEmpty) return null;
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool get isEmpty => _cookies.isEmpty;

  bool get isNotEmpty => _cookies.isNotEmpty;

  /// Records a `Set-Cookie` header value.
  ///
  /// Handles the attributes the portal sends: `Path`, `Expires`, `HttpOnly`,
  /// `Secure`, `SameSite`. Only `Path` and `Expires` affect whether the cookie
  /// is still live, and this jar is single-origin so `Path` needs no matching.
  ///
  /// A cookie whose `Expires` is in the past is a deletion, and is removed.
  void setCookie(String raw) {
    final parts = raw.split(';');
    final pair = parts.first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) return;

    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();

    // Deletion: an empty value or a past expiry removes the cookie.
    if (value.isEmpty) {
      _cookies.remove(name);
      return;
    }

    DateTime? expiresAt;
    for (final attribute in parts.skip(1)) {
      final trimmed = attribute.trim();
      if (trimmed.toLowerCase().startsWith('expires=')) {
        expiresAt = _parseHttpDate(trimmed.substring(8));
      }
    }
    if (expiresAt != null && expiresAt.isBefore(DateTime.now().toUtc())) {
      _cookies.remove(name);
      return;
    }

    _cookies[name] = value;
  }

  /// Replaces the whole jar, e.g. when restoring a persisted session.
  void replaceAll(Map<String, String> values) {
    _cookies
      ..clear()
      ..addAll(values);
  }

  void clear() => _cookies.clear();

  /// The set of cookie names, for diagnostics.
  Iterable<String> get names => _cookies.keys;

  @override
  String toString() => 'AccountCookieJar($accountId, ${_cookies.length} cookies)';
}

/// Holds one jar per account.
class CookieJarStore {
  final Map<AccountId, AccountCookieJar> _jars = {};

  /// The jar for [accountId], created on first use.
  AccountCookieJar jarFor(AccountId accountId) =>
      _jars.putIfAbsent(accountId, () => AccountCookieJar(accountId));

  /// The jar for [accountId] if one exists, without creating it.
  AccountCookieJar? existingJar(AccountId accountId) => _jars[accountId];

  void remove(AccountId accountId) => _jars.remove(accountId);

  void clear() => _jars.clear();

  int get jarCount => _jars.length;
}

/// Parses an HTTP date (`Sun, 18 Oct 2026 18:08:43 GMT`).
///
/// Returns null when the date cannot be parsed, which makes the cookie
/// non-expiring rather than immediately stale — the safe default, since
/// wrongly expiring a live session cookie logs the user out.
DateTime? _parseHttpDate(String value) {
  try {
    final parsed = HttpDateParser.parse(value);
    return parsed;
  } catch (_) {
    return null;
  }
}

/// Minimal HTTP-date parser, avoiding a dependency for one call site.
///
/// Handles the three formats a server may send:
///   * `Sun, 18 Oct 2026 18:08:43 GMT`   (RFC 1123, what the portal sends)
///   * `Sunday, 18-Oct-26 18:08:43 GMT`  (RFC 850)
///   * `Sun Oct 18 18:08:43 2026`        (asctime)
abstract final class HttpDateParser {
  static final RegExp _rfc1123 = RegExp(
    r'^[A-Za-z]{3,9},?\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})\s*(?:GMT|UTC)?$',
  );

  static final RegExp _rfc850 = RegExp(
    r'^[A-Za-z]{3,9},?\s+(\d{1,2})-([A-Za-z]{3})-(\d{2})\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})\s*(?:GMT|UTC)?$',
  );

  static final RegExp _asctime = RegExp(
    r'^[A-Za-z]{3,9}\s+([A-Za-z]{3})\s+(\d{1,2})\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})\s+(\d{4})$',
  );

  static DateTime parse(String value) {
    final text = value.trim();

    final rfc1123 = _rfc1123.firstMatch(text);
    if (rfc1123 != null) {
      return DateTime.utc(
        int.parse(rfc1123.group(3)!),
        _monthFromName(rfc1123.group(2)!),
        int.parse(rfc1123.group(1)!),
        int.parse(rfc1123.group(4)!),
        int.parse(rfc1123.group(5)!),
        int.parse(rfc1123.group(6)!),
      );
    }

    final rfc850 = _rfc850.firstMatch(text);
    if (rfc850 != null) {
      final twoDigitYear = int.parse(rfc850.group(3)!);
      return DateTime.utc(
        // RFC 850's two-digit year: 70-99 is 19xx, 00-69 is 20xx.
        twoDigitYear >= 70 ? 1900 + twoDigitYear : 2000 + twoDigitYear,
        _monthFromName(rfc850.group(2)!),
        int.parse(rfc850.group(1)!),
        int.parse(rfc850.group(4)!),
        int.parse(rfc850.group(5)!),
        int.parse(rfc850.group(6)!),
      );
    }

    final asctime = _asctime.firstMatch(text);
    if (asctime != null) {
      // Groups: 1=month 2=day 3=hour 4=minute 5=second 6=year
      return DateTime.utc(
        int.parse(asctime.group(6)!),
        _monthFromName(asctime.group(1)!),
        int.parse(asctime.group(2)!),
        int.parse(asctime.group(3)!),
        int.parse(asctime.group(4)!),
        int.parse(asctime.group(5)!),
      );
    }

    throw FormatException('unrecognised HTTP date: $value');
  }

  static int _monthFromName(String name) {
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final key = name.substring(0, 3).toLowerCase();
    final month = months[key];
    if (month == null) throw FormatException('unknown month: $name');
    return month;
  }
}
