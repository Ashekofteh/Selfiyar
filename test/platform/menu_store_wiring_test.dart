import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;
import 'package:flutter_test/flutter_test.dart';

class _MemoryPlainStore implements PlainStore {
  final Map<String, Object> values = {};

  @override
  Future<String?> readString(String key) async => values[key] as String?;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<int?> readInt(String key) async => values[key] as int?;

  @override
  Future<void> writeInt(String key, int value) async => values[key] = value;

  @override
  Future<bool?> readBool(String key) async => values[key] as bool?;

  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}

class _EmptySecureStore implements SecureCredentialStore {
  @override
  Future<Credentials?> read(AccountId accountId) async => null;

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async {}

  @override
  Future<void> delete(AccountId accountId) async {}

  @override
  Future<List<AccountId>> listAccountIds() async => const [];
}

class _EmptyClient extends FakePortalClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recent = DateTime.utc(2026, 10, 20);
  final obsolete = DateTime.utc(2026, 9, 1);

  MealMenu makeMenu(DateTime date, MealSlot slot) => MealMenu(
        date: date,
        slot: slot,
        reservable: true,
        halls: const [Hall(id: '1', name: 'سلف مرکزی')],
        dishes: const [MenuOption(id: '1', name: 'چلو کباب', priceRial: 600000)],
      );

  group('LocalMenuStoreHolder persistence', () {
    test('persist writes encoded menus to PlainStore and restore reads them back', () async {
      final plainStore = _MemoryPlainStore();
      final holder1 = LocalMenuStoreHolder(plainStore);

      holder1.store.put(makeMenu(recent, MealSlot.lunch));
      holder1.store.put(makeMenu(recent, MealSlot.dinner));
      await holder1.persist();

      final raw = await plainStore.readString(LocalMenuStoreHolder.key);
      expect(raw, isNotNull);
      expect(raw, contains('چلو کباب'));

      // New holder with fresh in-memory store simulating app restart
      final holder2 = LocalMenuStoreHolder(plainStore);
      expect(holder2.store.count, 0);

      await holder2.restore();
      expect(holder2.store.count, 2);
      expect(holder2.store.find(recent, MealSlot.lunch), isNotNull);
      expect(holder2.store.find(recent, MealSlot.dinner), isNotNull);
    });

    test('restore automatically prunes obsolete entries', () async {
      final plainStore = _MemoryPlainStore();

      // Directly seed the plain store with a recent and an obsolete menu (>28 days old)
      final raw = encodeMenuList([
        makeMenu(recent, MealSlot.lunch),
        makeMenu(obsolete, MealSlot.lunch),
      ]);
      await plainStore.writeString(LocalMenuStoreHolder.key, raw);

      final holder = LocalMenuStoreHolder(plainStore);
      await holder.restore();

      // Only the recent menu should survive pruning on restore
      expect(holder.store.find(recent, MealSlot.lunch), isNotNull);
      expect(holder.store.find(obsolete, MealSlot.lunch), isNull);
    });

    test('persist automatically prunes obsolete entries before saving', () async {
      final plainStore = _MemoryPlainStore();
      final holder = LocalMenuStoreHolder(plainStore);

      holder.store.put(makeMenu(recent, MealSlot.lunch));
      holder.store.put(makeMenu(obsolete, MealSlot.lunch));
      expect(holder.store.count, 2);

      await holder.persist();

      final raw = await plainStore.readString(LocalMenuStoreHolder.key);
      final decoded = decodeMenuList(raw!);
      expect(decoded.length, 1);
      expect(decoded.first.date, recent);
    });

    test('restore gracefully discards corrupted JSON in plainStore', () async {
      final plainStore = _MemoryPlainStore();
      await plainStore.writeString(LocalMenuStoreHolder.key, 'corrupted_garbage_content');

      final holder = LocalMenuStoreHolder(plainStore);
      await holder.restore();
      expect(holder.store.count, 0);
    });

    test('AppServices exposes shared menuStore', () {
      final plainStore = _MemoryPlainStore();
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20));
      final client = _EmptyClient();
      final services = AppServices(
        bridge: PlatformBridge(),
        client: client,
        sessions: SessionManager(
          client: client,
          store: PlatformSessionStore(
            secureStore: _EmptySecureStore(),
            plainStore: plainStore,
          ),
          solver: const NoSolver(),
          clock: clock,
        ),
        credentialStore: _EmptySecureStore(),
        plainStore: plainStore,
        clock: clock,
      );

      expect(services.menuStore, isNotNull);
      expect(services.connectivity, isNotNull);
    });
  });
}

class NoSolver implements ChallengeSolver {
  const NoSolver();
  @override
  Future<String?> solve(LoginChallenge challenge) async => null;
}
