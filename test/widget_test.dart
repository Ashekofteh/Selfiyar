import 'package:bahonar_nut/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app's shell test: it must start, in Persian, right-to-left, with the
/// four destinations present.
void main() {
  testWidgets('the app starts in Persian with all four destinations', (
    tester,
  ) async {
    await tester.pumpWidget(const SelfiyarApp());
    await tester.pumpAndSettle();

    // The app bar of the first screen.
    expect(find.text('حساب‌ها'), findsWidgets);

    // The four navigation destinations.
    expect(find.text('رزروها'), findsOneWidget);
    expect(find.text('مالی'), findsOneWidget);
    expect(find.text('یادآورها'), findsOneWidget);
  });

  testWidgets('the layout is right-to-left', (tester) async {
    await tester.pumpWidget(const SelfiyarApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('fa', 'IR'));
    expect(
      Directionality.of(tester.element(find.byType(NavigationBar))),
      TextDirection.rtl,
      reason: 'a Persian app must lay out right-to-left',
    );
  });

  testWidgets('the Persian localisations are available', (tester) async {
    await tester.pumpWidget(const SelfiyarApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.localizationsDelegates,
      contains(GlobalMaterialLocalizations.delegate),
    );
    expect(
      app.localizationsDelegates,
      contains(GlobalWidgetsLocalizations.delegate),
    );
  });
}
