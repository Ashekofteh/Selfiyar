import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(
    account: '400123456',
    cookies: const {'ASP.NET_SessionId': 'test-session'},
    establishedAt: DateTime.utc(2026, 10, 20),
  );

  String sampleForgotPage({
    String viewState = 'VS_FORGOT',
    String viewStateGen = 'GEN_FORGOT',
    String alert = '',
    String message = 'توجه - گرفتن فیش فراموشی تا سقف صبحانه: 2 ناهار: 2 شام: 2 درخواست درماه',
  }) =>
      '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx" id="MainForm">
    <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewState" />
    <input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="$viewStateGen" />
    <div id="cphMain_alertBox" class="alertBox" style="${alert.isEmpty ? 'display:none;' : ''}">
      <label id="cphMain_alertBoxValue">$alert</label>
    </div>
    <div id="cphMain_messageBox" class="messageBox">
      <label id="cphMain_messageBoxValue">$message</label>
    </div>
    <input name="ctl00\$cphMain\$txtDate" type="text" id="cphMain_txtDate" value="1405/07/26" />
    <select name="ctl00\$cphMain\$drpReserveType" id="cphMain_drpReserveType">
      <option value="0">رزرو هفتگی</option>
      <option value="1">روزفروش</option>
      <option value="2">سبد غذایی</option>
    </select>
    <select name="ctl00\$cphMain\$drpFoodType" id="cphMain_drpFoodType">
      <option value="1">صبحانه</option>
      <option value="2">ناهار</option>
      <option value="3">شام</option>
    </select>
    <input name="ctl00\$cphMain\$btnOk" type="submit" id="cphMain_btnOk" value="تأیید" />
  </form>
</body>
</html>
''';

  group('CullinanParser - ForgotReceipt.aspx', () {
    test('forgotReceiptFormBody builds correct fields', () {
      final html = sampleForgotPage(viewState: 'VS999', viewStateGen: 'GEN999');
      final body = CullinanParser.forgotReceiptFormBody(
        html,
        jalaliDate: '1405/07/26',
        slot: MealSlot.lunch,
        reserveType: ReserveType.weekly,
      );

      expect(body['__VIEWSTATE'], 'VS999');
      expect(body['__VIEWSTATEGENERATOR'], 'GEN999');
      expect(body[r'ctl00$cphMain$txtDate'], '1405/07/26');
      expect(body[r'ctl00$cphMain$drpReserveType'], '0');
      expect(body[r'ctl00$cphMain$drpFoodType'], '2'); // lunch = 2
      expect(body[r'ctl00$cphMain$btnOk'], 'تأیید');
    });

    test('parses success with receipt code from alert', () {
      final html = sampleForgotPage(alert: 'کد فیش فراموشی : 789456');
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<ForgotReceiptSucceeded>());
      final success = outcome as ForgotReceiptSucceeded;
      expect(success.code, '789456');
      expect(success.slot, MealSlot.lunch);
    });

    test('parses success when slip code is in page body', () {
      final html = '''
<html>
<body>
  <div>کد فیش: 1234567</div>
</body>
</html>
''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.dinner,
      );

      expect(outcome, isA<ForgotReceiptSucceeded>());
      final success = outcome as ForgotReceiptSucceeded;
      expect(success.code, '1234567');
      expect(success.slot, MealSlot.dinner);
    });

    test('parses refusal when monthly quota exceeded', () {
      final html = sampleForgotPage(alert: 'بیش از سقف مجاز (۲ درخواست در ماه)');
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<ForgotReceiptRefused>());
      final refused = outcome as ForgotReceiptRefused;
      expect(refused.reason, contains('سقف مجاز'));
    });

    test('parses refusal when no meal is booked for slot', () {
      final html = sampleForgotPage(alert: 'غذایی برای این وعده یافت نشد');
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.breakfast,
      );

      expect(outcome, isA<ForgotReceiptRefused>());
      final refused = outcome as ForgotReceiptRefused;
      expect(refused.reason, contains('یافت نشد'));
    });

    test('static disclaimer with "غیرفعال" does not trigger false refusal', () {
      final html = sampleForgotPage(
        alert: '',
        message: 'توجه - گرفتن فیش فراموشی تا سقف صبحانه: 2 ناهار: 2 شام: 2 درخواست درماه با نرخ جریمه : صبحانه: 0 ریال ناهار: 0 ریال شام: 0 ریال و بیش از این تعداد غیرفعال می گردد',
      );
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<ForgotReceiptAmbiguous>());
      final amb = outcome as ForgotReceiptAmbiguous;
      expect(amb.diagnostic, contains('در روز توزیع و در ساعات مجاز'));
    });

    test('parses error from toastr notification', () {
      final html = '''
<html>
<body>
  <script>toastr.error("مهلت دریافت فیش برای این وعده به پایان رسیده است");</script>
</body>
</html>''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.dinner,
      );

      expect(outcome, isA<ForgotReceiptRefused>());
      final refused = outcome as ForgotReceiptRefused;
      expect(refused.reason, contains('مهلت دریافت فیش'));
    });

    test('parses success code from toastr notification', () {
      final html = '''
<html>
<body>
  <script>toastr.success("کد فیش: 887766");</script>
</body>
</html>''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<ForgotReceiptSucceeded>());
      final success = outcome as ForgotReceiptSucceeded;
      expect(success.code, '887766');
    });
  });

  group('CullinanPortalClient - requestForgotReceipt', () {
    test('successful receipt request returns code', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(viewState: 'V1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            return http.Response(sampleForgotPage(alert: 'کد فیش : 554433'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          return http.Response('not found', 404);
        }),
      );
      final client = CullinanPortalClient(transport: transport);

      final result = await client.requestForgotReceipt(
        session,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(result, isA<ForgotReceiptSucceeded>());
      final success = result as ForgotReceiptSucceeded;
      expect(success.code, '554433');
    });

    test('quota exceeded refusal is reported', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            return http.Response(sampleForgotPage(alert: 'تعداد درخواست در ماه بیش از سقف مجاز است'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          return http.Response('not found', 404);
        }),
      );
      final client = CullinanPortalClient(transport: transport);

      final result = await client.requestForgotReceipt(
        session,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(result, isA<ForgotReceiptRefused>());
      final refused = result as ForgotReceiptRefused;
      expect(refused.reason, contains('سقف مجاز'));
    });
  });
}
