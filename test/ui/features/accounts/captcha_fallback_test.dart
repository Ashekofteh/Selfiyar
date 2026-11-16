import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/shell/home_shell.dart';
import 'package:bahonar_nut/ui/features/accounts/captcha_dialog.dart';
import '../../../helpers/memory_stores.dart';
import '../../../helpers/portal_stubs.dart' show FakePortalClient;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The CAPTCHA fallback, at the level the student sees it.
///
/// ## Why this is a widget test
///
/// The defect was a **wiring** one, and it was invisible to the domain
/// tests: the session manager posted the student's digits against a challenge
/// it had fetched itself, so every correct answer was refused by the portal.
///
/// The chain that has to work is: the solver declines → the student is asked →
/// the digits they type reach the portal **in the session the image came
/// from** → the login succeeds → the dashboard shows the account.
///
/// The session is the part that matters. The portal judges the answer against
/// the session the image was fetched in, and it mints a new session whenever
/// it renders the login page, so an answer posted in the wrong session is
/// refused however correct the digits are. Verified live 2026-10-21 (F77).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  late _CaptchaPortalClient portal;
  late AppState state;
  late AppServices services;

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  Future<void> pumpShell(WidgetTester tester) async {
    portal = _CaptchaPortalClient();

    services = AppServices(
      bridge: PlatformBridge(channel: channel),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.upsertAccount(studentId: '400123456');
    await state.load();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the accounts tab and reads the portal.
  ///
  /// Not `pumpAndSettle`: the CAPTCHA dialog stays open waiting for the
  /// student, and a settled pump would wait for an animation that never
  /// finishes — the dialog is not going anywhere until someone types.
  Future<void> refreshFromPortal(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('حساب‌ها'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the student is asked, and the digits they type log in',
      (tester) async {
    await pumpShell(tester);

    // The solver declined, so the app asks.
    await refreshFromPortal(tester);

    expect(find.byType(CaptchaDialog), findsOneWidget,
        reason: 'the student must be asked, not left with a dead end');
    expect(find.text('کد امنیتی'), findsOneWidget);

    // The student reads the code and types it.
    await tester.enterText(find.byType(TextField), portal.issuedAnswer);
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(portal.answerPostedInSession, portal.issuedSession,
        reason: 'the answer must be posted in the session the image came '
            'from — the portal judges it against that session');
    expect(portal.answerPosted, portal.issuedAnswer,
        reason: 'the digits the student typed are the ones posted');
    expect(find.byType(CaptchaDialog), findsNothing,
        reason: 'the dialog closes once the answer is accepted');
  });

  testWidgets('a correct answer is accepted, and the account is read',
      (tester) async {
    await pumpShell(tester);
    await refreshFromPortal(tester);

    await tester.enterText(find.byType(TextField), portal.issuedAnswer);
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(portal.answerAccepted, isTrue,
        reason: 'the portal accepted the answer the student typed');
    expect(
      state.balanceFor(state.accounts.first.id),
      isNotNull,
      reason: 'the account was read after the login, so the dashboard has '
          'a balance to show',
    );
  });

  testWidgets('the answer survives a read that happens while the student '
      'is reading', (tester) async {
    await pumpShell(tester);
    await refreshFromPortal(tester);

    expect(find.byType(CaptchaDialog), findsOneWidget);

    // Something else reads the portal while the student is reading — a
    // hunt's pre-flight, a reminder's digest. The portal mints a new session
    // whenever it renders the login page, so the session has moved.
    portal.rotateSession();

    await tester.enterText(find.byType(TextField), portal.issuedAnswer);
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(portal.answerPostedInSession, portal.issuedSession,
        reason: 'the answer goes back to the session the image came from, '
            'however much happened in between');
    expect(portal.answerAccepted, isTrue,
        reason: 'an interleaved read must not spoil a correct answer');
  });

  testWidgets('a refused answer reports the refusal, not the first error',
      (tester) async {
    // Found on the device: the student typed a correct code, the portal
    // refused it, and the account card said «کد امنیتی به‌صورت خودکار
    // خوانده نشد.» — the *first* sync's error, which blames the app's own
    // reader for something that happened after the student did their part.
    //
    // The real reason was thrown away, so the student was told nothing they
    // could act on.
    await pumpShell(tester);
    portal.refuseWith = 'نام کاربری یا گذرواژه اشتباه است';

    await refreshFromPortal(tester);
    expect(find.byType(CaptchaDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), portal.issuedAnswer);
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('گذرواژه اشتباه است'),
      findsOneWidget,
      reason: 'the reason the portal gave is the one the student can act on',
    );
    expect(
      find.textContaining('به‌صورت خودکار خوانده نشد'),
      findsNothing,
      reason: 'the stale first error must not be reported after the student '
          'has answered — it describes a step they have already passed',
    );
  });

  testWidgets('a read that is bounced after the answer asks the student '
      'again', (tester) async {
    // The login succeeds, and then the read that follows is bounced — the
    // portal replaced the session while the student was reading. The retry
    // needs a fresh CAPTCHA, and the student has to be asked for it.
    //
    // Before the fix the app showed the first error and left the account
    // unread, so the student was never asked a second time.
    await pumpShell(tester);
    portal.bounceTheReadAfterLogin = true;

    // The count is taken as a **delta**: the launch does a quiet balance read
    // of its own (see HomeShell._refreshBalancesQuietly), and that read can
    // issue a challenge of its own. What this test is about is the *refresh*
    // the student asked for, so only its challenges are counted.
    final before = portal.challengesIssued;

    await refreshFromPortal(tester);
    expect(find.byType(CaptchaDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), portal.issuedAnswer);
    await tester.tap(find.text('ادامه'));
    // Not `pumpAndSettle`: the second dialog stays open waiting for the
    // student, and a settled pump would wait for an animation that never
    // finishes.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(portal.challengesIssued - before, 2,
        reason: 'the bounced read needs a fresh code, so the student is '
            'asked again rather than left with a dead end');
    expect(find.byType(CaptchaDialog), findsWidgets,
        reason: 'the second question is on screen');

    // The student answers it, and the account is finally read.
    //
    // The **last** field: the first dialog is still on its way out, so two
    // fields are in the tree, and the live one is the newer.
    await tester.enterText(find.byType(TextField).last, portal.issuedAnswer);
    await tester.tap(find.text('ادامه').last);
    await tester.pumpAndSettle();

    expect(
      state.balanceFor(state.accounts.first.id),
      isNotNull,
      reason: 'the account is read once the student has answered the '
          'second code',
    );
  });
}

/// A portal that issues a challenge bound to a session, and judges the answer
/// against that session — the way the live one does.
class _CaptchaPortalClient extends FakePortalClient {
  /// The session the outstanding challenge is bound to.
  String _currentSession = 'session-1';
  int _rotateCount = 1;

  /// The session the outstanding challenge was issued in.
  String? issuedSession;

  /// The answer the portal expects.
  String issuedAnswer = '4321';

  /// The answer that was posted, and the session it was posted in.
  String? answerPosted;
  String? answerPostedInSession;

  /// Whether the portal accepted the answer.
  bool answerAccepted = false;

  /// How many challenges the portal has issued.
  int challengesIssued = 0;

  /// The reason the portal refuses the answer, when it should refuse.
  ///
  /// Null means the answer is accepted. A reason that does **not** name the
  /// CAPTCHA is the case that matters: the app then treats it as a
  /// credential failure rather than a code the student got wrong.
  String? refuseWith;

  /// Whether the read that follows a successful login is bounced.
  ///
  /// The portal answers an expired session with the login page, and the app
  /// retries with a fresh login — which needs a CAPTCHA the student has not
  /// been asked for yet.
  bool bounceTheReadAfterLogin = false;

  void rotateSession() {
    _currentSession = 'session-${++_rotateCount}';
  }

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    challengesIssued++;
    issuedSession = _currentSession;
    // The answer is derived from the session, so a wrong session cannot be
    // matched by accident.
    issuedAnswer = '4321';
    return LoginChallenge(
      imageBytes: Uint8List.fromList([1, 2, 3, 4]),
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
    answerPosted = challenge?.answer;
    answerPostedInSession = challenge?.sessionId;

    if (refuseWith != null) {
      throw LoginRejectedException(refuseWith!);
    }

    // The portal judges the answer against the session the challenge was
    // issued in. An answer posted in another session is refused, however
    // correct the digits are.
    if (challenge != null && challenge.sessionId != issuedSession) {
      throw const LoginRejectedException('کد امنیتی صحیح نمی باشد');
    }
    if (challenge != null && challenge.answer != issuedAnswer) {
      throw const LoginRejectedException('کد امنیتی صحیح نمی باشد');
    }

    answerAccepted = true;
    return Session(
      account: username,
      cookies: const {},
      establishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    if (bounceTheReadAfterLogin && answerAccepted) {
      // The portal bounced the session, so the read has to be retried with
      // a fresh login. That login needs a CAPTCHA.
      bounceTheReadAfterLogin = false;
      answerAccepted = false;
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    return Balance(
      amountRial: 500000,
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.now().toUtc();
}
