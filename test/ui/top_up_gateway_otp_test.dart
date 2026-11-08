import 'package:bahonar_nut/core/bank_card.dart';
import 'package:bahonar_nut/ui/screens/top_up_gateway_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const card1 = SavedBankCard(
    id: 'c1',
    pan: '6219861012343769',
    title: 'کارت اصلی سامان',
    bankName: 'بانک سامان',
    expMonth: '08',
    expYear: '05',
    cvv2: '321',
  );

  Widget createTestWidget({
    List<SavedBankCard> savedCards = const [card1],
    Future<bool> Function()? onAuthenticateBiometric,
    Future<bool> Function()? onStartSmsUserConsent,
    void Function(void Function(String message))? onListenOtpSms,
    Future<void> Function()? onStopSmsUserConsent,
    void Function()? onReturned,
  }) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: TopUpGatewayScreen(
        gateway: Uri.parse('https://sep.shaparak.ir/OnlinePayment/test'),
        cookies: const {'ASP.NET_SessionId': 'session123'},
        portalHost: 'nut.uk.ac.ir',
        savedCards: savedCards,
        autoLaunchBrowser: false,
        onAuthenticateBiometric: onAuthenticateBiometric,
        onStartSmsUserConsent: onStartSmsUserConsent,
        onListenOtpSms: onListenOtpSms,
        onStopSmsUserConsent: onStopSmsUserConsent,
        onReturned: onReturned,
      ),
    );
  }

  group('TopUpGatewayScreen OTP Autofill & UI Integration', () {
    testWidgets('starts SMS user consent and receives OTP correctly', (tester) async {
      var smsStarted = false;
      void Function(String message)? smsCallback;

      await tester.pumpWidget(
        createTestWidget(
          onStartSmsUserConsent: () async {
            smsStarted = true;
            return true;
          },
          onListenOtpSms: (callback) {
            smsCallback = callback;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(smsStarted, isTrue);
      expect(smsCallback, isNotNull);

      // Initially, no OTP chip is shown
      expect(find.textContaining('رمز دوم پویا:'), findsNothing);

      // Simulate incoming SMS from bank
      smsCallback!('بانک سامان\nرمز دوم پویا: 749215 برای خرید اینترنتی');
      await tester.pumpAndSettle();

      // OTP chip should now be visible with Persian digits
      expect(find.textContaining('رمز دوم پویا: ۷۴۹۲۱۵'), findsOneWidget);
      expect(find.text('درج در درگاه'), findsOneWidget);

      // SnackBar should confirm OTP receipt
      expect(find.textContaining('رمز دوم پویا (۷۴۹۲۱۵) با موفقیت دریافت و در فیلد درج شد.'), findsOneWidget);

      // Tap "درج در درگاه" chip button
      await tester.tap(find.text('درج در درگاه'));
      await tester.pumpAndSettle();
    });

    testWidgets('calls onReturned when clicking تکمیل و بازگشت', (tester) async {
      var returnedCalled = false;

      await tester.pumpWidget(
        createTestWidget(
          onReturned: () {
            returnedCalled = true;
          },
        ),
      );
      await tester.pumpAndSettle();

      // Tap "تکمیل و بازگشت" on AppBar
      await tester.tap(find.text('تکمیل و بازگشت'));
      await tester.pumpAndSettle();

      expect(returnedCalled, isTrue);
    });
  });
}
