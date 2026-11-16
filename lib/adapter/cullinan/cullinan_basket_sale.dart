/// The `FoodBasketSale.aspx` page: listing a held meal for sale in the
/// secondary Food Basket, and taking it back off sale.
///
/// The page is a two-step WebForms flow. A "بارگذاری غذا" post loads the meal's
/// details and renders either a sell button or a cancel button; a second post
/// confirms whichever button the page rendered. The outcome is then read from
/// the alert the page carries and, when that is silent, from the state of the
/// buttons themselves.
library;

import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../transport/http_transport.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// The secondary-basket area of the portal.
class CullinanBasketSale extends CullinanArea {
  CullinanBasketSale({required super.transport, required super.clock});

  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    if (reserveType == ReserveType.foodBasket) {
      return const SaleListingRefused(
        'غذای خریداری‌شده از سبد غذایی، امکان فروش مجدد در سبد را ندارد.',
      );
    }

    try {
      final page = await transport.get(
        session.account,
        CullinanPaths.basketSale,
      );
      if (page.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final jalaliDate = CullinanForms.jalaliOf(date);

      // Step 1: Post "بارگذاری غذا" to load the meal details and render the
      // sell button.
      final step1Body = CullinanParser.saleReloadFormBody(
        page.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );

      final step1Response = await transport.post(
        session.account,
        CullinanPaths.basketSale,
        body: step1Body,
      );

      if (step1Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final step1Alert = CullinanParser.parseSaleAlert(step1Response.body);
      if (step1Alert != null && step1Alert.isNotEmpty) {
        return SaleListingRefused(step1Alert);
      }

      // Step 2: Find the "فروش به سبد غذا" button rendered in the reloaded page.
      final sellBtn = CullinanParser.parseSaleSubmitButton(step1Response.body);
      if (sellBtn == null) {
        // If the meal is already in the basket (cancel button shown), report it.
        final cancelBtn = CullinanParser.parseSaleCancelButton(
          step1Response.body,
        );
        if (cancelBtn != null) {
          return const SaleListingRefused(
            'این وعده از قبل برای فروش در سبد قرار گرفته است.',
          );
        }
        return const SaleListingRefused(
          'امکان فروش این وعده در سبد وجود ندارد.',
        );
      }

      // Submit Step 2: Post the actual sale confirmation.
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
        CullinanPaths.basketSale,
        body: step2Body,
      );

      if (step2Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final alert = CullinanParser.parseSaleAlert(step2Response.body);
      if (alert != null && alert.isNotEmpty) {
        final isSuccess =
            (alert.contains('موفق') ||
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

      // Check if page state flipped to "in basket" (cancel button rendered).
      if (CullinanParser.isListedInBasketOnPage(step2Response.body)) {
        return const SaleListingSucceeded(
          'غذا با موفقیت در سبد غذایی برای فروش قرار گرفت.',
        );
      }

      // If sell button is still on the page and cancel button is absent, the
      // server refused.
      if (CullinanParser.isReservedNotForSaleOnPage(step2Response.body)) {
        return const SaleListingRefused(
          'سامانه دانشگاه فروش این غذا در سبد را ثبت نکرد. لطفاً مجدداً تلاش نمایید.',
        );
      }

      // Read-back verification via fresh reload.
      final verifyBody = CullinanParser.saleReloadFormBody(
        step2Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );
      final verifyResponse = await transport.post(
        session.account,
        CullinanPaths.basketSale,
        body: verifyBody,
      );
      final verifyAlert = CullinanParser.parseSaleAlert(verifyResponse.body);
      if (verifyAlert != null && verifyAlert.isNotEmpty) {
        return SaleListingRefused(verifyAlert);
      }
      if (CullinanParser.isListedInBasketOnPage(verifyResponse.body)) {
        return const SaleListingSucceeded(
          'غذا با موفقیت در سبد غذایی برای فروش قرار گرفت.',
        );
      }

      return const SaleListingRefused(
        'سامانه دانشگاه فروش این غذا در سبد را تأیید نکرد.',
      );
    } on TransportException catch (e) {
      return SaleListingAmbiguous(e.message);
    } catch (e) {
      return SaleListingAmbiguous(e.toString());
    }
  }

  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async {
    if (reserveType == ReserveType.foodBasket) {
      return const SaleListingRefused(
        'غذای خریداری‌شده از سبد در بخش فروش سبد وجود ندارد.',
      );
    }

    try {
      final page = await transport.get(
        session.account,
        CullinanPaths.basketSale,
      );
      if (page.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final jalaliDate = CullinanForms.jalaliOf(date);

      // Step 1: Post "بارگذاری غذا" to reload the meal status and render the
      // cancel button.
      final step1Body = CullinanParser.saleReloadFormBody(
        page.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );

      final step1Response = await transport.post(
        session.account,
        CullinanPaths.basketSale,
        body: step1Body,
      );

      if (step1Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final step1Alert = CullinanParser.parseSaleAlert(step1Response.body);
      if (step1Alert != null && step1Alert.isNotEmpty) {
        return SaleListingRefused(step1Alert);
      }

      // If the meal is already NOT in the basket (sell button shown and cancel
      // absent):
      if (CullinanParser.isReservedNotForSaleOnPage(step1Response.body) &&
          !CullinanParser.isListedInBasketOnPage(step1Response.body)) {
        return const SaleListingSucceeded('غذا در سبد فروش قرار ندارد.');
      }

      // Find the cancellation button (active only if meal was in basket and not
      // yet sold).
      final cancelBtn = CullinanParser.parseSaleCancelButton(
        step1Response.body,
      );
      if (cancelBtn == null) {
        if (CullinanParser.parseSaleSubmitButton(step1Response.body) != null) {
          return const SaleListingSucceeded('غذا در سبد فروش قرار ندارد.');
        }
        return const SaleListingRefused(
          'دکمه حذف فروش در سامانه فعال نیست (احتمالاً غذا قبلاً فروخته شده یا مهلت آن به پایان رسیده است).',
        );
      }

      // Step 2: Post the cancel confirmation.
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
        CullinanPaths.basketSale,
        body: step2Body,
      );

      if (step2Response.looksLikeLoginPage) {
        return const SaleListingRefused('نشست منقضی شده است.');
      }

      final alert = CullinanParser.parseSaleAlert(step2Response.body);
      if (alert != null && alert.isNotEmpty) {
        final isSuccess =
            (alert.contains('موفق') ||
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

      // State verification: if meal reverted to reserved not for sale (sell
      // button rendered, cancel absent).
      if (CullinanParser.isReservedNotForSaleOnPage(step2Response.body)) {
        return const SaleListingSucceeded('غذا با موفقیت از سبد فروش خارج شد.');
      }

      // If cancel button is still present on step2Response, the cancellation
      // failed.
      if (CullinanParser.isListedInBasketOnPage(step2Response.body)) {
        return const SaleListingRefused(
          'لغو فروش غذا در سامانه تأیید نشد و غذا همچنان در سبد قرار دارد.',
        );
      }

      // Read-back verification via fresh reload.
      final verifyBody = CullinanParser.saleReloadFormBody(
        step2Response.body,
        jalaliDate: jalaliDate,
        slot: slot,
        reserveType: reserveType,
      );
      final verifyResponse = await transport.post(
        session.account,
        CullinanPaths.basketSale,
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

      return const SaleListingRefused(
        'غذای مورد نظر در سامانه یافت نشد (احتمالاً به فروش رفته است).',
      );
    } on TransportException catch (e) {
      return SaleListingAmbiguous(e.message);
    } catch (e) {
      return SaleListingAmbiguous(e.toString());
    }
  }
}
