/// The Cullinan portal adapter: the only code that knows this particular
/// website exists.
///
/// Everything above this file reasons in domain terms (listings, reservations,
/// meals) and everything below it moves bytes. When the university redesigns
/// their site, this file is what breaks — and it is the only thing that should.
///
/// ## What the portal's pages actually look like
///
/// `FoodBasketBuy.aspx` renders one row per (date, meal slot) for a single
/// date, chosen by the `txtDate` filter. Each row carries a `chkReserve`
/// checkbox, a hall dropdown, a **food dropdown holding the purchasable
/// options**, a count dropdown, a price, and a shared `btnSave`.
///
/// The important consequence: **the individual listings live in the food
/// dropdown, not in the grid rows.** A row for lunch carried two options
/// (`62726` and `62729`), each with its own menu item and price. A "listing" is
/// therefore `(date, slot, option id)` — which is why
/// [Listing.compositeListingId] exists.
///
/// `Reservation.aspx` renders three grids (breakfast, lunch, dinner) of seven
/// days each, with a per-grid `btnSaveBreakfast` / `btnSaveLunch` /
/// `btnSaveDinner`.
///
/// The portal is ASP.NET WebForms: every POST must carry `__VIEWSTATE` from the
/// page it came from, and `__EVENTVALIDATION` is absent, so option ids come
/// from the live dropdowns rather than from constants.
library;

import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/portal.dart';
import '../core/persian.dart';
import '../core/session_manager.dart'
    show
        LoginRejectedException,
        PortalUnreachableException,
        ReservationLockedException,
        TopUpRejectedException;
import '../core/top_up.dart';
import '../transport/html_parsing.dart';
import '../transport/http_transport.dart';
import 'cullinan_parser.dart';

/// Portal paths.
class _Paths {
  static const login = '/';
  static const reservation = '/Reservation/Reservation.aspx';
  static const basketBuy = '/FoodBasket/FoodBasketBuy.aspx';
  static const basketSale = '/FoodBasket/FoodBasketSale.aspx';
  static const transactions = '/MyCullinan/MyTransaction.aspx';
  static const captcha = '/UserControls/Captcha.ashx';
  static const topUp = '/ePay/ePay_Payment.aspx';
  static const topUpList = '/MyCullinan/MyePayList.aspx';
  static const forgotReceipt = '/Reservation/ForgotReceipt.aspx';
}

/// The top-up form's control names.
///
/// The ePay page has **no submit button** — the bank logos are image inputs,
/// and an image input posts its own name plus the click coordinates. That is
/// why the bank is part of the *form* rather than a separate parameter.
class _TopUpFields {
  static const amount = r'ctl00$cphMain$txtPaymentAmount';

  /// The bank logo for the bank at [index] in the page's list.
  ///
  /// The index is **zero-padded to two digits**, as ASP.NET writes it:
  /// `ctl00` for the first bank, `ctl01` for the second. An unpadded index
  /// names a control the page does not have, and the post would be answered
  /// as if no bank had been chosen.
  static String bankLogo(int index) {
    final padded = index.toString().padLeft(2, '0');
    return r'ctl00$cphMain$dataLstBank$ctl' '$padded' r'$imgBankLogo';
  }

  /// The confirmation page's pay button.
  static const pay = r'ctl00$cphMain$btnPay';
}

/// The weekly menu's "next week" postback target.
///
/// The weekly menu is one page per week, and this is how the portal moves to
/// the next one. It is a navigation, not a write.
/// (The portal page also carries `ctl00$cphMain$imgbtnLastWeek` and
/// `ctl00$cphMain$imgbtnCurrentWeek`).
const _eventTargetNextWeek = r'ctl00$cphMain$imgbtnNextWeek';


/// What a read-back page says about a meal.
enum _ReadbackState {
  /// The page carries the meal, and it is still held.
  stillHeld,

  /// The page carries the meal, and it is no longer held.
  gone,

  /// The page does not carry the meal's date, so it says nothing about it.
  notOnPage,
}

/// The Cullinan implementation of [PortalClient].
class CullinanPortalClient implements PortalClient {
  CullinanPortalClient({
    required this.transport,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final PortalTransport transport;
  final DateTime Function() _now;

  /// The pending login state, keyed by account.
  ///
  /// The portal binds a CAPTCHA answer to the **session** the image was
  /// fetched in, so the viewstate and the session id captured with the
  /// challenge must be the ones submitted with the answer. Keeping them
  /// together per account is what makes the login sequence atomic.
  final Map<AccountId, _PendingLogin> _pendingLogins = {};

  // ---------------------------------------------------------------- auth

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    final accountId = username;
    final response = await transport.get(accountId, _Paths.login);

    // The challenge must be fetched in the same session, immediately before the
    // POST: the session holds one challenge, so a second fetch would replace
    // the one the student is about to read.
    final captchaBytes = await transport.getBytes(accountId, _Paths.captcha);

    // The session id the challenge is bound to.
    //
    // The portal mints a new `ASP.NET_SessionId` every time it renders the
    // login page, and the CAPTCHA endpoint sets no cookie of its own — so the
    // challenge lives in the session that was current when the image was
    // fetched. Any other request in between replaces that session, and the
    // portal then refuses a correct answer. Verified live 2026-10-21.
    final sessionId =
        transport.jars.jarFor(accountId).cookies['ASP.NET_SessionId'];

    _pendingLogins[accountId] = _PendingLogin(
      viewState: hiddenFieldValue(response.body, '__VIEWSTATE'),
      viewStateGenerator: hiddenFieldValue(response.body, '__VIEWSTATEGENERATOR'),
      sessionId: sessionId,
    );

    return LoginChallenge(
      imageBytes: captchaBytes,
      kind: ChallengeKind.digits4,
      sessionId: sessionId,
    );
  }

  @override
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

    final response = await transport.post(accountId, _Paths.login, body: body);

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
      establishedAt: _now(),
    );
  }

  @override
  Future<Session> refresh(Session session) async {
    // A session refresh is a cheap authenticated GET: if the portal still
    // recognises the cookies it serves the page, and if not it bounces to the
    // login form.
    _applySession(session);
    final response = await transport.get(session.account, _Paths.reservation);
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

  /// Puts [session]'s cookies into the transport's jar.
  ///
  /// The jar is filled by the responses the portal sends, so a session that
  /// was restored from storage — never a response — would go out
  /// unauthenticated. The portal would answer with the login page, and the
  /// read would be reported as an expired session rather than as a session
  /// that was never applied.
  void _applySession(Session session) {
    transport.restoreSession(session.account, session.cookies);
  }

  @override
  Future<void> logout(Session session) async {
    // The portal exposes logout as a postback to a `ctl00$logout` event target.
    final page = await transport.get(session.account, _Paths.reservation);
    await transport.post(session.account, _Paths.reservation, body: {
      '__VIEWSTATE': hiddenFieldValue(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(page.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': 'ctl00\$logout',
      '__EVENTARGUMENT': '',
    });
    transport.jars.remove(session.account);
  }

  // ---------------------------------------------------------------- time

  @override
  Future<DateTime> fetchServerTime(Session session) async {
    _applySession(session);
    // The `Date` header is authoritative and needs no page of its own.
    final response = await transport.get(session.account, _Paths.reservation);
    final serverDate = response.serverDateUtc;
    if (serverDate == null) {
      throw const PortalUnreachableException('سرور زمان را برنگرداند.');
    }
    return serverDate;
  }

  // ---------------------------------------------------------------- reads

  /// Throws when a read came back as the login form rather than the page.
  ///
  /// The portal answers an expired session by serving the login page, which is
  /// a perfectly valid response — and which every parser downstream would
  /// misread as "the page had no rows". So the bounce is detected here and
  /// reported as [LoginRejectedException], which tells the caller to log in
  /// again rather than to conclude the account holds nothing.
  static void _rejectIfBounced(TransportResponse response) {
    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(page);
    final text = labelText(page.body, 'lblCredit');
    if (text == null) {
      throw const PortalUnreachableException('موجودی خوانده نشد.');
    }
    final amount = parseRial(text);
    if (amount == null) {
      throw PortalUnreachableException('موجودی قابل تفسیر نبود: $text');
    }
    final profileName = CullinanParser.parseProfileName(page.body);
    return Balance(
      amountRial: amount,
      fetchedAt: _now(),
      profileName: profileName,
    );
  }

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(page);
    return _parseOfferings(page.body, date);
  }

  @override
  Future<List<MealMenu>> fetchMenu(
    Session session,
    DateTime date,
  ) async {
    _applySession(session);
    final html = await _readMenuFor(session, date);
    return CullinanParser.parseMenu(html, date);
  }

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    _applySession(session);

    // The first read is what makes the time trustworthy: every portal
    // response carries a `Date` header, and the transport syncs the clock
    // from it.
    final current = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(current);

    final menus = <MealMenu>[];
    final seen = <String>{};

    // 1. Current week menus
    for (final menu in CullinanParser.parseMenus(current.body)) {
      if (seen.add(_menuKey(menu))) {
        menus.add(menu);
      }
    }

    // 2. Next week menus (best-effort navigation)
    final viewState = hiddenFieldValue(current.body, '__VIEWSTATE');
    if (viewState.isNotEmpty) {
      try {
        final next = await transport.post(
          session.account,
          _Paths.reservation,
          body: {
            '__VIEWSTATE': viewState,
            '__VIEWSTATEGENERATOR':
                hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
            '__EVENTTARGET': _eventTargetNextWeek,
            '__EVENTARGUMENT': '',
          },
        );
        _rejectIfBounced(next);
        for (final menu in CullinanParser.parseMenus(next.body)) {
          if (seen.add(_menuKey(menu))) {
            menus.add(menu);
          }
        }
      } catch (_) {
        // Next week is optional (e.g. single page test mocks)
      }
    }

    final dates = menus.map((m) => m.date).toSet().toList()..sort();
    return BookableMenus(dates: dates, menus: menus);
  }

  /// The identity of a menu entry: a (date, slot) pair.
  ///
  /// A day serves **three** meals, so the date alone is not an identity — a
  /// set keyed by date keeps only the first of them, and the other two meals
  /// of that day vanish.
  static String _menuKey(MealMenu menu) =>
      '${menu.date.toIso8601String().substring(0, 10)}|${menu.slot.name}';



  /// The weekly menu page that carries [date].
  ///
  /// ## Why the second page
  ///
  /// The weekly menu is **one page per week**. `Reservation.aspx` carries the
  /// current week; the next week is a separate page, reached by posting
  /// `ctl00$cphMain$imgbtnNextWeek`. The hunt's targetable range is seven
  /// days long, so it routinely crosses that boundary — and a read that only
  /// ever fetched the current week's page would find no menu for a target
  /// date in next week, and report it as "no food is served that day".
  ///
  /// So the page is fetched, and the target date is looked for in it. If it
  /// is not there, next week's page is fetched and looked in.
  ///
  /// The postback is a **navigation**, not a write: it carries no save button
  /// and changes nothing on the account.
  Future<String> _readMenuFor(Session session, DateTime date) async {
    final current = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(current);

    if (_menuCovers(current.body, date)) return current.body;

    final next = await transport.post(
      session.account,
      _Paths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': _eventTargetNextWeek,
        '__EVENTARGUMENT': '',
      },
    );
    _rejectIfBounced(next);

    return next.body;
  }

  /// The reservation page for the week that carries [date].
  ///
  /// ## Why the write path must go through this
  ///
  /// The grid control names are **identical in every week** — `$ctl02$chkReserve`
  /// is the second *row*, not the second *date*. Which week a post affects is
  /// decided by the `__VIEWSTATE` it carries (F12). So a booking posted against
  /// the current week's viewstate lands in the current week, or is silently
  /// ignored — and the target's row was never in the posted state at all.
  ///
  /// The live book-and-cancel cycle learned this the hard way: the target was
  /// in next week, and the post had to carry **next week's** viewstate.
  Future<TransportResponse> _readWeekFor(Session session, DateTime date) async {
    final current = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(current);

    if (_weekCovers(current.body, date)) return current;

    final next = await transport.post(
      session.account,
      _Paths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': _eventTargetNextWeek,
        '__EVENTARGUMENT': '',
      },
    );
    _rejectIfBounced(next);

    return next;
  }

  /// Whether the page carries a grid row for [date].
  ///
  /// The date is compared by its **civil** form, because the grids label
  /// their rows in Jalali and a Jalali label is a date, not an instant.
  static bool _weekCovers(String html, DateTime date) {
    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, _gridForSlot(slot))) {
        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null) continue;
        if (_sameDate(rowDate, date)) return true;
      }
    }
    return false;
  }

  /// Whether the menu page carries a row for [date].
  ///
  /// The date is compared by its **civil** form, because the grids label
  /// their rows in Jalali and a Jalali label is a date, not an instant.
  static bool _menuCovers(String html, DateTime date) {
    for (final menu in CullinanParser.parseMenu(html, date)) {
      if (menu.date.year == date.year &&
          menu.date.month == date.month &&
          menu.date.day == date.day) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    _applySession(session);

    // ## Why two weeks, and not one
    //
    // The weekly page carries **one** week of grids. The portal lets a
    // student reserve up to **the following week** — verified live on
    // 2026-10-21: the rows two weeks out are every one of them `disabled`,
    // while the rows of the week ahead are editable. So the horizon is
    // exactly two weeks wide, and a read that stops at the first week
    // **misses every reservation the student holds next week**.
    //
    // What that miss cost, measured on the live account: a breakfast on
    // 1405/08/03 (2026-10-25) was held in week two. A one-week read did not
    // see it, so the mirror fell back to the ledger, and the ledger cannot
    // tell a weekly reservation from a Food Basket purchase — it records
    // both the same way. So the meal was filed as an **irreversible basket
    // purchase**: the table showed «خریداری شده» with no cancel button, on
    // a meal the portal would have let the student give back. And the
    // one-meal pre-flight check, which reads the same list, could not see
    // that the slot was already taken.
    //
    // So the read covers every week a student can hold a reservation in.
    final current = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(current);

    final reservations = _parseReservations(current.body);

    final next = await transport.post(
      session.account,
      _Paths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': _eventTargetNextWeek,
        '__EVENTARGUMENT': '',
      },
    );
    _rejectIfBounced(next);

    // The two weeks are parsed **separately**, not merged blindly: a date
    // that appears on neither simply is not held. And a meal is keyed by
    // (date, slot), so a meal that somehow appeared on both pages is
    // counted once.
    final seen = <String>{
      for (final reservation in reservations) _reservationKey(reservation),
    };
    for (final reservation in _parseReservations(next.body)) {
      if (seen.add(_reservationKey(reservation))) {
        reservations.add(reservation);
      }
    }

    return reservations;
  }

  /// The identity of a reservation: a (date, slot) pair.
  ///
  /// The date is compared by its **civil** form, because the grids label
  /// their rows in Jalali and a Jalali label is a date, not an instant.
  static String _reservationKey(Reservation reservation) =>
      '${HeldMeal.dateKey(reservation.date)}|${reservation.slot.name}';

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.transactions);
    _rejectIfBounced(page);
    return CullinanParser.parseTransactions(
      page.body,
      accountId: session.account,
    );
  }

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    _applySession(session);
    // The basket page is filtered by date, and the cursor is the Jalali date
    // the caller wants. Verified live 2026-10-20: the page's own `txtDate`
    // field agrees with the rows it renders, so a GET alone returns the page's
    // default date — reading it for any other date requires the filter
    // postback.
    final wanted = cursor ?? _todayJalali();
    final first = await transport.get(session.account, _Paths.basketBuy);
    _rejectIfBounced(first);

    if (CullinanParser.buyPageDate(first.body) == wanted) {
      return BasketPage(listings: _parseBasket(first.body, wanted));
    }

    final filtered = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(first.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': wanted,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      },
    );

    if (filtered.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }

    return BasketPage(listings: _parseBasket(filtered.body, wanted));
  }

  // ---------------------------------------------------------------- writes

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    _applySession(session);
    // `listingId` is the composite `date|slot|hall|option`, so it is
    // decomposed back into the parts the claim POST needs. The hall is part of
    // the identity: a purchase names a hall as well as a dish.
    final parts = _parseListingId(listingId);
    if (parts == null) {
      return const ClaimRejected('شناسه آگهی معتبر نیست.');
    }

    try {
      // The page must be read for the listing's own date, not the default one.
      final html = await _readBuyPage(session, parts.date);
      // Awaited inside the try so that a transport failure *during the POST* is
      // reported as ambiguous rather than escaping as an exception: the server
      // may have completed the purchase before the connection broke, and the
      // engine's whole safety story rests on that being a distinct outcome.
      return await _submitBasketRow(session, html, parts);
    } on TransportException catch (e) {
      // A transport failure is genuinely ambiguous: the request may have been
      // processed before the connection broke. The engine reconciles rather
      // than retrying, so reporting ambiguity here is the safe choice.
      return ClaimAmbiguous(e.message);
    }
  }

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    _applySession(session);

    // The post must go against the week that **carries the target**. The grid
    // control names are identical in every week, and the viewstate decides
    // which week's rows a post affects (F12) — so a booking for a next-week
    // date, posted against the current week's viewstate, names rows that do
    // not exist in the current week and books nothing.
    final page = await _readWeekFor(session, offering.date);

    final body = _reservationFormBody(page.body, offering);
    final response = await transport.post(
      session.account,
      _Paths.reservation,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }

    // The server either re-renders the grid with the reservation held, or
    // reports a problem. Reading it back is the only honest confirmation.
    //
    // But the response re-renders the server's **default** week, not the week
    // the post was made against — so a next-week booking is not visible in it
    // at all. The confirmation therefore re-reads the target's week.
    final confirmation = await _readWeekFor(session, offering.date);
    final reservations = _parseReservations(confirmation.body);
    for (final reservation in reservations) {
      if (reservation.slot == offering.slot &&
          _sameDate(reservation.date, offering.date)) {
        return reservation;
      }
    }

    // Nothing held, and no error was reported.
    //
    // A **locked date is refused silently**: the row renders `disabled` and the
    // server ignores the post entirely — no error label, no alert box, no state
    // change. Verified live (2026-10-19): posting a reservation for 1405/07/28,
    // whose cutoff had passed three days earlier, produced an identical page
    // and no reservation. So the absence of a reservation after a save is NOT
    // proof of a transport problem, and a client that waited for an error
    // message would wait forever.
    //
    // Distinguish the two by re-reading the row: a locked row still renders
    // `disabled`, which is the server's own statement that the date is closed.
    if (_isLockedForSlot(confirmation.body, offering)) {
      throw ReservationLockedException(
        'مهلت رزرو این تاریخ به پایان رسیده است.',
        date: offering.date,
        slot: offering.slot,
      );
    }

    throw const PortalUnreachableException('رزرو تأیید نشد.');
  }

  @override
  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings,
  ) async {
    if (offerings.isEmpty) return const [];
    _applySession(session);

    final currentWeek =
        await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(currentWeek);

    final currentOfferings = <MealOffering>[];
    final otherOfferings = <MealOffering>[];

    for (final offering in offerings) {
      if (_weekCovers(currentWeek.body, offering.date)) {
        currentOfferings.add(offering);
      } else {
        otherOfferings.add(offering);
      }
    }

    final confirmed = <Reservation>[];
    MealOffering? lockedOffering;

    Future<void> submitWeek(
      List<MealOffering> weekOfferings,
      DateTime sampleDate,
    ) async {
      if (weekOfferings.isEmpty) return;

      final slots = [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner];
      for (final slot in slots) {
        final offeringsForSlot =
            weekOfferings.where((o) => o.slot == slot).toList();
        if (offeringsForSlot.isEmpty) continue;

        final page = await _readWeekFor(session, sampleDate);
        final body =
            _batchReservationFormBody(page.body, offeringsForSlot, slot);
        final response = await transport.post(
          session.account,
          _Paths.reservation,
          body: body,
        );
        _rejectIfBounced(response);
      }

      final confirmation = await _readWeekFor(session, sampleDate);
      final reservations = _parseReservations(confirmation.body);

      for (final offering in weekOfferings) {
        final match = reservations.where((r) =>
            r.slot == offering.slot &&
            _sameDate(r.date, offering.date)).firstOrNull;
        if (match != null) {
          confirmed.add(match);
        } else if (_isLockedForSlot(confirmation.body, offering)) {
          lockedOffering ??= offering;
        }
      }
    }

    if (currentOfferings.isNotEmpty) {
      try {
        await submitWeek(currentOfferings, currentOfferings.first.date);
      } on LoginRejectedException {
        rethrow;
      } catch (_) {
        if (confirmed.isEmpty) rethrow;
      }
    }

    if (otherOfferings.isNotEmpty) {
      final remaining = List<MealOffering>.from(otherOfferings);
      while (remaining.isNotEmpty) {
        final first = remaining.removeAt(0);
        final group = <MealOffering>[first];
        try {
          final weekPage = await _readWeekFor(session, first.date);
          remaining.removeWhere((o) {
            if (_weekCovers(weekPage.body, o.date)) {
              group.add(o);
              return true;
            }
            return false;
          });
          await submitWeek(group, first.date);
        } on LoginRejectedException {
          rethrow;
        } catch (_) {
          if (confirmed.isEmpty) rethrow;
        }
      }
    }

    if (confirmed.isEmpty) {
      final locked = lockedOffering;
      if (locked != null) {
        throw ReservationLockedException(
          'مهلت رزرو این تاریخ به پایان رسیده است.',
          date: locked.date,
          slot: locked.slot,
        );
      }
      throw const PortalUnreachableException('رزرو تأیید نشد.');
    }

    return confirmed;
  }

  /// True when the portal still renders this date's row as locked.
  ///
  /// The lock is the server's own signal, and it survives a refused post.
  bool _isLockedForSlot(String html, MealOffering offering) {
    final gridId = switch (offering.slot) {
      MealSlot.breakfast => 'grdReservationBreakfast',
      MealSlot.lunch => 'grdReservationLunch',
      MealSlot.dinner => 'grdReservationDinner',
    };

    for (final row in tableRows(html, gridId)) {
      if (row.cells.length < 4) continue;
      final date = parseJalaliDate(row.cell(1));
      if (date == null || !_sameDate(date, offering.date)) continue;

      // The checkbox is the server's lock marker.
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return checkbox?.disabled ?? false;
    }

    return false;
  }

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async {
    final html = await _readBuyPage(session, date);
    return CullinanParser.heldOnBuyPage(html, optionId);
  }

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    _applySession(session);

    // The cancel must post against the week that **carries the target**. The
    // grid control names are identical in every week, and the viewstate
    // decides which week's rows a post affects (F12), so posting the current
    // week's viewstate for a next-week meal cancels nothing.
    final page = await _readWeekFor(session, ref.date);

    // The weekly cancel is **uncheck the row and save again**. There is no
    // cancel button on the reservation hub (F14).
    //
    // And the post must carry the **complete form state**, with the target
    // row's checkbox *absent*: an ASP.NET checkbox that is absent from a POST
    // reads as **unchecked**, so posting only the target row would present
    // every other checked row as unchecked and cancel the account's other
    // meals. Every other row is therefore posted exactly as the page renders
    // it, and only the target is left out.
    final body = _cancelFormBody(page.body, ref);
    final postResponse =
        await transport.post(session.account, _Paths.reservation, body: body);
    // A bounced session is the one case where the post itself says the
    // write did not happen. The silent refusal of a locked date (F14) is not
    // like this — that one answers a plain `200` and is caught by the
    // read-back below.
    _rejectIfBounced(postResponse);

    // The post is **not** the outcome.
    //
    // A locked date is refused **silently** (F14): the server discards the
    // post, the response is a plain `200`, and nothing on the page changes. So
    // a cancel that trusted the status code would report success for a
    // cancellation that never happened, and the app would hide a meal the
    // student still holds (F63).
    //
    // The portal is read back instead, exactly as the booking path does.
    final confirmation = await _readWeekFor(session, ref.date);
    final readback = _readbackOf(confirmation.body, ref);

    switch (readback) {
      case _ReadbackState.stillHeld:
        // The meal is still there. The only reason the portal keeps it is
        // that the date has locked — the row is rendered `disabled` and the
        // post was ignored.
        return const CancelRefused(
          'مهلت رزرو این تاریخ به پایان رسیده است.',
        );
      case _ReadbackState.gone:
        return const CancelSucceeded();
      case _ReadbackState.notOnPage:
        // The read-back page does not carry the target date at all, so it
        // says **nothing** about the meal. Reporting success here would empty
        // the mirror for a cancel that may never have happened (F65).
        return const CancelAmbiguous(
          'وضعیت رزرو در سایت تایید نشد.',
        );
    }
  }

  @override
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    if (reserveType == ReserveType.foodBasket) {
      return const SaleListingRefused('غذای خریداری‌شده از سبد غذایی، امکان فروش مجدد در سبد را ندارد.');
    }

    try {
      final page = await transport.get(session.account, _Paths.basketSale);
      if (page.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final jalaliDate = _jalaliOf(date);

      // Step 1: Post "بارگذاری غذا" to load the meal details and render the sell button
      final step1Body = CullinanParser.saleReloadFormBody(
        page.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );

      final step1Response = await transport.post(
        session.account,
        _Paths.basketSale,
        body: step1Body,
      );

      if (step1Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final step1Alert = CullinanParser.parseSaleAlert(step1Response.body);
      if (step1Alert != null && step1Alert.isNotEmpty) {
        return SaleListingRefused(step1Alert);
      }

      // Step 2: Find the "فروش به سبد غذا" button rendered in the reloaded page
      final sellBtn = CullinanParser.parseSaleSubmitButton(step1Response.body);
      if (sellBtn == null) {
        // If the meal is already in the basket (cancel button shown), report it
        final cancelBtn = CullinanParser.parseSaleCancelButton(step1Response.body);
        if (cancelBtn != null) {
          return const SaleListingRefused('این وعده از قبل برای فروش در سبد قرار گرفته است.');
        }
        return const SaleListingRefused('امکان فروش این وعده در سبد وجود ندارد.');
      }

      // Submit Step 2: Post the actual sale confirmation
      final step2Body = CullinanParser.saleConfirmFormBody(
        step1Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
        buttonName: sellBtn.name,
        buttonValue: sellBtn.value,
        isEventTarget: sellBtn.isEventTarget,
      );

      final step2Response = await transport.post(
        session.account,
        _Paths.basketSale,
        body: step2Body,
      );

      if (step2Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final alert = CullinanParser.parseSaleAlert(step2Response.body);
      if (alert != null && alert.isNotEmpty) {
        final isSuccess = (alert.contains('موفق') ||
                alert.contains('ثبت شد') ||
                alert.contains('انجام شد') ||
                alert.contains('در سبد قرار گرفت')) &&
            !alert.contains('خطا') &&
            !alert.contains('ناموفق') &&
            !alert.contains('نیست');
        if (isSuccess) {
          return SaleListingSucceeded(alert);
        }
        return SaleListingRefused(alert);
      }

      // Check if page state flipped to "in basket" (cancel button rendered)
      if (CullinanParser.isListedInBasketOnPage(step2Response.body)) {
        return const SaleListingSucceeded('غذا با موفقیت در سبد غذایی برای فروش قرار گرفت.');
      }

      // If sell button is still on the page and cancel button is absent, the server refused
      if (CullinanParser.isReservedNotForSaleOnPage(step2Response.body)) {
        return const SaleListingRefused('سامانه دانشگاه فروش این غذا در سبد را ثبت نکرد. لطفاً مجدداً تلاش نمایید.');
      }

      // Read-back verification via fresh reload
      final verifyBody = CullinanParser.saleReloadFormBody(
        step2Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );
      final verifyResponse = await transport.post(
        session.account,
        _Paths.basketSale,
        body: verifyBody,
      );
      final verifyAlert = CullinanParser.parseSaleAlert(verifyResponse.body);
      if (verifyAlert != null && verifyAlert.isNotEmpty) {
        return SaleListingRefused(verifyAlert);
      }
      if (CullinanParser.isListedInBasketOnPage(verifyResponse.body)) {
        return const SaleListingSucceeded('غذا با موفقیت در سبد غذایی برای فروش قرار گرفت.');
      }

      return const SaleListingRefused('سامانه دانشگاه فروش این غذا در سبد را تأیید نکرد.');
    } on TransportException catch (e) {
      return SaleListingAmbiguous(e.message);
    } catch (e) {
      return SaleListingAmbiguous(e.toString());
    }
  }

  @override
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    if (reserveType == ReserveType.foodBasket) {
      return const SaleListingRefused('غذای خریداری‌شده از سبد در بخش فروش سبد وجود ندارد.');
    }

    try {
      final page = await transport.get(session.account, _Paths.basketSale);
      if (page.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final jalaliDate = _jalaliOf(date);

      // Step 1: Post "بارگذاری غذا" to reload the meal status and render the cancel button
      final step1Body = CullinanParser.saleReloadFormBody(
        page.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );

      final step1Response = await transport.post(
        session.account,
        _Paths.basketSale,
        body: step1Body,
      );

      if (step1Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final step1Alert = CullinanParser.parseSaleAlert(step1Response.body);
      if (step1Alert != null && step1Alert.isNotEmpty) {
        return SaleListingRefused(step1Alert);
      }

      // If the meal is already NOT in the basket (sell button shown and cancel absent):
      if (CullinanParser.isReservedNotForSaleOnPage(step1Response.body) &&
          !CullinanParser.isListedInBasketOnPage(step1Response.body)) {
        return const SaleListingSucceeded('غذا در سبد فروش قرار ندارد.');
      }

      // Find the cancellation button (active only if meal was in basket and not yet sold)
      final cancelBtn = CullinanParser.parseSaleCancelButton(step1Response.body);
      if (cancelBtn == null) {
        if (CullinanParser.parseSaleSubmitButton(step1Response.body) != null) {
          return const SaleListingSucceeded('غذا در سبد فروش قرار ندارد.');
        }
        return const SaleListingRefused(
          'دکمه حذف فروش در سامانه فعال نیست (احتمالاً غذا قبلاً فروخته شده یا مهلت آن به پایان رسیده است).',
        );
      }

      // Step 2: Post the cancel confirmation
      final step2Body = CullinanParser.saleConfirmFormBody(
        step1Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
        buttonName: cancelBtn.name,
        buttonValue: cancelBtn.value,
        isEventTarget: cancelBtn.isEventTarget,
      );

      final step2Response = await transport.post(
        session.account,
        _Paths.basketSale,
        body: step2Body,
      );

      if (step2Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final alert = CullinanParser.parseSaleAlert(step2Response.body);
      if (alert != null && alert.isNotEmpty) {
        final isSuccess = (alert.contains('موفق') ||
                alert.contains('با موفقیت') ||
                alert.contains('خارج شد') ||
                alert.contains('لغو شد') ||
                alert.contains('انجام شد')) &&
            !alert.contains('خطا') &&
            !alert.contains('ناموفق') &&
            !alert.contains('نیست') &&
            !alert.contains('نمی باشد') &&
            !alert.contains('امکان') &&
            !alert.contains('مهلت');
        if (isSuccess) {
          return SaleListingSucceeded(alert);
        }
        return SaleListingRefused(alert);
      }

      // State verification: if meal reverted to reserved not for sale (sell button rendered, cancel absent)
      if (CullinanParser.isReservedNotForSaleOnPage(step2Response.body)) {
        return const SaleListingSucceeded('غذا با موفقیت از سبد فروش خارج شد.');
      }

      // If cancel button is still present on step2Response, the cancellation failed
      if (CullinanParser.isListedInBasketOnPage(step2Response.body)) {
        return const SaleListingRefused('لغو فروش غذا در سامانه تأیید نشد و غذا همچنان در سبد قرار دارد.');
      }

      // Read-back verification via fresh reload
      final verifyBody = CullinanParser.saleReloadFormBody(
        step2Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );
      final verifyResponse = await transport.post(
        session.account,
        _Paths.basketSale,
        body: verifyBody,
      );
      final verifyAlert = CullinanParser.parseSaleAlert(verifyResponse.body);
      if (verifyAlert != null && verifyAlert.isNotEmpty) {
        return SaleListingRefused(verifyAlert);
      }
      if (CullinanParser.isReservedNotForSaleOnPage(verifyResponse.body)) {
        return const SaleListingSucceeded('غذا با موفقیت از سبد فروش خارج شد.');
      }
      if (CullinanParser.isListedInBasketOnPage(verifyResponse.body)) {
        return const SaleListingRefused('لغو فروش غذا در سامانه تأیید نشد.');
      }

      return const SaleListingRefused('غذای مورد نظر در سامانه یافت نشد (احتمالاً به فروش رفته است).');
    } on TransportException catch (e) {
      return SaleListingAmbiguous(e.message);
    } catch (e) {
      return SaleListingAmbiguous(e.toString());
    }
  }

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    try {
      // 1. GET page
      final page = await transport.get(session.account, _Paths.forgotReceipt);
      if (page.looksLikeLoginPage) {
        return const ForgotReceiptRefused('نشست منقضی شده است. لطفا دوباره وارد شوید.');
      }

      // 2. Step 1 POST (Submit date, meal, reserve type)
      final step1Body = CullinanParser.forgotReceiptFormBody(
        page.body,
        jalaliDate: _jalaliOf(date),
        slot: slot,
        reserveType: reserveType,
      );

      final response1 = await transport.post(
        session.account,
        _Paths.forgotReceipt,
        body: step1Body,
      );

      if (response1.looksLikeLoginPage) {
        return const ForgotReceiptRefused('نشست منقضی شده است. لطفا دوباره وارد شوید.');
      }

      // Check step 1 status and agree button
      final step1Status = CullinanParser.parseForgotReceiptStep1Status(response1.body);
      final agreeButton = CullinanParser.parseForgotReceiptAgreeButton(response1.body);

      // If no agreement button appeared, evaluate refusal reasons, quota exhaustion, or immediate code
      if (agreeButton == null) {
        final immediateOutcome = CullinanParser.parseForgotReceiptOutcome(
          response1.body,
          date: date,
          slot: slot,
        );
        if (immediateOutcome is ForgotReceiptSucceeded) {
          if (immediateOutcome.quotaRemaining == null && step1Status.usedCount != null) {
            final remaining = (2 - step1Status.usedCount!).clamp(0, 2);
            return ForgotReceiptSucceeded(
              date: immediateOutcome.date,
              slot: immediateOutcome.slot,
              code: immediateOutcome.code,
              message: immediateOutcome.message,
              quotaRemaining: remaining,
            );
          }
          return immediateOutcome;
        }
        if (immediateOutcome is ForgotReceiptRefused) {
          return immediateOutcome;
        }

        if (step1Status.refusalReason != null) {
          return ForgotReceiptRefused(step1Status.refusalReason!);
        }

        if (step1Status.isQuotaExceeded) {
          return const ForgotReceiptRefused(
            'شما دو فیش خود را دریافت کرده‌اید و سقف مجاز دریافت فیش فراموشی (۲ بار در ماه) برای این وعده به پایان رسیده است.',
          );
        }

        return immediateOutcome;
      }

      // 3. Step 2 POST (Confirm with "موافقم")
      // Since agreeButton is present, the student is eligible: immediately submit confirmation.
      final step2Body = CullinanParser.forgotReceiptStep2FormBody(
        response1.body,
        button: agreeButton,
        jalaliDate: _jalaliOf(date),
        slot: slot,
        reserveType: reserveType,
      );

      final response2 = await transport.post(
        session.account,
        _Paths.forgotReceipt,
        body: step2Body,
      );

      if (response2.looksLikeLoginPage) {
        return const ForgotReceiptRefused('نشست منقضی شده است. لطفا دوباره وارد شوید.');
      }

      final outcome = CullinanParser.parseForgotReceiptOutcome(
        response2.body,
        date: date,
        slot: slot,
      );

      if (outcome is ForgotReceiptSucceeded && outcome.quotaRemaining == null && step1Status.usedCount != null) {
        final remaining = (2 - (step1Status.usedCount! + 1)).clamp(0, 2);
        return ForgotReceiptSucceeded(
          date: outcome.date,
          slot: outcome.slot,
          code: outcome.code,
          message: outcome.message,
          quotaRemaining: remaining,
        );
      }

      return outcome;
    } on TransportException catch (e) {
      return ForgotReceiptAmbiguous(e.message);
    } catch (e) {
      return ForgotReceiptAmbiguous(e.toString());
    }
  }

  /// What [html] says about the meal [ref].
  ///
  /// ## Why the three states, and not a bool
  ///
  /// A bool cannot tell "the meal is gone" from "the page does not show that
  /// day". The second is what made the cancel report a success it never
  /// earned (F65): the read-back looked in the wrong grid, found no row, and
  /// concluded the meal had been released.
  ///
  /// So the row's presence is checked first, and only a page that genuinely
  /// carries the day can say the meal is gone.
  static _ReadbackState _readbackOf(String html, MealRef ref) {
    for (final row in tableRows(html, _gridForSlot(ref.slot))) {
      if (row.cells.length < 7) continue;

      final date = parseJalaliDate(row.cell(1));
      if (date == null || !_sameDate(date, ref.date)) continue;

      // The row is on the page, so the page can speak about it.
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      if (checkbox == null || !checkbox.checked) return _ReadbackState.gone;

      // The same two markers a held meal has everywhere else: the row is
      // `checked`, and it carries a non-zero amount (F13). A row the portal
      // merely echoes as `checked` is not a reservation, so the amount is
      // what tells the two apart.
      return _isGenuinelyHeld(row)
          ? _ReadbackState.stillHeld
          : _ReadbackState.gone;
    }

    // No row for that day in that grid. The day might not be on this page
    // at all — which is a different thing from the meal being released.
    return _ReadbackState.notOnPage;
  }

  /// The form state for a cancel: every row as the page renders it, except
  /// the target, whose checkbox is omitted.
  ///
  /// ## Why only genuinely held rows are re-posted
  ///
  /// A row the portal merely echoes as `checked` is not a reservation (F13),
  /// and re-posting its checkbox would **book** it — a meal the student never
  /// asked for, charged to their account. So the checkbox is re-posted only
  /// for rows that carry the green «رزرو شده» icon and a non-zero amount.
  Map<String, String> _cancelFormBody(String html, MealRef ref) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };

    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, _gridForSlot(slot))) {
        final date = parseJalaliDate(row.cell(1));
        if (date == null) continue;

        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        final self = selectBySuffix(row.raw, 'drpSelf');
        final food = selectBySuffix(row.raw, 'drpFood');
        final count = selectBySuffix(row.raw, 'drpFoodCount');
        if (checkbox == null || self == null || food == null || count == null) {
          continue;
        }

        // The row's own state, unchanged.
        body[self.name] = self.selected?.value ?? '-1';
        body[food.name] = food.selected?.value ?? '-1';
        body[count.name] = count.selected?.value ?? '0';

        final isTarget = slot == ref.slot && _sameDate(date, ref.date);

        // The target's checkbox is **omitted**, which is how it is unchecked.
        // Every other row is posted as the page renders it, so the account's
        // other meals survive.
        if (!isTarget && checkbox.checked && _isGenuinelyHeld(row)) {
          body[checkbox.name] = 'on';
        }
      }
    }

    final saveCancelBtnName = _gridSaveButton(ref.slot);
    final saveCancelBtnInput = inputBySuffix(html, _gridSaveButtonSuffix(ref.slot));
    body[saveCancelBtnName] = saveCancelBtnInput?.value.isNotEmpty == true
        ? saveCancelBtnInput!.value
        : 'ذخیره';
    return body;
  }

  /// Whether the row is a genuine, charged reservation.
  ///
  /// Both markers are required: the green «رزرو شده» icon, and a non-zero
  /// **مبلغ خرید**. An echoed row has neither (F13).
  static bool _isGenuinelyHeld(ParsedRow row) {
    final status = rowStatus(row.raw);
    if (!status.held) return false;
    return (parseRial(row.cell(6)) ?? 0) > 0;
  }

  @override
  Uri? topUpUrl(Session session) => transport.resolve(_Paths.topUp);

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.topUp);
    _rejectIfBounced(page);

    final balance = parseRial(labelText(page.body, 'lblCredit') ?? '');
    if (balance == null) {
      throw const PortalUnreachableException('موجودی خوانده نشد.');
    }

    return TopUpPage(
      balanceRial: balance,
      banks: _topUpBanks(page.body),
      defaultAmountRial: parseRial(
        labelText(page.body, 'cphMain_txtPaymentAmount') ??
            _inputValue(page.body, 'cphMain_txtPaymentAmount') ??
            '',
      ),
    );
  }

  /// The banks the page offers.
  ///
  /// A bank whose logo is missing is still offered — the portal renders the
  /// second bank's title empty (F57), but the control is there and the
  /// student may be able to use it. The app filters on the *gateway's*
  /// behaviour, not on the title, and refuses the ones that cannot work.
  List<TopUpBank> _topUpBanks(String html) {
    final out = <TopUpBank>[];

    for (final match in RegExp(
      r'<input[^>]*type="image"[^>]*id="cphMain_dataLstBank_imgBankLogo_(\d+)"'
      r'[^>]*>',
      dotAll: true,
    ).allMatches(html)) {
      final index = match.group(1)!;
      final tag = match.group(0)!;
      final title =
          labelText(html, 'cphMain_dataLstBank_lblBankTitle_$index')?.trim();

      out.add(TopUpBank(
        id: _TopUpFields.bankLogo(int.parse(index)),
        // The portal leaves the second bank's title empty, so the name falls
        // back to something the student can still recognise.
        name: (title == null || title.isEmpty) ? 'درگاه پرداخت' : title,
        logoPath: _firstSrc(tag),
      ));
    }

    return out;
  }

  /// The first `src` attribute in a tag.
  ///
  /// The portal writes the bank logo as `<input ... src="NewMelli.jpg" src="" />`
  /// — **two** `src` attributes, the second one empty. A greedy match takes
  /// the empty one and the logo is lost, so the first is taken.
  static String? _firstSrc(String tag) {
    final match = RegExp(r'src="([^"]*)"').firstMatch(tag);
    final value = match?.group(1);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) async {
    _applySession(session);

    // Step 1: the amount and the bank. The bank logo is the submit button,
    // so the post carries its name and the click coordinates.
    final page = await transport.get(session.account, _Paths.topUp);
    _rejectIfBounced(page);

    final amountBody = _topUpFormState(page.body)
      ..[_TopUpFields.amount] = '$amountRial'
      ..['${bank.id}.x'] = '10'
      ..['${bank.id}.y'] = '10';

    final confirmation =
        await transport.post(session.account, _Paths.topUp, body: amountBody);
    _rejectIfBounced(confirmation);

    // The confirmation page is the proof that the amount was accepted: the
    // portal refuses an out-of-range amount **silently**, re-rendering the
    // amount form with no message (F56). So the absence of the pay button is
    // the only signal, and it is checked here rather than left to the
    // student to discover.
    if (!confirmation.body.contains(_TopUpFields.pay)) {
      throw const TopUpRejectedException(
        'این مبلغ پذیرفته نشد. کمترین ۱۲٬۰۰۰ و بیشترین ۵۰۰٬۰۰۰ تومان است.',
      );
    }

    // Step 2: confirm, and read the redirect to the bank's gateway.
    final payBody = _topUpFormState(confirmation.body)
      ..[_TopUpFields.pay] = 'پرداخت';

    final response = await transport.post(
      session.account,
      _Paths.topUp,
      body: payBody,
      // The redirect points at the **bank**, and the bank is not reachable
      // from this transport — the TLS handshake fails there (F55). Following
      // it would turn a successful handoff into a network error, so the
      // location is read and handed to the WebView instead.
      followRedirects: false,
    );

    final location = response.headers['location'];
    if (location == null || location.isEmpty) {
      throw const TopUpRejectedException(
        'درگاه پرداخت پاسخ نداد. لطفاً دوباره تلاش کنید.',
      );
    }

    final gateway = Uri.tryParse(location);
    if (gateway == null || !gateway.hasScheme) {
      throw const TopUpRejectedException(
        'نشانی درگاه پرداخت معتبر نبود.',
      );
    }

    return gateway;
  }

  @override
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.topUpList);
    _rejectIfBounced(page);
    return CullinanParser.parseTopUpPayments(page.body);
  }

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) async {
    _applySession(session);
    final first = await transport.get(session.account, _Paths.topUpList);
    _rejectIfBounced(first);

    // Find the first non-disabled «استعلام» verify button in the table.
    // Rows that have already been verified carry disabled="disabled".
    final allButtons = RegExp(
      r'<input[^>]*name="([^"]*imgbtnVerify)"[^>]*>',
      caseSensitive: false,
    ).allMatches(first.body);

    String? btnName;
    for (final m in allButtons) {
      final fullTag = m.group(0)!;
      if (!fullTag.contains('disabled')) {
        btnName = m.group(1);
        break;
      }
    }

    btnName ??= RegExp(r'name="([^"]*imgbtnVerify)"').firstMatch(first.body)?.group(1);

    if (btnName == null) {
      return CullinanParser.parseTopUpPayments(first.body);
    }

    final postBody = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR':
          hiddenFieldValue(first.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED':
          hiddenFieldValue(first.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    final ev = hiddenFieldValue(first.body, '__EVENTVALIDATION');
    if (ev.isNotEmpty) {
      postBody['__EVENTVALIDATION'] = ev;
    }

    final dateFrom = _inputValue(first.body, 'cphMain_txtDateFrom');
    if (dateFrom != null && dateFrom.isNotEmpty) {
      postBody['ctl00\$cphMain\$txtDateFrom'] = dateFrom;
    }
    final dateTo = _inputValue(first.body, 'cphMain_txtDateTo');
    if (dateTo != null && dateTo.isNotEmpty) {
      postBody['ctl00\$cphMain\$txtDateTo'] = dateTo;
    }

    postBody['$btnName.x'] = '15';
    postBody['$btnName.y'] = '15';

    final verified = await transport.post(
      session.account,
      _Paths.topUpList,
      body: postBody,
    );
    _rejectIfBounced(verified);
    return CullinanParser.parseTopUpPayments(verified.body);
  }

  /// The ePay form's own state, with the fields that must travel with it.
  ///
  /// The `__VIEWSTATE` is the whole form state: a post without it is
  /// processed against no state at all and silently does nothing.
  static Map<String, String> _topUpFormState(String html) {
    final state = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': hiddenFieldValue(html, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    final ev = hiddenFieldValue(html, '__EVENTVALIDATION');
    if (ev.isNotEmpty) {
      state['__EVENTVALIDATION'] = ev;
    }
    return state;
  }

  /// The value of an `<input>`, found by its id.
  static String? _inputValue(String html, String id) {
    final match = RegExp('id="${RegExp.escape(id)}"[^>]*value="([^"]*)"')
        .firstMatch(html);
    return match?.group(1);
  }

  // ------------------------------------------------------------- internals

  /// The Jalali date string for today, as the portal expects it.
  String _todayJalali() => _jalaliOf(_now());

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  static String _jalaliOf(DateTime date) {
    final jalali = toJalali(date);
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
  }

  /// Parses the three reservation grids into offerings.
  List<MealOffering> _parseOfferings(String html, DateTime targetDate) =>
      CullinanParser.parseOfferings(html, targetDate);

  /// Parses the three reservation grids into the reservations held.
  List<Reservation> _parseReservations(String html) =>
      CullinanParser.parseReservations(html);

  /// Parses the basket buy grid into listings.
  List<Listing> _parseBasket(String html, String jalaliDate) {
    final date = parseJalaliDate(jalaliDate);
    if (date == null) return const [];
    return CullinanParser.parseBasket(html, date);
  }

  /// Reads the buy page filtered to [date], returning its HTML.
  Future<String> _readBuyPage(Session session, DateTime date) async {
    final wanted = _jalaliOf(date);
    final first = await transport.get(session.account, _Paths.basketBuy);
    if (CullinanParser.buyPageDate(first.body) == wanted) return first.body;

    final filtered = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(first.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': wanted,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      },
    );
    if (filtered.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    return filtered.body;
  }

  /// Submits the buy page's form for one listing.
  ///
  /// The outcome is decided by **the row's amount**, not by whether the option
  /// disappeared. Verified live 2026-10-20 against the response to a real
  /// purchase: the bought option is still offered afterwards, and what changes
  /// is that its row becomes checked and its مبلغ خرید cell becomes non-zero.
  /// A client that tested "the option is gone" would report a completed,
  /// irreversible purchase as a failure and keep hunting.
  Future<ClaimResult> _submitBasketRow(
    Session session,
    String html,
    _ListingParts parts,
  ) async {
    final offered = CullinanParser.parseBasket(
      html,
      parts.date,
    ).where((l) => l.option.id == parts.optionId).toList();
    if (offered.isEmpty) {
      return const ClaimRejected('این آگهی دیگر در دسترس نیست.');
    }

    // The hall must be one the page actually offers for this dish. Posting a
    // hallucinated hall would be a request the portal rejects at best, and an
    // unintended purchase at worst.
    if (!offered.any((l) => l.hall.id == parts.hallId)) {
      return const ClaimRejected('این آگهی در سالن انتخاب‌شده موجود نیست.');
    }

    final body = CullinanParser.claimFormBody(
      html,
      listingId: parts.optionId,
      hallId: parts.hallId,
      date: _jalaliOf(parts.date),
    );

    final response = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      return const ClaimRejected('نشست منقضی شده است.');
    }

    final error = _basketError(response.body);
    if (error != null) {
      return ClaimRejected(error);
    }

    // The amount is the only trustworthy success signal.
    final hold = CullinanParser.heldOnBuyPage(response.body, parts.optionId);
    if (hold != null && hold.isHeld) {
      return ClaimSucceeded(Reservation(
        id: parts.optionId,
        date: parts.date,
        slot: parts.slot,
        hall: Hall(id: parts.hallId, name: ''),
        option: MenuOption(
          id: parts.optionId,
          name: '',
          priceRial: parts.priceRial,
        ),
        state: ReservationState.active,
      ));
    }

    // The page neither reported an error nor showed the meal as held. That is
    // not proof of failure — the response may not have rendered the final
    // state — so it must not be reported as a rejection, which would invite a
    // second, irreversible purchase.
    return const ClaimAmbiguous('پاسخ سامانه نتیجه خرید را روشن نکرد.');
  }

  /// The error text the basket page shows for a failed purchase, if any.
  String? _basketError(String html) {
    // The status column carries the outcome. A row that failed shows text in
    // its last cell.
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 8) continue;
      final status = row.cell(7).trim();
      if (status.isEmpty) continue;
      if (status.contains('موجودی') ||
          status.contains('ناموفق') ||
          status.contains('خطا')) {
        return status;
      }
    }
    return null;
  }

  /// The reservation form body for reserving one offering.
  ///
  /// ## Why the whole form is posted
  ///
  /// The reservation page holds **three grids of seven rows**, and a browser
  /// submits every control in the form. An ASP.NET checkbox that is *absent*
  /// from a POST reads as **unchecked** — so posting only the target row
  /// presents every other checked row as unchecked, and **cancels the
  /// account's other reservations** (F12).
  ///
  /// So the post carries the COMPLETE current form state — every row's
  /// dropdown values, and the checkbox of every genuinely held row — with
  /// exactly one field changed: the target row's checkbox is turned on and its
  /// dropdowns are pointed at the requested hall and dish.
  ///
  /// ## Why only genuinely held rows are re-posted
  ///
  /// A row the portal merely echoes as `checked` is not a reservation (F13),
  /// and re-posting its checkbox would **book** it — a meal the student never
  /// asked for, charged to their account. Only rows carrying the green
  /// «رزرو شده» icon and a non-zero amount are re-posted.
  Map<String, String> _reservationFormBody(
    String html,
    MealOffering offering,
  ) =>
      _batchReservationFormBody(html, [offering], offering.slot);

  Map<String, String> _batchReservationFormBody(
    String html,
    List<MealOffering> offeringsForSlot,
    MealSlot targetSlot,
  ) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };

    // Every row of every grid, so the account's other meals survive the post.
    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, _gridForSlot(slot))) {
        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        final self = selectBySuffix(row.raw, 'drpSelf');
        final food = selectBySuffix(row.raw, 'drpFood');
        final count = selectBySuffix(row.raw, 'drpFoodCount');
        if (checkbox == null ||
            self == null ||
            food == null ||
            count == null) {
          continue;
        }

        final rowDate = parseJalaliDate(row.cell(1));
        final matchingOffering = (slot == targetSlot && rowDate != null)
            ? offeringsForSlot
                .where((o) => _sameDate(o.date, rowDate))
                .firstOrNull
            : null;

        if (matchingOffering != null) {
          // The requested meal in this batch.
          body[checkbox.name] = 'on';
          body[self.name] = matchingOffering.hall.id;
          body[food.name] = matchingOffering.option.id;
          body[count.name] = count.options.any((o) => o.value == '1')
              ? '1'
              : (count.options.firstOrNull?.value ?? '1');
          continue;
        }

        // Every other row, exactly as the page renders it.
        body[self.name] = self.selected?.value ?? '-1';
        body[food.name] = food.selected?.value ?? '-1';
        body[count.name] = count.selected?.value ?? '0';

        if (checkbox.checked && _isGenuinelyHeld(row)) {
          body[checkbox.name] = 'on';
        }
      }
    }

    final saveBtnName = _gridSaveButton(targetSlot);
    final saveBtnInput =
        inputBySuffix(html, _gridSaveButtonSuffix(targetSlot));
    body[saveBtnName] = saveBtnInput?.value.isNotEmpty == true
        ? saveBtnInput!.value
        : 'ذخیره';
    return body;
  }

  static String _gridForSlot(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'grdReservationBreakfast',
        MealSlot.lunch => 'grdReservationLunch',
        MealSlot.dinner => 'grdReservationDinner',
      };

  static String _gridSaveButtonSuffix(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'btnSaveBreakfast',
        MealSlot.lunch => 'btnSaveLunch',
        MealSlot.dinner => 'btnSaveDinner',
      };

  static String _gridSaveButton(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'ctl00\$cphMain\$btnSaveBreakfast',
        MealSlot.lunch => 'ctl00\$cphMain\$btnSaveLunch',
        MealSlot.dinner => 'ctl00\$cphMain\$btnSaveDinner',
      };

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// The parts of a composite listing id.
class _ListingParts {
  const _ListingParts({
    required this.date,
    required this.slot,
    required this.optionId,
    required this.hallId,
    required this.priceRial,
  });

  final DateTime date;
  final MealSlot slot;
  final String optionId;
  final String hallId;
  final int priceRial;
}

/// Parses a composite listing id back into its parts.
_ListingParts? _parseListingId(String id) {
  final parts = id.split('|');
  if (parts.length != 4) return null;

  final date = DateTime.tryParse(parts[0]);
  if (date == null) return null;

  final slot = MealSlot.values.where((s) => s.name == parts[1]).firstOrNull;
  if (slot == null) return null;

  final hallId = parts[2];
  if (hallId.isEmpty) return null;

  return _ListingParts(
    date: DateTime.utc(date.year, date.month, date.day),
    slot: slot,
    hallId: hallId,
    optionId: parts[3],
    priceRial: 0,
  );
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
