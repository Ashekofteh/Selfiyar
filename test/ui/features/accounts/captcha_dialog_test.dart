import 'dart:typed_data';

import 'package:bahonar_nut/ui/features/accounts/captcha_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The CAPTCHA dialog, at the level the student sees it.
///
/// ## Why these exist
///
/// The solver reads the CAPTCHA on the device, and it almost always
/// succeeds. When it does not, the app has one way to keep working: **ask
/// the student**. That fallback is the difference between an app that
/// occasionally asks a question and an app that cannot log in at all.
///
/// So the dialog has to do two things right: show the image that is
/// **live**, and take the digits the student typed.
void main() {
  /// A tiny valid GIF, so `Image.memory` has something to decode.
  final imageBytes = Uint8List.fromList([
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xFF,
    0xFF,
    0xFF,
    0x21,
    0xF9,
    0x04,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x2C,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x44,
    0x01,
    0x00,
    0x3B,
  ]);

  testWidgets('the image is shown, so the student can read it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                CaptchaDialog.show(context, imageBytes: imageBytes),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('کد امنیتی'), findsOneWidget);
  });

  testWidgets('the digits the student typed are returned', (tester) async {
    String? answer;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await CaptchaDialog.show(
                context,
                imageBytes: imageBytes,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(answer, '1234');
  });

  testWidgets('Persian digits are accepted', (tester) async {
    // The student types on a Persian keyboard, so the digits arrive as
    // Persian ones. The portal wants Western digits, so they are converted.
    String? answer;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await CaptchaDialog.show(
                context,
                imageBytes: imageBytes,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '۱۲۳۴');
    await tester.tap(find.text('ادامه'));
    await tester.pumpAndSettle();

    expect(answer, '1234');
  });

  testWidgets('giving up returns nothing', (tester) async {
    String? answer;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await CaptchaDialog.show(
                context,
                imageBytes: imageBytes,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('انصراف'));
    await tester.pumpAndSettle();

    expect(
      answer,
      isNull,
      reason:
          'the student must not be trapped in a dialog they cannot '
          'leave',
    );
  });

  testWidgets('a refused answer says so', (tester) async {
    // "Wrong" and "the app cannot read this" are different situations, and
    // the student should not have to guess which one they are in.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => CaptchaDialog.show(
              context,
              imageBytes: imageBytes,
              previousAttempts: 1,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('کد قبلی درست تشخیص داده نشد'), findsOneWidget);
  });
}
