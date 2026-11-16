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

import '../../core/auth/session_manager.dart' show LoginRejectedException;
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

  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    applySession(session);
    // The basket page is filtered by date, and the cursor is the Jalali date
    // the caller wants. Verified live 2026-10-20: the page's own `txtDate`
    // field agrees with the rows it renders, so a GET alone returns the page's
    // default date — reading it for any other date requires the filter
    // postback.
    final wanted = cursor ?? todayJalali;
    final first = await transport.get(session.account, CullinanPaths.basketBuy);
    CullinanForms.rejectIfBounced(first);

    if (CullinanParser.buyPageDate(first.body) == wanted) {
      return BasketPage(listings: _parseBasket(first.body, wanted));
    }

    final filtered = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          first.body,
          '__VIEWSTATEGENERATOR',
        ),
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
    if (CullinanParser.buyPageDate(first.body) == wanted) return first.body;

    final filtered = await transport.post(
      session.account,
      CullinanPaths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(
          first.body,
          '__VIEWSTATEGENERATOR',
        ),
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
      date: CullinanForms.jalaliOf(parts.date),
    );

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
        ),
      );
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
