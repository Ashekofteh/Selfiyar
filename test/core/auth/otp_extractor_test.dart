import 'package:bahonar_nut/core/auth/otp_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('OtpExtractor', () {
    test('returns null for null or empty input', () {
      expect(extractOtpCode(null), isNull);
      expect(extractOtpCode(''), isNull);
      expect(extractOtpCode('   \n  '), isNull);
    });

    test('extracts Mellat OTP', () {
      const sms = '''
بانک ملت
رمز اینترنتی یکبار مصرف شما: 649215
مبلغ: 50,000 ریال
کارت: 610433******1234
''';
      expect(extractOtpCode(sms), equals('649215'));
    });

    test('extracts Melli OTP across newline', () {
      const sms = '''
بانک ملی ایران
کد یکبار مصرف خرید اینترنتی:
724915
اعتبار: 120 ثانیه
''';
      expect(extractOtpCode(sms), equals('724915'));
    });

    test('extracts Saman OTP', () {
      const sms = 'بانک سامان: رمز دوم پویا: 918342 برای خرید از درگاه شاپرک';
      expect(extractOtpCode(sms), equals('918342'));
    });

    test('extracts Pasargad OTP', () {
      const sms = 'بانک پاسارگاد\nرمز پویا: 839201';
      expect(extractOtpCode(sms), equals('839201'));
    });

    test('extracts Tejarat OTP', () {
      const sms = 'بانک تجارت\nرمز یکبار مصرف: 529183';
      expect(extractOtpCode(sms), equals('529183'));
    });

    test('extracts Saderat OTP with sentence structure', () {
      const sms = 'کد تایید یکبار مصرف شما 392815 می باشد.';
      expect(extractOtpCode(sms), equals('392815'));
    });

    test('extracts Keshavarzi 5-digit OTP', () {
      const sms = 'بانک کشاورزی\nرمز دوم یکبار مصرف: 81923';
      expect(extractOtpCode(sms), equals('81923'));
    });

    test('extracts Persian digits correctly', () {
      const sms = '''
بانک قرض الحسنه رسالت
رمز دوم پویا: ۴۸۲۹۱۰
کارت: ****۱۲۳۴
مبلغ: ۱۰۰,۰۰۰ ریال
''';
      expect(extractOtpCode(sms), equals('482910'));
    });

    test('extracts Arabic digits correctly', () {
      const sms = 'رمز دوم پویا: ٦٣٩١٨٢ برای کارت ٦٢١٩٨٦';
      expect(extractOtpCode(sms), equals('639182'));
    });

    test('extracts 7-digit OTP', () {
      const sms = 'کد رمز پویا: 8492018';
      expect(extractOtpCode(sms), equals('8492018'));
    });

    test('extracts 8-digit OTP', () {
      const sms = 'رمز یکبار مصرف خرید اینترنتی شما 12345678 است';
      expect(extractOtpCode(sms), equals('12345678'));
    });

    test('extracts code when code precedes keyword', () {
      const sms = 'کد 482915 رمز پویا شماست';
      expect(extractOtpCode(sms), equals('482915'));
    });

    test('extracts code with کد اعتبارسنجی', () {
      const sms = 'کد اعتبارسنجی: 928371';
      expect(extractOtpCode(sms), equals('928371'));
    });

    test('extracts code with رمز موقت', () {
      const sms = 'رمز موقت: 371902';
      expect(extractOtpCode(sms), equals('371902'));
    });

    test('does not extract currency amounts as OTP', () {
      const sms = '''
برداشت از حساب: 500000 ریال
موجودی: 1200000 ریال
پیگیری: 9812
''';
      // No OTP keywords, only transaction amount
      expect(extractOtpCode(sms), isNull);
    });

    test('extracts OTP from SMS containing masked card number with 6-digit BIN prefix', () {
      const sms = 'بانک سامان: رمز پویا کارت 621986***9876: 837492';
      expect(extractOtpCode(sms), equals('837492'));
    });

    test('extracts OTP when amount is on the same line before OTP', () {
      const sms = 'مبلغ: 50000 ریال، رمز پویا: 482915';
      expect(extractOtpCode(sms), equals('482915'));
    });

    test('extracts OTP when masked card and amount precede OTP on newline', () {
      const sms = '''
بانک ملی ایران
خرید اینترنتی کارت 603799******1234
مبلغ 250000 ریال
کد: 749102
''';
      expect(extractOtpCode(sms), equals('749102'));
    });

    test(
      'extracts OTP ignoring tracking numbers, phone numbers, and dates',
      () {
        const sms = '''
بانک سپه
رمز دوم پویا: 581920
کارت: 589210******4321
شماره پیگیری: 81924510
تاریخ: 1403/08/18 18:45:10
پشتیبانی: 02188776655
''';
        expect(extractOtpCode(sms), equals('581920'));
      },
    );

    test('extracts OTP with ZWNJ and Arabic digits with masked card', () {
      const sms = 'رمز یک\u200cبار مصرف: ٦٣٩١٨٢ برای کارت ٦٢١٩٨٦***٤٣٢١';
      expect(extractOtpCode(sms), equals('639182'));
    });

    test('extracts OTP from Bank Refah format', () {
      const sms =
          'بانک رفاه: رمز پویا خرید اینترنتی کارت 589463***1234 مبلغ 150000 ریال: 829104';
      expect(extractOtpCode(sms), equals('829104'));
    });

    test('extracts space-grouped OTP', () {
      const sms = 'بانک سامان: رمز پویا: 123 456';
      expect(extractOtpCode(sms), equals('123456'));
    });

    test('extracts hyphen-grouped OTP', () {
      const sms = 'بانک ملت: رمز دوم پویا: 123-456';
      expect(extractOtpCode(sms), equals('123456'));
    });

    test('extracts multi-group OTP split as 12-34-56', () {
      const sms = 'کد تایید: 12 34 56';
      expect(extractOtpCode(sms), equals('123456'));
    });

    test('extracts grouped Persian digits', () {
      const sms = 'رمز یک‌بار مصرف: ۱۲۳ ۴۵۶';
      expect(extractOtpCode(sms), equals('123456'));
    });

    test('prefers banking OTP keyword code over other numbers', () {
      const sms = '''
بانک ملی
شماره حساب: 9812451023
رمز پویا: 123 456
''';
      expect(extractOtpCode(sms), equals('123456'));
    });

    test('does not treat a space-grouped amount as an OTP', () {
      const sms = 'برداشت از حساب: 50 000 ریال\nموجودی: 120,000 ریال';
      expect(extractOtpCode(sms), isNull);
    });

    test('ignores spaced phone numbers', () {
      const sms = '''
پشتیبانی: 021 8877 6655
رمز موقت: 371902
''';
      expect(extractOtpCode(sms), equals('371902'));
    });

    test('ignores international phone numbers with +98', () {
      const sms = '''
پشتیبانی: +98-21-88776655
رمز پویا: 482910
''';
      expect(extractOtpCode(sms), equals('482910'));
    });

    test('does not treat spaced amounts without currency word as OTP (B-3)', () {
      expect(extractOtpCode('برداشت: 1 200 000'), isNull);
      expect(
        extractOtpCode('برداشت از حساب: 50 000\nموجودی: 120,000 ریال'),
        isNull,
      );
      expect(extractOtpCode('موجودی: 2 500 000'), isNull);
      expect(extractOtpCode('برداشت 50 000 از حساب'), isNull);
      expect(extractOtpCode('واریز: 15 000 000'), isNull);
    });

    test('ignores spaced dates without OTP', () {
      expect(extractOtpCode('تاریخ: 1403 05 12'), isNull);
    });

    test('extracts OTP when purchase/transfer keywords precede the label (R-1)', () {
      expect(extractOtpCode('رمز پویا خرید: 482915'), equals('482915'));
      expect(extractOtpCode('رمز دوم پویا خرید: 482915'), equals('482915'));
      expect(extractOtpCode('کد تایید خرید: 482915'), equals('482915'));
      expect(extractOtpCode('رمز دوم خرید: 482915'), equals('482915'));
      expect(extractOtpCode('کد یکبار مصرف خرید: 482915'), equals('482915'));
    });

    test('ignores spaced tracking and national ID codes (R-3)', () {
      expect(extractOtpCode('کد رهگیری: 12 345 678'), isNull);
      expect(extractOtpCode('کد ملی: 12 345 678'), isNull);
      expect(extractOtpCode('کد پستی: 12 345 678'), isNull);
      expect(extractOtpCode('کد شعبه: 123 456'), isNull);
    });

    test('does not conflate Bank Melli name with national code (R-7)', () {
      expect(extractOtpCode('بانک ملی\n123456 رمز پویا شماست'), equals('123456'));
      expect(extractOtpCode('بانک ملی 482915 رمز پویا'), equals('482915'));
    });
  });
}
