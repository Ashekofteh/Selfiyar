import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bahonar_nut/core/shared/app_version.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/shell/about_dialog.dart';
import 'package:bahonar_nut/ui/features/accounts/accounts_screen.dart';

import '../../helpers/memory_stores.dart';
import '../../helpers/portal_stubs.dart';

class _RecordingBridge extends PlatformBridge {
  final List<String> openedUrls = [];

  @override
  Future<void> openUrl(String url) async {
    openedUrls.add(url);
  }
}

void main() {
  group('About Selfiyar Dialog & Updates', () {
    late MemoryPlainStore plainStore;
    late _RecordingBridge bridge;
    late AppServices services;
    late AppState state;

    setUp(() {
      plainStore = MemoryPlainStore();
      bridge = _RecordingBridge();

      final portal = FakePortalClient();
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 30, 12));

      services = AppServices(
        bridge: bridge,
        client: portal,
        sessions: SessionManager(
          client: portal,
          store: MemorySessionStore(),
          solver: NoSolver(),
          clock: clock,
        ),
        credentialStore: MemorySecureStore(),
        plainStore: plainStore,
        clock: clock,
      );

      state = AppState(
        accountStore: PreferencesAccountStore(plainStore),
        reminderConfigStore: PreferencesReminderConfigStore(plainStore),
        plainStore: plainStore,
      );
    });

    Widget wrap(Widget child) {
      return MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('fa')],
        home: Scaffold(body: child),
      );
    }

    testWidgets('renders developer information and repo links correctly', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAboutSelfiyarDialog(context, services, state: state),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('سِلفیار'), findsOneWidget);
      expect(find.text('راهنمای استفاده از برنامه'), findsOneWidget);
      expect(find.text('صفحه گیت‌هاب Ashekofteh'), findsOneWidget);
      expect(find.text('مخزن رسمی سورس‌کد'), findsOneWidget);
      expect(find.text('گزارش مشکل یا پیشنهاد'), findsOneWidget);

      // Tap developer profile
      await tester.tap(find.text('توسعه‌دهنده'));
      await tester.pumpAndSettle();

      expect(bridge.openedUrls, contains(kGitHubDeveloperUrl));

      // Tap repository
      await tester.tap(find.text('مخزن رسمی سورس‌کد'));
      await tester.pumpAndSettle();

      expect(bridge.openedUrls, contains(kGitHubRepoUrl));
    });

    testWidgets('AccountsScreen info action opens about dialog', (tester) async {
      await tester.pumpWidget(
        wrap(
          AccountsScreen(
            state: state,
            services: services,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final infoButton = find.byTooltip('درباره سِلفیار و بروزرسانی');
      expect(infoButton, findsOneWidget);

      await tester.tap(infoButton);
      await tester.pumpAndSettle();

      expect(find.text('سِلفیار'), findsOneWidget);
      expect(find.text('راهنمای استفاده از برنامه'), findsOneWidget);
      expect(find.text('صفحه گیت‌هاب Ashekofteh'), findsOneWidget);
    });
  });
}
