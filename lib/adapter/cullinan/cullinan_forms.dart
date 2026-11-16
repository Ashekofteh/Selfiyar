/// Shared plumbing for the Cullinan adapter: portal paths, the WebForms
/// viewstate that every POST must carry, and the grid/row helpers.
///
/// The portal is ASP.NET WebForms, and the same rules hold on every page:
/// a POST without the page's `__VIEWSTATE` is processed against no state at
/// all, control names carry a `ctl00$cphMain$...` prefix, and the grid rows are
/// matched by suffix because their indices shift whenever the portal changes a
/// grid. Keeping those rules here means a page-area collaborator only carries
/// the part that is particular to its own page.
library;

import '../../core/auth/session_manager.dart' show LoginRejectedException;
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../core/shared/persian.dart';
import '../../transport/html_parsing.dart';
import '../../transport/http_transport.dart';

/// Portal paths.
abstract final class CullinanPaths {
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

/// The weekly menu's "next week" postback target.
///
/// The weekly menu is one page per week, and this is how the portal moves to
/// the next one. It is a navigation, not a write.
/// (The portal page also carries `ctl00$cphMain$imgbtnLastWeek` and
/// `ctl00$cphMain$imgbtnCurrentWeek`).
const cullinanNextWeekEventTarget = r'ctl00$cphMain$imgbtnNextWeek';

/// The shared form and grid operations of the portal.
abstract final class CullinanForms {
  /// Throws when a read came back as the login form rather than the page.
  ///
  /// The portal answers an expired session by serving the login page, which is
  /// a perfectly valid response — and which every parser downstream would
  /// misread as "the page had no rows". So the bounce is detected here and
  /// reported as [LoginRejectedException], which tells the caller to log in
  /// again rather than to conclude the account holds nothing.
  static void rejectIfBounced(TransportResponse response) {
    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
  }

  /// The hidden WebForms state a post must carry: viewstate, generator, and
  /// the event target/argument fields.
  static Map<String, String> viewState(String html) => <String, String>{
    '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
  };

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  static String jalaliOf(DateTime date) {
    final jalali = toJalali(date);
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
  }

  /// Whether two civil dates name the same day.
  static bool sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The reservation grid for a meal slot.
  static String gridForSlot(MealSlot slot) => switch (slot) {
    MealSlot.breakfast => 'grdReservationBreakfast',
    MealSlot.lunch => 'grdReservationLunch',
    MealSlot.dinner => 'grdReservationDinner',
  };

  /// The save button's control-name suffix for a meal slot's grid.
  static String gridSaveButtonSuffix(MealSlot slot) => switch (slot) {
    MealSlot.breakfast => 'btnSaveBreakfast',
    MealSlot.lunch => 'btnSaveLunch',
    MealSlot.dinner => 'btnSaveDinner',
  };

  /// The save button's full control name for a meal slot's grid.
  static String gridSaveButton(MealSlot slot) => switch (slot) {
    MealSlot.breakfast => 'ctl00\$cphMain\$btnSaveBreakfast',
    MealSlot.lunch => 'ctl00\$cphMain\$btnSaveLunch',
    MealSlot.dinner => 'ctl00\$cphMain\$btnSaveDinner',
  };

  /// Whether the row is a genuine, charged reservation.
  ///
  /// Both markers are required: the green «رزرو شده» icon, and a non-zero
  /// **مبلغ خرید**. An echoed row has neither (F13).
  static bool isGenuinelyHeld(ParsedRow row) {
    final status = rowStatus(row.raw);
    if (!status.held) return false;
    return (parseRial(row.cell(6)) ?? 0) > 0;
  }
}

/// A portal-area collaborator: one page-family, one transport, one clock.
///
/// The collaborators share only these three things. They never call each
/// other, which is what keeps a change in one page area from rippling through
/// the others.
abstract class CullinanArea {
  CullinanArea({required this.transport, required DateTime Function() clock})
    : _now = clock;

  final PortalTransport transport;
  final DateTime Function() _now;

  /// The current time, on the adapter's injected clock.
  DateTime get now => _now();

  /// The Jalali date string for today, as the portal expects it.
  String get todayJalali => CullinanForms.jalaliOf(now);

  /// Puts [session]'s cookies into the transport's jar.
  ///
  /// The jar is filled by the responses the portal sends, so a session that
  /// was restored from storage — never a response — would go out
  /// unauthenticated. The portal would answer with the login page, and the
  /// read would be reported as an expired session rather than as a session
  /// that was never applied.
  void applySession(Session session) {
    transport.restoreSession(session.account, session.cookies);
  }
}
