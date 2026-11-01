import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/meal_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final saturday = DateTime.utc(2026, 10, 24);

  const hallCentral = Hall(id: '1', name: 'سلف مرکزی برادران');
  const hallEng = Hall(id: '2', name: 'سلف مهندسی');

  const optQormeh = MenuOption(id: '101', name: 'چلوخورشت سبزی', priceRial: 350000);
  const optJoojeh = MenuOption(id: '102', name: 'چلو جوجه کباب', priceRial: 500000);

  final testMenu = MealMenu(
    date: saturday,
    slot: MealSlot.lunch,
    halls: const [hallCentral, hallEng],
    dishes: const [optQormeh, optJoojeh],
    reservable: true,
  );

  Widget wrap(Widget child) {
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

  group('MealDetailSheet', () {
    testWidgets('renders full untruncated dish name, hall name, and status', (tester) async {
      final row = MealRow(
        date: saturday,
        slot: MealSlot.lunch,
        dishName: 'چلو جوجه کباب مخصوص به همراه ماست موسیر و نوشیدنی',
        hallName: 'سلف مرکزی برادران',
        priceRial: 500000,
        status: MealRowStatus.held,
      );

      await tester.pumpWidget(wrap(MealDetailSheet(
        row: row,
        menu: testMenu,
        accountName: 'علی محمدی',
      )));
      await tester.pumpAndSettle();

      expect(find.text('چلو جوجه کباب مخصوص به همراه ماست موسیر و نوشیدنی'), findsOneWidget);
      expect(find.textContaining('سلف توزیع: سلف مرکزی برادران'), findsOneWidget);
      expect(find.text('علی محمدی'), findsOneWidget);
      expect(find.text(formatTomanPersian(500000)), findsWidgets);
    });

    testWidgets('allows changing dish and hall when cancellable and reservable', (tester) async {
      MealOffering? submittedOffering;

      final row = MealRow(
        date: saturday,
        slot: MealSlot.lunch,
        dishName: optQormeh.name,
        hallName: hallCentral.name,
        priceRial: optQormeh.priceRial,
        status: MealRowStatus.held,
      );

      await tester.pumpWidget(wrap(MealDetailSheet(
        row: row,
        menu: testMenu,
        currentBalanceRial: 200000,
        onModify: (offering) async {
          submittedOffering = offering;
          return null;
        },
      )));
      await tester.pumpAndSettle();

      // Initially no save button because selection hasn't changed
      expect(find.text('ذخیره تغییرات'), findsNothing);

      // Select the alternative dish (چلو جوجه کباب)
      await tester.tap(find.text(optJoojeh.name));
      await tester.pumpAndSettle();

      // Price difference and save button should appear
      expect(find.text('ذخیره تغییرات'), findsOneWidget);
      expect(find.textContaining('+${formatTomanPersian(150000)}'), findsWidgets);

      // Tap save
      await tester.ensureVisible(find.text('ذخیره تغییرات'));
      await tester.tap(find.text('ذخیره تغییرات'));
      await tester.pumpAndSettle();

      expect(submittedOffering, isNotNull);
      expect(submittedOffering?.option.id, optJoojeh.id);
      expect(submittedOffering?.hall.id, hallCentral.id);
    });

    testWidgets('renders explanation and no edit options when row is heldLocked', (tester) async {
      bool sellTapped = false;

      final row = MealRow(
        date: saturday,
        slot: MealSlot.lunch,
        dishName: optQormeh.name,
        hallName: hallCentral.name,
        priceRial: optQormeh.priceRial,
        status: MealRowStatus.heldLocked,
      );

      await tester.pumpWidget(wrap(MealDetailSheet(
        row: row,
        menu: testMenu,
        onSell: () => sellTapped = true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('تغییر نوع غذا یا سلف توزیع'), findsNothing);
      expect(find.text('مهلت رزرو، ویرایش یا لغو این تاریخ به پایان رسیده است.'), findsOneWidget);
      expect(find.text('فروش در سبد غذایی'), findsOneWidget);

      await tester.tap(find.text('فروش در سبد غذایی'));
      await tester.pumpAndSettle();

      expect(sellTapped, isTrue);
    });

    testWidgets('displays receipt code card when receiptCode is present', (tester) async {
      final row = MealRow(
        date: saturday,
        slot: MealSlot.lunch,
        dishName: optQormeh.name,
        hallName: hallCentral.name,
        priceRial: optQormeh.priceRial,
        status: MealRowStatus.held,
        receiptCode: '84920',
      );

      await tester.pumpWidget(wrap(MealDetailSheet(
        row: row,
        menu: testMenu,
      )));
      await tester.pumpAndSettle();

      expect(find.text('کد فیش فراموشی صادر شده'), findsOneWidget);
      expect(find.text(toPersianDigits('84920')), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });
  });
}
