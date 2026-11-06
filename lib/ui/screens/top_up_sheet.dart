/// The top-up sheet: choosing how much to add to the account's balance.
///
/// ## Why a sheet and not a screen
///
/// A top-up is a **payment**, and a payment is a decision the student makes
/// in the middle of something else — they saw a meal they cannot afford, or
/// the balance is low. A sheet over the screen they were on keeps that
/// context; a full screen would hide it and lose the reason they opened it.
///
/// ## Why the amount is validated here
///
/// The portal accepts a top-up between 120,000 and 5,000,000 Rial, and
/// **refuses anything outside that range silently** — it re-renders the
/// amount form with no message at all (F56). So the sheet is the only place
/// the student can be told what is wrong, and it is checked on every
/// keystroke, not on submit.
///
/// ## Why the amount is in Toman
///
/// Every amount the student sees is in Toman, and the conversion happens at
/// this boundary, exactly once — the same rule the rest of the app follows
/// ([MoneyText]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bank_card.dart';
import '../../core/persian.dart';
import '../../core/top_up.dart';
import '../widgets.dart';

/// The sheet that starts a top-up.
class TopUpSheet extends StatefulWidget {
  const TopUpSheet({
    super.key,
    required this.balanceRial,
    required this.banks,
    required this.onSubmit,
    this.suggestedAmounts = const [],
    this.initialAmountRial,
    this.savedCards = const [],
  });

  /// The account's balance now, in Rial.
  final int balanceRial;

  /// The banks the portal offers.
  final List<TopUpBank> banks;

  /// Starts the top-up. Returns the message to show, or null on success.
  final Future<String?> Function(int amountRial, TopUpBank bank) onSubmit;

  /// Amounts offered as one-tap chips, in Rial.
  final List<int> suggestedAmounts;

  /// Optional initial amount to pre-fill in Rial (e.g. from deficit calculation).
  final int? initialAmountRial;

  /// The student's saved bank cards.
  final List<SavedBankCard> savedCards;

  /// Shows the sheet.
  static Future<void> show(
    BuildContext context, {
    required int balanceRial,
    required List<TopUpBank> banks,
    required Future<String?> Function(int amountRial, TopUpBank bank) onSubmit,
    List<int> suggestedAmounts = const [],
    int? initialAmountRial,
    List<SavedBankCard> savedCards = const [],
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => TopUpSheet(
        balanceRial: balanceRial,
        banks: banks,
        onSubmit: onSubmit,
        suggestedAmounts: suggestedAmounts,
        initialAmountRial: initialAmountRial,
        savedCards: savedCards,
      ),
    );
  }

  @override
  State<TopUpSheet> createState() => _TopUpSheetState();
}

class _TopUpSheetState extends State<TopUpSheet> {
  final TextEditingController _amount = TextEditingController();

  TopUpBank? _bank;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_onAmountChanged);
    if (widget.initialAmountRial != null && widget.initialAmountRial! > 0) {
      final effectiveRial = widget.initialAmountRial! < minTopUpRial
          ? minTopUpRial
          : widget.initialAmountRial!;
      final toman = (effectiveRial / 10).round();
      _amount.text = toman.toString();
    }
    if (widget.banks.isNotEmpty) {
      _bank = widget.banks.first;
    }
  }

  @override
  void dispose() {
    _amount.removeListener(_onAmountChanged);
    _amount.dispose();
    super.dispose();
  }

  void _onAmountChanged() => setState(() {});

  /// The typed amount, in Rial.
  int? get _rial {
    final text = _amount.text.trim();
    if (text.isEmpty) return null;
    final digits = text.replaceAll(RegExp(r'[^\d۰-۹]'), '');
    if (digits.isEmpty) return null;
    return tomanToRial(int.tryParse(toEnglishDigits(digits)) ?? 0);
  }

  /// The typed amount as a [TopUpAmount], for the bounds check.
  TopUpAmount get _typed => TopUpAmount(_rial ?? 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = _typed;
    final canSubmit = amount.isValid && _bank != null && !_busy;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('افزایش اعتبار', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'اعتبار فعلی حساب',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                MoneyText(
                  widget.balanceRial,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    // Money is teal in this app, so a balance never looks
                    // like a meal.
                    color: theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 20),

                if (_error != null) ...[
                  _ErrorBanner(_error!),
                  const SizedBox(height: 16),
                ],

                TextField(
                  controller: _amount,
                  keyboardType: TextInputType.number,
                  textDirection: TextDirection.ltr,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[0-9۰-۹]'),
                    ),
                  ],
                  decoration: InputDecoration(
                    labelText: 'مبلغ افزایش اعتبار',
                    suffixText: 'تومان',
                    helperText: 'مبلغ را به تومان وارد کنید.',
                    helperMaxLines: 2,
                    errorText: _rial == null ? null : amount.problem,
                  ),
                ),

                if (widget.suggestedAmounts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final suggested in widget.suggestedAmounts)
                        ActionChip(
                          label: MoneyText(
                            suggested,
                            style: theme.textTheme.labelLarge,
                            compact: true,
                          ),
                          onPressed: () => _setAmount(suggested),
                        ),
                    ],
                  ),
                ],

                if (widget.banks.length > 1) ...[
                  const SizedBox(height: 20),
                  _Banks(
                    banks: widget.banks,
                    selected: _bank,
                    onChanged: (bank) => setState(() => _bank = bank),
                  ),
                ],

                if (widget.savedCards.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.credit_card, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'کارت‌های ذخیره‌شده شما برای پرداخت:',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final card in widget.savedCards)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Chip(
                              avatar: const Icon(Icons.payment, size: 14),
                              label: Text(
                                '${card.displayName} (${toPersianDigits(card.lastFourDigits)})',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'پرداخت در صفحه بانک انجام می‌شود. اطلاعات کارت خود را '
                  'آنجا وارد کنید.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: Icon(
                      _busy ? Icons.hourglass_empty : Icons.credit_card,
                    ),
                    label: Text(_busy ? 'در حال اتصال' : 'پرداخت و افزایش اعتبار'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setAmount(int rial) {
    _amount.text = toPersianDigits('${rialToToman(rial)}');
  }

  Future<void> _submit() async {
    final amount = _rial;
    final bank = _bank;
    if (amount == null || bank == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final message = await widget.onSubmit(amount, bank);

    if (!mounted) return;

    if (message == null) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _busy = false;
      _error = message;
    });
  }
}

/// The inline error banner.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.errorContainer,
      ),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

/// The banks to pay through.
class _Banks extends StatelessWidget {
  const _Banks({
    required this.banks,
    required this.selected,
    required this.onChanged,
  });

  final List<TopUpBank> banks;
  final TopUpBank? selected;
  final void Function(TopUpBank) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('درگاه پرداخت', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: selected?.id,
          onChanged: (v) {
            if (v == null) return;
            for (final bank in banks) {
              if (bank.id == v) {
                onChanged(bank);
                return;
              }
            }
          },
          child: Column(
            children: [
              for (final bank in banks)
                RadioListTile<String>(
                  value: bank.id,
                  title: Text(bank.name),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
