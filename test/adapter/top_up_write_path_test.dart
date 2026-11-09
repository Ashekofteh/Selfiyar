import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/top_up.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The top-up write path, pinned against the portal's real shape.
///
/// ## Why these tests exist
///
/// The top-up is **three steps**, and each of them can fail in a way the
/// student pays for:
///
///   * **The amount post names the wrong fields.** The ePay page has *no*
///     submit button — the bank logos are image inputs, so the bank is part
///     of the form and its name carries the click coordinates (F54).
///   * **The confirmation is not checked.** The portal refuses an
///     out-of-range amount **silently**: it re-renders the amount form with
///     no message, so the only signal is the *absence* of the pay button
///     (F56). A client that posts `btnPay` against that page gets a server
///     error instead of a clear refusal.
///   * **The redirect is followed.** The `btnPay` post answers with a `302`
///     to the bank's gateway, and the gateway is unreachable from this
///     transport — the TLS handshake fails there (F55). Following the
///     redirect turns a successful handoff into a network error.
///
/// Each test below is checked to fail without its fix.
void main() {
  final session = Session(
    account: 'a1',
    cookies: const {'ASP.NET_SessionId': 's1'},
    establishedAt: DateTime.utc(2026, 10, 21),
  );

  /// The amount form, as the portal renders it.
  ///
  /// The two bank logos are image inputs, and the second one's title is
  /// empty — which is what the portal actually serves.
  String amountPage() => r'''
<html><body>
<form method="post" action="./ePay_Payment.aspx" id="MainForm">
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="VS1" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN1" />
<input type="hidden" name="__VIEWSTATEENCRYPTED" id="__VIEWSTATEENCRYPTED" value="" />
<div id="divCredit"><label id="lblCredit">75,000 ريال </label></div>
<input name="ctl00$cphMain$txtPaymentAmount" type="text" id="cphMain_txtPaymentAmount" value="120,000" />
<table id="cphMain_dataLstBank">
<tr>
<td class="BankItem">
<input type="image" name="ctl00$cphMain$dataLstBank$ctl00$imgBankLogo" id="cphMain_dataLstBank_imgBankLogo_0" src="../Images/Logo/NewMelli.jpg" />
<label id="cphMain_dataLstBank_lblBankTitle_0">درگاه سداد</label>
</td>
<td class="BankItem">
<input type="image" name="ctl00$cphMain$dataLstBank$ctl01$imgBankLogo" id="cphMain_dataLstBank_imgBankLogo_1" src="../Images/Logo/Mellat.jpg" />
<label id="cphMain_dataLstBank_lblBankTitle_1"></label>
</td>
</tr>
</table>
</form>
</body></html>
''';

  /// The confirmation page the portal answers the amount post with.
  String confirmationPage() => r'''
<html><body>
<form method="post" action="./ePay_Payment.aspx" id="MainForm">
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="VS2" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN2" />
<div>تأیید پرداخت</div>
<div>مبلغ خرید اعتبار: 120000 ریال</div>
<input name="ctl00$cphMain$btnPay" type="submit" id="cphMain_btnPay" value="پرداخت" />
<input name="ctl00$cphMain$btnCancel" type="submit" id="cphMain_btnCancel" value="انصراف" />
</form>
</body></html>
''';

  /// The amount form again — which is what the portal answers a refused
  /// amount with. No pay button, and no message anywhere.
  String refusedAmountPage() => amountPage();

  /// A transport that serves [pages] in order, one per request.
  ///
  /// The [gateway] is the `302` target the `btnPay` post answers with.
  PortalTransport serving(
    List<String> pages, {
    List<String>? sentBodies,
    List<String>? requestUrls,
    String? gateway,
  }) {
    var index = 0;
    return PortalTransport(
      baseUri: Uri.parse('https://nut.uk.ac.ir/'),
      httpClient: MockClient((request) async {
        requestUrls?.add('${request.method} ${request.url}');
        if (request.method == 'POST' && sentBodies != null) {
          sentBodies.add(request.body);
        }

        // The pay post is answered with a redirect, and the redirect is
        // where the gateway URL lives.
        final body = pages[index < pages.length ? index : pages.length - 1];
        index++;

        if (body == '__GATEWAY__') {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  gateway ?? 'https://sadad.shaparak.ir/VPG/Purchase/Index?token=T',
            },
          );
        }

        return http.Response(body, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );
  }

  /// The body of the post that carries the amount.
  String? amountPost(List<String> bodies) {
    for (final body in bodies) {
      if (body.contains('txtPaymentAmount')) return body;
    }
    return null;
  }

  /// The body of the post that carries the pay button.
  String? payPost(List<String> bodies) {
    for (final body in bodies) {
      if (body.contains('btnPay')) return body;
    }
    return null;
  }

  group('the top-up page', () {
    test('the balance and the banks are read', () async {
      final client = CullinanPortalClient(
        transport: serving([amountPage()]),
      );

      final page = await client.fetchTopUpPage(session);

      expect(page.balanceRial, 75000);
      expect(page.banks.length, 2);
      expect(page.banks.first.name, 'درگاه سداد');
    });

    test('a bank with an empty title still has a name', () async {
      // The portal serves the second bank's title empty (F57). A blank name
      // would render as an empty radio button, so it gets a fallback.
      final client = CullinanPortalClient(
        transport: serving([amountPage()]),
      );

      final page = await client.fetchTopUpPage(session);

      expect(page.banks[1].name, isNotEmpty);
    });

    test('the bank carries the control name the post needs', () async {
      final client = CullinanPortalClient(
        transport: serving([amountPage()]),
      );

      final page = await client.fetchTopUpPage(session);

      // The bank logo IS the submit button, so its control name is what the
      // amount post carries (F54).
      expect(
        page.banks.first.id,
        r'ctl00$cphMain$dataLstBank$ctl00$imgBankLogo',
      );
    });
  });

  group('starting a top-up', () {
    test('the amount post carries the amount and the bank', () async {
      final bodies = <String>[];
      final client = CullinanPortalClient(
        transport: serving(
            [amountPage(), amountPage(), confirmationPage(), '__GATEWAY__'],
            sentBodies: bodies,
          ),
      );

      final page = await client.fetchTopUpPage(session);
      await client.beginTopUp(session, 150000, page.banks.first);

      final post = amountPost(bodies);
      expect(post, isNotNull);
      expect(post, contains('txtPaymentAmount=150000'));
      // The image input posts its own name plus the click coordinates.
      expect(post, contains('imgBankLogo.x=10'));
      expect(post, contains('imgBankLogo.y=10'));
    });

    test('the amount post carries the viewstate', () async {
      // A post without the viewstate is processed against no state at all
      // and silently does nothing.
      final bodies = <String>[];
      final client = CullinanPortalClient(
        transport: serving(
            [amountPage(), amountPage(), confirmationPage(), '__GATEWAY__'],
            sentBodies: bodies,
          ),
      );

      final page = await client.fetchTopUpPage(session);
      await client.beginTopUp(session, 150000, page.banks.first);

      expect(amountPost(bodies), contains('__VIEWSTATE=VS1'));
    });

    test('the pay post carries the confirmation page\'s viewstate', () async {
      // The two steps are two different pages, so two different viewstates.
      // Posting the first page's viewstate for the second step would be
      // processed against the wrong state.
      final bodies = <String>[];
      final client = CullinanPortalClient(
        transport: serving(
            [amountPage(), amountPage(), confirmationPage(), '__GATEWAY__'],
            sentBodies: bodies,
          ),
      );

      final page = await client.fetchTopUpPage(session);
      await client.beginTopUp(session, 150000, page.banks.first);

      final post = payPost(bodies);
      expect(post, isNotNull);
      expect(post, contains('__VIEWSTATE=VS2'));
      expect(post, contains('btnPay='));
    });

    test('the gateway URL is returned, and the redirect is not followed',
        () async {
      final requestUrls = <String>[];
      final client = CullinanPortalClient(
        transport: serving(
          [amountPage(), amountPage(), confirmationPage(), '__GATEWAY__'],
          requestUrls: requestUrls,
          gateway: 'https://sadad.shaparak.ir/VPG/Purchase/Index?token=TOK',
        ),
      );

      final page = await client.fetchTopUpPage(session);
      final gateway = await client.beginTopUp(session, 150000, page.banks.first);

      expect(gateway.host, 'sadad.shaparak.ir');
      expect(gateway.queryParameters['token'], 'TOK');

      // The redirect must NOT have been fetched: the gateway is not
      // reachable from this transport (F55), and following it would turn a
      // successful handoff into a network error.
      expect(
        requestUrls.where((u) => u.contains('shaparak')),
        isEmpty,
        reason: 'the bank gateway was fetched; it must be opened in a WebView',
      );
    });

    test('a refused amount is reported, not posted on', () async {
      // The portal refuses an out-of-range amount SILENTLY: it re-renders the
      // amount form with no message, so the only signal is the absence of
      // the pay button (F56).
      final bodies = <String>[];
      final client = CullinanPortalClient(
        transport: serving(
            [amountPage(), amountPage(), refusedAmountPage()],
            sentBodies: bodies,
          ),
      );

      final page = await client.fetchTopUpPage(session);

      await expectLater(
        client.beginTopUp(session, 50000, page.banks.first),
        throwsA(isA<TopUpRejectedException>()),
      );

      // And the pay post was never sent — the portal would have answered
      // with a server error.
      expect(payPost(bodies), isNull);
    });

    test('a gateway that does not redirect is reported', () async {
      // The second bank answers with a server error rather than a redirect
      // (F57). The app must not hand the student an empty payment page.
      final client = CullinanPortalClient(
        transport: serving([amountPage(), amountPage(), confirmationPage(), confirmationPage()]),
      );

      final page = await client.fetchTopUpPage(session);

      await expectLater(
        client.beginTopUp(session, 150000, page.banks.first),
        throwsA(isA<TopUpRejectedException>()),
      );
    });
  });

  group('the payment list', () {
    /// A payment list, as the portal renders it.
    ///
    /// The rows are newest-first, and the status is the **icon** — not the
    /// message (F58).
    String listPage() => r'''
<html><body>
<table class="GridviewStyle" id="cphMain_grdContent">
<tr>
<td style="width:5%;">1</td>
<td style="width:5%;"><img id="cphMain_grdContent_imgPaymentStatus_0" src="../Images/Icon/Accept16.png" /></td>
<td style="width:10%;">1405/07/24 14:38:56</td>
<td style="width:10%;">120000</td>
<td style="width:13%;">12611450535</td>
<td style="width:14%;">-</td>
<td style="width:8%;">ملی</td>
<td style="width:20%;">پرداخت موفق</td>
<td style="width:10%;">-</td>
<td style="width:5%;"></td>
</tr>
<tr>
<td style="width:5%;">2</td>
<td style="width:5%;"><img id="cphMain_grdContent_imgPaymentStatus_1" src="../Images/Icon/Cancel16.png" /></td>
<td style="width:10%;">1405/07/29 04:21:50</td>
<td style="width:10%;">50000</td>
<td style="width:13%;">12657130488</td>
<td style="width:14%;">-</td>
<td style="width:8%;">ملی</td>
<td style="width:20%;">خطا در دریافت اطلاعات از بانک</td>
<td style="width:10%;">-</td>
<td style="width:5%;"></td>
</tr>
</table>
</body></html>
''';

    test('the payments are read, with their status', () async {
      final client = CullinanPortalClient(
        transport: serving([listPage()]),
      );

      final payments = await client.fetchTopUpPayments(session);

      expect(payments.length, 2);
      expect(payments.first.amountRial, 120000);
      expect(payments.first.status, TopUpStatus.paid);
      expect(payments.first.message, 'پرداخت موفق');
      expect(payments.first.bank, 'ملی');
      expect(payments.first.invoiceNumber, '12611450535');

      expect(payments[1].amountRial, 50000);
      expect(payments[1].status, TopUpStatus.failed);
    });

    test('a row with no status icon is not a success', () async {
      // The icon is the authority. A row the app cannot classify must not
      // be read as a success, or the student would be told their money
      // arrived when it did not.
      final client = CullinanPortalClient(
        transport: serving([
          r'''
<html><body><table id="cphMain_grdContent">
<tr>
<td>1</td>
<td><img id="cphMain_grdContent_imgPaymentStatus_0" src="../Images/Icon/SomeNewIcon.png" /></td>
<td>1405/07/24 14:38:56</td>
<td>120000</td>
<td>12611450535</td>
<td>-</td>
<td>ملی</td>
<td></td>
<td>-</td>
<td></td>
</tr>
</table></body></html>
''',
        ]),
      );

      final payments = await client.fetchTopUpPayments(session);

      expect(payments.single.status, TopUpStatus.pending);
      expect(payments.single.status.isPaid, isFalse);
    });

    test('verifyTopUpPayment posts __EVENTVALIDATION and button coords', () async {
      final bodies = <String>[];
      const verifyPageHtml = r'''
<html><body>
<form method="post" action="./MyePayList.aspx" id="MainForm">
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="VS_VERIFY" />
<input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="GEN_VERIFY" />
<input type="hidden" name="__EVENTVALIDATION" id="__EVENTVALIDATION" value="EV_VERIFY_TOKEN" />
<input name="ctl00$cphMain$txtDateFrom" id="cphMain_txtDateFrom" value="1405/01/01" />
<input name="ctl00$cphMain$txtDateTo" id="cphMain_txtDateTo" value="1405/08/15" />
<table class="GridviewStyle" id="cphMain_grdContent">
<tr>
<td>1</td>
<td><img id="cphMain_grdContent_imgPaymentStatus_0" src="../Images/Icon/Accept16.png" /></td>
<td>1405/08/15 12:00:00</td>
<td>150000</td>
<td>123456</td>
<td>-</td>
<td>سامان</td>
<td>پرداخت موفق</td>
<td>-</td>
<td><input type="image" name="ctl00$cphMain$grdContent$ctl02$imgbtnVerify" src="../Images/Icon/Verify.png" /></td>
</tr>
</table>
</form>
</body></html>
''';

      final client = CullinanPortalClient(
        transport: serving(
          [verifyPageHtml, verifyPageHtml],
          sentBodies: bodies,
        ),
      );

      final payments = await client.verifyTopUpPayment(session);
      expect(payments, isNotEmpty);
      expect(payments.first.status, TopUpStatus.paid);

      expect(bodies, isNotEmpty);
      final post = bodies.first;
      expect(post, contains('__VIEWSTATE=VS_VERIFY'));
      expect(post, contains('__EVENTVALIDATION=EV_VERIFY_TOKEN'));
      expect(post, contains('ctl00%24cphMain%24grdContent%24ctl02%24imgbtnVerify.x=15'));
      expect(post, contains('ctl00%24cphMain%24grdContent%24ctl02%24imgbtnVerify.y=15'));
      expect(post, contains('ctl00%24cphMain%24txtDateFrom=1405%2F01%2F01'));
      expect(post, contains('ctl00%24cphMain%24txtDateTo=1405%2F08%2F15'));
    });

    test('hasVerifyButton is true when imgbtnVerify is active and false when disabled', () async {
      const activeVerifyHtml = r'''
<html><body><table id="cphMain_grdContent">
<tr>
<td>1</td>
<td><img id="cphMain_grdContent_imgPaymentStatus_0" src="../Images/Icon/Accept16.png" /></td>
<td>1405/08/15 12:00:00</td>
<td>150000</td>
<td>123456</td>
<td>-</td>
<td>سامان</td>
<td>پرداخت موفق</td>
<td>-</td>
<td><input type="image" name="ctl00$cphMain$grdContent$ctl02$imgbtnVerify" src="../Images/Icon/Verify.png" /></td>
</tr>
<tr>
<td>2</td>
<td><img id="cphMain_grdContent_imgPaymentStatus_1" src="../Images/Icon/Accept16.png" /></td>
<td>1405/08/10 12:00:00</td>
<td>150000</td>
<td>123455</td>
<td>-</td>
<td>سامان</td>
<td>پرداخت موفق</td>
<td>-</td>
<td><input type="image" name="ctl00$cphMain$grdContent$ctl03$imgbtnVerify" disabled="disabled" class="aspNetDisabled" src="../Images/Icon/Verify.png" /></td>
</tr>
</table></body></html>
''';

      final client = CullinanPortalClient(transport: serving([activeVerifyHtml]));
      final payments = await client.fetchTopUpPayments(session);

      expect(payments.length, 2);
      expect(payments[0].hasVerifyButton, isTrue);
      expect(payments[1].hasVerifyButton, isFalse);
    });
  });
}
