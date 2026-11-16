import 'package:bahonar_nut/core/auth/account.dart';
import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/features/accounts/accounts_screen.dart';
import 'package:bahonar_nut/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlainStore implements PlainStore {
  final Map<String, dynamic> _data = {};

  @override
  Future<Set<String>> keys() async => _data.keys.toSet();

  @override
  Future<bool?> readBool(String key) async => _data[key] as bool?;

  @override
  Future<int?> readInt(String key) async => _data[key] as int?;

  @override
  Future<String?> readString(String key) async => _data[key] as String?;

  @override
  Future<void> remove(String key) async => _data.remove(key);

  @override
  Future<void> writeBool(String key, bool value) async => _data[key] = value;

  @override
  Future<void> writeInt(String key, int value) async => _data[key] = value;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }
}

class _FakeAccountStore implements AccountStore {
  @override
  Future<List<SavedAccount>> loadAll() async => [];
  @override
  Future<void> remove(AccountId id) async {}
  @override
  Future<void> save(SavedAccount account) async {}
}

class _FakeReminderConfigStore implements ReminderConfigStore {
  @override
  Future<ReminderConfig> load() async => const ReminderConfig();
  @override
  Future<void> save(ReminderConfig config) async {}
}

void main() {
  Color? chipLabelColour(WidgetTester tester, String label) {
    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((rt) => rt.text.toPlainText() == label);
    return rich.text.style?.color;
  }

  Future<void> pumpChips(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              ChoiceChip(
                label: const Text('unselected'),
                selected: false,
                onSelected: (_) {},
              ),
              ChoiceChip(
                label: const Text('selected'),
                selected: true,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the light theme', () {
    testWidgets('a chip label is coloured, not left to inherit', (
      tester,
    ) async {
      final theme = buildLightTheme();
      await pumpChips(tester, theme);

      final scheme = theme.colorScheme;
      expect(
        chipLabelColour(tester, 'unselected'),
        scheme.onSurfaceVariant,
        reason: 'an unselected chip label must be readable against the chip',
      );
      expect(
        chipLabelColour(tester, 'selected'),
        scheme.onSecondaryContainer,
        reason: 'a selected chip label must be readable against its fill',
      );
    });

    testWidgets('a chip label is not white on a light surface', (tester) async {
      await pumpChips(tester, buildLightTheme());

      for (final label in ['unselected', 'selected']) {
        final colour = chipLabelColour(tester, label);
        expect(colour, isNotNull, reason: '$label must carry a colour');
        expect(
          colour!.computeLuminance(),
          lessThan(0.5),
          reason: '$label must be dark on a light theme',
        );
      }
    });
  });

  group('the dark theme', () {
    testWidgets('a chip label is coloured, not left to inherit', (
      tester,
    ) async {
      final theme = buildDarkTheme();
      await pumpChips(tester, theme);

      final scheme = theme.colorScheme;
      expect(chipLabelColour(tester, 'unselected'), scheme.onSurfaceVariant);
      expect(chipLabelColour(tester, 'selected'), scheme.onSecondaryContainer);
    });

    test('dark theme complies with Material 3 elevation and contrast', () {
      final theme = buildDarkTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.brightness, Brightness.dark);

      // Card elevation and surface hierarchy:
      expect(theme.cardTheme.color, theme.colorScheme.surfaceContainer);
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);

      // Edge-to-edge system overlay style:
      final overlay = theme.appBarTheme.systemOverlayStyle;
      expect(overlay?.statusBarIconBrightness, Brightness.light);
      expect(overlay?.systemNavigationBarIconBrightness, Brightness.light);

      // High contrast surfaces:
      expect(
        theme.dialogTheme.backgroundColor,
        theme.colorScheme.surfaceContainerHigh,
      );
      expect(
        theme.bottomSheetTheme.backgroundColor,
        theme.colorScheme.surfaceContainerLow,
      );

      // Semantic extension included:
      final ext = theme.extension<AppSemanticColors>();
      expect(ext, isNotNull);
      expect(ext?.held, AppColors.heldDark);
      expect(ext?.released, AppColors.releasedDark);
      expect(ext?.closing, AppColors.closingDark);
    });
  });

  group('semantic colours and accessibility contrast', () {
    testWidgets('AppColors.heldOf respects light and dark contexts', (
      tester,
    ) async {
      late Color lightHeld;
      late Color darkHeld;

      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey('light_app'),
          theme: buildLightTheme(),
          home: Builder(
            builder: (ctx) {
              lightHeld = AppColors.heldOf(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(lightHeld, AppColors.held);

      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey('dark_app'),
          theme: buildDarkTheme(),
          home: Builder(
            builder: (ctx) {
              darkHeld = AppColors.heldOf(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(darkHeld, AppColors.heldDark);
      // Dark held must have significantly higher luminance for legibility:
      expect(
        darkHeld.computeLuminance(),
        greaterThan(lightHeld.computeLuminance()),
      );
    });

    testWidgets('AppColors.releasedOf and closingOf adapt to dark mode', (
      tester,
    ) async {
      late Color darkReleased;
      late Color darkClosing;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: Builder(
            builder: (ctx) {
              darkReleased = AppColors.releasedOf(ctx);
              darkClosing = AppColors.closingOf(ctx);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(darkReleased, AppColors.releasedDark);
      expect(darkClosing, AppColors.closingDark);
      expect(darkReleased.computeLuminance(), greaterThan(0.2));
      expect(darkClosing.computeLuminance(), greaterThan(0.3));
    });
  });

  group('AppState theme mode persistence', () {
    test('defaults to system and updates / persists theme mode', () async {
      final store = _FakePlainStore();
      final state = AppState(
        accountStore: _FakeAccountStore(),
        reminderConfigStore: _FakeReminderConfigStore(),
        plainStore: store,
      );

      expect(state.themeMode, ThemeMode.system);

      var notified = 0;
      state.addListener(() => notified++);

      await state.setThemeMode(ThemeMode.dark);
      expect(state.themeMode, ThemeMode.dark);
      expect(notified, 1);
      expect(await store.readString(StoreKeys.themeMode), 'dark');

      await state.setThemeMode(ThemeMode.light);
      expect(state.themeMode, ThemeMode.light);
      expect(notified, 2);
      expect(await store.readString(StoreKeys.themeMode), 'light');

      // Restoring on load():
      final restoredState = AppState(
        accountStore: _FakeAccountStore(),
        reminderConfigStore: _FakeReminderConfigStore(),
        plainStore: store,
      );
      await restoredState.load();
      expect(restoredState.themeMode, ThemeMode.light);
    });
  });

  group('AccountsScreen theme mode dialog', () {
    testWidgets('opens theme dialog and changes mode', (tester) async {
      final store = _FakePlainStore();
      final state = AppState(
        accountStore: _FakeAccountStore(),
        reminderConfigStore: _FakeReminderConfigStore(),
        plainStore: store,
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa', 'IR'),
          supportedLocales: const [Locale('fa', 'IR')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: AccountsScreen(state: state),
        ),
      );

      expect(
        find.byTooltip('حالت پوسته (روشن / تاریک / خودکار)'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('حالت پوسته (روشن / تاریک / خودکار)'));
      await tester.pumpAndSettle();

      expect(find.text('حالت پوسته برنامه'), findsOneWidget);
      expect(find.text('پیرو سیستم (خودکار)'), findsOneWidget);
      expect(find.text('حالت روشن'), findsOneWidget);
      expect(find.text('حالت تاریک'), findsOneWidget);

      // Tap dark mode
      await tester.tap(find.text('حالت تاریک'));
      await tester.pumpAndSettle();

      expect(state.themeMode, ThemeMode.dark);
      expect(await store.readString(StoreKeys.themeMode), 'dark');
    });
  });
}
