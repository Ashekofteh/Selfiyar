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

  // ---------------------------------------------------------------- writes

  Future<Reservation> reserve(Session session, MealOffering offering) async {
    applySession(session);

    // The post must go against the week that **carries the target**. The grid
    // control names are identical in every week, and the viewstate decides
    // which week's rows a post affects (F12) — so a booking for a next-week
    // date, posted against the current week's viewstate, names rows that do
    // not exist in the current week and books nothing.
    final page = await _readWeekFor(session, offering.date);

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
    // at all. The confirmation therefore re-reads the target's week.
    final confirmation = await _readWeekFor(session, offering.date);
    final reservations = CullinanParser.parseReservations(confirmation.body);
    for (final reservation in reservations) {
      if (reservation.slot == offering.slot &&
          CullinanForms.sameDate(reservation.date, offering.date)) {
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

  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings,
  ) async {
    if (offerings.isEmpty) return const [];
    applySession(session);

    final currentWeek = await transport.get(
      session.account,
      CullinanPaths.reservation,
    );
    CullinanForms.rejectIfBounced(currentWeek);

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
        final offeringsForSlot = weekOfferings
            .where((o) => o.slot == slot)
            .toList();
        if (offeringsForSlot.isEmpty) continue;

        final page = await _readWeekFor(session, sampleDate);
        final body = _batchReservationFormBody(
          page.body,
          offeringsForSlot,
          slot,
        );
        final response = await transport.post(
          session.account,
          CullinanPaths.reservation,
          body: body,
        );
        CullinanForms.rejectIfBounced(response);
      }

      final confirmation = await _readWeekFor(session, sampleDate);
      final reservations = CullinanParser.parseReservations(confirmation.body);

      for (final offering in weekOfferings) {
        final match = reservations
            .where(
              (r) =>
                  r.slot == offering.slot &&
                  CullinanForms.sameDate(r.date, offering.date),
            )
            .firstOrNull;
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
    final confirmation = await _readWeekFor(session, ref.date);
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
