/// The `ForgotReceipt.aspx` page: the forgot-card slip (فیش فراموشی).
///
/// The page is a two-step flow. The first post names the meal and renders
/// either a refusal or an "موافقم" button; the second post answers that button
/// and yields the slip code. The quota is two slips per meal slot per month,
/// and the remaining count is derived from the first page's used-count when
/// the outcome does not state it itself.
library;

import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../transport/http_transport.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// The forgot-receipt area of the portal.
class CullinanReceipt extends CullinanArea {
  CullinanReceipt({required super.transport, required super.clock});

  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    try {
      // 1. GET page
      final page = await transport.get(
        session.account,
        CullinanPaths.forgotReceipt,
      );
      if (page.looksLikeLoginPage) {
        return const ForgotReceiptRefused(
          'نشست منقضی شده است. لطفا دوباره وارد شوید.',
        );
      }

      // 2. Step 1 POST (Submit date, meal, reserve type)
      final step1Body = CullinanParser.forgotReceiptFormBody(
        page.body,
        jalaliDate: CullinanForms.jalaliOf(date),
        slot: slot,
        reserveType: reserveType,
      );

      final response1 = await transport.post(
        session.account,
        CullinanPaths.forgotReceipt,
        body: step1Body,
      );

      if (response1.looksLikeLoginPage) {
        return const ForgotReceiptRefused(
          'نشست منقضی شده است. لطفا دوباره وارد شوید.',
        );
      }

      // Check step 1 status and agree button
      final step1Status = CullinanParser.parseForgotReceiptStep1Status(
        response1.body,
      );
      final agreeButton = CullinanParser.parseForgotReceiptAgreeButton(
        response1.body,
      );

      // If no agreement button appeared, evaluate refusal reasons, quota
      // exhaustion, or immediate code.
      if (agreeButton == null) {
        final immediateOutcome = CullinanParser.parseForgotReceiptOutcome(
          response1.body,
          date: date,
          slot: slot,
        );
        if (immediateOutcome is ForgotReceiptSucceeded) {
          if (immediateOutcome.quotaRemaining == null &&
              step1Status.usedCount != null) {
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
      // Since agreeButton is present, the student is eligible: immediately
      // submit confirmation.
      final step2Body = CullinanParser.forgotReceiptStep2FormBody(
        response1.body,
        button: agreeButton,
        jalaliDate: CullinanForms.jalaliOf(date),
        slot: slot,
        reserveType: reserveType,
      );

      final response2 = await transport.post(
        session.account,
        CullinanPaths.forgotReceipt,
        body: step2Body,
      );

      if (response2.looksLikeLoginPage) {
        return const ForgotReceiptRefused(
          'نشست منقضی شده است. لطفا دوباره وارد شوید.',
        );
      }

      final outcome = CullinanParser.parseForgotReceiptOutcome(
        response2.body,
        date: date,
        slot: slot,
      );

      if (outcome is ForgotReceiptSucceeded &&
          outcome.quotaRemaining == null &&
          step1Status.usedCount != null) {
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
}
