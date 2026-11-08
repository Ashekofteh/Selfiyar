import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/ui/widgets/hunt_success_dialog.dart';

void main() {
  testWidgets('HuntSuccessDialog renders celebratory info and details', (tester) async {
    var viewedReservations = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                HuntSuccessDialog.show(
                  context: context,
                  dishName: 'چلو کباب کوبیده',
                  hallName: 'سلف مرکزی',
                  priceRial: 500000,
                  date: DateTime.utc(2026, 11, 12),
                  slot: MealSlot.lunch,
                  onViewReservations: () {
                    viewedReservations = true;
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    // Tap to open dialog
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Verify Title and Subtitle
    expect(find.text('شکار موفق غذا!'), findsOneWidget);
    expect(find.text('غذای انتخابی شما با موفقیت از بازار سبد غذا خریداری و رزرو شد.'), findsOneWidget);

    // Verify Details
    expect(find.text('چلو کباب کوبیده'), findsOneWidget);
    expect(find.text('سلف مرکزی'), findsOneWidget);
    expect(find.text('۵۰٬۰۰۰ تومان'), findsOneWidget);
    expect(find.textContaining('ناهار'), findsOneWidget);

    // Tap View Reservations
    await tester.tap(find.text('مشاهده رزروها'));
    await tester.pumpAndSettle();

    expect(viewedReservations, isTrue);
    expect(find.text('شکار موفق غذا!'), findsNothing);
  });
}
