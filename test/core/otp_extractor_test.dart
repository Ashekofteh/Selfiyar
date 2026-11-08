import 'package:bahonar_nut/core/otp_extractor.dart';
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
  });
}
