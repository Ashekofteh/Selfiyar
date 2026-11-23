/// The `Reservation.aspx` page: the weekly menus, the reservations held, and
/// the booking and cancellation writes.
///
/// `Reservation.aspx` renders three grids (breakfast, lunch, dinner) of seven
/// days each, with a per-grid `btnSaveBreakfast` / `btnSaveLunch` /
/// `btnSaveDinner`. The grid control names are **identical in every week** —
/// `$ctl02$chkReserve` is the second *row*, not the second *date*. Which week a
/// post affects is decided by the `__VIEWSTATE` it carries (F12), so every
/// write reads the week that carries its target first.
library;

import '../../core/auth/session_manager.dart'
    show
        LoginRejectedException,
        PortalUnreachableException,
        ReservationLockedException;
import '../../core/meal/meal_invariant.dart';
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../core/shared/persian.dart';
import '../../transport/html_parsing.dart';
import '../../transport/http_transport.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// What a read-back page says about a meal.
enum _ReadbackState {
  /// The page carries the meal, and it is still held.
  stillHeld,

  /// The page carries the meal, and it is no longer held.
  gone,

  /// The page does not carry the meal's date, so it says nothing about it.
  notOnPage,
}

/// The reservation area of the portal.
class CullinanReservation extends CullinanArea {
  CullinanReservation({required super.transport, required super.clock});

  // ---------------------------------------------------------------- reads

  Future<Balance> fetchBalance(Session session) async {
    applySession(session);
    final page = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(page);
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
      fetchedAt: now,
      profileName: profileName,
    );
  }

  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async {
    applySession(session);
    final page = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(page);
    return CullinanParser.parseOfferings(page.body, date);
  }

  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async {
    applySession(session);
    final html = await _readMenuFor(session, date);
    return CullinanParser.parseMenu(html, date);
  }

  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    applySession(session);

    // The first read is what makes the time trustworthy: every portal
    // response carries a `Date` header, and the transport syncs the clock
    // from it.
    final current = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(current);

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
          CullinanPaths.reservation,
          body: {
            '__VIEWSTATE': viewState,
            '__VIEWSTATEGENERATOR': hiddenFieldValue(
              current.body,
              '__VIEWSTATEGENERATOR',
            ),
            '__EVENTTARGET': cullinanNextWeekEventTarget,
            '__EVENTARGUMENT': '',
          },
        );
        CullinanForms.rejectIfBounced(next);
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
    final current = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(current);

    if (_menuCovers(current.body, date)) return current.body;

    final next = await transport.post(
      session.account,
      CullinanPaths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          current.body,
          '__VIEWSTATEGENERATOR',
        ),
        '__EVENTTARGET': cullinanNextWeekEventTarget,
        '__EVENTARGUMENT': '',
      },
    );
    CullinanForms.rejectIfBounced(next);

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
    final current = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(current);

    if (_weekCovers(current.body, date)) return current;

    final next = await transport.post(
      session.account,
      CullinanPaths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          current.body,
          '__VIEWSTATEGENERATOR',
        ),
        '__EVENTTARGET': cullinanNextWeekEventTarget,
        '__EVENTARGUMENT': '',
      },
    );
    CullinanForms.rejectIfBounced(next);

    return next;
  }

  /// The page for the week that carries [date], reusing [page] when it
  /// already carries that week.
  ///
  /// A write is answered with the server's **default** week. When the target
  /// is in that week, the response *is* the confirmation: reading the same
  /// page again would be a second request for an answer already in hand.
  ///
  /// When the target is in the other week, the response still carries a valid
  /// `__VIEWSTATE`, so the next-week navigation can be posted against it
  /// instead of fetching the current week again. If that navigation does not
  /// produce a page carrying the target — a stale viewstate, a redirect, an
  /// error page — the old two-request read is used, so the result is never
  /// weaker than it was.
  ///
  /// The same reuse drives a batch: the page that confirmed one slot is the
  /// form for the next slot, and the page that opened a week is the form for
  /// its first write.
  Future<TransportResponse> _weekPageFor(
    Session session,
    TransportResponse page,
    DateTime date,
  ) async {
    if (_weekCovers(page.body, date)) return page;

    final viewState = hiddenFieldValue(page.body, '__VIEWSTATE');
    if (viewState.isNotEmpty) {
      try {
        final next = await transport.post(
          session.account,
          CullinanPaths.reservation,
          body: {
            '__VIEWSTATE': viewState,
            '__VIEWSTATEGENERATOR': hiddenFieldValue(
              page.body,
              '__VIEWSTATEGENERATOR',
            ),
            '__EVENTTARGET': cullinanNextWeekEventTarget,
            '__EVENTARGUMENT': '',
          },
        );
        CullinanForms.rejectIfBounced(next);
        if (_weekCovers(next.body, date)) return next;
      } catch (_) {
        // Fall through to the read that starts from a fresh page.
      }
    }

    return _readWeekFor(session, date);
  }

  /// Whether [html] is a complete reservation form for the target rows.
  ///
  /// A write response can serve as the next slot's form, but only when it is
  /// the reservation page itself: it must carry a viewstate, the slot's save
  /// button, a row for **every** offering in the target slot, and every row
  /// already posted in this batch must still be genuinely held. Anything else
  /// — an error page, the other week, a stripped-down page, or a page that
  /// lost a just-booked row — is re-read before the next write. Reusing a
  /// page that does not carry a booked row would present that row as
  /// unchecked, and an absent ASP.NET checkbox reads as *unchecked* — which
  /// cancels the meal the previous post just booked.
  bool _canPostFor(
    String html,
    List<MealOffering> offeringsForSlot,
    MealSlot slot, {
    List<MealOffering> requiredHeld = const [],
  }) {
    if (hiddenFieldValue(html, '__VIEWSTATE').isEmpty) return false;
    if (inputBySuffix(html, CullinanForms.gridSaveButtonSuffix(slot)) == null) {
      return false;
    }

    for (final offering in offeringsForSlot) {
      if (!_rowPresent(html, slot, offering.date)) return false;
    }
    for (final offering in requiredHeld) {
      if (!_pageHoldsSlot(html, offering.slot, offering.date)) return false;
    }
    return true;
  }

  /// Whether [html] shows a reservation genuinely held for the given [slot] and [date],
  /// regardless of whether the portal substituted the dish or hall.
  ///
  /// This check is used by [_canPostFor] to ensure the page carries previously booked
  /// rows as checked and held so that posting the next slot won't silently unreserve them.
  bool _pageHoldsSlot(String html, MealSlot slot, DateTime date) {
    for (final row in tableRows(html, CullinanForms.gridForSlot(slot))) {
      final rowDate = parseJalaliDate(row.cell(1));
      if (rowDate == null || !CullinanForms.sameDate(rowDate, date)) {
        continue;
      }
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return checkbox?.checked == true && CullinanForms.isGenuinelyHeld(row);
    }
    return false;
  }

  /// Whether the target slot's grid carries a row for [date].
  bool _rowPresent(String html, MealSlot slot, DateTime date) {
    for (final row in tableRows(html, CullinanForms.gridForSlot(slot))) {
      final rowDate = parseJalaliDate(row.cell(1));
      if (rowDate != null && CullinanForms.sameDate(rowDate, date)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [html] shows [offering] as a genuine, still-held reservation.
  ///
  /// **All four parts must match**: date, slot, hall id and option id. A row
  /// for the same date and slot holding a different dish is not this offering
  /// — the portal substituted it (C4), and counting it as success would tell
  /// the student they got a meal they did not ask for.
  static bool pageHolds(String html, MealOffering offering) {
    for (final row in tableRows(
      html,
      CullinanForms.gridForSlot(offering.slot),
    )) {
      final rowDate = parseJalaliDate(row.cell(1));
      if (rowDate == null || !CullinanForms.sameDate(rowDate, offering.date)) {
        continue;
      }

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      if (checkbox?.checked != true || !CullinanForms.isGenuinelyHeld(row)) {
        return false;
      }

      final self = selectBySuffix(row.raw, 'drpSelf');
      final food = selectBySuffix(row.raw, 'drpFood');
      if (self == null || food == null) return false;
      return self.selected?.value == offering.hall.id &&
          food.selected?.value == offering.option.id;
    }
    return false;
  }

  /// Whether the page carries a grid row for [date].
  ///
  /// The date is compared by its **civil** form, because the grids label
  /// their rows in Jalali and a Jalali label is a date, not an instant.
  static bool _weekCovers(String html, DateTime date) {
    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, CullinanForms.gridForSlot(slot))) {
        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null) continue;
        if (CullinanForms.sameDate(rowDate, date)) return true;
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

  Future<List<Reservation>> fetchReservations(Session session) async {
    applySession(session);

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
    final current = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(current);

    final reservations = CullinanParser.parseReservations(current.body);

    final next = await transport.post(
      session.account,
      CullinanPaths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          current.body,
          '__VIEWSTATEGENERATOR',
        ),
        '__EVENTTARGET': cullinanNextWeekEventTarget,
        '__EVENTARGUMENT': '',
      },
    );
    CullinanForms.rejectIfBounced(next);

    // The two weeks are parsed **separately**, not merged blindly: a date
    // that appears on neither simply is not held. And a meal is keyed by
    // (date, slot), so a meal that somehow appeared on both pages is
    // counted once.
    final seen = <String>{
      for (final reservation in reservations) _reservationKey(reservation),
    };
    for (final reservation in CullinanParser.parseReservations(next.body)) {
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

  /// The reservation for [offering] on [html], if the page shows one.
  ///
  /// Identity is **(date, slot, hall, option)**, not date and slot alone. The
  /// portal can save a different hall or dish for the same row; returning that
  /// row as this offering is the substitution bug (C4). A mismatched row is
  /// found by [_reservationAt] so the caller can report it.
  static Reservation? _reservationFor(String html, MealOffering offering) {
    for (final reservation in CullinanParser.parseReservations(html)) {
      if (offering.matches(reservation)) return reservation;
    }
    return null;
  }

  /// Whatever reservation the page shows for [offering]'s date and slot,
  /// regardless of the hall or dish it holds.
  ///
  /// This is how a substitution is detected: the requested pair is absent, but
  /// the row is not — the portal saved something else in its place.
  static Reservation? _reservationAt(String html, MealOffering offering) {
    for (final reservation in CullinanParser.parseReservations(html)) {
      if (reservation.slot == offering.slot &&
          CullinanForms.sameDate(reservation.date, offering.date)) {
        return reservation;
      }
    }
    return null;
  }

  /// Reads [offering]'s row, re-rendering it for the requested hall when the
  /// page was rendered for another one.
  ///
  /// The row's `drpFood` holds the option ids of **one** hall. Posting a dish
  /// id read for another hall makes the portal silently save that hall's first
  /// option — verified live 2026-11-22 — so the row must be re-rendered first,
  /// with a postback that carries no save button.
  ///
  /// Returns the page that is rendered for [offering]'s hall **and** offers
  /// its dish, or null when that state cannot be reached. Null means the pair
  /// is invalid and must be refused before any booking POST.
  Future<TransportResponse?> _ensureOfferingRendered(
    Session session,
    TransportResponse page,
    MealOffering offering,
  ) async {
    var current = page;
    var switched = false;

    for (var attempt = 0; attempt < 2; attempt++) {
      final row = CullinanParser.renderedReservationRow(
        current.body,
        slot: offering.slot,
        date: offering.date,
      );
      if (row == null) return null;

      final sameHall = row.hall.id == offering.hall.id;
      final offersDish = row.options.any((o) => o.id == offering.option.id);
      if (sameHall) return offersDish ? current : null;

      // The star of the substitution bug: the ids on this page belong to
      // another hall. A second failed attempt is not worth another request.
      if (switched) return null;

      final switchBody = CullinanParser.reservationHallSwitchBody(
        current.body,
        slot: offering.slot,
        date: offering.date,
        hallId: offering.hall.id,
      );
      if (switchBody == null) return null;

      final switchedPage = await transport.post(
        session.account,
        CullinanPaths.reservation,
        body: switchBody,
      );
      CullinanForms.rejectIfBounced(switchedPage);
      switched = true;

      // The postback normally answers with the same week, but the server's
      // default week can win. Re-open the target's week if it did.
      current = await _weekPageFor(session, switchedPage, offering.date);
    }

    return null;
  }

  /// Refuses when [html]'s own balance cannot cover [requiredRial].
  ///
  /// The balance label is on the reservation page, which every write path has
  /// to read anyway, so this check is free. A missing or unparseable label is
  /// a refusal, not a pass: no booking may be sent on a balance that was not
  /// read. Throwing before the first write keeps a batch atomic and keeps a
  /// single booking from being sent without funds.
  static void _requireBalance(String html, int requiredRial) {
    final text = labelText(html, 'lblCredit');
    final amount = text == null ? null : parseRial(text);
    if (amount == null) {
      throw const PortalUnreachableException('موجودی خوانده نشد.');
    }
    if (amount < requiredRial) {
      throw InsufficientBalanceException(
        balanceRial: amount,
        requiredRial: requiredRial,
      );
    }
  }

  /// What the page says this write needs from the balance.
  ///
  /// A new booking needs the meal's full price. A **modification** — the row
  /// is already genuinely held — needs only the price difference: the portal
  /// replaces the row's charged amount rather than charging it twice, and the
  /// row itself reports the old charge.
  static int _requiredRialFor(String html, MealOffering offering) {
    for (final row in tableRows(
      html,
      CullinanForms.gridForSlot(offering.slot),
    )) {
      final rowDate = parseJalaliDate(row.cell(1));
      if (rowDate == null || !CullinanForms.sameDate(rowDate, offering.date)) {
        continue;
      }
      if (!CullinanForms.isGenuinelyHeld(row)) break;
      final oldPrice = parseRial(row.cell(6)) ?? 0;
      final difference = offering.option.priceRial - oldPrice;
      return difference > 0 ? difference : 0;
    }
    return offering.option.priceRial;
  }

  // ---------------------------------------------------------------- writes

  Future<Reservation> reserve(Session session, MealOffering offering) async {
    applySession(session);

    // The post must go against the week that **carries the target**. The grid
    // control names are identical in every week, and the viewstate decides
    // which week's rows a post affects (F12) — so a booking for a next-week
    // date, posted against the current week's viewstate, names rows that do
    // not exist in the current week and books nothing.
    var page = await _readWeekFor(session, offering.date);

    // The row's food list belongs to the hall it was rendered for. If that is
    // not the requested hall, the requested dish id is meaningless here and
    // the portal would silently substitute the target hall's first option.
    // Re-render first, then require the page to actually offer the pair.
    final rendered = await _ensureOfferingRendered(session, page, offering);
    if (rendered == null) {
      if (_isLockedForSlot(page.body, offering)) {
        throw ReservationLockedException(
          'مهلت رزرو این تاریخ به پایان رسیده است.',
          date: offering.date,
          slot: offering.slot,
        );
      }
      throw ReservationNotOfferedException(offering: offering);
    }
    page = rendered;

    // The page that must be read to post is also the page that carries the
    // balance (`lblCredit`), so the affordability check costs nothing extra.
    // It runs **before** the write, against the portal's own figure — not a
    // cached estimate — so a booking the account cannot pay for is never sent.
    _requireBalance(page.body, _requiredRialFor(page.body, offering));

    final body = _reservationFormBody(page.body, offering);
    final response = await transport.post(
      session.account,
      CullinanPaths.reservation,
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
    // at all. The confirmation therefore reads the target's week, reusing the
    // write's response when it already carries that week.
    var confirmation = await _weekPageFor(session, response, offering.date);
    var found = _reservationFor(confirmation.body, offering);
    if (found == null) {
      // A candidate page is not proof: the write response can cover the week
      // and still be the pre-write render, or omit the row it just booked.
      // One fresh read decides before the app reports a locked date or a
      // failure, so a slow server render is not mistaken for a refusal.
      confirmation = await _readWeekFor(session, offering.date);
      found = _reservationFor(confirmation.body, offering);
    }
    if (found != null) return found;

    // The row exists but holds a different hall or dish. That is a real
    // booking — money moved — but not the one asked for, so it must not be
    // reported as a clean success (C4).
    final substituted = _reservationAt(confirmation.body, offering);
    if (substituted != null) {
      throw ReservationSubstitutedException(
        requested: offering,
        saved: substituted,
      );
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

  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings, {
    int? requiredBalanceRial,
  }) async {
    if (offerings.isEmpty) return const [];
    applySession(session);

    final currentWeek = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(currentWeek);

    // The balance label and the write form are the same page. Checking the
    // batch's total here, against the page that is about to be posted, makes
    // the refusal atomic without a separate balance read of the same HTML.
    if (requiredBalanceRial != null) {
      _requireBalance(currentWeek.body, requiredBalanceRial);
    }

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
    final rejected = <MealOffering>[];
    MealOffering? lockedOffering;

    Future<void> submitWeek(
      List<MealOffering> weekOfferings,
      DateTime sampleDate, {
      required TransportResponse page,
    }) async {
      if (weekOfferings.isEmpty) return;

      // The page that opened the week is the form for the first write, and
      // each write response is the form for the next slot. A browser does the
      // same: save one grid, the server re-renders the page, then edit the
      // next grid and save it. Reading the week again between slots spends a
      // round trip for a form already in hand. [_canPostFor] guards the
      // reuse: a response that is not the full form is re-read first, because
      // posting a page that lacks a booked row would present it as unchecked
      // and cancel it.
      var base = page;
      final posted = <MealOffering>[];
      final accepted = <MealOffering>[];

      final slots = [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner];
      for (final slot in slots) {
        final requestedForSlot = weekOfferings
            .where((o) => o.slot == slot)
            .toList();
        if (requestedForSlot.isEmpty) continue;

        if (!_canPostFor(
          base.body,
          requestedForSlot,
          slot,
          requiredHeld: posted,
        )) {
          // A write is answered with the server's default week, so a
          // next-week write response is one navigation post away from the
          // form the next slot needs. A page that still is not the complete
          // form after that navigation is read from a fresh GET.
          final page = await _weekPageFor(session, base, sampleDate);
          if (_canPostFor(
            page.body,
            requestedForSlot,
            slot,
            requiredHeld: posted,
          )) {
            base = page;
          } else {
            final reread = await _readWeekFor(session, sampleDate);
            if (!_canPostFor(
              reread.body,
              requestedForSlot,
              slot,
              requiredHeld: posted,
            )) {
              throw const PortalUnreachableException(
                'فرم رزرو کامل نبود؛ برای جلوگیری از لغو رزروهای دیگر، '
                'نوشتن انجام نشد.',
              );
            }
            base = reread;
          }
        }

        // Each target row must be rendered for the hall it names, and must
        // actually offer the requested dish. A pair the page does not offer is
        // dropped rather than posted: the portal would silently save that
        // hall's first option instead (C3). Dropped offerings are simply not
        // confirmed, so the service reports them as failures.
        final offeringsForSlot = <MealOffering>[];
        for (final offering in requestedForSlot) {
          final ensured = await _ensureOfferingRendered(session, base, offering);
          if (ensured == null) {
            rejected.add(offering);
            continue;
          }
          base = ensured;
          offeringsForSlot.add(offering);
        }
        if (offeringsForSlot.isEmpty) continue;

        final body = _batchReservationFormBody(
          base.body,
          offeringsForSlot,
          slot,
        );
        final response = await transport.post(
          session.account,
          CullinanPaths.reservation,
          body: body,
        );
        CullinanForms.rejectIfBounced(response);
        base = response;
        posted.addAll(offeringsForSlot);
        accepted.addAll(offeringsForSlot);
      }

      var confirmation = await _weekPageFor(session, base, sampleDate);
      // A write response is a candidate, not proof: it can cover the week and
      // still omit the row this batch just booked. Only a page that shows every
      // accepted meal as genuinely held can confirm the batch. One fresh read
      // is spent when the candidate cannot.
      if (!accepted.every((o) => _pageHoldsSlot(confirmation.body, o.slot, o.date))) {
        confirmation = await _readWeekFor(session, sampleDate);
      }
      final reservations = CullinanParser.parseReservations(confirmation.body);

      for (final offering in accepted) {
        final match = reservations
            .where(
              (r) =>
                  r.slot == offering.slot &&
                  CullinanForms.sameDate(r.date, offering.date),
            )
            .firstOrNull;
        if (match != null) {
          // The match can be a substitution (same row, different hall/dish).
          // It is returned so the service can report what was actually saved
          // instead of counting it as a clean success (C4).
          confirmed.add(match);
        } else if (_isLockedForSlot(confirmation.body, offering)) {
          lockedOffering ??= offering;
        }
      }
    }

    if (currentOfferings.isNotEmpty) {
      try {
        await submitWeek(
          currentOfferings,
          currentOfferings.first.date,
          page: currentWeek,
        );
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
          // The initial GET already carries a valid viewstate, so opening the
          // other week is one navigation post rather than a fresh GET plus
          // the same post.
          final weekPage = await _weekPageFor(session, currentWeek, first.date);
          remaining.removeWhere((o) {
            if (_weekCovers(weekPage.body, o.date)) {
              group.add(o);
              return true;
            }
            return false;
          });
          await submitWeek(group, first.date, page: weekPage);
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
      if (rejected.isNotEmpty) {
        throw ReservationNotOfferedException(offering: rejected.first);
      }
      throw const PortalUnreachableException('رزرو تأیید نشد.');
    }

    return confirmed;
  }

  /// True when the portal still renders this date's row as locked.
  ///
  /// The lock is the server's own signal, and it survives a refused post.
  bool _isLockedForSlot(String html, MealOffering offering) {
    final gridId = CullinanForms.gridForSlot(offering.slot);

    for (final row in tableRows(html, gridId)) {
      if (row.cells.length < 4) continue;
      final date = parseJalaliDate(row.cell(1));
      if (date == null || !CullinanForms.sameDate(date, offering.date)) {
        continue;
      }

      // The checkbox is the server's lock marker.
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return checkbox?.disabled ?? false;
    }

    return false;
  }

  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    applySession(session);

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
    final postResponse = await transport.post(
      session.account,
      CullinanPaths.reservation,
      body: body,
    );
    // A bounced session is the one case where the post itself says the
    // write did not happen. The silent refusal of a locked date (F14) is not
    // like this — that one answers a plain `200` and is caught by the
    // read-back below.
    CullinanForms.rejectIfBounced(postResponse);

    // The post is **not** the outcome.
    //
    // A locked date is refused **silently** (F14): the server discards the
    // post, the response is a plain `200`, and nothing on the page changes. So
    // a cancel that trusted the status code would report success for a
    // cancellation that never happened, and the app would hide a meal the
    // student still holds (F63).
    //
    // The portal is read back instead, exactly as the booking path does.
    final confirmation = await _weekPageFor(session, postResponse, ref.date);
    final readback = _readbackOf(confirmation.body, ref);

    switch (readback) {
      case _ReadbackState.stillHeld:
        // The meal is still there. The only reason the portal keeps it is
        // that the date has locked — the row is rendered `disabled` and the
        // post was ignored.
        return const CancelRefused('مهلت رزرو این تاریخ به پایان رسیده است.');
      case _ReadbackState.gone:
        return const CancelSucceeded();
      case _ReadbackState.notOnPage:
        // The read-back page does not carry the target date at all, so it
        // says **nothing** about the meal. Reporting success here would empty
        // the mirror for a cancel that may never have happened (F65).
        return const CancelAmbiguous('وضعیت رزرو در سایت تایید نشد.');
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
    for (final row in tableRows(html, CullinanForms.gridForSlot(ref.slot))) {
      if (row.cells.length < 7) continue;

      final date = parseJalaliDate(row.cell(1));
      if (date == null || !CullinanForms.sameDate(date, ref.date)) continue;

      // The row is on the page, so the page can speak about it.
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      if (checkbox == null || !checkbox.checked) {
        return _ReadbackState.gone;
      }

      // The same two markers a held meal has everywhere else: the row is
      // `checked`, and it carries a non-zero amount (F13). A row the portal
      // merely echoes as `checked` is not a reservation, so the amount is
      // what tells the two apart.
      return CullinanForms.isGenuinelyHeld(row)
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
    final body = CullinanForms.viewState(html);

    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, CullinanForms.gridForSlot(slot))) {
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

        final isTarget =
            slot == ref.slot && CullinanForms.sameDate(date, ref.date);

        // The target's checkbox is **omitted**, which is how it is unchecked.
        // Every other row is posted as the page renders it, so the account's
        // other meals survive.
        if (!isTarget &&
            checkbox.checked &&
            CullinanForms.isGenuinelyHeld(row)) {
          body[checkbox.name] = 'on';
        }
      }
    }

    final saveCancelBtnName = CullinanForms.gridSaveButton(ref.slot);
    final saveCancelBtnInput = inputBySuffix(
      html,
      CullinanForms.gridSaveButtonSuffix(ref.slot),
    );
    body[saveCancelBtnName] = saveCancelBtnInput?.value.isNotEmpty == true
        ? saveCancelBtnInput!.value
        : 'ذخیره';
    return body;
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
  ) => _batchReservationFormBody(html, [offering], offering.slot);

  Map<String, String> _batchReservationFormBody(
    String html,
    List<MealOffering> offeringsForSlot,
    MealSlot targetSlot,
  ) {
    final body = CullinanForms.viewState(html);

    // Every row of every grid, so the account's other meals survive the post.
    for (final slot in CullinanParser.reservationSlots) {
      for (final row in tableRows(html, CullinanForms.gridForSlot(slot))) {
        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        final self = selectBySuffix(row.raw, 'drpSelf');
        final food = selectBySuffix(row.raw, 'drpFood');
        final count = selectBySuffix(row.raw, 'drpFoodCount');
        if (checkbox == null || self == null || food == null || count == null) {
          continue;
        }

        final rowDate = parseJalaliDate(row.cell(1));
        final matchingOffering = (slot == targetSlot && rowDate != null)
            ? offeringsForSlot
                  .where((o) => CullinanForms.sameDate(o.date, rowDate))
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

        if (checkbox.checked && CullinanForms.isGenuinelyHeld(row)) {
          body[checkbox.name] = 'on';
        }
      }
    }

    final saveBtnName = CullinanForms.gridSaveButton(targetSlot);
    final saveBtnInput = inputBySuffix(
      html,
      CullinanForms.gridSaveButtonSuffix(targetSlot),
    );
    body[saveBtnName] = saveBtnInput?.value.isNotEmpty == true
        ? saveBtnInput!.value
        : 'ذخیره';
    return body;
  }
}
