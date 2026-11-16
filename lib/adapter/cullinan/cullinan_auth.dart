/// Login, CAPTCHA and session handling for the Cullinan portal.
///
/// The portal binds a CAPTCHA answer to the **session** the image was fetched
/// in, so the viewstate and the session id captured with the challenge must be
/// the ones submitted with the answer. Keeping them together per account is
/// what makes the login sequence atomic.
library;

import '../../core/auth/session_manager.dart'
    show LoginRejectedException, PortalUnreachableException;
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../transport/html_parsing.dart';
import 'cullinan_forms.dart';

/// The auth area of the portal: login, refresh, logout, and server time.
class CullinanAuth extends CullinanArea {
  CullinanAuth({required super.transport, required super.clock});

  /// The pending login state, keyed by account.
  final Map<AccountId, _PendingLogin> _pendingLogins = {};

  Future<LoginChallenge?> beginLogin(String username) async {
    final accountId = username;
    final response = await transport.get(accountId, CullinanPaths.login);

    // The challenge must be fetched in the same session, immediately before the
    // POST: the session holds one challenge, so a second fetch would replace
    // the one the student is about to read.
    final captchaBytes = await transport.getBytes(
      accountId,
      CullinanPaths.captcha,
    );

    // The session id the challenge is bound to.
    //
    // The portal mints a new `ASP.NET_SessionId` every time it renders the
    // login page, and the CAPTCHA endpoint sets no cookie of its own — so the
    // challenge lives in the session that was current when the image was
    // fetched. Any other request in between replaces that session, and the
    // portal then refuses a correct answer. Verified live 2026-10-21.
    final sessionId = transport.jars
        .jarFor(accountId)
        .cookies['ASP.NET_SessionId'];

    _pendingLogins[accountId] = _PendingLogin(
      viewState: hiddenFieldValue(response.body, '__VIEWSTATE'),
      viewStateGenerator: hiddenFieldValue(
        response.body,
        '__VIEWSTATEGENERATOR',
      ),
      sessionId: sessionId,
    );

    return LoginChallenge(
      imageBytes: captchaBytes,
      kind: ChallengeKind.digits4,
      sessionId: sessionId,
    );
  }

  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    final accountId = username;
    final pending = _pendingLogins.remove(accountId);

    // The answer must be posted in the session that holds the challenge.
    //
    // The student may have taken minutes to read four digits, and the app may
    // have read the portal in the meantime — and a read of the login page
    // replaces the session the challenge lives in. So the session the answer
    // names is restored before the POST, and the answer is judged against the
    // challenge the student actually read.
    final sessionId = challenge?.sessionId ?? pending?.sessionId;
    if (sessionId != null) {
      transport.jars
          .jarFor(accountId)
          .setCookie('ASP.NET_SessionId=$sessionId');
    }

    final body = <String, String>{
      // The viewstate must accompany the answer: it is what ties the POST to
      // the page and session the challenge was issued against.
      '__VIEWSTATE': pending?.viewState ?? '',
      '__VIEWSTATEGENERATOR': pending?.viewStateGenerator ?? '',
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'txtUsername': username,
      'txtPassword': password,
      'btnLogin': 'ورود سمت سرور ',
    };
    if (challenge != null) body['txtCaptcha'] = challenge.answer;

    final response = await transport.post(
      accountId,
      CullinanPaths.login,
      body: body,
    );

    // A failed login re-renders the login page with an error label. A
    // successful login ends up on the reservation hub, because the transport
    // follows the portal's 302.
    final error = labelText(response.body, 'lblLoginError');
    if (response.looksLikeLoginPage || error != null) {
      throw LoginRejectedException(error ?? 'ورود ناموفق بود.');
    }

    final jar = transport.jars.jarFor(accountId);
    return Session(
      account: accountId,
      cookies: jar.cookies,
      establishedAt: now,
    );
  }

  Future<Session> refresh(Session session) async {
    // A session refresh is a cheap authenticated GET: if the portal still
    // recognises the cookies it serves the page, and if not it bounces to the
    // login form.
    applySession(session);
    final response = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    final jar = transport.jars.jarFor(session.account);
    return Session(
      account: session.account,
      cookies: jar.cookies,
      establishedAt: session.establishedAt,
    );
  }

  Future<void> logout(Session session) async {
    // The portal exposes logout as a postback to a `ctl00$logout` event target.
    final page = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    await transport.post(
      session.account,
      CullinanPaths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(page.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          page.body,
          '__VIEWSTATEGENERATOR',
        ),
        '__EVENTTARGET': 'ctl00\$logout',
        '__EVENTARGUMENT': '',
      },
    );
    transport.jars.remove(session.account);
  }

  Future<DateTime> fetchServerTime(Session session) async {
    applySession(session);
    // The `Date` header is authoritative and needs no page of its own.
    final response = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    final serverDate = response.serverDateUtc;
    if (serverDate == null) {
      throw const PortalUnreachableException('سرور زمان را برنگرداند.');
    }
    return serverDate;
  }
}

/// The state captured between fetching a challenge and answering it.
class _PendingLogin {
  const _PendingLogin({
    required this.viewState,
    required this.viewStateGenerator,
    this.sessionId,
  });

  final String viewState;
  final String viewStateGenerator;

  /// The session the challenge was fetched in.
  ///
  /// The challenge lives in this session, so the answer has to be posted in
  /// it — even if something else has read the login page since.
  final String? sessionId;
}
