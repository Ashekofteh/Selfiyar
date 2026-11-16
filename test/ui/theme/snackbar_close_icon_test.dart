import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bahonar_nut/ui/theme/theme.dart';
void main() {
  testWidgets('SnackBar includes close cross button and dismisses when tapped', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('اعلان آزمایشی درون برنامه'),
                      duration: const Duration(seconds: 10),
                      action: SnackBarAction(
                        label: 'مشاهده',
                        onPressed: () {},
                      ),
                    ),
                  );
                },
                child: const Text('نمایش اعلان'),
              ),
            ),
          ),
        ),
      ),
    );

    // Tap button to show SnackBar
    await tester.tap(find.text('نمایش اعلان'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('اعلان آزمایشی درون برنامه'), findsOneWidget);
    expect(find.text('مشاهده'), findsOneWidget);

    // Verify close icon (Icons.close) is present
    expect(find.byIcon(Icons.close), findsOneWidget);

    // Tap the close button
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // SnackBar is dismissed
    expect(find.text('اعلان آزمایشی درون برنامه'), findsNothing);
  });
}
