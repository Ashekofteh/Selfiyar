import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/persian.dart';
import '../../core/session.dart';
import '../app_state.dart';
import '../widgets.dart';
import '../../platform/platform_services.dart';
import 'about_dialog.dart';

/// The accounts screen: the app's front door.
///
/// Shows every saved account with its **resolved** name — the user's alias if
/// they set one, otherwise the student's real name from the portal, otherwise
/// the student ID. The source of the name is shown too, so a student can see
/// at a glance that the app knows their real name but they have not given it a
/// nickname, and can fix that in one tap.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({
    super.key,
    required this.state,
    this.services,
    this.onRefresh,
    this.onTopUp,
    this.onAccountAdded,
  });

  final AppState state;
  final AppServices? services;

  /// Reads the portal for the saved accounts. Null in tests.
  final Future<void> Function()? onRefresh;

  /// Starts a top-up for an account. Null in tests.
  final void Function(SavedAccount account)? onTopUp;

  /// Called when a new account has been successfully added and saved.
  final ValueChanged<SavedAccount>? onAccountAdded;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final accounts = widget.state.accounts;

        return Scaffold(
          appBar: AppBar(
            title: const Text('حساب‌ها'),
            actions: [
              IconButton(
                onPressed: () {
                  if (widget.services != null) {
                    showAboutSelfiyarDialog(
                      context,
                      widget.services!,
                      state: widget.state,
                    );
                  }
                },
                icon: Badge(
                  isLabelVisible: widget.state.hasAvailableUpdate,
                  child: const Icon(Icons.info_outline_rounded),
                ),
                tooltip: 'درباره سِلفیار و بروزرسانی',
              ),
              IconButton(
                onPressed: () => _chooseThemeMode(context),
                icon: Icon(switch (widget.state.themeMode) {
                  ThemeMode.system => Icons.brightness_auto_outlined,
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.dark => Icons.dark_mode_outlined,
                }),
                tooltip: 'حالت پوسته (روشن / تاریک / خودکار)',
              ),
              if (widget.onRefresh != null)
                RotatingRefreshButton(
                  isSyncing: widget.state.isSyncing,
                  onPressed: widget.onRefresh,
                ),
              IconButton(
                onPressed: () => _addAccount(context),
                icon: const Icon(Icons.person_add_alt),
                tooltip: 'افزودن حساب',
              ),
            ],
          ),
          body: accounts.isEmpty
              ? EmptyState(
                  icon: Icons.people_outline,
                  title: 'هنوز حسابی اضافه نشده',
                  message: 'برای شروع، شماره دانشجویی خود را وارد کنید.',
                  action: FilledButton.icon(
                    onPressed: () => _addAccount(context),
                    icon: const Icon(Icons.add),
                    label: const Text('افزودن حساب'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: accounts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _AccountTile(
                    account: accounts[index],
                    onEdit: () => _editAccount(context, accounts[index]),
                    onDelete: () => _deleteAccount(context, accounts[index]),
                    onTopUp: widget.onTopUp == null
                        ? null
                        : () => widget.onTopUp!(accounts[index]),
                    balanceRial: widget.state.balanceFor(accounts[index].id),
                    syncError: widget.state.syncErrorFor(accounts[index].id),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _chooseThemeMode(BuildContext context) async {
    final currentMode = widget.state.themeMode;
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.palette_outlined),
            SizedBox(width: 8),
            Text('حالت پوسته برنامه'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ignore_for_file: deprecated_member_use
            RadioListTile<ThemeMode>(
              value: ThemeMode.system,
              groupValue: currentMode,
              title: const Text('پیرو سیستم (خودکار)'),
              subtitle: const Text('هماهنگ با حالت روز یا شب گوشی'),
              secondary: const Icon(Icons.brightness_auto),
              onChanged: (mode) => Navigator.of(dialogCtx).pop(mode),
            ),
            RadioListTile<ThemeMode>(
              value: ThemeMode.light,
              groupValue: currentMode,
              title: const Text('حالت روشن'),
              subtitle: const Text('زمینه روشن مناسب برای روز'),
              secondary: const Icon(Icons.light_mode),
              onChanged: (mode) => Navigator.of(dialogCtx).pop(mode),
            ),
            RadioListTile<ThemeMode>(
              value: ThemeMode.dark,
              groupValue: currentMode,
              title: const Text('حالت تاریک'),
              subtitle: const Text('زمینه تیره برای کاهش خستگی چشم'),
              secondary: const Icon(Icons.dark_mode),
              onChanged: (mode) => Navigator.of(dialogCtx).pop(mode),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('انصراف'),
          ),
        ],
      ),
    );

    if (selected != null && selected != currentMode) {
      await widget.state.setThemeMode(selected);
    }
  }

  Future<void> _addAccount(BuildContext context) async {
    final result = await showDialog<_AccountDraft>(
      context: context,
      builder: (_) => const _AccountDialog(),
    );
    if (result == null) return;

    try {
      await widget.state.upsertAccount(
        studentId: result.studentId,
        alias: result.alias,
      );

      // The password goes to the Keystore, never to the account list.
      if (result.password != null) {
        final account = widget.state.accounts.firstWhere(
          (a) => a.studentId == result.studentId,
        );
        await widget.state.saveCredentials(
          account.id,
          Credentials(
            studentId: result.studentId,
            password: result.password!,
          ),
        );
        if (widget.state.selectedReservationsAccountId == null) {
          widget.state.selectReservationsAccount(account.id);
        }
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حساب «${result.studentId}» ذخیره شد.')),
      );
      widget.onRefresh?.call();
      if (result.password != null) {
        final account = widget.state.accounts.firstWhere(
          (a) => a.studentId == result.studentId,
        );
        widget.onAccountAdded?.call(account);
      }
    } catch (e) {
      // A failed save must be visible. Silently dropping it would leave the
      // user believing the account is stored when it is not.
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ذخیره حساب ناموفق بود: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _editAccount(BuildContext context, SavedAccount account) async {
    final result = await showDialog<_AccountDraft>(
      context: context,
      builder: (_) => _AccountDialog(initial: account),
    );
    if (result == null) return;

    // The dialog's password field starts empty even in edit mode, so a
    // non-empty value here is a fresh password the user typed: it must go to
    // the secure store. Dropping it silently would leave the red
    // "credentials not saved" warning standing while the user believes they
    // saved everything — which is exactly the state that breaks the
    // automated hunt later. An empty field means "leave the stored password
    // unchanged" (or absent, if none was ever set).
    if (result.password != null) {
      await widget.state.saveCredentials(
        account.id,
        Credentials(studentId: result.studentId, password: result.password!),
      );
    }

    await widget.state.setAlias(account.id, result.alias);
    if (result.studentId != account.studentId) {
      await widget.state.upsertAccount(
        studentId: result.studentId,
        alias: result.alias,
      );
    }
  }

  Future<void> _deleteAccount(BuildContext context, SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف حساب'),
        content: Text(
          'حساب «${account.resolvedName}» و تمام اطلاعات آن '
          '(ورود، نشست و رزروهای ذخیره‌شده) حذف می‌شود. '
          'این کار برگشت‌پذیر نیست.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('حذف کن'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.state.removeAccount(account.id);
  }
}

/// One account row.
class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.onEdit,
    required this.onDelete,
    this.onTopUp,
    this.balanceRial,
    this.syncError,
  });

  final SavedAccount account;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Starts a top-up for this account. Null when the top-up is not offered.
  final VoidCallback? onTopUp;

  /// The balance last read from the portal, in Rial. Null when the account
  /// has not been read yet.
  final int? balanceRial;

  /// Why the last read failed, if it did.
  final String? syncError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = identityOf(account);

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            _initial(identity.displayName),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        title: Text(
          identity.displayName,
          style: theme.textTheme.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _subtitle(identity),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (balanceRial != null)
              _BalanceLine(
                balanceRial: balanceRial!,
                onTopUp: onTopUp,
              )
            else if (syncError != null)
              Text(
                syncError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'ویرایش نام',
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'حذف',
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }

  /// The first letter of the display name, for the avatar.
  static String _initial(String name) {
    if (name.isEmpty) return '؟';
    return name.characters.first;
  }

  /// The secondary line: the student ID, and where the name came from.
  static String _subtitle(AccountIdentity identity) {
    final source = switch (identity.source) {
      NameSource.alias => 'نام دلخواه',
      NameSource.profile => 'نام پروفایل',
      NameSource.studentId => 'نام پروفایل در دسترس نیست',
    };
    return '${identity.studentId} • $source';
  }
}

/// The balance line, with the top-up affordance.
///
/// The balance is the reason the student opens this screen, and the top-up
/// is what they do when it is too low. So the two sit together: the amount
/// in teal (money is teal in this app), and a small button beside it.
///
/// The amount gets its own row rather than sharing one with the button.
/// Side by side, the button's label ate the digits — and the digits are the
/// part the student came to read.
class _BalanceLine extends StatelessWidget {
  const _BalanceLine({required this.balanceRial, this.onTopUp});

  final int balanceRial;
  final VoidCallback? onTopUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'اعتبار: ${formatTomanPersian(balanceRial)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.secondary,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (onTopUp != null)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: onTopUp,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('افزایش اعتبار'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: theme.textTheme.labelMedium,
              ),
            ),
          ),
      ],
    );
  }
}

/// The result of the account dialog.
class _AccountDraft {
  const _AccountDraft({required this.studentId, this.alias, this.password});

  final String studentId;
  final String? alias;

  /// The portal password. Optional: an account can be added without one and
  /// the credentials can be filled in later.
  final String? password;
}

/// The add/edit dialog.
class _AccountDialog extends StatefulWidget {
  const _AccountDialog({this.initial});

  final SavedAccount? initial;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _studentId =
      TextEditingController(text: widget.initial?.studentId ?? '');
  late final TextEditingController _alias =
      TextEditingController(text: widget.initial?.alias ?? '');
  late final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _studentId.dispose();
    _alias.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;

    return AlertDialog(
      title: Text(isEdit ? 'ویرایش حساب' : 'افزودن حساب'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _studentId,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'شماره دانشجویی',
              hintText: '۴۰۰۱۲۳۴۵۶',
            ),
            enabled: !isEdit,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _alias,
            textDirection: TextDirection.rtl,
            decoration: const InputDecoration(
              labelText: 'نام دلخواه (اختیاری)',
              helperText: 'اگر خالی بماند، نام واقعی و سپس شماره دانشجویی نشان داده می‌شود.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'گذرواژه (اختیاری)',
              helperText: 'برای ورود خودکار لازم است. به‌صورت رمزگذاری‌شده ذخیره می‌شود.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () {
            final id = _studentId.text.trim();
            if (id.isEmpty) return;
            final alias = _alias.text.trim();
            final password = _password.text;
            Navigator.of(context).pop(_AccountDraft(
              studentId: id,
              alias: alias.isEmpty ? null : alias,
              password: password.isEmpty ? null : password,
            ));
          },
          child: Text(isEdit ? 'ذخیره' : 'افزودن'),
        ),
      ],
    );
  }
}
