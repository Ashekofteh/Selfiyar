/// Session management: keeping N accounts authenticated with no user effort.
///
/// The portal binds its CAPTCHA answer to the **session** the image was fetched
/// in, and it mints a new session every time it renders the login page. So a
/// challenge carries the session it belongs to, and an answer is posted back
/// in that session — which is what makes the student's reading time safe.
///
/// That constraint is also why [SessionManager] serialises authentication per
/// account rather than firing logins concurrently.
///
/// The design intent: the common case is that a stored session still works, and
/// the user never notices anything. Re-authentication is the exception, and when
/// it happens it should be invisible — the CAPTCHA solver reads the code in
/// milliseconds without involving anyone.
library;

import 'dart:typed_data';

import 'models.dart';
import 'portal.dart';

/// Credentials for one account.
///
/// Held only in memory for the duration of a login, and at rest inside the
/// platform keystore. Never logged, never serialised to plain storage.
class Credentials {
  const Credentials({required this.studentId, required this.password});

  final String studentId;
  final String password;

  /// Deliberately omits the password so an accidental log or `print` leaks
  /// nothing. Do not "improve" this to include it.
  @override
  String toString() => 'Credentials(studentId: $studentId, password: <redacted>)';
}

/// A stored account plus its session, as persisted between runs.
class StoredSession {
  const StoredSession({
    required this.accountId,
    required this.cookies,
    required this.establishedAt,
  });

  final AccountId accountId;
  final Map<String, String> cookies;
  final DateTime establishedAt;

  Session toSession() => Session(
        account: accountId,
        cookies: cookies,
        establishedAt: establishedAt,
      );

  static StoredSession fromSession(AccountId accountId, Session session) =>
      StoredSession(
        accountId: accountId,
        cookies: session.cookies,
        establishedAt: session.establishedAt,
      );
}

/// Persistence for credentials and sessions.
///
/// Implementations MUST encrypt at rest (Android Keystore / Windows DPAPI).
/// Nothing in this interface may write plaintext credentials to disk.
abstract class SessionStore {
  Future<Credentials?> readCredentials(AccountId accountId);
  Future<void> writeCredentials(AccountId accountId, Credentials credentials);

  Future<StoredSession?> readSession(AccountId accountId);
  Future<void> writeSession(StoredSession session);
  Future<void> deleteSession(AccountId accountId);

  /// Removes everything for an account, credentials included. Used when the
  /// user deletes an account, which must be complete and irreversible.
  Future<void> purge(AccountId accountId);
}

/// Solves a login challenge. Implemented by the on-device CAPTCHA solver.
///
/// Returns null when it declines to guess — which callers must treat as "ask the
/// user", never as "try anyway".
abstract class ChallengeSolver {
  Future<String?> solve(LoginChallenge challenge);
}

/// Outcome of ensuring an account is authenticated.
sealed class SessionResult {
  const SessionResult();
}

/// The account has a usable session, whether reused or freshly obtained.
class SessionReady extends SessionResult {
  const SessionReady({required this.session, required this.wasReused});

  final Session session;

  /// True when the stored session still worked and no login was needed.
  final bool wasReused;
}

/// The account could not be authenticated, and the user must act.
class SessionUnavailable extends SessionResult {
  const SessionUnavailable({required this.reason, required this.cause});

  final String reason;
  final SessionFailureCause cause;
}

/// The login needs the student to read the CAPTCHA themselves.
///
/// ## Why this exists
///
/// The on-device solver reads the CAPTCHA. When it cannot — the portal
/// changed the image, or the digits are ambiguous — the only honest outcome
/// is to **ask the student**, not to fail.
///
/// A failure here is not a cosmetic one. The login is what every read and
/// every write depends on, and the app's whole purpose is to replace the web
/// portal. A student who cannot log in cannot use the app at all.
///
/// ## Why the image travels with the result
///
/// The solver is not the only reader of the CAPTCHA. When it declines, the
/// **image** is what the student needs — and the image is bound to the
/// session at fetch time, so the exact bytes that were fetched are the ones
/// the answer will be judged against. Throwing them away and re-fetching
/// would fetch a *different* challenge, and the typed answer would be
/// rejected for no reason.
///
/// So the image comes with the failure, and the student answers the
/// challenge that is actually live.
///
/// ## Why the session id travels with it too
///
/// The portal mints a new `ASP.NET_SessionId` every time it renders the
/// login page, and the CAPTCHA endpoint sets no cookie of its own. So the
/// challenge lives in the session that was current when the image was
/// fetched, and **any** other request in between replaces that session and
/// makes a correct answer wrong. Verified live 2026-10-21.
///
/// So the session id comes with the failure as well, and the answer is
/// posted back in the session the student actually read.
class SessionNeedsCaptcha extends SessionResult {
  const SessionNeedsCaptcha({
    required this.imageBytes,
    required this.accountId,
    this.sessionId,
    this.previousAttempts = 0,
  });

  /// The CAPTCHA image, as fetched.
  final Uint8List imageBytes;

  /// The account the challenge belongs to.
  final AccountId accountId;

  /// The session the challenge is bound to.
  ///
  /// The answer has to be posted in this session, or the portal judges it
  /// against a session that no longer holds the challenge. Null when the
  /// portal issued no session id.
  final String? sessionId;

  /// How many times the automatic answer has been tried and refused.
  ///
  /// Carried so the UI can say "the code was wrong" rather than showing the
  /// image as if nothing had happened, and so a challenge that keeps being
  /// refused can be re-fetched rather than retried forever.
  final int previousAttempts;
}

enum SessionFailureCause {
  /// No credentials stored for this account.
  noCredentials,

  /// The portal rejected the username or password.
  badCredentials,

  /// The CAPTCHA solver declined and no human was available to help.
  challengeUnsolvable,

  /// The portal rejected the CAPTCHA the app typed.
  ///
  /// Distinct from [badCredentials] because the fix is different: the
  /// student types the code again, and the password may be perfectly fine.
  /// Reporting a wrong CAPTCHA as a wrong password sends the student to
  /// change a password that was never the problem.
  wrongCaptcha,

  /// The portal was unreachable or returned an unexpected response.
  networkError,

  /// The portal's clock could not be read, so trustworthiness is unknown.
  clockUnsynced,

  /// The portal server or database failed (e.g. SQL Server deadlock or transient error).
  serverError,
}

/// Why a session had to be re-established, for diagnostics.
enum ReauthReason {
  /// No stored session at all.
  firstLogin,

  /// The portal rejected the stored cookies.
  sessionExpired,

  /// A read failed in a way that suggests the session is stale.
  readFailed,

  /// The session was older than the configured maximum age.
  agedOut,
}

/// Result of a lightweight session check.
class SessionCheck {
  const SessionCheck({required this.valid, this.reason});

  final bool valid;
  final String? reason;

  static const ok = SessionCheck(valid: true);
  factory SessionCheck.invalid(String reason) =>
      SessionCheck(valid: false, reason: reason);
}