import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';

import '../../helpers/portal_stubs.dart' show FakePortalClient;

import 'package:test/test.dart';

/// An in-memory [SessionStore].
class FakeStore implements SessionStore {
  FakeStore({this.credentials = true});

  final Map<AccountId, Credentials> stored = {
    'a1': const Credentials(studentId: '400123456', password: 'pw'),
  };

  /// Whether the account has stored credentials at all.
  bool credentials;

  int logins = 0;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      credentials ? stored[accountId] : null;

  @override
  Future<void> writeCredentials(AccountId accountId, Credentials creds) async {
    stored[accountId] = creds;
  }

  @override
  Future<StoredSession?> readSession(AccountId accountId) async => null;

  @override
  Future<void> writeSession(StoredSession session) async {}

  @override
  Future<void> deleteSession(AccountId accountId) async {}

  @override
  Future<void> purge(AccountId accountId) async {}
}

/// A client whose session expires after a scripted number of reads.
class ExpiringClient extends FakePortalClient {
  /// The number of reads before the session is treated as expired.
  int readsBeforeExpiry;

  ExpiringClient({this.readsBeforeExpiry = 1});

  int reads = 0;
  int logins = 0;

  /// The cookies the current session carries. A fresh login changes them.
  String sessionCookie = 'old';

  @override
  Future<Balance> fetchBalance(Session session) async {
    reads++;
    if (reads > readsBeforeExpiry) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    return Balance(amountRial: 225000, fetchedAt: DateTime.now().toUtc());
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    reads++;
    if (reads > readsBeforeExpiry) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    return const [];
  }

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    logins++;
    sessionCookie = 'new-$logins';
    return Session(
      account: username,
      cookies: {'ASP.NET_SessionId': sessionCookie},
      establishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.now().toUtc();

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async => const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      const [];

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async => const BookableMenus(dates: [], menus: []);

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async => null;

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError();

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Uri? topUpUrl(Session session) => null;
}

class NoopSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => '1234';
}

void main() {
  group('an expired session is renewed, not reported as a failure', () {
    test(
      'a read that hits the login page is retried with a fresh login',
      () async {
        final client = ExpiringClient(readsBeforeExpiry: 1);
        final manager = SessionManager(
          client: client,
          store: FakeStore(),
          solver: NoopSolver(),
          clock: FixedServerClock.now(DateTime.now().toUtc()),
        );

        // The first read succeeds; the second finds the session expired.
        final balance = await manager.withSession(
          'a1',
          (session) => client.fetchBalance(session),
        );

        expect(balance.amountRial, 225000);
        expect(
          client.logins,
          greaterThanOrEqualTo(1),
          reason: 'the expired session must be replaced by a real login',
        );
      },
    );

    test('a second bounce is reported, not retried forever', () async {
      // Every read fails, so the retry also fails. The caller must be told.
      final client = ExpiringClient(readsBeforeExpiry: 0);
      final manager = SessionManager(
        client: client,
        store: FakeStore(),
        solver: NoopSolver(),
        clock: FixedServerClock.now(DateTime.now().toUtc()),
      );

      await expectLater(
        manager.withSession('a1', (session) => client.fetchBalance(session)),
        throwsA(isA<LoginRejectedException>()),
      );
    });

    test(
      'no credentials means no session, and the reason is reported',
      () async {
        final client = ExpiringClient(readsBeforeExpiry: 100);
        final manager = SessionManager(
          client: client,
          store: FakeStore(credentials: false),
          solver: NoopSolver(),
          clock: FixedServerClock.now(DateTime.now().toUtc()),
        );

        await expectLater(
          manager.withSession('a1', (session) => client.fetchBalance(session)),
          throwsA(
            isA<SessionUnavailableException>().having(
              (e) => e.reason,
              'reason',
              contains('ذخیره نشده'),
            ),
          ),
        );
      },
    );

    test('the read is attempted once when the session is fresh', () async {
      final client = ExpiringClient(readsBeforeExpiry: 100);
      final manager = SessionManager(
        client: client,
        store: FakeStore(),
        solver: NoopSolver(),
        clock: FixedServerClock.now(DateTime.now().toUtc()),
      );

      await manager.withSession(
        'a1',
        (session) => client.fetchBalance(session),
      );

      expect(client.reads, 1);
      expect(client.logins, 1);
    });
  });
}
