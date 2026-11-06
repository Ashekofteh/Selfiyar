import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/ui/screens/booking_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final date = DateTime(2026, 10, 25);
  const hall = Hall(id: '1', name: 'سلف مرکزی');
  final menu = MealMenu(
    date: date,
    slot: MealSlot.lunch,
    halls: const [hall],
    dishes: const [
      MenuOption(
        id: '101',
        name: 'چلو جوجه کباب',
        priceRial: 250000,
      ),
      MenuOption(
        id: '102',
        name: 'چلو قورمه سبزی',
        priceRial: 180000,
      ),
    ],
    reservable: true,
  );

  testWidgets('BookingSheet renders deficit notice when balance is insufficient',
      (tester) async {
    int? requestedDeficit;
    MealOffering? requestedOffering;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingSheet(
            menu: menu,
            currentBalanceRial: 100000, // 10,000 Toman, meal is 25,000 Toman -> 15,000 Toman deficit
            onTopUp: (deficit, offering) {
              requestedDeficit = deficit;
              requestedOffering = offering;
            },
            onBook: (_) async => null,
          ),
        ),
      ),
    );

    // Tap first dish (250,000 Rial)
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    // Deficit is 250,000 - 100,000 = 150,000 Rial (15,000 Toman).
    expect(find.text('کسری موجودی: ${formatTomanPersian(150000)}'), findsOneWidget);
    expect(find.text('افزایش موجودی'), findsOneWidget);

    // Tap on top up
    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    expect(requestedDeficit, 150000);
    expect(requestedOffering, isNotNull);
    expect(requestedOffering?.option.id, '101');
    expect(requestedOffering?.option.name, 'چلو جوجه کباب');
  });

  testWidgets('BookingSheet deficit updates when choosing different priced dish',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingSheet(
            menu: menu,
            currentBalanceRial: 150000, // 15,000 Toman
            onBook: (_) async => null,
          ),
        ),
      ),
    );

    // Tap first dish 250,000 -> deficit 100,000
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();
    expect(find.text('کسری موجودی: ${formatTomanPersian(100000)}'), findsOneWidget);

    // Switch to second option 180,000 -> deficit 30,000
    await tester.tap(find.text('چلو قورمه سبزی'));
    await tester.pumpAndSettle();

    expect(find.text('کسری موجودی: ${formatTomanPersian(30000)}'), findsOneWidget);
  });

  testWidgets('BookingSheet does not show deficit notice when balance is sufficient',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingSheet(
            menu: menu,
            currentBalanceRial: 500000, // 50,000 Toman > 25,000 Toman
            onBook: (_) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    expect(find.textContaining('کسری موجودی'), findsNothing);
    expect(find.text('افزایش موجودی'), findsNothing);
  });
}
