import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/reservations_table.dart';

class _FakePlainStore implements PlainStore {
  final Map<String, dynamic> data = {};

  @override
  Future<Set<String>> keys() async => data.keys.toSet();

  @override
  Future<bool?> readBool(String key) async => data[key] as bool?;

  @override
  Future<int?> readInt(String key) async => data[key] as int?;

  @override
  Future<String?> readString(String key) async => data[key] as String?;

  @override
  Future<void> remove(String key) async => data.remove(key);

  @override
  Future<void> writeBool(String key, bool value) async => data[key] = value;

  @override
  Future<void> writeInt(String key, int value) async => data[key] = value;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}

void main() {
  group('Forgot Receipt Caching in AppState', () {
    test('AppState records, retrieves, and restores receipt code per account, date, and slot', () async {
      final store = _FakePlainStore();
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        plainStore: store,
      );
      await state.load();

      final date = DateTime.utc(2026, 10, 20);
      expect(state.receiptCodeFor('user1', date, MealSlot.lunch), isNull);

      state.recordReceipt('user1', date, MealSlot.lunch, '987654');
      expect(state.receiptCodeFor('user1', date, MealSlot.lunch), '987654');

      // Different meal slot or date does not have it
      expect(state.receiptCodeFor('user1', date, MealSlot.dinner), isNull);
      expect(state.receiptCodeFor('user1', DateTime.utc(2026, 10, 21), MealSlot.lunch), isNull);

      // Different account does not have it
      expect(state.receiptCodeFor('user2', date, MealSlot.lunch), isNull);

      // Verify persistence to store
      expect(store.data[StoreKeys.forgotReceipts], contains('987654'));

      // Test restoring across app restart / reload
      final restoredState = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        plainStore: store,
      );
      await restoredState.load();
      expect(restoredState.receiptCodeFor('user1', date, MealSlot.lunch), '987654');
    });
  });

  group('ReservationsTable Receipt Button Display', () {
    testWidgets('shows Icons.receipt when code is cached and Icons.receipt_long when not', (tester) async {
      final date = DateTime.utc(2026, 10, 20);
      final rows = [
        MealRow(
          date: date,
          slot: MealSlot.lunch,
          status: MealRowStatus.held,
          dishName: 'چلو کباب',
          receiptCode: '123456',
        ),
        MealRow(
          date: date,
          slot: MealSlot.dinner,
          status: MealRowStatus.bought,
          dishName: 'خورشت قیمه',
          receiptCode: null,
        ),
      ];

      expect(rows[0].hasReceipt, isTrue);
      expect(rows[1].hasReceipt, isFalse);

      DateTime? clickedDate;
      MealSlot? clickedSlot;
      String? clickedDish;
      ReserveType? clickedReserveType;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReservationsTable(
              rows: rows,
              onBook: (_, __) {},
              onCancel: (_, __) {},
              onForgotReceipt: (d, s, dish, rType) {
                clickedDate = d;
                clickedSlot = s;
                clickedDish = dish;
                clickedReserveType = rType;
              },
            ),
          ),
        ),
      );

      // Verify cached receipt row has Icons.receipt
      final cachedIcon = find.byIcon(Icons.receipt);
      expect(cachedIcon, findsOneWidget);

      // Verify un-cached receipt row has Icons.receipt_long
      final freshIcon = find.byIcon(Icons.receipt_long);
      expect(freshIcon, findsOneWidget);

      // Tap cached receipt icon
      await tester.tap(cachedIcon);
      await tester.pump();

      expect(clickedDate, date);
      expect(clickedSlot, MealSlot.lunch);
      expect(clickedDish, 'چلو کباب');
      expect(clickedReserveType, ReserveType.weekly);

      // Tap un-cached receipt icon for bought meal
      await tester.tap(freshIcon);
      await tester.pump();

      expect(clickedDate, date);
      expect(clickedSlot, MealSlot.dinner);
      expect(clickedDish, 'خورشت قیمه');
      expect(clickedReserveType, ReserveType.foodBasket);
    });
  });
}
