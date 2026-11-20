import 'package:bahonar_nut/ui/features/reservations/batch_booking_loading_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: child),
      ),
    );
  }

  testWidgets(
    'BatchBookingLoadingDialog displays correct meal count with Persian digits and animation',
    (tester) async {
      await tester.pumpWidget(
        wrap(const BatchBookingLoadingDialog(mealCount: 4)),
      );

      // Verify Persian digits for 4 meals
      expect(find.text('در حال رزرو گروهی ۴ وعده غذا...'), findsOneWidget);

      // Verify initial status step
      expect(
        find.text('ارتباط امن با سامانه کالینان دانشگاه...'),
        findsOneWidget,
      );

      // Verify safety advisory
      expect(
        find.text('لطفاً تا پایان عملیات از برنامه خارج نشوید'),
        findsOneWidget,
      );

      // Verify dining/restaurant icon is present
      expect(find.byIcon(Icons.restaurant_rounded), findsOneWidget);

      // Verify circular progress indicator is present
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Advance time to verify smooth pulse animation and status text rotation
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 700));

      // After 2200ms timer ticks, status should rotate to second step
      await tester.pump(const Duration(milliseconds: 1000));
      expect(
        find.text('بررسی اعتبار و ثبت ژتون‌های انتخابی...'),
        findsOneWidget,
      );

      // Third step rotation
      await tester.pump(const Duration(milliseconds: 2200));
      expect(
        find.text('نهایی‌سازی رزروها... لطفاً شکیبا باشید.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('BatchBookingLoadingDialog prevents dismissal via PopScope', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const BatchBookingLoadingDialog(mealCount: 2)),
    );

    final popScopeFinder = find.byWidgetPredicate(
      (widget) => widget is PopScope && widget.canPop == false,
    );
    expect(popScopeFinder, findsOneWidget);
  });
}
