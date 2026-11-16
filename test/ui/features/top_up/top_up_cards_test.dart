import 'package:bahonar_nut/core/finance/bank_card.dart';
import 'package:bahonar_nut/core/finance/top_up.dart';
import 'package:bahonar_nut/ui/features/top_up/top_up_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bank = TopUpBank(
    id: 'bank1',
    name: 'بانک سامان',
    logoPath: null,
  );

  const card1 = SavedBankCard(
    id: 'c1',
    pan: '6219861012343769',
    title: 'کارت اصلی سامان',
    bankName: 'بانک سامان',
    expMonth: '08',
    expYear: '05',
    cvv2: '321',
  );

  testWidgets('TopUpSheet renders saved cards chips when provided', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopUpSheet(
            balanceRial: 50000,
            banks: const [bank],
            savedCards: const [card1],
            onSubmit: (_, _) async => null,
          ),
        ),
      ),
    );

    expect(find.text('کارت‌های ذخیره‌شده شما برای پرداخت:'), findsOneWidget);
    expect(find.textContaining('کارت اصلی سامان'), findsOneWidget);
  });
}
