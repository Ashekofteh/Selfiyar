/// Extraction of dynamic one-time password (رمز پویا / کد یکبار مصرف) from bank SMS messages.
///
/// Designed specifically for Iranian banking SMS formats (Mellat, Melli, Saman,
/// Pasargad, Tejarat, Keshavarzi, Resalat, Sepah, Parsian, etc.).
/// Handles Persian, Arabic, and Western digits, varying OTP lengths (5 to 8 digits),
/// and messages containing amounts or card numbers.
library;

import 'persian.dart';

/// Extracts a dynamic one-time password (OTP) from an SMS [text].
///
/// Returns the extracted 5 to 8 digit OTP string, or `null` if no valid code is found.
String? extractOtpCode(String? text) {
  if (text == null || text.trim().isEmpty) return null;

  // Convert Persian and Arabic digits to ASCII English digits
  final normalized = toEnglishDigits(text);

  // Pattern 1: High-confidence keyword-anchored extraction.
  // Matches common bank prefixes like:
  // "رمز پویا: 123456", "رمز دوم: 12345", "رمز یکبار مصرف شما: 12345678",
  // "کد تایید: 123456", "کد اعتبارسنجی: 12345", "کد یکبار مصرف: 123456"
  final keywordPatterns = [
    RegExp(
      r'(?:رمز\s*(?:دوم|پویا|یکبار\s*مصرف|اینترنتی|موقت)?|کد\s*(?:ت[اأآ]یید|اعتبارسنجی|فعالسازی|یکبار\s*مصرف|رمز)?|password|otp|pin2?)\s*[:：=\-]?\s*([0-9]{5,8})(?![0-9])',
      caseSensitive: false,
    ),
    // Number followed by keyword: "123456 رمز دوم", "123456: رمز پویا"
    RegExp(
      r'(?<![0-9])([0-9]{5,8})\s*[:：=\-]?\s*(?:رمز|کد\s*(?:ت[اأآ]یید|اعتبارسنجی|یکبار\s*مصرف))',
      caseSensitive: false,
    ),
    // "شما 123456 است" or "برابر 123456"
    RegExp(
      r'(?:شما|برابر)\s*[:：=\-]?\s*([0-9]{5,8})(?![0-9])',
      caseSensitive: false,
    ),
  ];

  for (final regex in keywordPatterns) {
    final match = regex.firstMatch(normalized);
    if (match != null) {
      final code = match.group(1);
      if (code != null && code.length >= 5 && code.length <= 8) {
        return code;
      }
    }
  }

  // Pattern 2: Contextual fallback. Find standalone 5 to 8 digit numbers,
  // making sure not to pick currency amounts or card fragments.
  final lines = normalized.split('\n');
  for (final line in lines) {
    final isAmountLine = RegExp(r'مبلغ|ریال|تومان').hasMatch(line);
    final matches = RegExp(r'(?<![0-9])([0-9]{5,8})(?![0-9])').allMatches(line);

    for (final m in matches) {
      final candidate = m.group(1)!;

      // Skip if candidate is followed by currency words
      final after = line.substring(m.end).trimLeft();
      if (RegExp(r'^(?:ریال|تومان)').hasMatch(after)) {
        continue;
      }

      // If it's on an amount line and occurs after the word "مبلغ", skip it
      if (isAmountLine && line.contains('مبلغ') && line.indexOf(candidate) > line.indexOf('مبلغ')) {
        continue;
      }

      return candidate;
    }
  }

  return null;
}
