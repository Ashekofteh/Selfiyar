import 'package:flutter_test/flutter_test.dart';

import 'package:bahonar_nut/core/auth/account.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/main.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';

import '../../helpers/memory_stores.dart';
import '../../helpers/portal_stubs.dart';

class _FakeBridge extends PlatformBridge {}

void main() {
  testWidgets('accounts screen displays saved accounts immediately on startup', (
    tester,
  ) async {
    final plainStore = MemoryPlainStore();
    final accountStore = PreferencesAccountStore(plainStore);
    final account = SavedAccount(
      id: 'acc-1',
      studentId: '99123456',
      alias: 'علی رضایی',
      addedAt: DateTime.now(),
    );
    await accountStore.save(account);

    final portal = FakePortalClient();
    final bridge = _FakeBridge();
    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 21, 12));
    final services = AppServices(
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

    await tester.pumpWidget(SelfiyarApp(services: services));
    await tester.pumpAndSettle();

    // Verify whether the saved account is visible on startup without navigating
    expect(find.text('علی رضایی'), findsOneWidget);
    expect(find.text('هنوز حسابی اضافه نشده'), findsNothing);
  });
}
