/// The `FoodBasketBuy.aspx` page: the listings, the date filter, and the
/// irreversible purchase.
///
/// The page renders one row per (date, meal slot) for a single date, chosen by
/// the `txtDate` filter. Each row carries a `chkReserve` checkbox, a hall
/// dropdown, a **food dropdown holding the purchasable options**, a count
/// dropdown, a price, and a shared `btnSave`.
///
/// The important consequence: **the individual listings live in the food
/// dropdown, not in the grid rows.** A row for lunch carried two options
/// (`62726` and `62729`), each with its own menu item and price. A "listing" is
/// therefore `(date, slot, option id)` — which is why
/// [Listing.compositeListingId] exists.
library;

import '../../core/auth/session_manager.dart'
    show LoginRejectedException, PortalUnreachableException;
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../core/shared/persian.dart';
import '../../transport/html_parsing.dart';
import '../../transport/http_transport.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// The basket-buy area of the portal.
class CullinanBasketBuy extends CullinanArea {
  CullinanBasketBuy({required super.transport, required super.clock});

  /// The WebForms state the last buy-page response carried.
  ///
  /// A poll normally needs **one** request. The page's `__VIEWSTATE` is the
  /// form state the date-filter postback must carry, and the portal hands back
  /// a fresh one with every response — so the state from the previous poll is
  /// exactly what the next poll needs. Caching it means the poll can go
  /// straight to the filtered POST instead of spending a GET on a default
  /// date it is about to discard. Since a hunt polls every two seconds, that
  /// halves the traffic and, more importantly, halves the request pattern the
  /// portal sees.
  ///
  /// The cache is bound to the session that produced it (see
  /// [_BasketFormState.belongsTo]): viewstate is signed against the session,
  /// so state from a previous login is worse than no state at all.
  _BasketFormState? _formState;

  Future<BasketPage> fetchBasket(
    Session session, {
    String? cursor,
    List<HallId> halls = const [],
    MealSlot? slot,
  }) async {
    applySession(session);
    // The basket page is filtered by date, and the cursor is the Jalali date
    // the caller wants. Verified live 2026-10-20: the page's own `txtDate`
    // field agrees with the rows it renders, so a GET alone returns the page's
    // default date — reading it for any other date requires the filter
    // postback.
    final wanted = cursor ?? todayJalali;

    final html = await _readBasketHtml(session, wanted);
    if (html == null) {
      // The portal refused the filter twice. Reporting an empty page keeps the
      // hunt from acting on a page it could not read; the next poll starts
      // again from a fresh GET.
      return const BasketPage(listings: []);
    }

    final listings = _parseBasket(html, wanted);
    if (halls.isEmpty || slot == null) {
      return BasketPage(listings: listings);
    }

    // The page renders `drpFood` for one hall per row. A hunt that named two
    // halls would otherwise see only the one the portal defaulted to, and the
    // second hall's listings would be invisible. A bounded number of
    // read-only `drpSelf` postbacks shows the prioritized halls, merging what
    // each render offered.
    final merged = <Listing>[...listings];
    final seen = <ListingId>{for (final listing in listings) listing.id};
    var page = html;
    var switches = 0;

    for (final hallId in halls.take(2)) {
      if (switches >= 2) break;

      final switchBody = CullinanParser.hallSwitchBody(
        page,
        slot: slot,
        hallId: hallId,
        date: wanted,
      );
      if (switchBody == null) continue;

      final switched = await _postHallSwitch(session, switchBody, wanted);
      switches++;
      if (switched == null) continue;

      page = switched.body;
      for (final listing in _parseBasket(page, wanted)) {
        if (seen.add(listing.id)) merged.add(listing);
      }
    }

    return BasketPage(listings: merged);
  }

  /// Reads the buy page for [wanted] and returns its HTML, or null when the
  /// portal refused the date filter twice.
  Future<String?> _readBasketHtml(Session session, String wanted) async {
    // The fast path: one POST carrying the state from the previous response.
    // A null answer means the state was refused (or the response was not a buy
    // page at all), and the GET below re-establishes it. That retry happens at
    // most once per call, so a broken portal cannot turn a poll into a burst.
    final cached = _formState;
    if (cached != null) {
      if (cached.belongsTo(session) && cached.isUsable) {
        final refreshed = await _postDateFilter(session, wanted, cached);
        if (refreshed != null) {
          return refreshed.body;
        }
      } else {
        // A different account/session, or state that could never be posted.
        _formState = null;
      }
    }

    final first = await transport.get(session.account, CullinanPaths.basketBuy);
    _rejectIfBounced(first);

    final state = _BasketFormState.from(session, first.body);
    _formState = state.isUsable ? state : null;

    if (CullinanParser.buyPageDate(first.body) == wanted) {
      return first.body;
    }

    // A page with no usable state cannot be posted, and because its date did
    // not match [wanted] (checked above), returning it would label rows with
    // the wrong date (L3).
    if (!state.isUsable) {
      return null;
    }

    final filtered = await _postDateFilter(session, wanted, state);
    return filtered?.body;
  }

  /// Posts a read-only `drpSelf` postback and returns the re-rendered page.
  ///
  /// Carries no save button, so it cannot buy. A login bounce is thrown; any
  /// other non-page response, or a page that is no longer for [wanted],
  /// returns null and drops the cached form state.
  ///
  /// The switch postback carries `txtDate` too, so a silently ignored switch
  /// can answer with the default date's grid. That page's rows must not be
  /// merged under [wanted] (L3).
  Future<TransportResponse?> _postHallSwitch(
    Session session,
    Map<String, String> body,
    String wanted,
  ) async {
    final response = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      _formState = null;
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    if (!_isRenderedPage(response) ||
        CullinanParser.buyPageDate(response.body) != wanted) {
      _formState = null;
      return null;
    }

    final next = _BasketFormState.from(session, response.body);
    _formState = next.isUsable ? next : null;
    return response;
  }

  /// Posts the buy page's date filter, returning the rendered page or null
  /// when [state] was stale/expired.
  ///
  /// No exception is thrown for a stale state: it is an expected outcome of
  /// caching (the portal recycles sessions and application restarts), and the
  /// caller knows how to repair it with one GET. A login bounce *is* thrown,
  /// because that is the one failure the transport's session manager must see.
  Future<TransportResponse?> _postDateFilter(
    Session session,
    String wanted,
    _BasketFormState state,
  ) async {
    final response = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
      body: state.postBody(wanted),
    );

    if (response.looksLikeLoginPage) {
      // The session is gone; its cached state is worthless too.
      _formState = null;
      throw const LoginRejectedException('نشست منقضی شده است.');
    }

    if (!_isRenderedPage(response)) {
      _formState = null;
      return null;
    }

    // The postback is only an answer for the requested date. The portal
    // refuses a stale filter silently now and then, and `_isRenderedPage`
    // would accept the default date's page: parsing its rows under the
    // requested date labels them with a date they do not carry (L3). A
    // mismatch is treated like a refused postback, so the caller re-reads and
    // retries once.
    if (CullinanParser.buyPageDate(response.body) != wanted) {
      _formState = null;
      return null;
    }

    // The response is the state the next poll must post. This is what makes
    // the single-POST cadence self-sustaining rather than a one-shot saving.
    final next = _BasketFormState.from(session, response.body);
    _formState = next.isUsable ? next : null;
    return response;
  }

  /// Whether a response is a rendered buy page rather than an error page.
  ///
  /// The transport does not throw on an HTTP error, and ASP.NET answers a
  /// rejected viewstate with a 200 error page as often as with a 500 — so
  /// "success" alone cannot be trusted. A page the following poll can post
  /// must have both its date field and its viewstate.
  static bool _isRenderedPage(TransportResponse response) {
    if (!response.isSuccess) return false;
    if (CullinanParser.buyPageDate(response.body) == null) return false;
    if (hiddenFieldValue(response.body, '__VIEWSTATE').isEmpty) return false;
    return !CullinanForms.looksLikeAspError(response.body);
  }

  /// Throws when a read came back as the login form, dropping cached state.
  void _rejectIfBounced(TransportResponse response) {
    if (!response.looksLikeLoginPage) return;
    _formState = null;
    throw const LoginRejectedException('نشست منقضی شده است.');
  }

  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    applySession(session);
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
    } finally {
      // A claim changes the page's server-side form state. The cached state
      // predates that change, so the next poll must re-read it rather than
      // post against a page that no longer exists.
      _formState = null;
    }
  }

  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async {
    final html = await _readBuyPage(session, date);
    return CullinanParser.heldOnBuyPage(html, optionId);
  }

  /// Reads the buy page filtered to [date], returning its HTML.
  Future<String> _readBuyPage(Session session, DateTime date) async {
    final wanted = CullinanForms.jalaliOf(date);
    final first = await transport.get(session.account, CullinanPaths.basketBuy);
    _rejectIfBounced(first);
    if (CullinanParser.buyPageDate(first.body) == wanted) return first.body;

    final filtered = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
      body: _BasketFormState.from(session, first.body).postBody(wanted),
    );
    _rejectIfBounced(filtered);

    // The claim must read the date it is about to buy from. If the portal
    // ignored the filter, this page is the default date's grid — and posting
    // its rows with `txtDate` set to [wanted] would name a date the page never
    // offered. Refuse before any write rather than parse an unintended date
    // (L3).
    if (!_isRenderedPage(filtered) ||
        CullinanParser.buyPageDate(filtered.body) != wanted) {
      throw PortalUnreachableException(
        'صفحهٔ سبد برای تاریخ ${CullinanForms.jalaliOf(date)} بارگذاری نشد.',
      );
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
    final wantedDate = CullinanForms.jalaliOf(parts.date);
    var page = html;

    // The page renders one hall per row. When the listing names another hall,
    // the food ids on this page belong to the selected hall and posting them
    // with the listing's hall makes the portal silently substitute that
    // hall's first option. A read-only `drpSelf` postback re-renders the row
    // first. It carries no `btnSave` and no target checkbox, so it cannot buy.
    var offered = _offeredListing(page, parts);
    if (offered == null) {
      final switchBody = CullinanParser.hallSwitchBody(
        page,
        slot: parts.slot,
        hallId: parts.hallId,
        date: wantedDate,
      );
      if (switchBody != null) {
        final TransportResponse switched;
        try {
          switched = await transport.post(
            session.account,
            CullinanPaths.basketBuy,
            body: switchBody,
          );
        } on TransportException {
          // Nothing was bought: the request carried no save button. Reporting
          // this as ambiguous would tombstone a listing that is still there.
          return const ClaimRejected('بارگذاری سلف موردنظر ناموفق بود.');
        }
        if (switched.looksLikeLoginPage) {
          return const ClaimRejected('نشست منقضی شده است.');
        }
        if (!_isRenderedPage(switched) ||
            CullinanParser.buyPageDate(switched.body) != wantedDate) {
          return const ClaimRejected(
            'صفحهٔ سبد برای سلف موردنظر بارگذاری نشد.',
          );
        }
        page = switched.body;
        offered = _offeredListing(page, parts);
      }
    }

    // Only a listing the page itself offers, in the hall whose food list it
    // rendered, is claimable. A closed row is not: the parser omits it, and
    // `claimFormBody` refuses it as the second layer.
    if (offered == null) {
      return const ClaimRejected('این آگهی دیگر در دسترس نیست.');
    }

    final body = CullinanParser.claimFormBody(
      page,
      listingId: parts.optionId,
      hallId: parts.hallId,
      date: wantedDate,
    );
    if (body == null) {
      return const ClaimRejected('این آگهی در صفحهٔ سبد قابل خرید نیست.');
    }

    final response = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
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
      return ClaimSucceeded(
        Reservation(
          id: offered.id,
          date: parts.date,
          slot: parts.slot,
          hall: offered.hall,
          option: offered.option,
          state: ReservationState.active,
        ),
      );
    }

    // The page neither reported an error nor showed the meal as held. That is
    // not proof of failure — the response may not have rendered the final
    // state — so it must not be reported as a rejection, which would invite a
    // second, irreversible purchase.
    return const ClaimAmbiguous('پاسخ سامانه نتیجه خرید را روشن نکرد.');
  }

  /// The buyable listing [page] renders for [parts], or null.
  ///
  /// Matching on the slot, option, and hall together is what rejects a hall-1
  /// option id posted against a hall-2 page before any request is sent.
  Listing? _offeredListing(String page, _ListingParts parts) {
    for (final listing in CullinanParser.parseBasket(page, parts.date)) {
      if (listing.slot == parts.slot &&
          listing.option.id == parts.optionId &&
          listing.hall.id == parts.hallId) {
        return listing;
      }
    }
    return null;
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

  /// Parses the basket buy grid into listings.
  List<Listing> _parseBasket(String html, String jalaliDate) {
    final date = parseJalaliDate(jalaliDate);
    if (date == null) return const [];
    return CullinanParser.parseBasket(html, date);
  }
}

/// The parts of a composite listing id.
class _ListingParts {
  const _ListingParts({
    required this.date,
    required this.slot,
    required this.optionId,
    required this.hallId,
  });

  final DateTime date;
  final MealSlot slot;
  final String optionId;
  final String hallId;
}

/// The WebForms form state of one buy-page response.
///
/// ASP.NET viewstate is signed against the session, so this carries the
/// account and session identity it came from. Posting state under a different
/// session is rejected at best and reads as an expired session at worst;
/// [belongsTo] is what makes the cache safe to keep across polls and logins.
class _BasketFormState {
  const _BasketFormState({
    required this.account,
    required this.sessionKey,
    required this.viewState,
    required this.viewStateGenerator,
    required this.eventValidation,
    required this.viewStateEncrypted,
  });

  factory _BasketFormState.from(Session session, String html) =>
      _BasketFormState(
        account: session.account,
        sessionKey: _sessionKey(session),
        viewState: hiddenFieldValue(html, '__VIEWSTATE'),
        viewStateGenerator: hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
        eventValidation: hiddenFieldValue(html, '__EVENTVALIDATION'),
        viewStateEncrypted: hiddenFieldValue(html, '__VIEWSTATEENCRYPTED'),
      );

  final AccountId account;
  final String sessionKey;
  final String viewState;
  final String viewStateGenerator;
  final String eventValidation;
  final String viewStateEncrypted;

  /// Whether this state is postable at all.
  bool get isUsable => viewState.isNotEmpty;

  /// Whether this state was produced by [session].
  ///
  /// The `ASP.NET_SessionId` is the strongest identity: a re-login mints a new
  /// one, and viewstate cannot cross it. A session restored without that
  /// cookie still has [Session.establishedAt], which changes on a fresh login,
  /// so it serves as the fallback key.
  bool belongsTo(Session session) =>
      account == session.account && sessionKey == _sessionKey(session);

  /// The date-filter postback's body.
  ///
  /// `__EVENTVALIDATION` travels only when the page carries it: on a page
  /// without event validation an extra field is harmless to ASP.NET, but the
  /// empty value other code sends is not what the portal's page rendered.
  Map<String, String> postBody(String jalaliDate) => {
    '__VIEWSTATE': viewState,
    if (viewStateGenerator.isNotEmpty)
      '__VIEWSTATEGENERATOR': viewStateGenerator,
    if (viewStateEncrypted.isNotEmpty)
      '__VIEWSTATEENCRYPTED': viewStateEncrypted,
    if (eventValidation.isNotEmpty) '__EVENTVALIDATION': eventValidation,
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
    'ctl00\$cphMain\$txtDate': jalaliDate,
    'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
    'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
  };

  static String _sessionKey(Session session) {
    final id = session.cookies['ASP.NET_SessionId'];
    if (id != null && id.isNotEmpty) return 'session:$id';
    return 'established:${session.establishedAt.toUtc().toIso8601String()}';
  }
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
  );
}
