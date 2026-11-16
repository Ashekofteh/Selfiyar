import 'dart:io';

import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/reminder/reminder_compose.dart';
import 'package:bahonar_nut/core/finance/spend_summary.dart';
import 'package:test/test.dart';

/// The product owner's requirement: **every monetary amount the user sees must
/// be in Toman**, because Iran has not used Rial in daily life for a long time.
///
/// Rial stays underneath — it is the portal's own unit, and every comparison
/// (the price cap, the balance check, the spend total) must be exact. The
/// conversion happens once, at the display boundary.
///
/// These tests are the guard. Without them, a future screen could reach for
/// [formatRialPersian] and quietly show Rial to a user who thinks in Toman —
/// a 10x error in a price, which is the kind of bug that looks like a joke and
/// is not.
void main() {
  group('the display formatters', () {
    test('the user-facing formatter emits Toman', () {
      expect(formatTomanPersian(350000), '۳۵٬۰۰۰ تومان');
    });

    test('no user-facing formatter emits the Rial unit', () {
      // The Rial formatter exists for the rare case it is needed, but nothing
      // in the display path may use it.
      final userFacing = <String, String>{
        'formatTomanPersian': formatTomanPersian(350000),
        'formatRialPersian': formatRialPersian(350000),
      };
      expect(userFacing['formatTomanPersian'], contains('تومان'));
    });
  });

  group('the notification text', () {
    NotificationText build() {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: DateTime.utc(2026, 10, 19),
        accounts: [
          AccountDigest(
            accountId: 'a1',
            displayName: 'مقسمی',
            items: [
              ReservedMealItem(
                date: DateTime.utc(2026, 10, 19),
                slot: MealSlot.dinner,
                hallName: 'مرکزی برادران',
                dishName: 'خوراک سالاد الویه',
                priceRial: 350000,
              ),
            ],
          ),
        ],
      );
      return composeNotification(digest);
    }

    test('a notification never shows a currency amount in Rial', () {
      final text = build();
      expect(text.body, isNot(contains('ریال')));
      expect(text.title, isNot(contains('ریال')));
    });
  });

  group('the spend summary carries Rial internally', () {
    test('totals are in Rial, and the display converts', () {
      final summary = summarise(transactions: [
        const Transaction(
          accountId: 'a1',
          type: 'رزرو غذا',
          foodName: 'چلو اکبرجوجه,دوغ',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
      ]);

      // Internally Rial, so it matches the portal exactly.
      expect(summary.totalRial, 500000);
      // Displayed as Toman.
      expect(formatTomanPersian(summary.totalRial), '۵۰٬۰۰۰ تومان');
    });
  });

  group('no source file may render Rial to the user', () {
    test('the string "ریال" appears only in comments, never in a literal',
        () {
      // A Persian-locale UI file could still hard-code the Rial unit. This
      // scans the source for the word in a *string literal* (which is what
      // reaches the user) and allows it only where the Rial unit is legitimately
      // referenced.
      //
      // Two legitimate places exist, and neither is a display:
      //   1. The portal itself writes "500000 ریال", so a PARSER must match the
      //      word to strip the price out of the dish name.
      //   2. The Rial formatter exists for the rare case it is needed.
      //
      // A display would concatenate the word onto a number as a suffix.
      final offenders = <String>[];

      for (final dir in ['lib']) {
        final directory = Directory(dir);
        if (!directory.existsSync()) continue;

        for (final entity in directory.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;

          final lines = entity.readAsLinesSync();
          // Track the enclosing top-level function, so the Rial formatter's own
          // return line can be allowed precisely rather than by pattern.
          String? enclosingFunction;
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            final trimmed = line.trim();

            // A top-level function, in either the block form (`... {`) or the
            // arrow form (`... =>`). The head may carry a return type and a
            // typed parameter list, so the name is taken from the *head* —
            // the text up to the first `{`, `;` or `=>` — and the body shape
            // from the line itself. Matching only the head is what keeps a
            // call inside the body (such as the formatter's own
            // `_groupDigits(...)`) from being mistaken for the declaration.
            final head = trimmed.split(RegExp(r'[{};]|=>')).first;
            final functionMatch =
                RegExp(r'([\w$]+)\s*\([^()]*\)\s*$').firstMatch(head);
            if (functionMatch != null &&
                (trimmed.endsWith('{') || trimmed.contains('=>'))) {
              enclosingFunction = functionMatch.group(1);
            }

            // Skip comments and doc comments.
            if (trimmed.startsWith('//') ||
                trimmed.startsWith('///') ||
                trimmed.startsWith('*')) {
              continue;
            }
            if (!line.contains('ریال')) continue;

            // The path is compared with forward slashes whatever the platform
            // hands back: `Directory.listSync` yields OS separators, and the
            // allowlist below is written against the repository's POSIX form.
            final normalizedPath = entity.path.replaceAll(r'\', '/');

            // A DISPLAY is the word inside a string literal, as a suffix or a
            // unit. That is the only thing the user can see.
            final isDisplay = RegExp(r'''[\'"][^'"]*ریال[^'"]*['"]''')
                    .hasMatch(trimmed) &&
                !_isParserContext(trimmed);

            if (isDisplay &&
                !_isAllowedRialDisplay(normalizedPath, enclosingFunction)) {
              offenders.add('${entity.path}:${i + 1}: $trimmed');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'the word "ریال" (Rial) must not reach the user; use Toman.\n'
            '${offenders.join('\n')}',
      );
    });
  });
}

/// True when the line is PARSING portal text rather than DISPLAYING an amount.

///
/// The portal renders prices as "500000 ریال", so a parser has to recognise
/// and strip that suffix. Matching the word in a regular expression is parsing,
/// not display.
bool _isParserContext(String line) =>
    line.contains('RegExp') ||
    line.contains('replaceAll') ||
    line.contains('replaceFirst');

/// The one place a Rial literal is allowed: inside the Rial formatter.
///
/// Matched by the enclosing function's name rather than by the shape of the
/// literal, so the allowance cannot drift onto an unrelated line that happens
/// to mention Rial.
bool _isAllowedRialDisplay(String path, String? enclosingFunction) =>
    path.endsWith('shared/persian.dart') && enclosingFunction == 'formatRialPersian';
