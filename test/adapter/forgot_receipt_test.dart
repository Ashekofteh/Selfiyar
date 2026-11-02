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

    test('normalizes Persian digits in receipt code', () {
      final html = sampleForgotPage(alert: 'کد فیش فراموشی : ۷۸۹۴۵۶');
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<ForgotReceiptSucceeded>());
      final success = outcome as ForgotReceiptSucceeded;
      expect(success.code, '789456');
    });

    test('parseForgotReceiptAgreeButton finds input button with موافقم', () {
      final html = '''
<form>
  <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
</form>''';
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNotNull);
      expect(btn!.name, r'ctl00$cphMain$btnAgree');
      expect(btn.value, 'موافقم');
      expect(btn.isEventTarget, isFalse);
    });

    test('parseForgotReceiptAgreeButton finds button element', () {
      final html = '''
<form>
  <button name="ctl00\$cphMain\$btnConfirm" type="submit">موافقم</button>
</form>''';
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNotNull);
      expect(btn!.name, r'ctl00$cphMain$btnConfirm');
      expect(btn.value, 'موافقم');
      expect(btn.isEventTarget, isFalse);
    });

    test('parseForgotReceiptAgreeButton finds LinkButton postback', () {
      final html = '''
<form>
  <a id="cphMain_lnkAgree" href="javascript:__doPostBack('ctl00\$cphMain\$lnkAgree','')">موافقم</a>
</form>''';
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNotNull);
      expect(btn!.name, r'ctl00$cphMain$lnkAgree');
      expect(btn.isEventTarget, isTrue);
    });

    test('parseForgotReceiptAgreeButton returns null on initial page with btnOk only', () {
      final html = sampleForgotPage();
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNull);
    });

    test('parseForgotReceiptStep1Status extracts usedCount: 1', () {
      final html = '''
<div>
  <span>تعداد فیش های استفاده شده در این ماه برای این وعده: 1</span>
  <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
</div>''';
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isFalse);
      expect(status.usedCount, 1);
      expect(status.refusalReason, isNull);
    });

    test('parseForgotReceiptStep1Status handles Persian digit ۰ (0 used)', () {
      final html = '''
<div>
  <span>تعداد فیش های استفاده شده در این ماه برای این وعده: ۰</span>
  <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
</div>''';
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isFalse);
      expect(status.usedCount, 0);
      expect(status.refusalReason, isNull);
    });

    test('parseForgotReceiptStep1Status detects quota exceeded text "شما دو فیش خود را دریافت کرده اید"', () {
      final html = '''
<div id="cphMain_alertBox">
  <label id="cphMain_alertBoxValue">شما دو فیش خود را دریافت کرده اید</label>
</div>''';
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isTrue);
      expect(status.usedCount, 2);
      expect(status.refusalReason, contains('دو فیش'));
    });

    test('parseForgotReceiptStep1Status does not trigger refusal on static disclaimer', () {
      final html = sampleForgotPage();
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isFalse);
      expect(status.refusalReason, isNull);
    });

    test('forgotReceiptStep2FormBody preserves ViewState and sets button', () {
      final step1Html = '''
<form>
  <input type="hidden" name="__VIEWSTATE" value="VS_STEP1_FRESH" />
  <input type="hidden" name="__EVENTVALIDATION" value="EV_STEP1_FRESH" />
  <input type="checkbox" name="ctl00\$cphMain\$chkAgree" />
  <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
</form>''';
      final body = CullinanParser.forgotReceiptStep2FormBody(
        step1Html,
        button: (name: r'ctl00$cphMain$btnAgree', value: 'موافقم', isEventTarget: false),
        jalaliDate: '1405/07/26',
        slot: MealSlot.lunch,
      );

      expect(body['__VIEWSTATE'], 'VS_STEP1_FRESH');
      expect(body['__EVENTVALIDATION'], 'EV_STEP1_FRESH');
      expect(body[r'ctl00$cphMain$txtDate'], '1405/07/26');
      expect(body[r'ctl00$cphMain$drpFoodType'], '2');
      expect(body[r'ctl00$cphMain$chkAgree'], 'on');
      expect(body[r'ctl00$cphMain$btnAgree'], 'موافقم');
    });

    test('parseForgotReceiptOutcome does not treat usage count 1 as receipt code', () {
      final html = '''
<div id="cphMain_alertBox">
  <label id="cphMain_alertBoxValue">تعداد فیش های استفاده شده در این ماه برای این وعده: 1</label>
</div>''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );
      // It is NOT a receipt code!
      expect(outcome, isNot(isA<ForgotReceiptSucceeded>()));
    });

    test('parseForgotReceiptOutcome parses refusal for "شما ۲ فیش خود را دریافت کرده اید"', () {
      final html = '''
<div id="cphMain_alertBox">
  <label id="cphMain_alertBoxValue">شما ۲ فیش خود را دریافت کرده اید</label>
</div>''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );
      expect(outcome, isA<ForgotReceiptRefused>());
      final refused = outcome as ForgotReceiptRefused;
      expect(refused.reason, contains('۲ فیش'));
    });

    test('parseForgotReceiptOutcome parses receipt code from span id="cphMain_alertBoxValue"', () {
      final html = '''
<div id="cphMain_alertBox">
  <span id="cphMain_alertBoxValue">کد فیش فراموشی : 654321</span>
</div>''';
      final outcome = CullinanParser.parseForgotReceiptOutcome(
        html,
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
      );
      expect(outcome, isA<ForgotReceiptSucceeded>());
      final success = outcome as ForgotReceiptSucceeded;
      expect(success.code, '654321');
    });

    test('parseForgotReceiptAgreeButton finds WebForm_DoPostBackWithOptions LinkButton', () {
      final html = '''
<a id="cphMain_lnkAgree" href="javascript:WebForm_DoPostBackWithOptions(new WebForm_PostBackOptions(&quot;ctl00\$cphMain\$lnkAgree&quot;, &quot;&quot;, true, &quot;&quot;, &quot;&quot;, false, true))">موافقم</a>''';
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNotNull);
      expect(btn!.name, r'ctl00$cphMain$lnkAgree');
      expect(btn.isEventTarget, isTrue);
    });

    test('parseForgotReceiptAgreeButton finds button element with __doPostBack onclick', () {
      final html = '''
<button id="cphMain_btnAgree" onclick="javascript:__doPostBack('ctl00\$cphMain\$btnAgree','')">موافقم</button>''';
      final btn = CullinanParser.parseForgotReceiptAgreeButton(html);
      expect(btn, isNotNull);
      expect(btn!.name, r'ctl00$cphMain$btnAgree');
      expect(btn.isEventTarget, isTrue);
    });

    test('parseForgotReceiptStep1Status extracts 0 used from text containing both usage and quota limit', () {
      final html = '''
<div id="cphMain_lblInfo">تعداد فیش های استفاده شده در این ماه برای این وعده: 0 (سقف مجاز: ۲ فیش)</div>''';
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isFalse);
      expect(status.usedCount, 0);
    });

    test('parseForgotReceiptStep1Status handles Persian word numbers', () {
      final html = '''
<div id="cphMain_lblInfo">تعداد فیش های استفاده شده در این ماه برای این وعده: یک</div>''';
      final status = CullinanParser.parseForgotReceiptStep1Status(html);
      expect(status.isQuotaExceeded, isFalse);
      expect(status.usedCount, 1);
    });
  });

  group('CullinanPortalClient - requestForgotReceipt', () {
    test('two-step intelligent flow succeeds and calculates quotaRemaining: 0 when 1 used', () async {
      int postCount = 0;
      final step1ResponseHtml = '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx">
    <input type="hidden" name="__VIEWSTATE" value="VS_AFTER_STEP1" />
    <input type="hidden" name="__EVENTVALIDATION" value="EV_AFTER_STEP1" />
    <div id="cphMain_lblInfo">تعداد فیش های استفاده شده در این ماه برای این وعده: 1</div>
    <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
  </form>
</body>
</html>''';

      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(viewState: 'V1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            if (postCount == 1) {
              // Step 1 response: Shows used count and agree button
              return http.Response(step1ResponseHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
            } else if (postCount == 2) {
              // Step 2 response: Receipt code generated!
              return http.Response(sampleForgotPage(alert: 'کد فیش فراموشی : 654321'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
            }
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

      expect(postCount, 2);
      expect(result, isA<ForgotReceiptSucceeded>());
      final success = result as ForgotReceiptSucceeded;
      expect(success.code, '654321');
      // 1 used before request + 1 now = 2 total => 0 remaining
      expect(success.quotaRemaining, 0);
    });

    test('two-step intelligent flow succeeds and calculates quotaRemaining: 1 when 0 used', () async {
      int postCount = 0;
      final step1ResponseHtml = '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx">
    <input type="hidden" name="__VIEWSTATE" value="VS_AFTER_STEP1" />
    <input type="hidden" name="__EVENTVALIDATION" value="EV_AFTER_STEP1" />
    <div id="cphMain_lblInfo">تعداد فیش های استفاده شده در این ماه برای این وعده: 0</div>
    <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
  </form>
</body>
</html>''';

      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(viewState: 'V1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            if (postCount == 1) {
              return http.Response(step1ResponseHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
            } else if (postCount == 2) {
              return http.Response(sampleForgotPage(alert: 'کد فیش فراموشی : 998877'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
            }
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

      expect(postCount, 2);
      expect(result, isA<ForgotReceiptSucceeded>());
      final success = result as ForgotReceiptSucceeded;
      expect(success.code, '998877');
      // 0 used before request + 1 now = 1 total => 1 remaining
      expect(success.quotaRemaining, 1);
    });

    test('stops at step 1 without step 2 when monthly quota (2 receipts) already used', () async {
      int postCount = 0;
      final quotaExceededHtml = '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx">
    <div id="cphMain_alertBox">
      <label id="cphMain_alertBoxValue">شما دو فیش خود را دریافت کرده اید</label>
    </div>
  </form>
</body>
</html>''';

      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            return http.Response(quotaExceededHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
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

      // Crucial: Step 2 must NEVER be called when quota is exceeded!
      expect(postCount, 1);
      expect(result, isA<ForgotReceiptRefused>());
      final refused = result as ForgotReceiptRefused;
      expect(refused.reason, contains('دو فیش'));
    });

    test('successful receipt request returns code when issued on step 1 (idempotency)', () async {
      int postCount = 0;
      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(viewState: 'V1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
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

      expect(postCount, 1);
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

    test('two-step flow succeeds when step 1 alert contains usage count (does not short-circuit to code 1)', () async {
      int postCount = 0;
      final step1ResponseHtml = '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx">
    <input type="hidden" name="__VIEWSTATE" value="VS_STEP1" />
    <div id="cphMain_alertBox">
      <label id="cphMain_alertBoxValue">تعداد فیش های استفاده شده در این ماه برای این وعده: 1</label>
    </div>
    <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
  </form>
</body>
</html>''';

      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(viewState: 'V1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            if (postCount == 1) {
              return http.Response(step1ResponseHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
            } else if (postCount == 2) {
              return http.Response(sampleForgotPage(alert: 'کد فیش فراموشی : 776655'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
            }
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

      // Must execute Step 2 POST and NOT mistakenly return code '1' from Step 1!
      expect(postCount, 2);
      expect(result, isA<ForgotReceiptSucceeded>());
      final success = result as ForgotReceiptSucceeded;
      expect(success.code, '776655');
      expect(success.quotaRemaining, 0);
    });

    test('two-step flow succeeds when step 1 page mentions 2-receipt limit rules', () async {
      int postCount = 0;
      final step1ResponseHtml = '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./ForgotReceipt.aspx">
    <input type="hidden" name="__VIEWSTATE" value="VS_STEP1" />
    <div id="cphMain_lblInfo">تعداد فیش های استفاده شده در این ماه برای این وعده: 0</div>
    <div>راهنما: سقف مجاز دریافت ۲ فیش در ماه است</div>
    <input name="ctl00\$cphMain\$btnAgree" type="submit" value="موافقم" />
  </form>
</body>
</html>''';

      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            if (postCount == 1) {
              return http.Response(step1ResponseHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
            } else if (postCount == 2) {
              return http.Response(sampleForgotPage(alert: 'کد فیش : 112233'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
            }
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

      expect(postCount, 2);
      expect(result, isA<ForgotReceiptSucceeded>());
      final success = result as ForgotReceiptSucceeded;
      expect(success.code, '112233');
      expect(success.quotaRemaining, 1);
    });

    test('stops at step 1 when alert says شما ۲ فیش خود را دریافت کرده اید', () async {
      int postCount = 0;
      final transport = PortalTransport(
        baseUri: Uri.parse('https://cullinan.uk.ac.ir'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleForgotPage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          if (request.method == 'POST') {
            postCount++;
            return http.Response(sampleForgotPage(alert: 'شما ۲ فیش خود را دریافت کرده اید'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
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

      expect(postCount, 1);
      expect(result, isA<ForgotReceiptRefused>());
      final refused = result as ForgotReceiptRefused;
      expect(refused.reason, contains('۲ فیش'));
    });
  });
}
