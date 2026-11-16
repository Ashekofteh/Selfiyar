/// The `ePay` top-up pages: the amount form, the bank hand-off, and the
/// payment history and verification.
///
/// The ePay page has **no submit button** — the bank logos are image inputs,
/// and an image input posts its own name plus the click coordinates. That is
/// why the bank is part of the *form* rather than a separate parameter.
library;

import '../../core/auth/session_manager.dart'
    show PortalUnreachableException, TopUpRejectedException;
import '../../core/finance/top_up.dart';
import '../../core/portal/portal.dart';
import '../../transport/html_parsing.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// The top-up form's control names.
class _TopUpFields {
  static const amount = r'ctl00$cphMain$txtPaymentAmount';

  /// The bank logo for the bank at [index] in the page's list.
  ///
  /// The index is **zero-padded to two digits**, as ASP.NET writes it:
  /// `ctl00` for the first bank, `ctl01` for the second. An unpadded index
  /// names a control the page does not have, and the post would be answered
  /// as if no bank had been chosen.
  static String bankLogo(int index) {
    final padded = index.toString().padLeft(2, '0');
    return r'ctl00$cphMain$dataLstBank$ctl'
        '$padded'
        r'$imgBankLogo';
  }

  /// The confirmation page's pay button.
  static const pay = r'ctl00$cphMain$btnPay';
}

/// The top-up area of the portal.
class CullinanTopUp extends CullinanArea {
  CullinanTopUp({required super.transport, required super.clock});

  Uri? topUpUrl(Session session) => transport.resolve(CullinanPaths.topUp);

  Future<TopUpPage> fetchTopUpPage(Session session) async {
    applySession(session);
    final page = await transport.get(session.account, CullinanPaths.topUp);
    CullinanForms.rejectIfBounced(page);

    final balance = parseRial(labelText(page.body, 'lblCredit') ?? '');
    if (balance == null) {
      throw const PortalUnreachableException('موجودی خوانده نشد.');
    }

    return TopUpPage(
      balanceRial: balance,
      banks: _topUpBanks(page.body),
      defaultAmountRial: parseRial(
        labelText(page.body, 'cphMain_txtPaymentAmount') ??
            _inputValue(page.body, 'cphMain_txtPaymentAmount') ??
            '',
      ),
    );
  }

  /// The banks the page offers.
  ///
  /// A bank whose logo is missing is still offered — the portal renders the
  /// second bank's title empty (F57), but the control is there and the
  /// student may be able to use it. The app filters on the *gateway's*
  /// behaviour, not on the title, and refuses the ones that cannot work.
  List<TopUpBank> _topUpBanks(String html) {
    final out = <TopUpBank>[];

    for (final match in RegExp(
      r'<input[^>]*type="image"[^>]*id="cphMain_dataLstBank_imgBankLogo_(\d+)"'
      r'[^>]*>',
      dotAll: true,
    ).allMatches(html)) {
      final index = match.group(1)!;
      final tag = match.group(0)!;
      final title = labelText(
        html,
        'cphMain_dataLstBank_lblBankTitle_$index',
      )?.trim();

      out.add(
        TopUpBank(
          id: _TopUpFields.bankLogo(int.parse(index)),
          // The portal leaves the second bank's title empty, so the name falls
          // back to something the student can still recognise.
          name: (title == null || title.isEmpty) ? 'درگاه پرداخت' : title,
          logoPath: _firstSrc(tag),
        ),
      );
    }

    return out;
  }

  /// The first `src` attribute in a tag.
  ///
  /// The portal writes the bank logo as `<input ... src="NewMelli.jpg" src="" />`
  /// — **two** `src` attributes, the second one empty. A greedy match takes
  /// the empty one and the logo is lost, so the first is taken.
  static String? _firstSrc(String tag) {
    final match = RegExp(r'src="([^"]*)"').firstMatch(tag);
    final value = match?.group(1);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) async {
    applySession(session);

    // Step 1: the amount and the bank. The bank logo is the submit button,
    // so the post carries its name and the click coordinates.
    final page = await transport.get(session.account, CullinanPaths.topUp);
    CullinanForms.rejectIfBounced(page);

    final amountBody = _topUpFormState(page.body)
      ..[_TopUpFields.amount] = '$amountRial'
      ..['${bank.id}.x'] = '10'
      ..['${bank.id}.y'] = '10';

    final confirmation = await transport.post(
      session.account,
      CullinanPaths.topUp,
      body: amountBody,
    );
    CullinanForms.rejectIfBounced(confirmation);

    // The confirmation page is the proof that the amount was accepted: the
    // portal refuses an out-of-range amount **silently**, re-rendering the
    // amount form with no message (F56). So the absence of the pay button is
    // the only signal, and it is checked here rather than left to the
    // student to discover.
    if (!confirmation.body.contains(_TopUpFields.pay)) {
      throw const TopUpRejectedException(
        'این مبلغ پذیرفته نشد. کمترین ۱۲٬۰۰۰ و بیشترین ۵۰۰٬۰۰۰ تومان است.',
      );
    }

    // Step 2: confirm, and read the redirect to the bank's gateway.
    final payBody = _topUpFormState(confirmation.body)
      ..[_TopUpFields.pay] = 'پرداخت';

    final response = await transport.post(
      session.account,
      CullinanPaths.topUp,
      body: payBody,
      // The redirect points at the **bank**, and the bank is not reachable
      // from this transport — the TLS handshake fails there (F55). Following
      // it would turn a successful handoff into a network error, so the
      // location is read and handed to the WebView instead.
      followRedirects: false,
    );

    final location = response.headers['location'];
    if (location == null || location.isEmpty) {
      throw const TopUpRejectedException(
        'درگاه پرداخت پاسخ نداد. لطفاً دوباره تلاش کنید.',
      );
    }

    final gateway = Uri.tryParse(location);
    if (gateway == null || !gateway.hasScheme) {
      throw const TopUpRejectedException('نشانی درگاه پرداخت معتبر نبود.');
    }

    return gateway;
  }

  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) async {
    applySession(session);
    final page = await transport.get(session.account, CullinanPaths.topUpList);
    CullinanForms.rejectIfBounced(page);
    return CullinanParser.parseTopUpPayments(page.body);
  }

  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) async {
    applySession(session);
    final first = await transport.get(session.account, CullinanPaths.topUpList);
    CullinanForms.rejectIfBounced(first);

    // Find the first non-disabled «استعلام» verify control in the table.
    // Rows that have already been verified carry disabled="disabled" or
    // class="aspNetDisabled".
    final allButtons = RegExp(
      r'<input[^>]*?(?:name="([^"]*(?:imgbtnVerify|btnVerify|imgVerify|btnInquiry|btnCheck|imgbtnCheck|lnkVerify))"|value="استعلام"|title="استعلام")[^>]*?>',
      caseSensitive: false,
    ).allMatches(first.body);

    String? btnName;
    String? btnValue;
    var isImageButton = true;
    String? linkEventTarget;

    for (final m in allButtons) {
      final fullTag = m.group(0)!;
      if (!fullTag.contains(RegExp(r'\bdisabled\b', caseSensitive: false)) &&
          !fullTag.contains('aspNetDisabled')) {
        btnName =
            m.group(1) ??
            RegExp(
              r'name="([^"]+)"',
              caseSensitive: false,
            ).firstMatch(fullTag)?.group(1);
        final typeMatch = RegExp(
          r'type=["\x27]([^"\x27]+)["\x27]',
          caseSensitive: false,
        ).firstMatch(fullTag);
        final inputType = typeMatch?.group(1)?.toLowerCase() ?? 'image';
        isImageButton = inputType == 'image';
        btnValue =
            RegExp(
              r'value=["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false,
            ).firstMatch(fullTag)?.group(1) ??
            'استعلام';
        break;
      }
    }

    if (btnName == null) {
      final linkMatch = RegExp(
        r'''<a[^>]*href=["']javascript:(?:__doPostBack|WebForm_DoPostBackWithOptions)\s*\(\s*(?:&quot;|['"])([^'"&]+)(?:&quot;|['"])[^>]*>(?:(?!</a>).)*استعلام|<a[^>]*href=["']javascript:(?:__doPostBack|WebForm_DoPostBackWithOptions\s*\(\s*new\s*WebForm_PostBackOptions)\s*\(\s*(?:&quot;|['"])([^'"&]+(?:Verify|Inquiry|Check|Estelam)[^'"&]*)(?:&quot;|['"])''',
        caseSensitive: false,
      ).allMatches(first.body);
      for (final m in linkMatch) {
        final fullTag = m.group(0)!;
        if (!fullTag.contains(RegExp(r'\bdisabled\b', caseSensitive: false)) &&
            !fullTag.contains('aspNetDisabled')) {
          linkEventTarget = m.group(1) ?? m.group(2);
          break;
        }
      }
    }

    if (btnName == null && linkEventTarget == null) {
      return CullinanParser.parseTopUpPayments(first.body);
    }

    // Extract all form fields (hidden tokens, dropdowns, inputs) so ASP.NET
    // WebForms processes the request with complete and valid viewstate & form
    // context.
    final postBody = CullinanParser.extractAllFormFields(first.body);

    final dateFrom =
        _inputValue(first.body, 'cphMain_txtDateFrom') ??
        _inputValue(first.body, 'ctl00_cphMain_txtDateFrom');
    if (dateFrom != null && dateFrom.isNotEmpty) {
      postBody['ctl00\$cphMain\$txtDateFrom'] = dateFrom;
    }
    final dateTo =
        _inputValue(first.body, 'cphMain_txtDateTo') ??
        _inputValue(first.body, 'ctl00_cphMain_txtDateTo');
    if (dateTo != null && dateTo.isNotEmpty) {
      postBody['ctl00\$cphMain\$txtDateTo'] = dateTo;
    }

    if (linkEventTarget != null) {
      postBody['__EVENTTARGET'] = linkEventTarget;
      postBody['__EVENTARGUMENT'] = '';
    } else if (isImageButton) {
      postBody['$btnName.x'] = '15';
      postBody['$btnName.y'] = '15';
      postBody['__EVENTTARGET'] = '';
      postBody['__EVENTARGUMENT'] = '';
    } else {
      postBody[btnName!] = btnValue ?? 'استعلام';
      postBody['__EVENTTARGET'] = '';
      postBody['__EVENTARGUMENT'] = '';
    }

    final verified = await transport.post(
      session.account,
      CullinanPaths.topUpList,
      body: postBody,
    );
    CullinanForms.rejectIfBounced(verified);
    return CullinanParser.parseTopUpPayments(verified.body);
  }

  /// The ePay form's own state, with the fields that must travel with it.
  ///
  /// The `__VIEWSTATE` is the whole form state: a post without it is
  /// processed against no state at all and silently does nothing.
  static Map<String, String> _topUpFormState(String html) {
    final state = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': hiddenFieldValue(html, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    final ev = hiddenFieldValue(html, '__EVENTVALIDATION');
    if (ev.isNotEmpty) {
      state['__EVENTVALIDATION'] = ev;
    }
    return state;
  }

  /// The value of an `<input>`, found by its id.
  static String? _inputValue(String html, String id) {
    final inputTag = RegExp(
      '<input[^>]*id=["\'][^"\']*${RegExp.escape(id)}["\'][^>]*>',
      caseSensitive: false,
    ).firstMatch(html)?.group(0);
    if (inputTag == null) {
      final match = RegExp(
        'id=["\']?${RegExp.escape(id)}["\']?[^>]*value=["\']([^"\']*)["\']',
      ).firstMatch(html);
      return match?.group(1);
    }
    final match = RegExp(
      'value=["\']([^"\']*)["\']',
      caseSensitive: false,
    ).firstMatch(inputTag);
    return match?.group(1);
  }
}
