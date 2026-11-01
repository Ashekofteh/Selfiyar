import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/reservations_table.dart';
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
      home: Scaffold(
        body: Directionality(
          textDirection: TextDirection.rtl,
          child: child,
        ),
      ),
    );
  }

  final testDate = DateTime.utc(2026, 10, 20);

  group('ReservationsTable - Food Basket Sale action', () {
    testWidgets('renders basket outline button for heldLocked row when onSell is provided',
        (tester) async {
      DateTime? soldDate;
      MealSlot? soldSlot;

      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
          hallName: 'مرکزی برادران',
          priceRial: 400000,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (date, slot) {
              soldDate = date;
              soldSlot = slot;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sellButtonFinder = find.widgetWithIcon(IconButton, Icons.shopping_basket_outlined);
      expect(sellButtonFinder, findsOneWidget);
      expect(find.byTooltip('فروش در سبد غذایی'), findsOneWidget);

      await tester.tap(sellButtonFinder);
      await tester.pump();

      expect(soldDate, testDate);
      expect(soldSlot, MealSlot.lunch);
    });

    testWidgets('disables sell button when row is marked busy', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
          hallName: 'مرکزی برادران',
          priceRial: 400000,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            busy: true,
            busyKey: '2026-10-20|lunch',
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.shopping_basket_outlined),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('renders lock clock icon when onSell is null', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('فروش در سبد غذایی'), findsNothing);
      expect(find.byIcon(Icons.lock_clock_outlined), findsOneWidget);
    });

    testWidgets('bought row renders lock icon and no sell button', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.bought,
          dishName: 'چلو اکبرجوجه',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('فروش در سبد غذایی'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('renders filled basket button and "در سبد فروش" for listedInBasket row',
        (tester) async {
      DateTime? removedDate;
      MealSlot? removedSlot;

      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.listedInBasket,
          dishName: 'چلو قرمه سبزی',
          hallName: 'مرکزی برادران',
          priceRial: 400000,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onRemoveFromSell: (date, slot) {
              removedDate = date;
              removedSlot = slot;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('در سبد فروش'), findsOneWidget);

      final removeButtonFinder = find.byTooltip('در سبد فروش (حذف از سبد)');
      expect(removeButtonFinder, findsOneWidget);
      expect(find.byIcon(Icons.shopping_basket), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);

      await tester.tap(removeButtonFinder);
      await tester.pump();

      expect(removedDate, testDate);
      expect(removedSlot, MealSlot.lunch);
    });

    testWidgets('disables remove-from-sale button when row is marked busy', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.listedInBasket,
          dishName: 'چلو قرمه سبزی',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            busy: true,
            busyKey: '2026-10-20|lunch',
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onRemoveFromSell: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.shopping_basket),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
    testWidgets('disables receipt button when row is listedInBasket', (tester) async {
      bool receiptCalled = false;
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.listedInBasket,
          dishName: 'چلو قرمه سبزی',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onRemoveFromSell: (_, _) {},
            onForgotReceipt: (_, _, _, _) {
              receiptCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final receiptBtnFinder = find.byTooltip('غذا در سبد فروش قرار دارد و دریافت فیش ممکن نیست');
      expect(receiptBtnFinder, findsOneWidget);

      final button = tester.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.receipt_long), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull);

      await tester.tap(receiptBtnFinder);
      await tester.pump();
      expect(receiptCalled, isFalse);
    });

    testWidgets('enables receipt button when row is heldLocked and not listedInBasket', (tester) async {
      bool receiptCalled = false;
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
            onForgotReceipt: (_, _, _, _) {
              receiptCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final receiptBtnFinder = find.byTooltip('دریافت فیش فراموشی');
      expect(receiptBtnFinder, findsOneWidget);

      final button = tester.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.receipt_long), matching: find.byType(IconButton)));
      expect(button.onPressed, isNotNull);

      await tester.tap(receiptBtnFinder);
      await tester.pump();
      expect(receiptCalled, isTrue);
    });
  });
}
