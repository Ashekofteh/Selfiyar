import 'package:bahonar_nut/ui/widgets/rotating_refresh_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('RotatingRefreshButton invokes onPressed when idle and not syncing',
      (tester) async {
    var pressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RotatingRefreshButton(
            isSyncing: false,
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byTooltip('به‌روزرسانی از سامانه'), findsOneWidget);

    await tester.tap(find.byType(RotatingRefreshButton));
    expect(pressed, isTrue);
  });

  testWidgets('RotatingRefreshButton disables tap and updates tooltip when syncing',
      (tester) async {
    var pressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RotatingRefreshButton(
            isSyncing: true,
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.byTooltip('در حال به‌روزرسانی...'), findsOneWidget);

    // Tapping should not trigger onPressed while syncing
    await tester.tap(find.byType(RotatingRefreshButton));
    expect(pressed, isFalse);
  });

  testWidgets('RotatingRefreshButton rotates when isSyncing is true and completes cleanly',
      (tester) async {
    var isSyncing = false;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  RotatingRefreshButton(
                    isSyncing: isSyncing,
                    onPressed: () {},
                  ),
                  GestureDetector(
                    onTap: () => setState(() => isSyncing = !isSyncing),
                    child: const Text('toggle'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    final transformFinder = find.descendant(
      of: find.byType(RotatingRefreshButton),
      matching: find.byType(Transform),
    );

    // Initial transform is identity
    Transform transform = tester.widget<Transform>(transformFinder);
    expect(transform.transform, equals(Matrix4.identity()));

    // Toggle syncing on
    await tester.tap(find.text('toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    transform = tester.widget<Transform>(transformFinder);
    // After 250ms of rotation, transform is no longer identity
    expect(transform.transform, isNot(equals(Matrix4.identity())));

    // Toggle syncing off
    await tester.tap(find.text('toggle'));
    await tester.pump();

    // Pump until animation settles to 1.0 (resets to 0.0)
    await tester.pumpAndSettle();

    transform = tester.widget<Transform>(transformFinder);
    // Rotation should reset to identity
    expect(transform.transform, equals(Matrix4.identity()));
  });
}
