import 'dart:async';
import 'dart:typed_data';

import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import '../helpers/portal_stubs.dart' as stubs;
import 'package:test/test.dart';

/// An in-memory [SessionStore] standing in for the platform keystore.
class FakeSessionStore implements SessionStore {
  final Map<AccountId, Credentials> credentials = {};
  final Map<AccountId, StoredSession> sessions = {};
  int purgeCount = 0;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      credentials[accountId];

  @override
  Future<void> writeCredentials(
      AccountId accountId, Credentials creds) async {
    credentials[accountId] = creds;
  }

  @override
  Future<StoredSession?> readSession(AccountId accountId) async =>
      sessions[accountId];

  @override
  Future<void> writeSession(StoredSession session) async {
    sessions[session.accountId] = session;
  }

  @override
  Future<void> deleteSession(AccountId accountId) async {
    sessions.remove(accountId);
  }

  @override
  Future<void> purge(AccountId accountId) async {
    purgeCount++;
    credentials.remove(accountId);
    sessions.remove(accountId);
  }
}

/// A solver that always returns a fixed code, and can be made to decline.
class FakeSolver implements ChallengeSolver {
  FakeSolver({this.answer = '1234', this.declines = false});

  String answer;
  bool declines;
  int solveCount = 0;

  @override
  Future<String?> solve(LoginChallenge challenge) async {
    solveCount++;
    return declines ? null : answer;
  }
}

/// A [PortalClient] that records calls and can be scripted to fail.
///
/// ## The challenge is bound to a session
///
/// This fake models what the live portal actually does, because the real one
/// does it and the difference is invisible otherwise:
///
///   * each challenge is issued against a **session id**;
///   * an answer is only accepted when it is posted **in that session**.
///
/// A fake that accepts any answer in any session cannot catch the bug where
/// the student's correct digits are refused, because there is no way for the
/// fake to be wrong. Verified live 2026-10-21: a request between the image
/// and the answer rotates the portal's session, and the answer is then
/// refused — restoring the session id makes it accepted again.
class FakePortalClient extends stubs.FakePortalClient {
  int beginLoginCount = 0;
  int completeLoginCount = 0;
  int logoutCount = 0;

  /// Custom exceptions to throw on [completeLogin] sequentially.
  final List<Exception> completeLoginExceptions = [];

  /// When true, [completeLogin] throws [LoginRejectedException] saying the
  /// **password** was wrong.
  bool rejectCredentials = false;

  /// When true, [completeLogin] throws [LoginRejectedException] saying the
  /// **CAPTCHA** was wrong.
  ///
  /// Distinct from [rejectCredentials] because the two call for different
  /// things from the student: one wants a new password, the other wants the
  /// code typed again. The portal says which, and the app has to believe it.
  bool rejectCaptcha = false;

  /// When true, [beginLogin] throws [PortalUnreachableException].
  bool unreachable = false;

  /// When true, [beginLogin] returns a challenge.
  bool issueChallenge = true;

  /// Delay applied to [completeLogin], for concurrency tests.
  Duration loginDelay = Duration.zero;

  /// The session the outstanding challenge is bound to.
  ///
  /// Null when no challenge is outstanding. A new challenge replaces it,
  /// which is what the portal does — the old one is dead.
  String? _challengeSession;

  /// The session the current account's requests are in.
  ///
  /// Rotated by [rotateSession], the way the portal mints a new
  /// `ASP.NET_SessionId` every time it renders the login page.
  String _currentSession = 'session-1';

  /// The session an answer was posted in, for assertions.
  String? answerPostedInSession;

  /// Simulates the portal rendering the login page: a new session id.
  void rotateSession() => _currentSession = 'session-${_rotateCount++}';
  int _rotateCount = 1;

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    beginLoginCount++;
    if (unreachable) {
      throw const PortalUnreachableException('connection refused');
    }
    if (!issueChallenge) {
      _challengeSession = null;
      return null;
    }
    // The challenge is bound to the session that is current right now.
    _challengeSession = _currentSession;
    return LoginChallenge(
      imageBytes: Uint8List.fromList([1, 2, 3]),
      kind: ChallengeKind.digits4,
      sessionId: _currentSession,
    );
  }

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    completeLoginCount++;
    if (loginDelay > Duration.zero) await Future<void>.delayed(loginDelay);
    if (completeLoginExceptions.isNotEmpty) {
      throw completeLoginExceptions.removeAt(0);
    }
    if (rejectCaptcha) {
      throw const LoginRejectedException('کد امنیتی صحیح نمی باشد');
    }
    if (rejectCredentials) {
      throw const LoginRejectedException('نام کاربری یا گذرواژه اشتباه است');
    }

    if (challenge != null) {
      answerPostedInSession = challenge.sessionId;
      // The portal judges the answer against the session the challenge was
      // issued in. An answer posted in a different session is wrong, however
      // correct the digits are.
      if (_challengeSession != null &&
          challenge.sessionId != _challengeSession) {
        throw const LoginRejectedException('کد امنیتی صحیح نمی باشد');
      }
    }

    return Session(
      account: username,
      cookies: {'ASP.NET_SessionId': 'sid-$username'},
      establishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {
    logoutCount++;
  }

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 18, 18, 0);

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 225000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<List<MealOffering>> fetchOfferings(
          Session session, DateTime date) async =>
      const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      const [];

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async =>
      const BookableMenus(dates: [], menus: []);

  @override
  Future<List<Reservation>> fetchReservations(Session session) async => const [];

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async =>
      null;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      const ClaimRejected('not exercised');

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) =>
      throw UnimplementedError('not exercised');

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Uri? topUpUrl(Session session) => null;
}

SessionManager buildManager({
  required FakePortalClient client,
  required FakeSessionStore store,
  required FakeSolver solver,
  SessionPolicy policy = const SessionPolicy(),
  Future<void> Function(Duration)? sleep,
}) =>
    SessionManager(
      client: client,
      store: store,
      solver: solver,
      clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 18, 0)),
      policy: policy,
      sleep: sleep ?? (_) async {},
    );

void main() {
  late FakePortalClient client;
  late FakeSessionStore store;
  late FakeSolver solver;

  setUp(() {
    client = FakePortalClient();
    store = FakeSessionStore();
    solver = FakeSolver();
  });

  group('first login', () {
    test('logs in when no session is stored', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '400123456', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      final ready = result as SessionReady;
      expect(ready.wasReused, isFalse);
      expect(client.completeLoginCount, 1);
      expect(ready.session.cookies['ASP.NET_SessionId'], 'sid-400123456');
    });

    test('solves the challenge and passes the answer through', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '400123456', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(solver.solveCount, 1);
    });

    test('persists the new session', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '400123456', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(store.sessions.containsKey('a1'), isTrue);
    });

    test('logs in even when the portal issues no challenge', () async {
      client.issueChallenge = false;
      await store.writeCredentials(
          'a1', const Credentials(studentId: '400123456', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      expect(solver.solveCount, 0, reason: 'nothing to solve');
    });
  });

  group('session reuse', () {
    test('reuses a stored session without logging in', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'stored'},
        establishedAt: DateTime.now().toUtc(),
      );

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      expect((result as SessionReady).wasReused, isTrue);
      expect(client.completeLoginCount, 0, reason: 'no login should happen');
      expect((result).session.cookies['ASP.NET_SessionId'], 'stored');
    });

    test('a second call reuses the in-memory session', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.ensureSession('a1');

      expect(client.completeLoginCount, 1, reason: 'only one login');
    });

    test('force bypasses reuse and logs in again', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'stored'},
        establishedAt: DateTime.now().toUtc(),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1', force: true);

      expect((result as SessionReady).wasReused, isFalse);
      expect(client.completeLoginCount, 1);
    });

    test('an aged-out session is not reused', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'old'},
        // Older than the default 12h policy.
        establishedAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionReady).wasReused, isFalse);
      expect(client.completeLoginCount, 1);
    });
  });

  group('failure modes are explicit', () {
    test('no stored credentials -> noCredentials', () async {
      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('missing');

      expect(result, isA<SessionUnavailable>());
      expect((result as SessionUnavailable).cause,
          SessionFailureCause.noCredentials);
      expect(client.completeLoginCount, 0);
    });

    test('rejected password -> badCredentials', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'wrong'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.badCredentials);
    });

    test('SQL Server deadlock automatically retries and succeeds if transient', () async {
      const deadlockMsg =
          'Transaction (Process ID 2879) was deadlocked on lock | communication buffer resources with another process and has been chosen as the deadlock victim. Rerun the transaction.';
      client.completeLoginExceptions.add(const LoginRejectedException(deadlockMsg));

      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      expect(client.completeLoginCount, 2, reason: 'retried once and succeeded');
    });

    test('SQL Server deadlock reports serverError (not bad credentials) when retries exhausted', () async {
      const deadlockMsg =
          'Transaction (Process ID 2879) was deadlocked on lock | communication buffer resources with another process and has been chosen as the deadlock victim. Rerun the transaction.';
      client.completeLoginExceptions.addAll([
        const LoginRejectedException(deadlockMsg),
        const LoginRejectedException(deadlockMsg),
        const LoginRejectedException(deadlockMsg),
      ]);

      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionUnavailable>());
      final unavail = result as SessionUnavailable;
      expect(unavail.cause, SessionFailureCause.serverError);
      expect(unavail.reason, contains('Deadlock'));
      expect(unavail.reason, isNot(contains('نام کاربری یا گذرواژه پذیرفته نشد')));
      expect(client.completeLoginCount, 3, reason: 'initial attempt plus 2 retries');
    });

    test('a rejected CAPTCHA is not reported as a wrong password', () async {
      // The portal says which, and the two call for different things from
      // the student: one wants a new password, the other wants the code
      // typed again. Reporting a wrong code as a wrong password sends the
      // student to change a password that was never the problem.
      client.rejectCaptcha = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.wrongCaptcha);
    });

    test('solver declining -> the challenge comes back for the student', () async {
      // The solver cannot read the code. That is not a dead end — the
      // student can — so the **image** travels with the failure.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionNeedsCaptcha>());
      final challenge = result as SessionNeedsCaptcha;
      expect(challenge.imageBytes, isNotEmpty,
          reason: 'the image is what the student has to read');
      expect(challenge.accountId, 'a1');
      expect(client.completeLoginCount, 0,
          reason: 'must not submit without an answer');
    });

    test('unreachable portal -> networkError', () async {
      client.unreachable = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.networkError);
    });

    test('a typed answer logs in, without consulting the solver', () async {
      // The student read the code; the solver's opinion is what got us here,
      // so it is not asked.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      // The solver declines, so the student is asked.
      final asked = await manager.ensureSession('a1');
      expect(asked, isA<SessionNeedsCaptcha>());

      final result = await manager.loginWithCaptcha('a1', '9876');

      expect(result, isA<SessionReady>());
      expect(solver.solveCount, 1,
          reason: 'the solver is not consulted for a typed answer');
    });

    test('a typed answer is posted against the challenge the student read',
        () async {
      // The portal judges the answer against the session the image was
      // fetched in, and a **new** challenge would rotate that session and
      // replace the challenge — so the digits the student read would be
      // judged against a challenge that is not theirs. This is the bug: every
      // correct answer was refused.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      final beginLoginsBefore = client.beginLoginCount;

      final result = await manager.loginWithCaptcha('a1', '9876');

      expect(result, isA<SessionReady>());
      expect(client.beginLoginCount, beginLoginsBefore,
          reason: 'the challenge must not be fetched again — a new fetch '
              'rotates the session and replaces the challenge');
      expect(client.answerPostedInSession, 'session-1',
          reason: 'the answer is posted in the session the image came from');
    });

    test("a correct answer survives a read that happens meanwhile", () async {
      // The app reads the portal on its own — a hunt's pre-flight, a
      // reminder's digest — and the student may be reading the code at that
      // moment. The portal mints a new session whenever it renders the login
      // page, so the read would otherwise leave the answer judged against a
      // session that no longer holds the challenge.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      // Something else reads the portal, and the session moves.
      client.rotateSession();

      final result = await manager.loginWithCaptcha('a1', '9876');

      expect(result, isA<SessionReady>());
      expect(client.answerPostedInSession, 'session-1',
          reason: 'the answer goes back to the session it was read in');
    });

    test('a typed answer with no challenge outstanding asks again', () async {
      // The student typed digits for an image the app no longer holds — the
      // app restarted, say. The digits cannot be judged against a challenge
      // that is gone, and blaming them for a wrong code would be the app's
      // bookkeeping being reported as the student's mistake.
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.loginWithCaptcha('a1', '9876');

      expect(result, isA<SessionNeedsCaptcha>());
      expect(client.completeLoginCount, 0,
          reason: 'there is no challenge to answer, so nothing is posted');
    });

    test('a read that needs a session carries the challenge out', () async {
      // The student must be asked, so the challenge has to travel with the
      // failure. A blind cast to `SessionUnavailable` throws a **type error**
      // instead, and the student sees an English Dart error rather than the
      // CAPTCHA dialog. This was thrown on the device and by no test.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      await expectLater(
        manager.withSession('a1', (session) async => 'read'),
        throwsA(
          isA<SessionUnavailableException>()
              .having((e) => e.needsCaptcha, 'needsCaptcha', isNotNull),
        ),
        reason: 'the challenge must reach the UI, not a type error',
      );
    });

    test('a bounced read that needs a session carries the challenge out',
        () async {
      // The retry path — a session the portal rejected, then a fresh login
      // that needs the student — must carry the challenge too. It is a
      // different code path from the first attempt, and it was the one that
      // threw a type error on the device.
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      // The session is established, and the read is refused: the portal
      // expired it. The solver declines from here on, so the retry needs the
      // student.
      await expectLater(
        manager.withSession('a1', (session) async {
          solver.declines = true;
          throw const LoginRejectedException('نشست منقضی شده است.');
        }),
        throwsA(
          isA<SessionUnavailableException>()
              .having((e) => e.needsCaptcha, 'needsCaptcha', isNotNull),
        ),
        reason: 'the challenge must reach the UI on the retry path too, not '
            'a type error',
      );
    });

    test('a top-up that needs a session carries the challenge out', () async {
      // The top-up's cookies come from a session too, so this is a third
      // site where a blind cast would throw a type error instead of asking
      // the student.
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      await expectLater(
        manager.cookiesFor('a1'),
        throwsA(
          isA<SessionUnavailableException>()
              .having((e) => e.needsCaptcha, 'needsCaptcha', isNotNull),
        ),
        reason: 'the challenge must reach the UI here too, not a type error',
      );
    });

    test('a refused typed answer brings a fresh challenge', () async {
      // The portal rotates the challenge when it refuses, so the image the
      // student answered is dead. Showing it again would invite the same
      // wrong answer.
      solver.declines = true;
      client.rejectCaptcha = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      final result = await manager.loginWithCaptcha('a1', '0000');

      expect(result, isA<SessionNeedsCaptcha>());
      final challenge = result as SessionNeedsCaptcha;
      expect(challenge.previousAttempts, 1,
          reason: 'the UI says the code was refused, and shows a new image');
      expect(challenge.imageBytes, isNotEmpty);
      expect(challenge.sessionId, isNotNull,
          reason: 'the fresh challenge names the session it is bound to');
    });

    test('a typed answer with no credentials -> noCredentials', () async {
      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.loginWithCaptcha('a1', '1234');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.noCredentials);
    });

    test('a failure never leaves a stale session cached', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'bad'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(manager.sessionFor('a1'), isNull);
    });
  });

  group('concurrency: logins are serialised per account', () {
    test('two concurrent calls produce exactly one login', () async {
      client.loginDelay = const Duration(milliseconds: 50);
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      final results = await Future.wait([
        manager.ensureSession('a1'),
        manager.ensureSession('a1'),
      ]);

      expect(results.every((r) => r is SessionReady), isTrue);
      // The first call logs in and caches; the second, queued behind it, finds
      // the fresh session and reuses it.
      expect(client.completeLoginCount, 1,
          reason: 'serialised calls must not both log in');
    });

    test('different accounts authenticate independently', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'one', password: 'pw'));
      await store.writeCredentials(
          'a2', const Credentials(studentId: 'two', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await Future.wait([
        manager.ensureSession('a1'),
        manager.ensureSession('a2'),
      ]);

      expect(client.completeLoginCount, 2);
      expect(manager.sessionFor('a1')!.cookies['ASP.NET_SessionId'], 'sid-one');
      expect(manager.sessionFor('a2')!.cookies['ASP.NET_SessionId'], 'sid-two');
    });

    test('a failing call does not block the next one', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'bad'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final first = await manager.ensureSession('a1');
      expect(first, isA<SessionUnavailable>());

      // Fix the credentials; the next attempt must actually run.
      client.rejectCredentials = false;
      final second = await manager.ensureSession('a1');
      expect(second, isA<SessionReady>());
      expect(client.completeLoginCount, 2);
    });
  });

  group('invalidate and forget', () {
    test('invalidate clears memory and storage so the next call logs in', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.invalidate('a1');

      expect(manager.sessionFor('a1'), isNull);
      expect(store.sessions.containsKey('a1'), isFalse);

      await manager.ensureSession('a1');
      expect(client.completeLoginCount, 2);
    });

    test('forget logs out and purges credentials', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.forget('a1');

      expect(client.logoutCount, 1);
      expect(store.purgeCount, 1);
      expect(store.credentials.containsKey('a1'), isFalse);
      expect(store.sessions.containsKey('a1'), isFalse);
      expect(manager.sessionFor('a1'), isNull);
    });

    test('forget succeeds even when the portal logout fails', () async {
      final throwing = _ThrowingLogoutClient();
      final manager = SessionManager(
        client: throwing,
        store: store,
        solver: solver,
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 18)),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));
      await store.writeSession(StoredSession(
        accountId: 'a1',
        cookies: const {'a': 'b'},
        establishedAt: DateTime.now().toUtc(),
      ));

      // Should not throw: the user asked for the account to be gone.
      await manager.forget('a1');
      expect(store.purgeCount, 1);
    });
  });

  group('clock trustworthiness', () {
    test('a synced clock within the staleness limit is trustworthy', () {
      final manager = buildManager(client: client, store: store, solver: solver);
      expect(manager.isClockTrustworthy, isTrue);
    });

    test('an unsynced clock is not trustworthy', () {
      final manager = SessionManager(
        client: client,
        store: store,
        solver: solver,
        clock: _UnsyncedClock(),
      );
      expect(manager.isClockTrustworthy, isFalse);
    });
  });

  group('Credentials redaction', () {
    test('toString never exposes the password', () {
      const creds = Credentials(studentId: '400123456', password: 'sekrit');
      expect(creds.toString(), isNot(contains('sekrit')));
      expect(creds.toString(), contains('400123456'));
    });
  });
}

class _ThrowingLogoutClient extends FakePortalClient {
  @override
  Future<void> logout(Session session) async {
    throw const PortalUnreachableException('timeout');
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const <Transaction>[];
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}