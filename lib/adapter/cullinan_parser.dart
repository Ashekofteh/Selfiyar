/// Parsing of the Cullinan portal's HTML into domain objects.
///
/// Split out from the client so it can be tested directly against captured
/// pages, with no transport and no network. The parsers are pure functions of
/// HTML text, which is what makes them verifiable: every assertion in
/// `cullinan_parser_test.dart` is a claim about real portal markup.
///
/// ## The page shapes this understands
///
/// `FoodBasketBuy.aspx` — one row per (date, meal slot), filtered by date.
/// The purchasable meals live in the row's **food dropdown**, one `<option>`
/// per listing, each with its own menu id and price. A row for lunch was seen
/// carrying two options, so a row is a slot and an option is a listing.
///
/// `Reservation.aspx` — three grids (breakfast, lunch, dinner) of seven days.
/// A held meal is the row whose `chkReserve` checkbox is `checked`; a locked
/// date is the row whose checkbox is `disabled`.
///
/// The portal is ASP.NET WebForms, so control names carry a `ctl00$cphMain$...`
/// prefix and row indices (`$ctl02`, `$ctl03`, ...). Names are matched by
/// suffix, because those indices shift whenever the portal changes a grid.
library;

import '../core/models.dart';
import '../core/persian.dart';
import '../core/portal.dart';
import '../core/top_up.dart';
import '../transport/html_parsing.dart';

/// The Persian meal names the portal renders.
const Map<String, MealSlot> mealSlotByPersianName = {
  'صبحانه': MealSlot.breakfast,
  'ناهار': MealSlot.lunch,
  'شام': MealSlot.dinner,
};

/// Parses the portal's pages.
abstract final class CullinanParser {
  /// The reservation grid for a meal slot.
  static String gridIdFor(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'grdReservationBreakfast',
        MealSlot.lunch => 'grdReservationLunch',
        MealSlot.dinner => 'grdReservationDinner',
      };

  /// The save button for a meal slot's grid.
  static String saveButtonFor(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'ctl00\$cphMain\$btnSaveBreakfast',
        MealSlot.lunch => 'ctl00\$cphMain\$btnSaveLunch',
        MealSlot.dinner => 'ctl00\$cphMain\$btnSaveDinner',
      };

  /// The meal slots a reservation page carries, in grid order.
  static const List<MealSlot> reservationSlots = [
    MealSlot.breakfast,
    MealSlot.lunch,
    MealSlot.dinner,
  ];

  /// Parses the reservation grids into the meals available on [date].
  ///
  /// A row with no service renders `-` in the hall and food dropdowns and
  /// contributes nothing. A locked date still lists its options — the lock is
  /// expressed by the row's checkbox being `disabled` — so [MealOffering
  /// .reservable] reports it rather than hiding the option.
  ///
  /// Only the **selected** hall is reported per offering: a held meal names
  /// the hall it is in. The *set* of halls that serve a meal is a different
  /// question, and [parseMenu] answers it.
  static List<MealOffering> parseOfferings(String html, DateTime date) {
    final offerings = <MealOffering>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null || !_sameDate(rowDate, date)) continue;

        final food = selectBySuffix(row.raw, 'drpFood');
        final self = selectBySuffix(row.raw, 'drpSelf');
        if (food == null || self == null) continue;

        final hallValue = self.selected?.value ?? '-1';
        if (hallValue == '-1') continue;

        final reservable = !_isDisabled(row.raw, 'chkReserve');

        for (final option in food.options) {
          if (option.value == '-1') continue;
          final price = parseRial(option.text);
          if (price == null) continue;

          offerings.add(MealOffering(
            date: rowDate,
            slot: slot,
            hall: Hall(id: hallValue, name: self.selected?.text ?? ''),
            option: MenuOption(
              id: option.value,
              name: dishName(option.text),
              priceRial: price,
            ),
            reservable: reservable,
          ));
        }
      }
    }

    return offerings;
  }

  /// Parses the reservation grids into the **official menu** for [date].
  ///
  /// ## Why this exists, and why the menu and not the marketplace
  ///
  /// The portal answers two different questions with two different pages:
  ///
  ///  * The **weekly menu** (`Reservation.aspx`) names the halls that *serve*
  ///    a meal and the dishes the university offers for it.
  ///  * The **buy page** (`FoodBasketBuy.aspx`) names the halls that have
  ///    *released* a meal into the marketplace.
  ///
  /// The buy page's set is a strict **subset** of the menu's: a hall appears
  /// there only once one of its students has released that meal. So a list
  /// built from the buy page hides every hall that has not yet released
  /// anything — and a hall that has not released anything *yet* is exactly
  /// the one a hunt needs to be able to name, because the market fills up
  /// **during** the hunt window. A "prefer Central, fall back to Engineering"
  /// hunt that could not name Engineering would never use the fallback.
  ///
  /// The hunt's setup therefore reads this page, and the marketplace remains
  /// the source of *listings* only.
  ///
  /// ## The dishes are the same in every hall
  ///
  /// The menu publishes one dish list per (date, slot) and a set of halls that
  /// serve it. The dishes are not per-hall, so this does not build a
  /// hall-to-dish map: the hall list and the dish list are independent, and
  /// the pairing is implied.
  ///
  /// A row with no service renders `-` in both dropdowns and contributes
  /// nothing. Returns an empty list when the page carries no row for [date].
  static List<MealMenu> parseMenu(String html, DateTime date) {
    final menus = <MealMenu>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null || !_sameDate(rowDate, date)) continue;

        final menu = _menuFromRow(row.raw, rowDate, slot);
        if (menu != null) menus.add(menu);
      }
    }

    return menus;
  }

  /// Parses **every** date the page carries.
  ///
  /// The weekly page is a whole week of grids, so one read answers the menu
  /// for seven dates at once. The booking screen used to read one page per
  /// date — seven reads, and fourteen once the week boundary is crossed — to
  /// answer a question a single read already answers. Every request the
  /// portal sees is a request pattern, so the reads are collapsed.
  ///
  /// The dates come back in the order the page lists them.
  static List<MealMenu> parseMenus(String html) {
    final menus = <MealMenu>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null) continue;

        final menu = _menuFromRow(row.raw, rowDate, slot);
        if (menu != null) menus.add(menu);
      }
    }

    return menus;
  }

  /// The menu one grid row describes, or null when the row serves nothing.
  static MealMenu? _menuFromRow(
    String rowHtml,
    DateTime rowDate,
    MealSlot slot,
  ) {
    final food = selectBySuffix(rowHtml, 'drpFood');
    final self = selectBySuffix(rowHtml, 'drpSelf');
    if (food == null || self == null) return null;

    // Every hall in the dropdown, not just the selected one.
    //
    // The selected hall is the one a *held* meal is in. The list is the
    // set of halls that serve the meal, and that is the set the hunt
    // needs: the user is choosing where to eat, not where a meal already
    // sits.
    final halls = <Hall>[
      for (final option in self.options)
        if (option.value != '-1') Hall(id: option.value, name: option.text),
    ];
    if (halls.isEmpty) return null;

    final dishes = <MenuOption>[];
    for (final option in food.options) {
      if (option.value == '-1') continue;
      final price = parseRial(option.text);
      if (price == null) continue;
      dishes.add(MenuOption(
        id: option.value,
        name: dishName(option.text),
        priceRial: price,
      ));
    }
    if (dishes.isEmpty) return null;

    return MealMenu(
      date: rowDate,
      slot: slot,
      halls: halls,
      dishes: dishes,
      reservable: !_isDisabled(rowHtml, 'chkReserve'),
    );
  }

  /// Parses the reservation grids into the meals the student holds.
  ///
  /// ## Why "checked" is not enough
  ///
  /// A checked checkbox does **not** mean the meal is held. The portal echoes
  /// back the checkbox state it was posted, so a row the app never reserved can
  /// come back `checked` while carrying no reservation at all (F13).
  ///
  /// Two independent signals say a meal is genuinely held, and **both** are
  /// required:
  ///
  ///   * the row's status icon is the green «رزرو شده» (`AcceptGreen16`), and
  ///   * the row's **مبلغ خرید** cell — column 6 — is non-zero.
  ///
  /// An echoed row has neither: no green icon, and an amount of 0.
  ///
  /// Getting this wrong is not a cosmetic error. The cancel posts the account's
  /// form state back, so a phantom row treated as held would have its checkbox
  /// re-posted — and that **books a meal the student never asked for**.
  static List<Reservation> parseReservations(String html) {
    final reservations = <Reservation>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        if (checkbox == null || !checkbox.checked) continue;

        // The two markers of a genuinely held meal.
        final status = rowStatus(row.raw);
        if (!status.held) continue;
        if ((parseRial(row.cell(6)) ?? 0) <= 0) continue;

        final date = parseJalaliDate(row.cell(1));
        if (date == null) continue;

        final food = selectBySuffix(row.raw, 'drpFood');
        final self = selectBySuffix(row.raw, 'drpSelf');
        if (food == null || self == null) continue;

        final selected = food.selected;
        if (selected == null || selected.value == '-1') continue;

        final price = parseRial(selected.text) ?? 0;

        reservations.add(Reservation(
          id: 'row-${slot.name}-${_dateKey(date)}',
          date: date,
          slot: slot,
          hall: Hall(
            id: self.selected?.value ?? '-1',
            name: self.selected?.text ?? '',
          ),
          option: MenuOption(
            id: selected.value,
            name: dishName(selected.text),
            priceRial: price,
          ),
          state: status.consumed
              ? ReservationState.consumed
              : ReservationState.active,
        ));
      }
    }

    return reservations;
  }

  /// Parses the basket buy grid into listings.
  ///
  /// **One listing per (hall, option) pair.** The row is a (date, slot) pair.
  /// Its food dropdown lists the meals on offer and its hall dropdown lists
  /// the halls they are offered in, so a row with two dishes in two halls
  /// yields four listings.
  ///
  /// The cross product is deliberate. A claim POST names a hall *and* a dish
  /// (`drpSelf` + `drpFood`), so each combination is separately purchasable and
  /// separately lost. Collapsing them would hide the second hall from the
  /// ranker, and the user's "Engineering as a fallback" would silently never
  /// fire.
  ///
  /// The hall list is what the portal publishes for that row, never a
  /// hardcoded pair: the portal names halls per account, and serves different
  /// ones on different days.
  static List<Listing> parseBasket(String html, DateTime date) {
    final listings = <Listing>[];

    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 4) continue;

      final slot = mealSlotByPersianName[row.cell(1).trim()];
      if (slot == null) continue;

      final food = selectBySuffix(row.raw, 'drpFood');
      final self = selectBySuffix(row.raw, 'drpSelf');
      if (food == null || self == null) continue;

      final halls = <Hall>[
        for (final option in self.options)
          if (option.value != '-1')
            Hall(id: option.value, name: option.text),
      ];
      if (halls.isEmpty) continue;

      for (final option in food.options) {
        if (option.value == '-1') continue;
        final price = parseRial(option.text);
        if (price == null) continue;

        final menuOption = MenuOption(
          id: option.value,
          name: dishName(option.text),
          priceRial: price,
        );

        for (final hall in halls) {
          listings.add(Listing.composite(
            date: date,
            slot: slot,
            hall: hall,
            option: menuOption,
          ));
        }
      }
    }

    return listings;
  }

  /// The name of a menu option, without its trailing price.
  ///
  /// The portal renders `زرشک پلو با مرغ,سس مرغ, ماست 500000 ریال`; the dish is
  /// everything before the price, and the price is parsed separately.
  static String dishName(String optionText) => optionText
      .replaceAll(RegExp(r'\s*\d[\d,٬]*\s*ریال\s*$'), '')
      .trim();

  /// The buy page's date, as the portal's Jalali string.
  ///
  /// Read from `txtDate`, which is the page's own filter and always agrees
  /// with the rows it renders — verified live 2026-10-20.
  static String? buyPageDate(String html) {
    final match = RegExp(
      '<input[^>]*id="[^"]*txtDate"[^>]*value="([^"]*)"',
      dotAll: true,
    ).firstMatch(html);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The complete form state of the buy page, with one listing selected.
  ///
  /// **The complete state, not one row.** The buy page is an ASP.NET grid, and
  /// an absent checkbox reads as *unchecked* on the server — so posting only
  /// the row being bought would silently release whatever else the account
  /// holds on that page. This mirrors what a browser sends, and matches the
  /// live capture of the one successful purchase
  /// (`captures/82_buy_post_body.txt`).
  ///
  /// [listingId] selects the row and the option; [hallId] overrides the hall,
  /// which is what makes the user's hall preference take effect.
  static Map<String, String> claimFormBody(
    String html, {
    required String listingId,
    required String hallId,
    String? date,
  }) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    if (date != null) body['ctl00\$cphMain\$txtDate'] = date;

    // Every row's current state, so nothing is released by omission. The row
    // carrying the target listing is written last, so its values win.
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      final food = selectBySuffix(row.raw, 'drpFood');
      final self = selectBySuffix(row.raw, 'drpSelf');
      final count = selectBySuffix(row.raw, 'drpFoodCount');
      if (food == null || self == null) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      final isTarget = food.options.any((o) => o.value == listingId);

      // Preserve an existing held meal. An absent checkbox reads as unchecked,
      // so dropping it would give the meal back.
      if (checkbox != null && checkbox.checked) body[checkbox.name] = 'on';

      body[self.name] = self.selected?.value ?? '-1';
      body[food.name] = food.selected?.value ?? '-1';
      if (count != null) body[count.name] = count.selected?.value ?? '-1';

      if (!isTarget) continue;

      if (checkbox != null) body[checkbox.name] = 'on';
      body[self.name] = hallId;
      body[food.name] = listingId;
      // The row renders count 0 when it has no service, and a count of 0 buys
      // nothing — the listing's presence is what makes the row buyable.
      if (count != null) body[count.name] = '1';
    }

    body['ctl00\$cphMain\$btnSave'] = 'ذخیره';
    return body;
  }

  /// The form fields for listing a meal for sale on `FoodBasketSale.aspx`.
  static Map<String, String> saleFormBody(
    String html, {
    required String jalaliDate,
    required MealSlot slot,
  }) =>
      <String, String>{
        '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
        '__VIEWSTATEENCRYPTED': '',
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        r'ctl00$cphMain$txtDate': jalaliDate,
        r'ctl00$cphMain$drpReserveType': '0',
        r'ctl00$cphMain$drpFoodType': switch (slot) {
          MealSlot.breakfast => '1',
          MealSlot.lunch => '2',
          MealSlot.dinner => '3',
        },
        r'ctl00$cphMain$btnFoodReload': 'بارگذاری غذا',
      };

  /// Form fields for cancelling/withdrawing a meal listing on `FoodBasketSale.aspx`.
  static Map<String, String> saleCancelFormBody(
    String html, {
    required String jalaliDate,
    required MealSlot slot,
  }) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      r'ctl00$cphMain$txtDate': jalaliDate,
      r'ctl00$cphMain$drpReserveType': '0',
      r'ctl00$cphMain$drpFoodType': switch (slot) {
        MealSlot.breakfast => '1',
        MealSlot.lunch => '2',
        MealSlot.dinner => '3',
      },
    };

    final cancelMatch = RegExp(
      r'<input[^>]*name="([^"]*(?:btnDelete|btnCancel|btnFoodDelete)[^"]*)"[^>]*(?:value="([^"]*)")?',
      caseSensitive: false,
    ).firstMatch(html);
    if (cancelMatch != null) {
      final btnName = cancelMatch.group(1)!;
      final btnVal = cancelMatch.group(2) ?? 'انصراف';
      body[btnName] = btnVal;
      return body;
    }

    body[r'ctl00$cphMain$btnCancel'] = 'انصراف';
    return body;
  }

  /// The alert message shown on the sale page, if any.
  static String? parseSaleAlert(String html) =>
      labelText(html, 'cphMain_alertBoxValue');

  /// Form data for requesting a forgot receipt on ForgotReceipt.aspx.
  static Map<String, String> forgotReceiptFormBody(
    String html, {
    required String jalaliDate,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) {
    final viewState = hiddenFieldValue(html, '__VIEWSTATE');
    final viewStateGen = hiddenFieldValue(html, '__VIEWSTATEGENERATOR');
    final eventValidation = hiddenFieldValue(html, '__EVENTVALIDATION');

    final btnMatch = RegExp(
      r'''name=["']([^"']*btnOk[^"']*)["'][^>]*value=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html) ??
    RegExp(
      r'''value=["']([^"']*)["'][^>]*name=["']([^"']*btnOk[^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);

    final btnName = btnMatch != null
        ? (btnMatch.group(1)!.contains('btnOk') ? btnMatch.group(1)! : btnMatch.group(2)!)
        : r'ctl00$cphMain$btnOk';
    final btnVal = btnMatch != null
        ? (btnMatch.group(1)!.contains('btnOk') ? btnMatch.group(2)! : btnMatch.group(1)!)
        : 'تأیید';

    return <String, String>{
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      if (eventValidation.isNotEmpty) '__EVENTVALIDATION': eventValidation,
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      r'ctl00$cphMain$txtDate': jalaliDate,
      r'ctl00$cphMain$drpReserveType': reserveType.value.toString(),
      r'ctl00$cphMain$drpFoodType': switch (slot) {
        MealSlot.breakfast => '1',
        MealSlot.lunch => '2',
        MealSlot.dinner => '3',
      },
      btnName: btnVal,
    };
  }

  /// Parses the response of a ForgotReceipt.aspx submission.
  static ForgotReceiptOutcome parseForgotReceiptOutcome(
    String html, {
    required DateTime date,
    required MealSlot slot,
  }) {
    if (html.contains('id="txtUsername"') || html.contains('ورود به سامانه')) {
      return const ForgotReceiptRefused('نشست کاربری منقضی شده است. لطفاً مجدداً وارد شوید.');
    }

    // 1. Toastr or scriptToast notifications (e.g. ScriptManager async postbacks)
    final toastrMatch = RegExp(r'''toastr\.(?:error|warning|info|success)\s*\(\s*['"]([^'"]+)['"]''').firstMatch(html)
        ?? RegExp(r'''scriptToast\s*\(\s*['"][^'"]*['"]\s*,\s*['"]([^'"]+)['"]''').firstMatch(html);
    if (toastrMatch != null) {
      final toastText = toastrMatch.group(1)!.trim();
      final codeMatch = RegExp(r'(?:کد|شماره|فیش|توکن)\s*(?:[:=]|\s)\s*(\d+)').firstMatch(toastText);
      final hasRefusalWord = toastText.contains('خطا') ||
          toastText.contains('غیرفعال') ||
          toastText.contains('یافت نشد') ||
          toastText.contains('مقدور') ||
          toastText.contains('مجاز') ||
          toastText.contains('نمی باشد') ||
          toastText.contains('امکان پذیر نیست');

      if (codeMatch != null && !hasRefusalWord) {
        return ForgotReceiptSucceeded(
          date: date,
          slot: slot,
          code: codeMatch.group(1)!,
          message: toastText,
        );
      }
      return ForgotReceiptRefused(toastText);
    }

    // 2. Alert box (cphMain_alertBoxValue)
    final alert = labelText(html, 'cphMain_alertBoxValue');
    if (alert != null && alert.trim().isNotEmpty) {
      final text = alert.trim();
      final hasRefusalWord = text.contains('خطا') ||
          text.contains('غیرفعال') ||
          text.contains('یافت نشد') ||
          text.contains('مقدور') ||
          text.contains('مجاز') ||
          text.contains('نمی باشد') ||
          text.contains('امکان پذیر نیست');

      final codeMatch = RegExp(r'(?:کد|شماره|فیش|توکن)\s*(?:[:=]|\s)\s*(\d+)').firstMatch(text);
      if (codeMatch != null && !hasRefusalWord) {
        return ForgotReceiptSucceeded(
          date: date,
          slot: slot,
          code: codeMatch.group(1)!,
          message: text,
        );
      }

      if (hasRefusalWord) {
        return ForgotReceiptRefused(text);
      }
    }

    // 3. General receipt code patterns in HTML
    final codeMatch = RegExp(r'(?:کد فیش|شماره فیش|کد رهگیری|کد رسید)[^\d]*(\d{3,10})').firstMatch(html);
    if (codeMatch != null) {
      return ForgotReceiptSucceeded(
        date: date,
        slot: slot,
        code: codeMatch.group(1)!,
        message: 'فیش فراموشی با موفقیت دریافت شد.',
      );
    }

    if (alert != null && alert.trim().isNotEmpty) {
      return ForgotReceiptRefused(alert.trim());
    }

    // Note: Do NOT parse cphMain_messageBoxValue as refusal! It is a static disclaimer
    // describing rules/quotas ("توجه - گرفتن فیش فراموشی تا سقف صبحانه: 2 ... بیش از این تعداد غیرفعال می گردد")
    // and causes false negatives if treated as an error.

    return const ForgotReceiptAmbiguous(
      'درخواستی از سمت سامانه دانشگاه ثبت نشد. دریافت فیش فقط در روز توزیع و در ساعات مجاز (ناهار ۹:۰۰ تا ۱۵:۳۰، شام و صبحانه ۱۶:۳۰ تا ۲۰:۳۰) امکان‌پذیر است.',
    );
  }

  /// Whether the buy page shows [optionId] as **held**: checked and charged.
  ///
  /// This is the only reliable success signal. Verified live 2026-10-20 against
  /// the response to a real purchase: the bought option's row comes back
  /// `checked` with a non-zero amount, and the option is **still listed** in
  /// the dropdown. So "the option disappeared" is not a success test, and a
  /// client that used it would mis-report a completed, irreversible purchase as
  /// a failure — and keep hunting into a second one.
  ///
  /// Returns null when no row offers the option at all.
  static BasketHoldStatus? heldOnBuyPage(String html, String optionId) {
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 7) continue;

      final food = selectBySuffix(row.raw, 'drpFood');
      if (food == null) continue;
      if (!food.options.any((o) => o.value == optionId)) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return BasketHoldStatus(
        checked: checkbox?.checked ?? false,
        amountRial: parseRial(row.cell(6)) ?? 0,
      );
    }
    return null;
  }

  /// The Persian meal names the ledger uses.
  static const Map<String, MealSlot> _ledgerSlots = {
    'صبحانه': MealSlot.breakfast,
    'ناهار': MealSlot.lunch,
    'شام': MealSlot.dinner,
  };

  /// Parses the transaction ledger.
  ///
  /// **The main grid is NOT enough.** `MyCullinan/MyTransaction.aspx` renders a
  /// single row in `grdContent` — the most recent transaction — and keeps the
  /// full history in `grdContent_grdDetail_N` sub-grids (verified: 13 rows
  /// before a purchase, 14 after). Reading only the main grid would make the
  /// account look like it had a single transaction ever.
  static List<Transaction> parseTransactions(
    String html, {
    AccountId accountId = '',
  }) {
    final out = <Transaction>[];

    // The detail sub-grids carry the history; the main grid carries the newest
    // row, which is also the first detail grid's row. Collect the details, and
    // fall back to the main grid if there are none.
    final detailIds = RegExp(r'id="(cphMain_grdContent_grdDetail_\d+)"')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toList();

    for (final id in detailIds) {
      final table = RegExp(
        '<table[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</table>',
        dotAll: true,
      ).firstMatch(html);
      if (table == null) continue;
      out.addAll(_transactionRows(table.group(1)!, accountId));
    }

    if (out.isEmpty) {
      final main = RegExp('<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
              dotAll: true)
          .firstMatch(html);
      if (main != null) {
        out.addAll(_transactionRows(main.group(1)!, accountId));
      }
    }

    return out;
  }

  static List<Transaction> _transactionRows(
    String tableBody,
    AccountId accountId,
  ) {
    final out = <Transaction>[];

    for (final row in _trPattern.allMatches(tableBody)) {
      final cells = _tdPattern
          .allMatches(row.group(1)!)
          .map((m) => stripTags(m.group(1)!))
          .toList();
      if (cells.length < 7) continue;
      if (cells[0].trim().isEmpty) continue;

      out.add(Transaction(
        accountId: accountId,
        type: cells[0].trim(),
        foodName: cells[1].trim(),
        slot: _ledgerSlots[cells[2].trim()],
        weekday: cells[3].trim(),
        date: cells[4].trim(),
        count: int.tryParse(cells[5].trim()) ?? 0,
        amountRial: parseRial(cells[6]) ?? 0,
      ));
    }

    return out;
  }

  /// Parses the internet-payment list (`MyePayList.aspx`).
  ///
  /// ## Why this is the proof of a top-up
  ///
  /// A top-up is credited **asynchronously**: the bank gateway answers first,
  /// and the portal re-queries the bank afterwards. So a balance read taken
  /// right after the handoff shows the old figure even though the money is on
  /// its way, and the balance alone cannot say whether the payment landed.
  /// This list is the portal's own account of what happened (F58).
  ///
  /// ## The row shape
  ///
  /// | cell | meaning |
  /// |---|---|
  /// | 0 | the row number |
  /// | 1 | the status **icon** — `Accept16.png` (paid) or `Cancel16.png` (not) |
  /// | 2 | the payment time, in the portal's Jalali format |
  /// | 3 | the amount, in Rial |
  /// | 4 | the invoice number |
  /// | 5 | the bank's tracking code (`-` when there is none) |
  /// | 6 | the bank |
  /// | 7 | the portal's own message |
  ///
  /// The status is read from the **icon**, not the message: the message is
  /// free text, and a row whose status the app cannot classify must not be
  /// read as a success.
  ///
  /// The list is rendered **newest first** (verified live: the newest attempt
  /// appears at the top), so the order is preserved.
  static List<TopUpPayment> parseTopUpPayments(String html) {
    final table = RegExp(
      '<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
      dotAll: true,
    ).firstMatch(html);
    if (table == null) return const [];

    final out = <TopUpPayment>[];

    for (final match in _trPattern.allMatches(table.group(1)!)) {
      final raw = match.group(1)!;
      final cells = _tdPattern
          .allMatches(raw)
          .map((m) => stripTags(m.group(1)!))
          .toList();
      if (cells.length < 8) continue;

      // The row number is the first cell; a row without one is a header or a
      // spacer.
      if (int.tryParse(cells[0].trim()) == null) continue;

      final amount = parseRial(cells[3]);
      if (amount == null || amount <= 0) continue;

      out.add(TopUpPayment(
        amountRial: amount,
        status: _topUpStatus(raw, cells[7].trim()),
        paidAtJalali: _emptyToNull(cells[2].trim()),
        invoiceNumber: _emptyToNull(cells[4].trim()),
        bank: _emptyToNull(cells[6].trim()),
        message: _emptyToNull(cells[7].trim()),
      ));
    }

    return out;
  }

  /// Parses the student's name from an authenticated page.
  ///
  /// Two sources carry it on authenticated pages:
  ///   1. `<div id="divUsername" class="profileTitle">رضا شريفي</div>`
  ///   2. `<label id="cphMain_titleBoxValue">کاربر: علی محمدی - 401000000</label>`
  static String? parseProfileName(String html) {
    final divUser = elementText(html, 'divUsername');
    if (divUser != null && divUser.trim().isNotEmpty) {
      return divUser.trim();
    }

    final raw = labelText(html, 'cphMain_titleBoxValue') ??
        elementText(html, 'titleBoxValue');
    if (raw == null || raw.trim().isEmpty) return null;

    return extractStudentName(raw);
  }

  /// Extracts the student's name from a string like "کاربر: علی محمدی - 401000000".
  static String? extractStudentName(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceFirst(_userPrefixPattern, '').trim();
    if (cleaned.isEmpty) return null;
    final dashIndex = cleaned.lastIndexOf('-');
    if (dashIndex != -1) {
      final namePart = cleaned.substring(0, dashIndex).trim();
      if (namePart.isNotEmpty) return namePart;
    }
    cleaned = cleaned.replaceAll(_trailingDigitsPattern, '').trim();
    return cleaned.isNotEmpty ? cleaned : null;
  }

  /// The status of a payment row, read from its icon.
  ///
  /// The icon is the authority. The message is a fallback for a row whose
  /// icon the app does not recognise, and a row with neither is **unknown** —
  /// never a success, because a mis-read row would tell the student their
  /// money arrived when it did not.
  static TopUpStatus _topUpStatus(String rowHtml, String message) {
    final icon = RegExp(r'<img[^>]*src="([^"]*)"', dotAll: true)
        .firstMatch(rowHtml)
        ?.group(1)
        ?.toLowerCase();

    if (icon != null) {
      if (icon.contains('accept')) return TopUpStatus.paid;
      if (icon.contains('cancel')) return TopUpStatus.failed;
    }

    // The portal's own words, for a row whose icon is missing or new.
    if (message.contains('موفق')) return TopUpStatus.paid;
    if (message.contains('خطا') || message.contains('ناموفق')) {
      return TopUpStatus.failed;
    }
    if (message.isEmpty) return TopUpStatus.pending;

    return TopUpStatus.unknown;
  }

  static String? _emptyToNull(String value) =>
      value.isEmpty || value == '-' ? null : value;

  /// True when the row's reserve checkbox is disabled, meaning the date is
  /// locked by the server.
  static bool _isDisabled(String rowHtml, String suffix) =>
      inputBySuffix(rowHtml, suffix)?.disabled ?? false;

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateKey(DateTime date) =>
      '${date.year}-${date.month}-${date.day}';

  static final RegExp _trPattern = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);
  static final RegExp _tdPattern = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true);
  static final RegExp _userPrefixPattern = RegExp(r'^کاربر\s*:\s*');
  static final RegExp _trailingDigitsPattern = RegExp(r'\s*\d+\s*$');
}
