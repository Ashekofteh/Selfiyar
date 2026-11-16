/// The top-up (balance recharge) domain: the amount rules, the payment
/// statuses, and the payment list.
///
/// ## Why the amount bounds live here
///
/// The portal accepts a top-up between **120,000 and 5,000,000 Rial**, and
/// refuses anything outside that range **silently** — it re-renders the
/// amount form with no message at all (F56). So the app cannot learn the
/// bounds by asking the portal; it has to know them, and it has to check
/// them *before* the request, or the student gets a button that does
/// nothing.
///
/// The bounds are a rule about the portal's business, not about the UI, so
/// they belong in the core — which is where the architecture test
/// (`test/core/architecture_test.dart`) proves they stay free of Flutter and
/// `dart:io`.
///
/// ## Why the balance is not the proof of payment
///
/// A payment is credited **asynchronously**: the bank gateway returns first,
/// and the portal re-queries the bank afterwards. A balance read taken too
/// early shows the old figure even though the money is on its way. So the
/// portal's own **payment list** is the authority on what happened (F58),
/// and the balance is only refreshed afterwards.
library;

/// The smallest top-up the portal accepts, in Rial.
const int minTopUpRial = 120000;

/// The largest top-up the portal accepts, in Rial.
const int maxTopUpRial = 5000000;

/// A bank gateway the top-up can be paid through.
///
/// ## Why the app offers only the banks that work
///
/// The portal's own top-up page renders two bank logos. Only one of them is
/// configured: the second answers «خطا در اجرای عملیات! Value cannot be
/// null» when the student tries to use it (F57). Offering a button that
/// cannot work is exactly the friction this app exists to remove, so the
/// unusable one is not offered at all.
class TopUpBank {
  const TopUpBank({
    required this.id,
    required this.name,
    required this.logoPath,
  });

  /// The portal's control name for this bank, e.g.
  /// `ctl00$cphMain$dataLstBank$ctl00$imgBankLogo`.
  ///
  /// The name is what the POST carries, because the bank logo **is** the
  /// submit button (F54) — the page has no `btnOk`.
  final String id;

  /// The bank's name, as the portal writes it.
  final String name;

  /// The logo's path, relative to the portal. Null when the portal serves no
  /// logo for this bank.
  final String? logoPath;

  @override
  String toString() => 'TopUpBank($id, $name)';
}

/// The top-up page: the balance, and the banks that work.
class TopUpPage {
  const TopUpPage({
    required this.balanceRial,
    this.banks = const [],
    this.defaultAmountRial,
  });

  /// The account's balance, in Rial.
  final int balanceRial;

  /// The banks that can be paid through.
  final List<TopUpBank> banks;

  /// The amount the portal pre-fills, in Rial. Null when it pre-fills none.
  final int? defaultAmountRial;

  @override
  String toString() =>
      'TopUpPage(balance=$balanceRial, banks=${banks.map((b) => b.name).toList()})';
}

/// The top-up amount, and whether the portal will accept it.
///
/// The amount is in **Rial** — the portal's unit — because every comparison
/// against a portal figure must be exact. The UI converts to Toman at the
/// display boundary, as everywhere else.
class TopUpAmount {
  const TopUpAmount(this.rial);

  /// The amount in Rial. A negative or zero amount is never valid.
  final int rial;

  /// The amount in Toman, rounded half up — the figure the student types.
  int get toman => (rial + 5) ~/ 10;

  /// Whether the portal will accept this amount.
  bool get isValid => rial >= minTopUpRial && rial <= maxTopUpRial;

  /// Why the amount is refused, in Persian, or null when it is accepted.
  ///
  /// The portal's own refusal is **silent**, so this is the only warning the
  /// student will get. It says what is wrong and what would be right.
  String? get problem {
    if (rial <= 0) return 'مبلغ افزایش اعتبار باید بیشتر از صفر باشد.';
    if (rial < minTopUpRial) {
      return 'کمترین مبلغ افزایش اعتبار ${_toman(minTopUpRial)} تومان است.';
    }
    if (rial > maxTopUpRial) {
      return 'بیشترین مبلغ افزایش اعتبار ${_toman(maxTopUpRial)} تومان است.';
    }
    return null;
  }

  /// A copy with a different amount.
  TopUpAmount withRial(int value) => TopUpAmount(value);

  @override
  String toString() => 'TopUpAmount($rial Rial)';

  /// The Toman figure, in Persian digits, with the thousands separator.
  static String _toman(int rial) => _groupDigits((rial + 5) ~/ 10);

  /// Groups an integer's digits with the Persian thousands separator.
  ///
  /// The same grouping the rest of the app uses, so a bound reads «۱۲٬۰۰۰
  /// تومان» here and «۱۲٬۰۰۰ تومان» everywhere else.
  static String _groupDigits(int amount) {
    final digits = amount.abs().toString();
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write('٬');
      grouped.write(digits[i]);
    }
    return _persianDigits(grouped.toString());
  }

  /// Persian digits, without importing the whole calendar module.
  ///
  /// The core's Persian helpers live in `persian.dart`, but this file is
  /// deliberately free of it: `persian.dart` owns the *calendar*, and a
  /// top-up amount is not a date. Keeping the digits local keeps the
  /// dependency one-directional and obvious.
  static String _persianDigits(String value) {
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        buffer.write(persian[rune - 0x30]);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }
}

/// How a top-up attempt ended.
enum TopUpStatus {
  /// The portal says the payment succeeded.
  paid,

  /// The portal says it failed — «خطا در دریافت اطلاعات از بانک» and the
  /// like. The bank rejected it, or the portal could not reach the bank.
  failed,

  /// The attempt is recorded but not yet resolved. The portal re-queries the
  /// bank later, so this is a normal state for a while after a payment.
  pending,

  /// The portal listed a row the app cannot classify.
  unknown;

  /// Whether this status means the money reached the account.
  bool get isPaid => this == TopUpStatus.paid;

  /// Whether the attempt is still in flight.
  bool get isPending => this == TopUpStatus.pending;
}

/// One row of the portal's payment list.
class TopUpPayment {
  const TopUpPayment({
    required this.amountRial,
    required this.status,
    this.paidAtJalali,
    this.invoiceNumber,
    this.bank,
    this.message,
    this.hasVerifyButton = false,
  });

  /// The amount, in Rial.
  final int amountRial;

  /// How the attempt ended.
  final TopUpStatus status;

  /// The portal's Jalali timestamp of the attempt, e.g. `1405/07/29 04:21:50`.
  final String? paidAtJalali;

  /// The portal's invoice number.
  final String? invoiceNumber;

  /// The bank the payment went to.
  final String? bank;

  /// The portal's own message, e.g. «پرداخت موفق».
  final String? message;

  /// Whether the row has an active, non-disabled verify («استعلام») button on the portal.
  final bool hasVerifyButton;

  @override
  String toString() =>
      'TopUpPayment($amountRial, ${status.name}, verify=$hasVerifyButton, $message)';
}

/// The outcome of settling a top-up: what the portal says, and the balance
/// as it stands now.
class TopUpReport {
  const TopUpReport({
    required this.payments,
    this.balanceRial,
    this.matched,
  });

  /// The payment list, newest first, as the portal reports it.
  final List<TopUpPayment> payments;

  /// The balance read after the payment, in Rial. Null when it could not be
  /// read.
  final int? balanceRial;

  /// The payment that matches the attempt the app made, when there is one.
  ///
  /// "Matches" means the same **amount** — the portal does not expose the
  /// app's attempt id, and the amount is what the student chose.
  final TopUpPayment? matched;

  /// Whether the payment landed.
  bool get isPaid => matched?.status.isPaid ?? false;

  @override
  String toString() => 'TopUpReport(paid=$isPaid, balance=$balanceRial)';
}

/// Finds the payment that matches [amountRial] among [payments].
///
/// The portal's list is newest-first, and several attempts can share an
/// amount, so the **newest** match wins: it is the one the student just
/// made, and an older attempt with the same amount would otherwise be
/// mistaken for it.
TopUpPayment? matchTopUpPayment(
  List<TopUpPayment> payments,
  int amountRial,
) {
  for (final payment in payments) {
    if (payment.amountRial == amountRial) return payment;
  }
  return null;
}
