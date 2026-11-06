/// The sheet that asks the student to read the CAPTCHA.
///
/// ## Why this exists
///
/// The app reads the CAPTCHA on the device, and it almost always succeeds. But
/// "almost always" is not "always": the portal may change the image, or the
/// digits may be genuinely ambiguous, and then the solver declines.
///
/// The alternative to asking the student is a login that cannot happen. The
/// login is what every read and every write depends on, and the app's whole
/// purpose is to replace the web portal — so a solver failure that ends the
/// session is a failure of the app, not of the student.
///
/// ## Why the image is shown as it was fetched
///
/// The portal binds the expected answer to the **session** the image was
/// fetched in, and it mints a new session every time it renders the login
/// page. The bytes shown here are the bytes that were fetched, and the answer
/// is judged against that challenge, in that session. Fetching a fresh image
/// would fetch a *different* challenge, and the answer the student is about to
/// type would be rejected for no reason at all.
///
/// So the image travels with the failure, all the way to here.
///
/// ## What happens when the answer is wrong
///
/// The portal has rotated the challenge by then, so the old image is dead.
/// A fresh one is fetched and shown again, with a message saying the code was
/// not accepted — because "wrong" and "the app cannot read this" are
/// different situations and the student should not have to guess which one
/// they are in.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/persian.dart';

/// Asks the student for the four digits of a CAPTCHA.
///
/// Returns the answer, or null if the student gave up.
class CaptchaDialog extends StatefulWidget {
  const CaptchaDialog({
    super.key,
    required this.imageBytes,
    this.previousAttempts = 0,
    this.accountLabel,
  });

  /// The CAPTCHA image, as fetched.
  final Uint8List imageBytes;

  /// How many times an answer has already been refused.
  final int previousAttempts;

  /// Optional account name or student ID requesting this CAPTCHA.
  final String? accountLabel;

  /// Shows the dialog and returns the answer, or null.
  static Future<String?> show(
    BuildContext context, {
    required Uint8List imageBytes,
    int previousAttempts = 0,
    String? accountLabel,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaptchaDialog(
        imageBytes: imageBytes,
        previousAttempts: previousAttempts,
        accountLabel: accountLabel,
      ),
    );
  }

  @override
  State<CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<CaptchaDialog> {
  final TextEditingController _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  void _submit() {
    final digits = toEnglishDigits(_answer.text).trim();
    if (digits.isEmpty) return;
    Navigator.of(context).pop(digits);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('کد امنیتی'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.accountLabel != null && widget.accountLabel!.trim().isNotEmpty) ...[
            Text(
              'حساب: ${widget.accountLabel!.trim()}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            'برنامه نتوانست کد را بخواند. لطفاً عدد داخل تصویر را وارد کنید.',
            style: theme.textTheme.bodyMedium,
          ),
          if (widget.previousAttempts > 0) ...[
            const SizedBox(height: 8),
            Text(
              'کد قبلی درست تشخیص داده نشد. تصویر تازه‌ای آمده است.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // The image, at the size the portal serves it, so the digits are
          // as legible as they were on the site.
          Center(
            child: Image.memory(
              widget.imageBytes,
              height: 40,
              fit: BoxFit.contain,
              // A failed decode is the portal changing the image format, and
              // the student cannot read a broken image. So it is shown as
              // plainly as it can be, and the field still accepts an answer.
              errorBuilder: (context, error, stack) => Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outline),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'تصویر بارگذاری نشد',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _answer,
            autofocus: true,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            maxLength: 4,
            inputFormatters: [
              // Persian digits are accepted as well: the student types on a
              // Persian keyboard, and a field that refuses them silently
              // drops the input — which looks like a frozen app.
              TextInputFormatter.withFunction(
                (oldValue, newValue) => TextEditingValue(
                  text: digitsOnly(newValue.text),
                  selection: TextSelection.collapsed(
                    offset: digitsOnly(newValue.text).length,
                  ),
                ),
              ),
            ],
            decoration: const InputDecoration(
              labelText: 'کد چهار رقمی',
              hintText: '۱۲۳۴',
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('ادامه'),
        ),
      ],
    );
  }
}
