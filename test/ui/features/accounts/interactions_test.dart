import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/features/accounts/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Interaction tests: the flows a user actually performs.
///
/// Driving these through the widget tester rather than by tapping a device
/// screen is deliberate. On a device, the soft keyboard moves the layout and
/// every tap coordinate has to be re-derived; here the same flow is exercised
/// deterministically, and the *device* run is left to confirm rendering.
void main() {
  Future<AppState> buildState() async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
    );
    await state.load();
    return state;
  }

  Widget wrap(AppState state, Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );
  }

  group('adding an account through the dialog', () {
    testWidgets('the typed values are saved and shown', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      await tester.tap(find.text('افزودن حساب'));
      await tester.pumpAndSettle();
      expect(find.text('افزودن حساب'), findsWidgets);

      // The student id field.
      await tester.enterText(
        find.widgetWithText(TextField, 'شماره دانشجویی'),
        '400123456',
      );
      // The alias field.
      await tester.enterText(
        find.widgetWithText(TextField, 'نام دلخواه (اختیاری)'),
        'برادر',
      );
      await tester.pumpAndSettle();

      // Save.
      await tester.tap(find.widgetWithText(FilledButton, 'افزودن'));
      await tester.pumpAndSettle();

      expect(state.accounts, hasLength(1));
      expect(state.accounts.single.studentId, '400123456');
      expect(state.accounts.single.resolvedName, 'برادر');

      // And the list now shows it.
      expect(find.text('برادر'), findsOneWidget);
    });

    testWidgets('the dialog is dismissed without saving on cancel',
        (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      await tester.tap(find.text('افزودن حساب'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'شماره دانشجویی'),
        '400123456',
      );
      await tester.tap(find.widgetWithText(TextButton, 'انصراف'));
      await tester.pumpAndSettle();

      expect(state.accounts, isEmpty);
    });

    testWidgets('an empty student id saves nothing', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      await tester.tap(find.text('افزودن حساب'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'افزودن'));
      await tester.pumpAndSettle();

      expect(state.accounts, isEmpty);
    });
  });

  group('editing an alias', () {
    testWidgets('an alias can be set and cleared', (tester) async {
      final state = await buildState();
      await state.upsertAccount(studentId: '400123456');
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      // Without an alias the student id is shown.
      expect(find.text('400123456'), findsWidgets);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'نام دلخواه (اختیاری)'),
        'برادر',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'ذخیره'));
      await tester.pumpAndSettle();

      expect(state.accounts.single.resolvedName, 'برادر');
      expect(find.text('برادر'), findsOneWidget);
    });
  });

  group('deleting an account', () {
    testWidgets('the confirmation is required', (tester) async {
      final state = await buildState();
      await state.upsertAccount(studentId: '400123456', alias: 'برادر');
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();

      // The dialog warns that the removal is complete and irreversible.
      expect(find.text('حذف حساب'), findsOneWidget);
      expect(find.textContaining('برگشت‌پذیر نیست'), findsOneWidget);

      // Cancel first: the account survives.
      await tester.tap(find.widgetWithText(TextButton, 'انصراف'));
      await tester.pumpAndSettle();
      expect(state.accounts, hasLength(1));

      // Then really delete it.
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'حذف کن'));
      await tester.pumpAndSettle();

      expect(state.accounts, isEmpty);
    });
  });
}
