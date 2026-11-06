/// Starting a top-up, and settling it once the student has paid.
///
/// ## Why this is a service and not a screen
///
/// A top-up spends the student's **own money**, and the portal's own rules
/// are unforgiving in a way that has to be handled before the request:
///
///   * the amount is refused **silently** outside 120,000–5,000,000 Rial
///     (F56), so the app checks the bounds itself;
///   * one of the two banks the portal lists is **not configured** and errors
///     (F57), so the app does not offer it;
///   * the payment is credited **asynchronously** (F58), so the balance read
///     right after the handoff is not the answer — the portal's payment list
///     is.
///
/// So the decision to charge lives in the platform layer, where it can be
/// checked against the balance and the bounds **before** the request goes
/// out, and where the outcome is established by reading the portal back
/// rather than by trusting the response.
library;

import '../core/models.dart';
import '../core/portal.dart';
import '../core/session_manager.dart'
    show
        LoginRejectedException,
        PortalUnreachableException,
        SessionManager,
        SessionUnavailableException,
        TopUpRejectedException;
import '../core/top_up.dart';

/// Why a top-up could not be started.
enum TopUpFailure {
  /// The amount is outside the range the portal accepts.
  amountOutOfRange,

  /// The portal has no usable bank gateway.
  noBank,

  /// The account has no usable session.
  noSession,

  /// The portal refused the request.
  rejected,
}

/// The outcome of starting a top-up.
class TopUpOutcome {
  const TopUpOutcome.ready(this.gateway)
      : failure = null,
        message = null;

  const TopUpOutcome.failed(this.failure, this.message) : gateway = null;

  /// The bank's gateway the student must pay at, when the top-up started.
  final Uri? gateway;

  /// Why it failed, when it did.
  final TopUpFailure? failure;

  /// The message to show the student.
  final String? message;

  bool get succeeded => gateway != null;

  @override
  String toString() => succeeded
      ? 'TopUpOutcome.ready($gateway)'
      : 'TopUpOutcome.failed(${failure?.name})';
}

/// Starts and settles top-ups.
class TopUpService {
  TopUpService({
    required this.client,
    required this.sessions,
    this.verifyDelays = defaultVerifyDelays,
  });

  /// Default exponential backoff delays for re-checking/verifying payment status on the portal.
  static const List<Duration> defaultVerifyDelays = [
    Duration(milliseconds: 600),
    Duration(milliseconds: 1200),
    Duration(milliseconds: 2000),
    Duration(milliseconds: 3000),
    Duration(milliseconds: 4000),
  ];

  final PortalClient client;
  final SessionManager sessions;
  final List<Duration> verifyDelays;

  /// Reads the top-up page: the balance and the banks that work.
  Future<TopUpPage?> page(AccountId accountId) async {
    try {
      return await sessions.withSession(
        accountId,
        (session) => client.fetchTopUpPage(session),
      );
    } catch (_) {
      return null;
    }
  }

  /// Starts a top-up of [amountRial] and returns the bank's gateway.
  ///
  /// ## The order of the checks
  ///
  /// The amount is checked **first**, because the portal's refusal is
  /// silent: an out-of-range amount would otherwise reach the portal and
  /// come back as a page that does nothing, with no error to show. The
  /// balance is not checked here — the student may be topping up *because*
  /// the balance is short, and a top-up that costs more than the balance is
  /// perfectly normal.
  ///
  /// The bank is chosen by the caller, from the page the portal rendered.
  Future<TopUpOutcome> begin({
    required AccountId accountId,
    required int amountRial,
    required TopUpBank bank,
  }) async {
    final amount = TopUpAmount(amountRial);
    if (!amount.isValid) {
      return TopUpOutcome.failed(
        TopUpFailure.amountOutOfRange,
        amount.problem,
      );
    }

    try {
      final gateway = await sessions.withSession(
        accountId,
        (session) => client.beginTopUp(session, amountRial, bank),
      );
      return TopUpOutcome.ready(gateway);
    } on TopUpRejectedException catch (e) {
      return TopUpOutcome.failed(TopUpFailure.rejected, e.message);
    } on LoginRejectedException {
      return const TopUpOutcome.failed(
        TopUpFailure.noSession,
        'نشست منقضی شده است. دوباره تلاش کنید.',
      );
    } on SessionUnavailableException catch (e) {
      return TopUpOutcome.failed(TopUpFailure.noSession, e.reason);
    } on PortalUnreachableException catch (e) {
      return TopUpOutcome.failed(TopUpFailure.rejected, e.message);
    } catch (e) {
      return TopUpOutcome.failed(
        TopUpFailure.rejected,
        'افزایش اعتبار انجام نشد: $e',
      );
    }
  }

  /// Reads back what the portal says about the payment, and the balance.
  ///
  /// ## Why the balance alone is not the answer
  ///
  /// The credit is applied **asynchronously**: the bank answers the
  /// gateway, and the portal re-queries the bank afterwards. So a balance
  /// read taken the moment the student leaves the gateway shows the old
  /// figure even when the money is on its way (F58). The payment list is
  /// the portal's own account of what happened, and it is what this reads.
  ///
  /// The balance is read too — so the app can show the new figure — but it
  /// is never used to decide whether the payment landed.
  Future<TopUpReport> settle({
    required AccountId accountId,
    required int amountRial,
  }) async {
    List<TopUpPayment> payments = const [];
    int? balance;

    try {
      await sessions.withSession(accountId, (session) async {
        payments = await client.fetchTopUpPayments(session);

        // If the newest payment for this amount is not yet recognized as paid,
        // trigger an automatic bank verification (استعلام) on the portal.
        var matched = matchTopUpPayment(payments, amountRial);
        if (matched == null || !matched.status.isPaid) {
          for (var i = 0; i < verifyDelays.length; i++) {
            try {
              payments = await client.verifyTopUpPayment(session);
              matched = matchTopUpPayment(payments, amountRial);
              if (matched != null && matched.status.isPaid) break;
            } catch (_) {
              // Best effort verification
            }
            if (i < verifyDelays.length - 1) {
              await Future<void>.delayed(verifyDelays[i]);
            }
          }
        }

        try {
          balance = (await client.fetchBalance(session)).amountRial;
        } catch (_) {
          // The balance is a bonus: the payment list is the proof, and a
          // balance that cannot be read must not cost the whole settlement.
          balance = null;
        }
      });
    } catch (_) {
      // The portal could not be read. The report says so rather than
      // claiming a payment failed: the money may well have arrived.
    }

    return TopUpReport(
      payments: payments,
      balanceRial: balance,
      matched: matchTopUpPayment(payments, amountRial),
    );
  }
}
