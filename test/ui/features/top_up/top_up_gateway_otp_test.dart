import 'package:bahonar_nut/core/finance/bank_card.dart';
import 'package:bahonar_nut/ui/features/top_up/top_up_gateway_screen.dart';
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
    void Function(void Function(String message)? handler)? onListenOtpSms,
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
    testWidgets('starts SMS user consent and receives OTP correctly', (
      tester,
    ) async {
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

      // SnackBar should confirm OTP receipt (truthful status: received, manual insertion available)
      expect(
        find.textContaining('رمز دوم پویا (۷۴۹۲۱۵) دریافت شد.'),
        findsOneWidget,
      );

      // Tap "درج در درگاه" chip button
      await tester.tap(find.text('درج در درگاه'));
      await tester.pumpAndSettle();
    });

    testWidgets('calls onReturned when clicking تکمیل و بازگشت', (
      tester,
    ) async {
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

    testWidgets(
      'handles consecutive payment sessions cleanly without stale callback leaks',
      (tester) async {
        void Function(String message)? currentSmsCallback;
        var startCount = 0;
        var stopCount = 0;

        // Session 1: First payment
        await tester.pumpWidget(
          createTestWidget(
            onStartSmsUserConsent: () async {
              startCount++;
              return true;
            },
            onStopSmsUserConsent: () async {
              stopCount++;
            },
            onListenOtpSms: (callback) {
              currentSmsCallback = callback;
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(startCount, equals(1));
        final firstCallback = currentSmsCallback;
        expect(firstCallback, isNotNull);

        // Receive SMS in Session 1
        firstCallback!('بانک ملت: رمز دوم پویا: 554433');
        await tester.pumpAndSettle();
        expect(find.textContaining('رمز دوم پویا: ۵۵۴۴۳۳'), findsOneWidget);

        // Exit / Dispose Session 1
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(stopCount, equals(1));

        // Attempting to send an SMS to the disposed callback must NOT throw or crash
        expect(
          () => firstCallback('بانک ملت: رمز دوم پویا: 998877'),
          returnsNormally,
        );

        // Session 2: Second payment in same app lifecycle
        await tester.pumpWidget(
          createTestWidget(
            onStartSmsUserConsent: () async {
              startCount++;
              return true;
            },
            onStopSmsUserConsent: () async {
              stopCount++;
            },
            onListenOtpSms: (callback) {
              currentSmsCallback = callback;
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(startCount, equals(2));
        final secondCallback = currentSmsCallback;
        expect(secondCallback, isNotNull);

        // Receive SMS in Session 2
        secondCallback!('بانک ملی: رمز دوم یکبار مصرف: 112233');
        await tester.pumpAndSettle();

        expect(find.textContaining('رمز دوم پویا: ۱۱۲۲۳۳'), findsOneWidget);
        expect(
          find.textContaining('رمز دوم پویا (۱۱۲۲۳۳) دریافت شد.'),
          findsOneWidget,
        );

        // Dispose Session 2
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(stopCount, equals(2));
      },
    );
  });
}
