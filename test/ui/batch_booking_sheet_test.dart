import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/batch_booking_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final saturday = DateTime.utc(2026, 10, 24);
  final sunday = DateTime.utc(2026, 10, 25);

  final hallCentral = const Hall(id: '1', name: 'سلف مرکزی برادران');
  final hallEng = const Hall(id: '2', name: 'سلف مهندسی');

  final optQormeh = const MenuOption(id: '101', name: 'چلوخورشت سبزی', priceRial: 350000); // 35,000 Toman
  final optJoojeh = const MenuOption(id: '102', name: 'چلو جوجه کباب', priceRial: 500000); // 50,000 Toman
  final optFish = const MenuOption(id: '201', name: 'شوید پلو با تن ماهی', priceRial: 400000); // 40,000 Toman

  final testMenus = [
    MealMenu(
      date: saturday,
      slot: MealSlot.lunch,
      halls: [hallCentral, hallEng],
      dishes: [optQormeh, optJoojeh],
      reservable: true,
    ),
    MealMenu(
      date: sunday,
      slot: MealSlot.lunch,
      halls: [hallCentral, hallEng],
      dishes: [optFish],
      reservable: true,
    ),
  ];

  final rowSaturday = MealRow(
    date: saturday,
    slot: MealSlot.lunch,
    dishName: optQormeh.name,
    hallName: hallCentral.name,
    priceRial: optQormeh.priceRial,
    status: MealRowStatus.bookable,
  );

  final rowSunday = MealRow(
    date: sunday,
    slot: MealSlot.lunch,
    dishName: optFish.name,
    hallName: hallCentral.name,
    priceRial: optFish.priceRial,
    status: MealRowStatus.bookable,
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
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: child),
      ),
    );
  }

  testWidgets('BatchBookingSheet allows choosing dish and hall and confirms exact offerings', (tester) async {
    List<MealOffering>? confirmedOfferings;

    await tester.pumpWidget(
      wrap(
        BatchBookingSheet(
          menus: testMenus,
          selectedRows: [rowSaturday, rowSunday],
          currentBalanceRial: 1000000, // 100,000 Toman - plenty
          onConfirm: (offerings) async {
            confirmedOfferings = offerings;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify header and selected dishes are shown
    expect(find.text('رزرو دسته‌ای ۲ وعده'), findsOneWidget);
    expect(find.text('چلوخورشت سبزی'), findsOneWidget);
    expect(find.text('چلو جوجه کباب'), findsOneWidget);
    expect(find.text('شوید پلو با تن ماهی'), findsOneWidget);

    // Initial total is 35,000 + 40,000 = 75,000 Toman (750,000 Rial)
    expect(find.text(formatTomanPersian(750000)), findsWidgets);

    // Switch Saturday dish from Qormeh (35k) to Joojeh (50k)
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    // Total should now be 50,000 + 40,000 = 90,000 Toman (900,000 Rial)
    expect(find.text(formatTomanPersian(900000)), findsWidgets);

    // Switch global hall to "سلف مهندسی"
    await tester.tap(find.widgetWithText(ChoiceChip, 'سلف مهندسی'));
    await tester.pumpAndSettle();

    // Confirm booking
    await tester.tap(find.text('تایید و ثبت رزرو (۲ وعده)'));
    await tester.pumpAndSettle();

    expect(confirmedOfferings, isNotNull);
    expect(confirmedOfferings!.length, 2);

    // Saturday offering must have Joojeh and Engineering hall
    final satOffering = confirmedOfferings!.firstWhere((o) => o.date == saturday);
    expect(satOffering.option.name, 'چلو جوجه کباب');
    expect(satOffering.option.priceRial, 500000);
    expect(satOffering.hall.name, 'سلف مهندسی');

    // Sunday offering must have Fish and Engineering hall
    final sunOffering = confirmedOfferings!.firstWhere((o) => o.date == sunday);
    expect(sunOffering.option.name, 'شوید پلو با تن ماهی');
    expect(sunOffering.hall.name, 'سلف مهندسی');
  });

  testWidgets('BatchBookingSheet handles deficit and directs to top up with pending offerings', (tester) async {
    int? capturedDeficit;
    List<MealOffering>? capturedOfferings;

    await tester.pumpWidget(
      wrap(
        BatchBookingSheet(
          menus: testMenus,
          selectedRows: [rowSaturday],
          currentBalanceRial: 200000, // 20,000 Toman - deficit of 15,000 Toman (150,000 Rial)
          onConfirm: (_) async {},
          onTopUp: (deficit, offerings) {
            capturedDeficit = deficit;
            capturedOfferings = offerings;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('کسری موجودی: ${formatTomanPersian(150000)}'), findsOneWidget);
    expect(find.text('شارژ حساب (${formatTomanPersian(150000)}) و رزرو خودکار'), findsOneWidget);

    await tester.tap(find.text('شارژ حساب (${formatTomanPersian(150000)}) و رزرو خودکار'));
    await tester.pumpAndSettle();

    expect(capturedDeficit, 150000);
    expect(capturedOfferings, isNotNull);
    expect(capturedOfferings!.single.option.name, 'چلوخورشت سبزی');
  });

  testWidgets(
      'BatchBookingSheet sorts items chronologically ascending by date and slot',
      (tester) async {
    final rowSatBreakfast = MealRow(
      date: saturday,
      slot: MealSlot.breakfast,
      dishName: 'نیمرو',
      hallName: hallCentral.name,
      priceRial: 100000,
      status: MealRowStatus.bookable,
    );
    final rowSatLunch = MealRow(
      date: saturday,
      slot: MealSlot.lunch,
      dishName: optQormeh.name,
      hallName: hallCentral.name,
      priceRial: optQormeh.priceRial,
      status: MealRowStatus.bookable,
    );
    final rowSatDinner = MealRow(
      date: saturday,
      slot: MealSlot.dinner,
      dishName: 'ماکارونی',
      hallName: hallCentral.name,
      priceRial: 200000,
      status: MealRowStatus.bookable,
    );
    final rowSunLunch = MealRow(
      date: sunday,
      slot: MealSlot.lunch,
      dishName: optFish.name,
      hallName: hallCentral.name,
      priceRial: optFish.priceRial,
      status: MealRowStatus.bookable,
    );

    final menus = [
      MealMenu(
        date: saturday,
        slot: MealSlot.breakfast,
        halls: [hallCentral],
        dishes: const [MenuOption(id: '99', name: 'نیمرو', priceRial: 100000)],
        reservable: true,
      ),
      MealMenu(
        date: saturday,
        slot: MealSlot.lunch,
        halls: [hallCentral],
        dishes: [optQormeh],
        reservable: true,
      ),
      MealMenu(
        date: saturday,
        slot: MealSlot.dinner,
        halls: [hallCentral],
        dishes: const [MenuOption(id: '88', name: 'ماکارونی', priceRial: 200000)],
        reservable: true,
      ),
      MealMenu(
        date: sunday,
        slot: MealSlot.lunch,
        halls: [hallCentral],
        dishes: [optFish],
        reservable: true,
      ),
    ];

    List<MealOffering>? confirmedOfferings;

    // Pass them intentionally out-of-order: Sunday lunch, Saturday dinner, Saturday lunch, Saturday breakfast
    await tester.pumpWidget(
      wrap(
        BatchBookingSheet(
          menus: menus,
          selectedRows: [
            rowSunLunch,
            rowSatDinner,
            rowSatLunch,
            rowSatBreakfast,
          ],
          currentBalanceRial: 10000000,
          onConfirm: (offerings) async {
            confirmedOfferings = offerings;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Confirm booking
    await tester.tap(find.text('تایید و ثبت رزرو (۴ وعده)'));
    await tester.pumpAndSettle();

    expect(confirmedOfferings, isNotNull);
    expect(confirmedOfferings!.length, 4);

    // Verify strict chronological order
    expect(confirmedOfferings![0].date, saturday);
    expect(confirmedOfferings![0].slot, MealSlot.breakfast);

    expect(confirmedOfferings![1].date, saturday);
    expect(confirmedOfferings![1].slot, MealSlot.lunch);

    expect(confirmedOfferings![2].date, saturday);
    expect(confirmedOfferings![2].slot, MealSlot.dinner);

    expect(confirmedOfferings![3].date, sunday);
    expect(confirmedOfferings![3].slot, MealSlot.lunch);
  });
}
