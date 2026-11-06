import 'package:bahonar_nut/core/bank_card.dart';
import 'package:bahonar_nut/ui/screens/top_up_gateway_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TopUpGatewayScreen renders desktop instructions and copy card actions', (tester) async {
    String clipboardDataText = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          final args = methodCall.arguments as Map<dynamic, dynamic>;
          clipboardDataText = args['text'] as String? ?? '';
          return null;
        } else if (methodCall.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboardDataText};
        }
        return null;
      },
    );

    final cards = [
      const SavedBankCard(
        id: 'card_1',
        title: 'بلو بانک',
        pan: '6219861012345678',
        cvv2: '123',
        expMonth: '12',
        expYear: '05',
      ),
    ];

    var returnedCalled = false;
    Uri? launchedUri;

    await tester.pumpWidget(
      MaterialApp(
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
          savedCards: cards,
          autoLaunchBrowser: false,
          onLaunchExternalBrowser: (uri) async => launchedUri = uri,
          onReturned: () => returnedCalled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify desktop card content is rendered on desktop (Windows / macOS / Linux)
    expect(find.text('انتقال به درگاه رسمی پرداخت شاپرک'), findsOneWidget);
    expect(find.text('تکمیل و ثبت نهایی در برنامه'), findsOneWidget);
    expect(find.text('باز کردن مجدد درگاه'), findsOneWidget);
    expect(find.text('بلو بانک'), findsOneWidget);

    // Test clicking re-open in external browser
    await tester.ensureVisible(find.text('باز کردن مجدد درگاه'));
    await tester.tap(find.text('باز کردن مجدد درگاه'));
    await tester.pumpAndSettle();
    expect(launchedUri, Uri.parse('https://sep.shaparak.ir/OnlinePayment/test'));

    // Test copying card number
    await tester.ensureVisible(find.byTooltip('کپی شماره کارت'));
    await tester.tap(find.byTooltip('کپی شماره کارت'));
    await tester.pumpAndSettle();

    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboardData?.text, '6219861012345678');

    // Test copying expiration date
    await tester.ensureVisible(find.byTooltip('کپی تاریخ انقضا'));
    await tester.tap(find.byTooltip('کپی تاریخ انقضا'));
    await tester.pumpAndSettle();

    final expData = await Clipboard.getData(Clipboard.kTextPlain);
    expect(expData?.text, '05/12');

    // Test copying CVV2
    await tester.ensureVisible(find.byTooltip('کپی کد CVV2'));
    await tester.tap(find.byTooltip('کپی کد CVV2'));
    await tester.pumpAndSettle();

    final cvvData = await Clipboard.getData(Clipboard.kTextPlain);
    expect(cvvData?.text, '123');

    // Test clicking complete and return button
    await tester.ensureVisible(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    expect(returnedCalled, isTrue);
  });

  testWidgets('Desktop CVV2 copy refuses if biometric authentication fails', (tester) async {
    String clipboardDataText = 'initial';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          final args = methodCall.arguments as Map<dynamic, dynamic>;
          clipboardDataText = args['text'] as String? ?? '';
          return null;
        } else if (methodCall.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboardDataText};
        }
        return null;
      },
    );

    const cards = [
      SavedBankCard(
        id: 'c1',
        title: 'کارت امن',
        pan: '6219861012345678',
        cvv2: '999',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
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
          savedCards: cards,
          autoLaunchBrowser: false,
          onAuthenticateBiometric: () async => false, // authentication denied
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('کپی کد CVV2'));
    await tester.tap(find.byTooltip('کپی کد CVV2'));
    await tester.pumpAndSettle();

    expect(find.text('احراز هویت انجام نشد. کد CVV2 کپی نشد.'), findsOneWidget);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    expect(data?.text, equals('initial')); // Clipboard was NOT updated with CVV2
  });
}
