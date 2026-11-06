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
    Future<void> Function(SavedBankCard)? onSaveCard,
    Future<void> Function(String)? onDeleteCard,
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
        onSaveCard: onSaveCard,
        onDeleteCard: onDeleteCard,
        onReturned: onReturned,
      ),
    );
  }

  group('TopUpGatewayScreen Card Vault & Security', () {
    testWidgets('displays saved cards and allows toggling manual entry mode', (tester) async {
      await tester.pumpWidget(createTestWidget());
      await tester.pumpAndSettle();

      // Verify cards bar header and card chip exist
      expect(find.text('کارت‌های ذخیره‌شده (با احراز هویت بیومتریک):'), findsOneWidget);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('ورود دستی'), findsOneWidget);

      // Tap "ورود دستی" (manual entry)
      await tester.tap(find.text('ورود دستی'));
      await tester.pumpAndSettle();

      // Cards bar should now be collapsed and manual entry status shown
      expect(find.text('حالت ورود دستی اطلاعات فعال است'), findsOneWidget);
      expect(find.text('نمایش کارت‌ها'), findsOneWidget);
      expect(find.text('کارت‌های ذخیره‌شده (با احراز هویت بیومتریک):'), findsNothing);

      // Tap "نمایش کارت‌ها" to expand back
      await tester.tap(find.text('نمایش کارت‌ها'));
      await tester.pumpAndSettle();

      expect(find.text('کارت‌های ذخیره‌شده (با احراز هویت بیومتریک):'), findsOneWidget);
      expect(find.byType(InputChip), findsOneWidget);
    });

    testWidgets('biometric gate blocks autofill if authentication fails or is cancelled', (tester) async {
      var biometricPrompted = false;

      await tester.pumpWidget(
        createTestWidget(
          onAuthenticateBiometric: () async {
            biometricPrompted = true;
            return false; // Authentication failed / cancelled
          },
        ),
      );
      await tester.pumpAndSettle();

      // Tap the card chip
      await tester.tap(find.byType(InputChip));
      await tester.pumpAndSettle();

      expect(biometricPrompted, isTrue);
      // SnackBar should warn about failed biometric auth
      expect(find.text('احراز هویت بیومتریک انجام نشد. اطلاعات کارت درج نگردید.'), findsOneWidget);
    });

    testWidgets('biometric gate approves autofill when authentication succeeds', (tester) async {
      var biometricPrompted = false;

      await tester.pumpWidget(
        createTestWidget(
          onAuthenticateBiometric: () async {
            biometricPrompted = true;
            return true; // Authentication succeeded
          },
        ),
      );
      await tester.pumpAndSettle();

      // Tap the card chip
      await tester.tap(find.byType(InputChip));
      await tester.pumpAndSettle();

      expect(biometricPrompted, isTrue);
      expect(find.text('احراز هویت بیومتریک انجام نشد. اطلاعات کارت درج نگردید.'), findsNothing);
    });

    testWidgets('deleting card from vault invokes onDeleteCard callback', (tester) async {
      String? deletedCardId;

      await tester.pumpWidget(
        createTestWidget(
          onDeleteCard: (id) async {
            deletedCardId = id;
          },
        ),
      );
      await tester.pumpAndSettle();

      // Tap the delete icon on the chip
      await tester.tap(find.descendant(of: find.byType(InputChip), matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();

      expect(deletedCardId, equals('c1'));
    });

    testWidgets('cancelling without payment does NOT show card save dialog', (tester) async {
      var returned = false;

      await tester.pumpWidget(
        createTestWidget(
          onReturned: () => returned = true,
        ),
      );
      await tester.pumpAndSettle();

      // Tap back button
      await tester.tap(find.byTooltip('بازگشت به برنامه'));
      await tester.pumpAndSettle();

      // Card save dialog must NOT appear
      expect(find.text('ذخیره امن در گاوصندوق کارت‌ها'), findsNothing);
      expect(returned, isTrue);
    });
  });
}
