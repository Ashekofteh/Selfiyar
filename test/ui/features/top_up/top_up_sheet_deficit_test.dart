import 'package:bahonar_nut/core/finance/top_up.dart';
import 'package:bahonar_nut/ui/features/top_up/top_up_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bank = TopUpBank(
    id: 'ctl00\$cphMain\$dataLstBank\$ctl00\$imgBankLogo',
    name: 'بانک ملت',
    logoPath: null,
  );

  testWidgets('TopUpSheet pre-fills amount in Toman when initialAmountRial is provided',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopUpSheet(
            balanceRial: 50000,
            banks: const [bank],
            initialAmountRial: 150000, // 15,000 Toman deficit
            onSubmit: (_, _) async => null,
          ),
        ),
      ),
    );

    // The text field should contain "15000"
    expect(find.widgetWithText(TextField, '15000'), findsOneWidget);
  });
}
