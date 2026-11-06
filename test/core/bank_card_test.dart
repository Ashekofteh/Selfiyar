import 'package:test/test.dart';
import 'package:bahonar_nut/core/bank_card.dart';
import 'package:bahonar_nut/core/bank_card_store.dart';
import '../helpers/memory_stores.dart';

void main() {
  group('SavedBankCard', () {
    test('detectBankName detects major Iranian banks from 6-digit BIN', () {
      expect(detectBankName('6219861012345678'), equals('بانک سامان'));
      expect(detectBankName('6037991122334455'), equals('بانک ملی'));
      expect(detectBankName('6104337788990011'), equals('بانک ملت'));
      expect(detectBankName('5892101234567890'), equals('بانک سپه'));
      expect(detectBankName('5022291234567890'), equals('بانک پاسارگاد'));
      expect(detectBankName('6221061234567890'), equals('بانک پارسیان'));
      expect(detectBankName('1111111111111111'), isNull);
    });

    test('cleanPan strips spaces, dashes and non-digits', () {
      const card = SavedBankCard(
        id: '1',
        pan: '6219-8610 1234-5678',
      );
      expect(card.cleanPan, equals('6219861012345678'));
    });

    test('maskedPan masks middle 6 digits', () {
      const card = SavedBankCard(
        id: '1',
        pan: '6219861012343769',
      );
      expect(card.maskedPan, equals('6219-86**-****-3769'));
    });

    test('formattedPan splits into 4-digit groups', () {
      const card = SavedBankCard(
        id: '1',
        pan: '6219861012343769',
      );
      expect(card.formattedPan, equals('6219 8610 1234 3769'));
    });

    test('lastFourDigits extracts last 4 digits', () {
      const card = SavedBankCard(
        id: '1',
        pan: '6219861012343769',
      );
      expect(card.lastFourDigits, equals('3769'));
    });

    test('json roundtrip preserves all fields', () {
      final card = SavedBankCard(
        id: 'c1',
        pan: '6219861012343769',
        title: 'کارت سامان اصلی',
        bankName: 'بانک سامان',
        expMonth: '08',
        expYear: '05',
        cvv2: '321',
        savedAt: DateTime(2026, 10, 29, 12, 0),
      );

      final json = card.toJson();
      final roundtrip = SavedBankCard.fromJson(json);

      expect(roundtrip.id, equals(card.id));
      expect(roundtrip.pan, equals(card.pan));
      expect(roundtrip.title, equals(card.title));
      expect(roundtrip.bankName, equals(card.bankName));
      expect(roundtrip.expMonth, equals(card.expMonth));
      expect(roundtrip.expYear, equals(card.expYear));
      expect(roundtrip.cvv2, equals(card.cvv2));
      expect(roundtrip.savedAt, equals(card.savedAt));
    });
  });

  group('BankCardStore', () {
    test('MemoryBankCardStore saves, deduplicates by PAN, and deletes', () async {
      final store = MemoryBankCardStore();
      expect(await store.loadCards(), isEmpty);

      const card1 = SavedBankCard(
        id: '1',
        pan: '6219861012343769',
        title: 'سامان',
      );
      await store.saveCard(card1);

      var cards = await store.loadCards();
      expect(cards.length, equals(1));
      expect(cards.first.pan, equals('6219861012343769'));

      // Saving updated info with same PAN deduplicates and moves to top
      const card1Updated = SavedBankCard(
        id: '1_updated',
        pan: '6219861012343769',
        title: 'سامان جدید',
      );
      await store.saveCard(card1Updated);

      cards = await store.loadCards();
      expect(cards.length, equals(1));
      expect(cards.first.title, equals('سامان جدید'));

      // Delete by id
      await store.deleteCard('1_updated');
      expect(await store.loadCards(), isEmpty);
    });

    test('PlatformBankCardStore persists to PlainStore', () async {
      final plainStore = MemoryPlainStore();
      final store = PlatformBankCardStore(plainStore: plainStore);

      const card = SavedBankCard(
        id: 'c1',
        pan: '6037991234567890',
        title: 'ملی',
      );
      await store.saveCard(card);

      final reloadedStore = PlatformBankCardStore(plainStore: plainStore);
      final cards = await reloadedStore.loadCards();
      expect(cards.length, equals(1));
      expect(cards.first.pan, equals('6037991234567890'));
      expect(cards.first.bankName, equals('بانک ملی'));

      await reloadedStore.deleteCard('c1');
      expect(await reloadedStore.loadCards(), isEmpty);
    });

    test('PlatformBankCardStore persists to secure storage when available', () async {
      final secureVault = <String, String>{};
      final store = PlatformBankCardStore(
        secureRead: (k) async => secureVault[k],
        secureWrite: (k, v) async => secureVault[k] = v,
        secureDelete: (k) async => secureVault.remove(k),
      );

      const card = SavedBankCard(
        id: 'c_sec',
        pan: '6219861012343769',
        title: 'سامان امن',
        cvv2: '321',
        expMonth: '05',
        expYear: '08',
      );
      await store.saveCard(card);

      expect(secureVault.containsKey(PlatformBankCardStore.storageKey), isTrue);

      final reloaded = PlatformBankCardStore(
        secureRead: (k) async => secureVault[k],
        secureWrite: (k, v) async => secureVault[k] = v,
        secureDelete: (k) async => secureVault.remove(k),
      );
      final cards = await reloaded.loadCards();
      expect(cards.length, equals(1));
      expect(cards.first.pan, equals('6219861012343769'));
      expect(cards.first.cvv2, equals('321'));
      expect(cards.first.expMonth, equals('05'));
      expect(cards.first.expYear, equals('08'));

      await reloaded.deleteCard('c_sec');
      expect(await reloaded.loadCards(), isEmpty);
      expect(secureVault.containsKey(PlatformBankCardStore.storageKey), isFalse);
    });

    test('PlatformBankCardStore migrates cards from PlainStore to secure storage and purges PlainStore', () async {
      final plainStore = MemoryPlainStore();
      final secureVault = <String, String>{};

      // Legacy plain store setup
      final legacyStore = PlatformBankCardStore(plainStore: plainStore);
      const card = SavedBankCard(
        id: 'c_legacy',
        pan: '6037991234567890',
        title: 'ملی قدیمی',
        cvv2: '456',
        expMonth: '11',
        expYear: '04',
      );
      await legacyStore.saveCard(card);
      expect(await plainStore.readString(PlatformBankCardStore.storageKey), isNotNull);

      // Now create store with both plainStore and secure storage
      final migratingStore = PlatformBankCardStore(
        plainStore: plainStore,
        secureRead: (k) async => secureVault[k],
        secureWrite: (k, v) async => secureVault[k] = v,
        secureDelete: (k) async => secureVault.remove(k),
      );

      final loaded = await migratingStore.loadCards();
      expect(loaded.length, equals(1));
      expect(loaded.first.pan, equals('6037991234567890'));
      expect(loaded.first.cvv2, equals('456'));

      // Migration must have written to secure storage and removed from PlainStore
      expect(secureVault.containsKey(PlatformBankCardStore.storageKey), isTrue);
      expect(await plainStore.readString(PlatformBankCardStore.storageKey), isNull);
    });

    test('PlatformBankCardStore skips corrupt entries without failing entire vault', () async {
      final secureVault = <String, String>{
        PlatformBankCardStore.storageKey: '[{"id":"c1","pan":"6037991234567890","title":"کارت معتبر"}, "corrupt_item", {"not_a_card": true}]',
      };
      final store = PlatformBankCardStore(
        secureRead: (k) async => secureVault[k],
        secureWrite: (k, v) async => secureVault[k] = v,
      );

      final cards = await store.loadCards();
      expect(cards.length, equals(1));
      expect(cards.first.pan, equals('6037991234567890'));
      expect(cards.first.title, equals('کارت معتبر'));
    });
  });
}
