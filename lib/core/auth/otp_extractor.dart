/// Extraction of dynamic one-time password (رمز پویا / کد یکبار مصرف) from bank SMS messages.
///
/// Designed specifically for Iranian banking SMS formats (Mellat, Melli, Saman,
/// Pasargad, Tejarat, Keshavarzi, Resalat, Sepah, Parsian, etc.).
/// Handles Persian, Arabic, and Western digits, varying OTP lengths (5 to 8 digits),
/// and messages containing amounts or card numbers.
library;

import '../shared/persian.dart';

/// Extracts a dynamic one-time password (OTP) from an SMS [text].
///
/// Returns the extracted 5 to 8 digit OTP string, or `null` if no valid code is found.
String? extractOtpCode(String? text) {
  if (text == null || text.trim().isEmpty) return null;

  // Convert Persian and Arabic digits to ASCII English digits
  var normalized = toEnglishDigits(text);

  // Normalize zero-width non-joiners (\u200c) to spaces
  normalized = normalized.replaceAll('\u200c', ' ');

  // Sanitize text by neutralizing non-OTP numbers so they are never mistakenly extracted:
  // 1. Masked bank card numbers (e.g., 603799******1234, 621986***9876, ****1234, *1234)
  var sanitized = normalized
      .replaceAll(
        RegExp(r'(?<![0-9])[0-9]{4,8}[\*\•\×Xx\.\-]{2,}[0-9]*'),
        ' [CARD] ',
      )
      .replaceAll(RegExp(r'[\*\•\×Xx\.\-]{2,}[0-9]{4,8}'), ' [CARD] ')
      .replaceAll(RegExp(r'(?<![0-9])[0-9]{16}(?![0-9])'), ' [CARD] ')
      .replaceAll(
        RegExp(
          r'(?<![0-9])[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}(?![0-9])',
        ),
        ' [CARD] ',
      )
      .replaceAll(
        RegExp(r'(?:کارت|حساب)\s*[:：=\-]?\s*[0-9]{4,16}'),
        ' [CARD] ',
      );

  // 2. Amounts with currency words or formatted with commas (e.g., 50,000 ریال, مبلغ 100000)
  sanitized = sanitized
      .replaceAll(
        RegExp(r'(?<![0-9])[0-9]{1,3}(?:[,،][0-9]{3})+(?:\s*(?:ریال|تومان))?'),
        ' [AMOUNT] ',
      )
      // Space-grouped thousands with currency word (e.g., 120 000 ریال)
      .replaceAll(
        RegExp(r'(?<![0-9])[0-9]{1,3}(?:[ \u200c][0-9]{3})+\s*(?:ریال|تومان)'),
        ' [AMOUNT] ',
      )
      // Any amount followed by currency word
      .replaceAll(
        RegExp(r'(?<![0-9])[0-9]{1,12}\s*(?:ریال|تومان)'),
        ' [AMOUNT] ',
      )
      // Banking transaction keywords followed by amount (with or without currency word,
      // grouped or un-grouped, e.g. "برداشت: 1 200 000", "موجودی: 2 500 000", "برداشت 50 000 از حساب")
      .replaceAll(
        RegExp(r'(?:مبلغ|به\s*مبلغ|موجودی|مانده|باقیمانده|برداشت|واریز)(?:\s*از\s*حساب)?\s*[:：=\-]?\s*[0-9]{1,3}(?:[ \u200c,،][0-9]{3})+(?:\s*(?:ریال|تومان))?'),
        ' [AMOUNT] ',
      )
      .replaceAll(
        RegExp(r'(?:مبلغ|به\s*مبلغ|موجودی|مانده|باقیمانده|برداشت|واریز)(?:\s*از\s*حساب)?\s*[:：=\-]?\s*[0-9]{1,12}(?:\s*(?:ریال|تومان))?'),
        ' [AMOUNT] ',
      )
      .replaceAll(
        RegExp(r'(?:برداشت|واریز)\s+[0-9]{1,3}(?:[ \u200c,،][0-9]{3})*\s+از\s*حساب'),
        ' [AMOUNT] ',
      );

  // 3. Tracking numbers, terminal IDs, reference numbers
  sanitized = sanitized.replaceAll(
    RegExp(
      r'(?:پیگیری|ارجاع|مرجع|ترمینال|پذیرنده|شناسه|رهگیری|کد\s*ملی|پستی|شعبه|بورسی|سفارش|تخفیف)\s*[:：=\-]?\s*[0-9]+(?:[ \u200c\-][0-9]+)*',
    ),
    ' [REF] ',
  );

  // 4. Dates and timestamps
  sanitized = sanitized
      .replaceAll(
        RegExp(
          r'(?<![0-9])(?:1[34][0-9]{2}|20[0-9]{2})[/\- ][0-9]{1,2}[/\- ][0-9]{1,2}(?![0-9])',
        ),
        ' [DATE] ',
      )
      .replaceAll(RegExp(r'[0-9]{2,4}[/-][0-9]{1,2}[/-][0-9]{1,2}'), ' [DATE] ')
      .replaceAll(RegExp(r'[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?'), ' [TIME] ');

  // 5. Phone numbers (with or without grouping, local or +98/0098)
  sanitized = sanitized.replaceAll(
    RegExp(
      r'(?<![0-9])(?:\+98|0098|0)[0-9]{2,4}[ -]?[0-9]{3,4}[ -]?[0-9]{3,4}(?![0-9])',
    ),
    ' [PHONE] ',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'(?<![0-9])(?:\+98|0098|0)[0-9]{9,10}(?![0-9])'),
    ' [PHONE] ',
  );

  // 6. Collapse codes banks group for readability: "123 456", "123-456", "12-34-56".
  // Only runs on lines that contain an OTP indicator keyword, so spaced transaction
  // amounts or account numbers on other lines are never joined into a synthetic OTP.
  final otpLineHint = RegExp(
    r'(?:رمز|کد\s*[:：=\-]|کد\s*(?:ت[اأآ]یید|اعتبار|فعالسازی|یک\s*بار\s*مصرف|ورود|پویا|دوم|خرید)|otp|pin|pass|اعتبار|تایید|یک\s*بار\s*مصرف)',
    caseSensitive: false,
  );
  sanitized = sanitized.split('\n').map((line) {
    if (!otpLineHint.hasMatch(line)) return line;
    return line.replaceAllMapped(
      RegExp(r'(?<![0-9])([0-9]{1,5})((?:[ -][0-9]{1,5})+)(?![0-9])'),
      (match) {
        final joined =
            '${match.group(1)!}${match.group(2)!.replaceAll(RegExp(r'[ -]'), '')}';
        if (joined.length >= 5 && joined.length <= 8) return joined;
        return match.group(0)!;
      },
    );
  }).join('\n');

  // Pattern 1: High-confidence keyword-anchored extraction.
  // Banking OTP label names are tried first ("رمز پویا", "رمز دوم",
  // "کد یکبار مصرف", "رمز موقت", "کد تایید"), then the generic labels.
  // Handles:
  // "رمز پویا: 123456", "رمز دوم کارت [CARD]: 837492", "رمز یکبار مصرف شما: 12345678",
  // "کد تایید: 123456", "کد اعتبارسنجی: 12345", "رمز: 482915", "کد: 749102"
  final keywordPatterns = [
    // Priority banking OTP keywords, in the order the banks use them.
    RegExp(
      r'(?:رمز\s*(?:دوم|پویا(?:ی)?|یک\s*بار\s*مصرف|اینترنتی|موقت|خرید)|کد\s*(?:ت[اأآ]یید|اعتبارسنجی|فعالسازی|یک\s*بار\s*مصرف)|second\s*password|one[-\s]?time[-\s]?code|otp|pin2?)[^0-9\n]{0,35}[:：=\-]?\s*([0-9]{5,8})(?![0-9])',
      caseSensitive: false,
    ),
    // Any remaining generic label ("رمز", "کد", ...).
    RegExp(
      r'(?:رمز|کد|password|otp|pin2?)[^0-9\n]{0,35}[:：=\-]?\s*([0-9]{5,8})(?![0-9])',
      caseSensitive: false,
    ),
    // Number followed by keyword: "123456 رمز دوم", "123456: رمز پویا", "کد 482915 رمز پویا شماست"
    RegExp(
      r'(?<![0-9])([0-9]{5,8})[^0-9\n]{0,35}[:：=\-]?\s*(?:رمز|کد\s*(?:ت[اأآ]یید|اعتبارسنجی|فعالسازی|یک\s*بار\s*مصرف))',
      caseSensitive: false,
    ),
    // "شما 123456 است" or "برابر 123456"
    RegExp(
      r'(?:شما|برابر|معادل)\s*[:：=\-]?\s*([0-9]{5,8})(?![0-9])',
      caseSensitive: false,
    ),
  ];

  for (final regex in keywordPatterns) {
    final match = regex.firstMatch(sanitized);
    if (match != null) {
      final code = match.group(1);
      if (code != null && code.length >= 5 && code.length <= 8) {
        return code;
      }
    }
  }

  // Pattern 2: Contextual fallback. Scan lines in sanitized text.
  // Lines mentioning OTP concepts get priority.
  final lines = sanitized.split('\n');
  for (final line in lines) {
    final hasOtpHint = RegExp(
      r'رمز|کد|otp|pin',
      caseSensitive: false,
    ).hasMatch(line);
    if (hasOtpHint) {
      final match = RegExp(r'(?<![0-9])([0-9]{5,8})(?![0-9])').firstMatch(line);
      if (match != null) {
        return match.group(1);
      }
    }
  }

  // Pattern 3: Standalone 5 to 8 digit number in sanitized text.
  for (final line in lines) {
    final matches = RegExp(r'(?<![0-9])([0-9]{5,8})(?![0-9])').allMatches(line);
    for (final m in matches) {
      return m.group(1);
    }
  }

  return null;
}
