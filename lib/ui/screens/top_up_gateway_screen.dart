/// The payment gateway: the bank's own page, inside the app.
///
/// ## Why a WebView and not the app's HTTP client
///
/// The bank gateway is **not reachable from the app's transport**. Every
/// attempt to follow the portal's redirect to `sadad.shaparak.ir` fails the
/// TLS handshake — from Dart's `HttpClient`, from `curl`, and from Python
/// alike, on all three Shaparak hosts (F55). It is a network path, not a
/// client bug, and no amount of retrying in Dart would fix it.
///
/// And even if it were reachable, a card-entry page needs a browser: it is
/// a form-posting page with the bank's own scripts, and it is the only
/// thing on Android with a browser engine. So the gateway is opened in a
/// WebView, and the app keeps everything else — the amount, the token, the
/// confirmation — in its own tested transport.
///
/// ## Why the session cookies are injected
///
/// The gateway's return posts back to the portal, and the portal credits the
/// account that **started** the payment. So the WebView has to carry the
/// portal's session cookies, or the return would credit nobody.
///
/// ## How the app knows the payment is done
///
/// The gateway returns to the portal, so a navigation back to the portal's
/// host is the signal. The app then **re-reads** the portal's payment list,
/// which is the authority on what happened (F58) — the balance alone cannot
/// say, because the credit is applied asynchronously.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/bank_card.dart';
import '../../core/otp_extractor.dart';
import '../../core/persian.dart';

/// The screen that hosts the bank's payment page.
class TopUpGatewayScreen extends StatefulWidget {
  const TopUpGatewayScreen({
    super.key,
    required this.gateway,
    required this.cookies,
    required this.portalHost,
    this.savedCards = const [],
    this.autoLaunchBrowser = true,
    this.onLaunchExternalBrowser,
    this.onSaveCard,
    this.onDeleteCard,
    this.onAuthenticateBiometric,
    this.onReturned,
    this.onStartSmsUserConsent,
    this.onListenOtpSms,
    this.onStopSmsUserConsent,
  });

  /// The bank's gateway URL, with the token the portal minted.
  final Uri gateway;

  /// The portal's session cookies, so the return credits the right account.
  final Map<String, String> cookies;

  /// The portal's host — the signal that the payment is finished.
  final String portalHost;

  /// The list of saved bank cards available for auto-filling.
  final List<SavedBankCard> savedCards;

  /// Whether to automatically launch the payment URL in the system browser on desktop.
  final bool autoLaunchBrowser;

  /// Optional override for launching the external browser (useful for testing).
  final Future<void> Function(Uri uri)? onLaunchExternalBrowser;

  /// Invoked when the user confirms saving a new card.
  final Future<void> Function(SavedBankCard card)? onSaveCard;

  /// Invoked when the user deletes a saved card.
  final Future<void> Function(String id)? onDeleteCard;

  /// Optional biometric/screen lock authentication callback prior to decrypting/autofilling card data.
  final Future<bool> Function()? onAuthenticateBiometric;

  /// Called when the gateway returns to the portal.
  final void Function()? onReturned;

  /// Starts listening for SMS User Consent on Android.
  final Future<bool> Function()? onStartSmsUserConsent;

  /// Registers listener for OTP SMS received via SMS User Consent.
  final void Function(void Function(String message))? onListenOtpSms;

  /// Stops SMS User Consent listening.
  final Future<void> Function()? onStopSmsUserConsent;

  @override
  State<TopUpGatewayScreen> createState() => _TopUpGatewayScreenState();
}

class _TopUpGatewayScreenState extends State<TopUpGatewayScreen> {
  WebViewController? _controller;
  bool _isDesktop = false;

  int _progress = 0;
  String? _error;
  bool _returned = false;
  bool _paymentSuccessDetected = false;
  bool _portalReturnCompleted = false;
  bool _showSavedCardsBar = true;
  bool _hasPromptedSaveCard = false;
  bool _isFinishing = false;
  String? _receivedOtp;
  SavedBankCard? _pendingCardToSave;
  late List<SavedBankCard> _cards;

  @override
  void initState() {
    super.initState();
    _cards = List.of(widget.savedCards);

    widget.onStartSmsUserConsent?.call();
    widget.onListenOtpSms?.call(_handleIncomingSms);

    _isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    if (_isDesktop) {
      _openInExternalBrowser();
      return;
    }

    try {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'BankCardCaptureChannel',
          onMessageReceived: _handleChannelMessage,
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (progress) {
              if (mounted) setState(() => _progress = progress);
            },
            onUrlChange: (change) {
              final url = change.url;
              if (url != null) _checkUrl(url);
            },
            onPageFinished: (url) {
              _injectGatewayScript();
              _onPageFinished(url);
            },
            onNavigationRequest: (request) => _onNavigationRequest(request.url),
            onWebResourceError: (error) {
              if (error.isForMainFrame == true) {
                if (mounted) {
                  setState(() => _error = 'صفحه درگاه پرداخت باز نشد.');
                }
              }
            },
          ),
        );
      _load();
    } catch (_) {
      setState(() => _isDesktop = true);
      _openInExternalBrowser();
    }
  }

  Future<void> _openInExternalBrowser({bool force = false}) async {
    if (!force && !widget.autoLaunchBrowser) return;
    if (widget.onLaunchExternalBrowser != null) {
      await widget.onLaunchExternalBrowser!(widget.gateway);
      return;
    }
    final uriStr = widget.gateway.toString();
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', uriStr], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [uriStr], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [uriStr], mode: ProcessStartMode.detached);
      }
    } catch (_) {}
  }

  void _handleChannelMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'card_input') {
        final pan = (data['pan'] as String? ?? '').replaceAll(RegExp(r'\D'), '');
        if (pan.length == 16) {
          final cvv2 = data['cvv2'] as String?;
          final expMonth = data['expMonth'] as String?;
          final expYear = data['expYear'] as String?;
          final bank = detectBankName(pan);

          final isAlreadySaved = _cards.any((c) => c.cleanPan == pan);
          if (!isAlreadySaved) {
            final prev = _pendingCardToSave;
            final isSameCard = prev != null && prev.cleanPan == pan;
            _pendingCardToSave = SavedBankCard(
              id: isSameCard ? prev.id : DateTime.now().millisecondsSinceEpoch.toString(),
              pan: pan,
              cvv2: cvv2?.isNotEmpty == true ? cvv2 : (isSameCard ? prev.cvv2 : null),
              expMonth: expMonth?.isNotEmpty == true ? expMonth : (isSameCard ? prev.expMonth : null),
              expYear: expYear?.isNotEmpty == true ? expYear : (isSameCard ? prev.expYear : null),
              bankName: bank,
              title: bank,
              savedAt: isSameCard ? prev.savedAt : DateTime.now(),
            );
          }
        }
      } else if (type == 'otp_requested') {
        widget.onStartSmsUserConsent?.call();
      } else if (type == 'payment_success' || type == 'portal_return_success') {
        if (mounted && !_paymentSuccessDetected) {
          setState(() => _paymentSuccessDetected = true);
        }
        if (type == 'portal_return_success') {
          if (!_portalReturnCompleted) {
            if (mounted) setState(() => _portalReturnCompleted = true);
          }
          if (!_returned) {
            _returned = true;
            Future.delayed(const Duration(milliseconds: 2500), () {
              if (mounted) _finishAndReturn();
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _injectGatewayScript() async {
    const script = r'''
(function() {
  function toEngDigits(str) {
    if (!str) return '';
    const fa = ['۰','۱','۲','۳','۴','۵','۶','۷','۸','۹'];
    const ar = ['٠','١','٢','٣','٤','٥','٦','٧','٨','٩'];
    let res = str.toString();
    for (let i = 0; i < 10; i++) {
      res = res.replaceAll(fa[i], i.toString()).replaceAll(ar[i], i.toString());
    }
    return res;
  }

  function cleanDigits(val) {
    return toEngDigits(val).replace(/\D/g, '');
  }

  function captureFormValues() {
    let pan = '';
    const allPanMatches = Array.from(document.querySelectorAll(
      'input:not([type="hidden"])[id*="pan" i], input:not([type="hidden"])[name*="pan" i], input:not([type="hidden"])[id*="card" i], input:not([type="hidden"])[name*="card" i]'
    )).filter(el => {
      const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
      return style ? (style.display !== 'none' && style.visibility !== 'hidden') : true;
    });

    if (allPanMatches.length === 4) {
      let combined = '';
      for (let i = 0; i < 4; i++) {
        combined += cleanDigits(allPanMatches[i].value);
      }
      if (combined.length === 16) {
        pan = combined;
      }
    }

    if (pan.length !== 16) {
      const panSelectors = [
        '#CardNumber', '#cardNumber', '#cardnumber', '#pan', '#pan-input', '#txtCardNo', '#card_number',
        'input[autocomplete="cc-number"]',
        'input[name="CardNumber"]', 'input[name="cardNumber"]', 'input[name="pan"]', 'input[name="txtCardNo"]',
        'input[id*="card" i]:not([id*="pass" i]):not([id*="cvv" i]):not([id*="exp" i]):not([id*="pin" i])',
        'input[name*="card" i]:not([name*="pass" i]):not([name*="cvv" i]):not([name*="exp" i]):not([name*="pin" i])',
        'input[id*="pan" i]', 'input[name*="pan" i]',
        'input[placeholder*="کارت"]'
      ];
      for (const s of panSelectors) {
        const el = document.querySelector(s);
        if (el && el.type !== 'hidden') {
          const val = cleanDigits(el.value);
          if (val.length === 16) {
            pan = val;
            break;
          }
        }
      }
    }

    let cvv2 = '';
    const cvvSelectors = [
      '#Cvv2', '#cvv2', '#cvv', '#txtCVV2', '#txtCvv2', '#cv2',
      'input[autocomplete="cc-csc"]',
      'input[id*="cvv" i]', 'input[name*="cvv" i]', 'input[id*="cv2" i]', 'input[name*="cv2" i]',
      'input[placeholder*="cvv" i]', 'input[placeholder*="CVV" i]', 'input[placeholder*="شناسایی"]'
    ];
    for (const s of cvvSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden') {
        const val = cleanDigits(el.value);
        if (val.length >= 3 && val.length <= 4) {
          cvv2 = val;
          break;
        }
      }
    }

    let expMonth = '';
    const mSelectors = [
      '#ExpireMonth', '#expMonth', '#month', '#txtExpMonth', '#txtMonth',
      'select[id*="month" i]', 'input[id*="month" i]', 'input[name*="month" i]', 'select[name*="month" i]',
      'input[placeholder*="ماه"]', 'select[id*="mah" i]', 'input[id*="mah" i]', 'input[name*="mah" i]'
    ];
    for (const s of mSelectors) {
      const el = document.querySelector(s);
      if (el) {
        const val = cleanDigits(el.value);
        if (val.length === 1 || val.length === 2) {
          expMonth = val.padStart(2, '0');
          break;
        }
      }
    }

    let expYear = '';
    const ySelectors = [
      '#ExpireYear', '#expYear', '#year', '#txtExpYear', '#txtYear',
      'select[id*="year" i]', 'input[id*="year" i]', 'input[name*="year" i]', 'select[name*="year" i]',
      'input[placeholder*="سال"]', 'select[id*="sal" i]', 'input[id*="sal" i]', 'input[name*="sal" i]'
    ];
    for (const s of ySelectors) {
      const el = document.querySelector(s);
      if (el) {
        let val = cleanDigits(el.value);
        if (val.length === 4 && val.startsWith('14')) val = val.substring(2);
        if (val.length === 2) {
          expYear = val;
          break;
        }
      }
    }

    if (pan.length === 16) {
      if (window.BankCardCaptureChannel) {
        window.BankCardCaptureChannel.postMessage(JSON.stringify({
          type: 'card_input',
          pan: pan,
          cvv2: cvv2,
          expMonth: expMonth,
          expYear: expYear
        }));
      }
    }
  }

  function attachListeners() {
    document.querySelectorAll('input, select').forEach(el => {
      el.removeEventListener('change', captureFormValues);
      el.removeEventListener('blur', captureFormValues);
      el.addEventListener('change', captureFormValues);
      el.addEventListener('blur', captureFormValues);
    });

    document.querySelectorAll('form').forEach(form => {
      form.removeEventListener('submit', captureFormValues);
      form.addEventListener('submit', captureFormValues);
    });

    document.querySelectorAll('button, input[type="submit"], input[type="button"], a').forEach(btn => {
      btn.removeEventListener('click', captureFormValues);
      btn.addEventListener('click', captureFormValues);
    });

    document.querySelectorAll('button, input[type="button"], a, .btn, span').forEach(btn => {
      const text = (btn.innerText || btn.value || '').trim();
      if (text.includes('رمز پویا') || text.includes('درخواست رمز') || text.includes('دریافت رمز')) {
        btn.removeEventListener('click', notifyOtpRequested);
        btn.addEventListener('click', notifyOtpRequested);
      }
    });
  }

  function notifyOtpRequested() {
    if (window.BankCardCaptureChannel) {
      window.BankCardCaptureChannel.postMessage(JSON.stringify({
        type: 'otp_requested'
      }));
    }
  }

  try {
    window.open = function(url) {
      if (url) window.location.href = url;
      return window;
    };
  } catch(e) {}
  document.querySelectorAll('form[target], a[target]').forEach(el => {
    if (el.target === '_blank' || el.target === '_parent') el.target = '_self';
  });

  function checkSuccessAndAutoReturn() {
    if (window.__isSubmittingReturn) return;

    const pageText = document.body ? (document.body.innerText || '') : '';
    const isPortal = window.location.hostname.includes('uk.ac.ir');

    if (isPortal) {
      const isPortalSuccess = pageText.includes('پرداخت اینترنتی با موفقیت') || 
                              pageText.includes('با موفقیت انجام شد') || 
                              (pageText.includes('موفق') && pageText.includes('کد پیگیری')) ||
                              pageText.includes('اعتبار');
      if (isPortalSuccess) {
        window.__isSubmittingReturn = true;
        if (window.__bankCaptureInterval) {
          clearInterval(window.__bankCaptureInterval);
          window.__bankCaptureInterval = null;
        }
        if (window.BankCardCaptureChannel) {
          window.BankCardCaptureChannel.postMessage(JSON.stringify({
            type: 'portal_return_success'
          }));
        }
        return;
      }
    }

    const hasSuccessText = pageText.includes('پرداخت با موفقیت انجام شد') || 
                           pageText.includes('پرداخت اینترنتی با موفقیت') || 
                           pageText.includes('تراکنش با موفقیت') || 
                           pageText.includes('تکمیل فرآیند خرید');

    if (hasSuccessText) {
      window.__isSubmittingReturn = true;
      if (window.__bankCaptureInterval) {
        clearInterval(window.__bankCaptureInterval);
        window.__bankCaptureInterval = null;
      }
      if (window.BankCardCaptureChannel) {
        window.BankCardCaptureChannel.postMessage(JSON.stringify({
          type: 'payment_success'
        }));
      }

      const returnForm = document.querySelector('form[action*="uk.ac.ir" i], form[action*="ePay" i], form[action*="Return" i], #returnForm, form[name="returnForm"]');
      if (returnForm) {
        setTimeout(() => {
          try { returnForm.submit(); } catch(e) {}
        }, 500);
        return;
      }

      const elements = document.querySelectorAll('button, input[type="submit"], input[type="button"], a, div[role="button"], span[role="button"], .btn, #btnConfirm, #submitBtn');
      for (const el of elements) {
        const text = (el.innerText || el.value || '').trim();
        if (text.includes('تکمیل فرآیند خرید') || text.includes('تکمیل خرید') || text.includes('بازگشت به سایت پذیرنده')) {
          setTimeout(() => {
            try {
              el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
              el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
              el.click();
            } catch(e) {}
          }, 500);
          break;
        }
      }
    }
  }

  attachListeners();
  checkSuccessAndAutoReturn();
  if (!window.__bankCaptureInterval) {
    window.__bankCaptureInterval = setInterval(() => {
      captureFormValues();
      checkSuccessAndAutoReturn();
    }, 1200);
  }
})();
''';
    try {
      if (_controller == null) return;
    await _controller!.runJavaScript(script);
    } catch (_) {}
  }

  Future<void> _autoFillCard(SavedBankCard card) async {
    final pan = card.cleanPan;
    final cvv2 = card.cvv2 ?? '';
    final expMonth = card.expMonth ?? '';
    final expYear = card.expYear ?? '';

    final script = '''
(function() {
  const pan = '$pan';
  const cvv2 = '$cvv2';
  const expMonth = '$expMonth';
  const expYear = '$expYear';

  function setVal(el, val) {
    if (!el || val === undefined || val === null) return false;
    el.focus();
    try {
      const proto = el instanceof HTMLSelectElement
          ? window.HTMLSelectElement.prototype
          : window.HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      if (setter) {
        setter.call(el, val);
      } else {
        el.value = val;
      }
    } catch (_) {
      el.value = val;
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    return true;
  }

  let panFilled = false;
  const allPanMatches = Array.from(document.querySelectorAll(
    'input:not([type="hidden"])[id*="pan" i], input:not([type="hidden"])[name*="pan" i], input:not([type="hidden"])[id*="card" i], input:not([type="hidden"])[name*="card" i]'
  )).filter(el => {
    const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
    return style ? (style.display !== 'none' && style.visibility !== 'hidden' && !el.disabled) : true;
  });

  if (allPanMatches.length === 4) {
    for (let i = 0; i < 4; i++) {
      setVal(allPanMatches[i], pan.substring(i * 4, (i + 1) * 4));
    }
    panFilled = true;
  }

  if (!panFilled) {
    const panSelectors = [
      '#CardNumber', '#cardNumber', '#cardnumber', '#pan', '#pan-input', '#txtCardNo', '#card_number',
      'input[autocomplete="cc-number"]',
      'input[name="CardNumber"]', 'input[name="cardNumber"]', 'input[name="pan"]', 'input[name="txtCardNo"]',
      'input[id*="card" i]:not([id*="pass" i]):not([id*="cvv" i]):not([id*="exp" i]):not([id*="pin" i])',
      'input[name*="card" i]:not([name*="pass" i]):not([name*="cvv" i]):not([name*="exp" i]):not([name*="pin" i])',
      'input[id*="pan" i]', 'input[name*="pan" i]',
      'input[placeholder*="کارت"]'
    ];
    for (const s of panSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden' && !el.disabled) {
        setVal(el, pan);
        panFilled = true;
        break;
      }
    }
  }

  if (cvv2) {
    const cvvSelectors = [
      '#Cvv2', '#cvv2', '#cvv', '#txtCVV2', '#txtCvv2', '#cv2',
      'input[autocomplete="cc-csc"]',
      'input[id*="cvv" i]', 'input[name*="cvv" i]', 'input[id*="cv2" i]', 'input[name*="cv2" i]',
      'input[placeholder*="cvv" i]', 'input[placeholder*="CVV" i]', 'input[placeholder*="شناسایی"]'
    ];
    for (const s of cvvSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden' && !el.disabled) {
        setVal(el, cvv2);
        break;
      }
    }
  }

  if (expMonth) {
    const mSelectors = [
      '#ExpireMonth', '#expMonth', '#month', '#txtExpMonth', '#txtMonth',
      'select[id*="month" i]', 'input[id*="month" i]', 'input[name*="month" i]', 'select[name*="month" i]',
      'input[placeholder*="ماه"]', 'select[id*="mah" i]', 'input[id*="mah" i]', 'input[name*="mah" i]'
    ];
    for (const s of mSelectors) {
      const el = document.querySelector(s);
      if (el && !el.disabled) {
        setVal(el, expMonth);
        break;
      }
    }
  }
  if (expYear) {
    const ySelectors = [
      '#ExpireYear', '#expYear', '#year', '#txtExpYear', '#txtYear',
      'select[id*="year" i]', 'input[id*="year" i]', 'input[name*="year" i]', 'select[name*="year" i]',
      'input[placeholder*="سال"]', 'select[id*="sal" i]', 'input[id*="sal" i]', 'input[name*="sal" i]'
    ];
    for (const s of ySelectors) {
      const el = document.querySelector(s);
      if (el && !el.disabled) {
        setVal(el, expYear);
        break;
      }
    }
  }
})();
''';
    try {
      if (_controller == null) return;
    await _controller!.runJavaScript(script);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('اطلاعات کارت ${card.displayName} در فرم درگاه قرار گرفت.'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.indigo.shade700,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _handleCardTap(SavedBankCard card) async {
    if (widget.onAuthenticateBiometric != null) {
      final authenticated = await widget.onAuthenticateBiometric!();
      if (!authenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'احراز هویت بیومتریک انجام نشد. اطلاعات کارت درج نگردید.',
              ),
              backgroundColor: Colors.red.shade800,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }
    }
    await _autoFillCard(card);
  }

  Future<void> _promptSaveCardIfPending() async {
    final card = _pendingCardToSave;
    if (card == null || _hasPromptedSaveCard) return;
    if (_cards.any((c) => c.cleanPan == card.cleanPan)) return;
    _hasPromptedSaveCard = true;

    final nameController = TextEditingController(
      text: card.title ?? card.bankName ?? 'کارت من',
    );

    final shouldSave = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Colors.teal),
            SizedBox(width: 8),
            Text('ذخیره امن در گاوصندوق کارت‌ها'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'آیا مایلید اطلاعات این کارت (شماره، تاریخ انقضا و CVV2) در گاوصندوق امن سخت‌افزاری دستگاه ذخیره شود؟',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.fingerprint, size: 16, color: Colors.teal),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'استفاده از کارت نیازمند تأیید اثر انگشت یا قفل گوشی خواهد بود.',
                      style: Theme.of(dialogCtx).textTheme.bodySmall?.copyWith(
                        color: Colors.teal.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(dialogCtx).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(dialogCtx).colorScheme.primary.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          card.bankName ?? 'کارت شتاب',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Icon(Icons.payment, size: 20),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        toPersianDigits(card.maskedPan),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (card.expMonth != null && card.expYear != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'انقضا: ${toPersianDigits(card.expYear!)}/${toPersianDigits(card.expMonth!)}${card.cvv2 != null ? ' | CVV2: ذخیره امن' : ''}',
                        style: Theme.of(dialogCtx).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'نام دلخواه کارت',
                  hintText: 'مثلاً: کارت سامان، کارت اصلی',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            icon: const Icon(Icons.security),
            label: const Text('ذخیره امن کارت'),
          ),
        ],
      ),
    );

    if (shouldSave == true) {
      final title = nameController.text.trim();
      final toSave = card.copyWith(
        title: title.isNotEmpty ? title : (card.bankName ?? 'کارت من'),
      );
      await widget.onSaveCard?.call(toSave);
      if (mounted) {
        setState(() {
          _cards.removeWhere((c) => c.cleanPan == toSave.cleanPan);
          _cards.insert(0, toSave);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('کارت ${toSave.displayName} با موفقیت در گاوصندوق امن ذخیره شد.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    }
  }

  Future<void> _finishAndReturn() async {
    if (_isFinishing) return;
    _isFinishing = true;
    // Only prompt to save card if a payment succeeded, not when payment failed/aborted
    if ((_paymentSuccessDetected || _portalReturnCompleted) &&
        _pendingCardToSave != null &&
        !_hasPromptedSaveCard) {
      await _promptSaveCardIfPending();
    }
    widget.onReturned?.call();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Puts the portal's cookies in place, then opens the gateway.
  Future<void> _load() async {
    final manager = WebViewCookieManager();
    final host = widget.gateway.host;

    for (final entry in widget.cookies.entries) {
      await manager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: host,
          path: '/',
        ),
      );
    }

    // The portal's own cookies live on the portal's host, and the return
    // goes back there — so those are set on the portal's domain too.
    for (final entry in widget.cookies.entries) {
      await manager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: widget.portalHost,
          path: '/',
        ),
      );
    }

    if (_controller == null) return;
    await _controller!.loadRequest(widget.gateway);
  }

  NavigationDecision _onNavigationRequest(String url) {
    // Crucial: ALWAYS allow navigation so the bank POST return to the portal is never aborted
    return NavigationDecision.navigate;
  }

  void _checkUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final isPortalHost = uri.host == widget.portalHost ||
        uri.host.endsWith('.uk.ac.ir') ||
        uri.host == 'uk.ac.ir';
    if (isPortalHost) {
      if (!_paymentSuccessDetected && mounted) {
        setState(() => _paymentSuccessDetected = true);
      }
    }
  }

  void _onPageFinished(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // Must strictly be on the university portal host, never match bank URLs that include 'ePay' in path
    final isPortalHost = uri.host == widget.portalHost ||
        uri.host.endsWith('.uk.ac.ir') ||
        uri.host == 'uk.ac.ir';

    if (isPortalHost) {
      if (!_paymentSuccessDetected && mounted) {
        setState(() => _paymentSuccessDetected = true);
      }
      // Re-inject script to inspect return receipt on the portal
      _injectGatewayScript();
    }
  }

  void _handleIncomingSms(String sms) {
    final code = extractOtpCode(sms);
    if (code != null && code.isNotEmpty) {
      if (mounted) {
        setState(() {
          _receivedOtp = code;
        });
      }
      Clipboard.setData(ClipboardData(text: code));
      _autoFillOtp(code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'رمز دوم پویا (${toPersianDigits(code)}) با موفقیت دریافت و در فیلد درج شد.',
            ),
            backgroundColor: Colors.teal.shade800,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'درج مجدد',
              textColor: Colors.white,
              onPressed: () => _autoFillOtp(code),
            ),
          ),
        );
      }
    }
  }

  Future<bool> _autoFillOtp(String otp) async {
    final script = '''
(function() {
  const otp = '$otp';
  function setVal(el, val) {
    if (!el || !val) return false;
    el.focus();
    try {
      const proto = window.HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      if (setter) {
        setter.call(el, val);
      } else {
        el.value = val;
      }
    } catch (_) {
      el.value = val;
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    return true;
  }

  const selectors = [
    '#pin2', '#txtPin2', '#txtCardPin2', '#secondPassword', '#SecondPassword',
    '#pin', '#txtPassword', '#txtPin', '#otp', '#txtOtp', '#input-pin2',
    'input[autocomplete="one-time-code"]',
    'input[name="pin2" i]', 'input[id="pin2" i]',
    'input[name*="pin2" i]', 'input[id*="pin2" i]',
    'input[name*="otp" i]', 'input[id*="otp" i]',
    'input[name*="secondpass" i]', 'input[id*="secondpass" i]',
    'input[name*="secondpin" i]', 'input[id*="secondpin" i]',
    'input[placeholder*="رمز دوم" i]', 'input[placeholder*="رمز پویا" i]', 'input[placeholder*="رمز اینترنتی" i]',
    'input[aria-label*="رمز دوم" i]', 'input[aria-label*="رمز پویا" i]',
    'input[placeholder*="رمز" i]:not([placeholder*="کارت" i]):not([placeholder*="cvv" i]):not([placeholder*="تاریخ" i])'
  ];

  function fillInDoc(doc) {
    if (!doc) return false;
    for (const s of selectors) {
      try {
        const el = doc.querySelector(s);
        const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
        const isVisible = style ? (style.display !== 'none' && style.visibility !== 'hidden') : true;
        if (el && el.type !== 'hidden' && !el.disabled && isVisible) {
          setVal(el, otp);
          return true;
        }
      } catch(_) {}
    }
    const iframes = doc.querySelectorAll('iframe');
    for (const ifr of iframes) {
      try {
        const subDoc = ifr.contentDocument || ifr.contentWindow?.document;
        if (subDoc && fillInDoc(subDoc)) return true;
      } catch(_) {}
    }
    return false;
  }

  return fillInDoc(document);
})();
''';
    try {
      if (_controller == null) return false;
      await _controller!.runJavaScript(script);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    widget.onStopSmsUserConsent?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _finishAndReturn();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'بازگشت به برنامه',
            onPressed: _finishAndReturn,
          ),
          title: const Text('پرداخت اینترنتی'),
          actions: [
            FilledButton.tonalIcon(
              onPressed: _finishAndReturn,
              icon: Icon(
                Icons.check_circle_outline,
                color: _paymentSuccessDetected ? AppColors.heldOf(context) : null,
              ),
              label: Text(
                'تکمیل و بازگشت',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _paymentSuccessDetected ? AppColors.heldOf(context) : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          bottom: _isDesktop || _progress >= 100
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                  ),
                ),
        ),
        body: Column(
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: theme.colorScheme.errorContainer,
                ),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            if (_portalReturnCompleted)
              Container(
                width: double.infinity,
                color: Colors.teal.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.verified, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'تراکنش با موفقیت در سامانه دانشگاه ثبت شد. در حال بازگشت به برنامه...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.teal.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      onPressed: _finishAndReturn,
                      child: const Text(
                        'تکمیل و بازگشت',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              )
            else if (_paymentSuccessDetected)
              Container(
                width: double.infinity,
                color: Colors.green.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'پرداخت با موفقیت انجام شد! در حال انتقال امن و ثبت نهایی در سامانه دانشگاه...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.green.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      onPressed: _finishAndReturn,
                      child: const Text(
                        'تکمیل و بازگشت',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            if (_receivedOtp != null)
              Container(
                width: double.infinity,
                color: Colors.teal.shade50,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.mark_email_read, color: Colors.teal, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'رمز دوم پویا: ${toPersianDigits(_receivedOtp!)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.teal.shade900,
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _autoFillOtp(_receivedOtp!),
                      icon: const Icon(Icons.paste, size: 16),
                      label: const Text('درج در درگاه'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      ),
                    ),
                  ],
                ),
              ),
            if (_cards.isNotEmpty && _showSavedCardsBar)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  border: Border(
                    bottom: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.shield_outlined, size: 16, color: Colors.teal),
                        const SizedBox(width: 6),
                        Text(
                          'کارت‌های ذخیره‌شده (با احراز هویت بیومتریک):',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: () => setState(() => _showSavedCardsBar = false),
                          icon: const Icon(Icons.keyboard, size: 16),
                          label: const Text('ورود دستی', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final card in _cards)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: InputChip(
                                avatar: const Icon(Icons.payment, size: 16),
                                label: Text(
                                  '${card.displayName} (${toPersianDigits(card.lastFourDigits)})',
                                ),
                                tooltip: 'درج خودکار امن اطلاعات ${card.displayName}',
                                onPressed: () => _handleCardTap(card),
                                onDeleted: widget.onDeleteCard != null
                                    ? () async {
                                        await widget.onDeleteCard!(card.id);
                                        if (mounted) {
                                          setState(() => _cards.removeWhere((c) => c.id == card.id));
                                        }
                                      }
                                    : null,
                                deleteIcon: const Icon(Icons.close, size: 14),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else if (_cards.isNotEmpty && !_showSavedCardsBar)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                child: Row(
                  children: [
                    const Icon(Icons.keyboard, size: 16),
                    const SizedBox(width: 8),
                    const Text('حالت ورود دستی اطلاعات فعال است', style: TextStyle(fontSize: 12)),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => setState(() => _showSavedCardsBar = true),
                      icon: const Icon(Icons.credit_card, size: 16),
                      label: const Text('نمایش کارت‌ها', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _isDesktop
                  ? _buildDesktopView(theme)
                  : WebViewWidget(controller: _controller!),
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildDesktopView(ThemeData theme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.payment_outlined,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'انتقال به درگاه رسمی پرداخت شاپرک',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'در نسخه ویندوز و مک، جهت حفظ بالاترین سطح امنیت بانکی، درگاه پرداخت شاپرک در مرورگر اصلی سیستم شما باز می‌شود.\n'
                    'پس از تکمیل تراکنش در مرورگر، روی دکمه «تکمیل و ثبت نهایی در برنامه» کلیک کنید تا موجودی حساب شما به‌روزرسانی شود.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.7,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _finishAndReturn,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('تکمیل و ثبت نهایی در برنامه'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _openInExternalBrowser(force: true),
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('باز کردن مجدد درگاه'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_cards.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(Icons.credit_card, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'کپی سریع اطلاعات کارت‌های بانکی ذخیره‌شده:',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final card in _cards)
                      _DesktopCardTile(
                        card: card,
                        onAuthenticateBiometric: widget.onAuthenticateBiometric,
                        onDelete: widget.onDeleteCard != null
                            ? () async {
                                await widget.onDeleteCard!(card.id);
                                if (mounted) {
                                  setState(() => _cards.removeWhere((c) => c.id == card.id));
                                }
                              }
                            : null,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopCardTile extends StatelessWidget {
  const _DesktopCardTile({
    required this.card,
    this.onAuthenticateBiometric,
    this.onDelete,
  });

  final SavedBankCard card;
  final Future<bool> Function()? onAuthenticateBiometric;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pan = card.cleanPan;
    final formattedPan = pan.length == 16
        ? '${pan.substring(0, 4)} - ${pan.substring(4, 8)} - ${pan.substring(8, 12)} - ${pan.substring(12, 16)}'
        : pan;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.payment, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  toPersianDigits(formattedPan),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  textDirection: TextDirection.ltr,
                ),
                if (card.expMonth != null && card.expYear != null)
                  Text(
                    'انقضا: ${toPersianDigits(card.expYear!)}/${toPersianDigits(card.expMonth!)}${card.cvv2 != null ? ' | CVV2: ذخیره امن' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'کپی شماره کارت',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pan));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('شماره کارت ${card.displayName} در کلیپ‌بورد کپی شد.'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          if (card.expMonth != null && card.expYear != null)
            IconButton(
              icon: const Icon(Icons.calendar_today, size: 18),
              tooltip: 'کپی تاریخ انقضا',
              onPressed: () {
                final exp = '${card.expYear}/${card.expMonth}';
                Clipboard.setData(ClipboardData(text: exp));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('تاریخ انقضا ($exp) در کلیپ‌بورد کپی شد.'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
          if (card.cvv2 != null && card.cvv2!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.password, size: 18),
              tooltip: 'کپی کد CVV2',
              onPressed: () async {
                if (onAuthenticateBiometric != null) {
                  final ok = await onAuthenticateBiometric!();
                  if (!ok) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('احراز هویت انجام نشد. کد CVV2 کپی نشد.'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                    return;
                  }
                }
                await Clipboard.setData(ClipboardData(text: card.cvv2!));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('کد CVV2 در کلیپ‌بورد کپی شد.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'حذف کارت',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}
