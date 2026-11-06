/// Persistence contracts and implementations for saved bank cards.
library;

import 'dart:convert';

import 'bank_card.dart';
import 'platform_stores.dart';

/// Persistence interface for saved payment cards.
abstract class BankCardStore {
  /// Loads all saved bank cards, newest first.
  Future<List<SavedBankCard>> loadCards();

  /// Saves or updates a bank card (deduplicated by PAN).
  Future<void> saveCard(SavedBankCard card);

  /// Removes a card by [id].
  Future<void> deleteCard(String id);
}

/// [BankCardStore] backed by hardware Keystore / secure vault with migration from [PlainStore].
class PlatformBankCardStore implements BankCardStore {
  PlatformBankCardStore({
    this.plainStore,
    this.secureRead,
    this.secureWrite,
    this.secureDelete,
  });

  final PlainStore? plainStore;
  final Future<String?> Function(String key)? secureRead;
  final Future<void> Function(String key, String value)? secureWrite;
  final Future<void> Function(String key)? secureDelete;

  static const String storageKey = 'saved_bank_cards';

  @override
  Future<List<SavedBankCard>> loadCards() async {
    String? raw;
    if (secureRead != null) {
      raw = await secureRead!(storageKey);
    }

    // Migration path: if secure store has no cards yet, check plainStore
    if ((raw == null || raw.trim().isEmpty) && plainStore != null) {
      final legacy = await plainStore!.readString(storageKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        raw = legacy;
        // Migrate to secure store and purge plaintext from plainStore
        if (secureWrite != null) {
          await secureWrite!(storageKey, legacy);
          await plainStore!.remove(storageKey);
        }
      }
    } else if (plainStore != null && secureRead != null) {
      // Clean up legacy plaintext store if already present in secure store
      await plainStore!.remove(storageKey);
    }

    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <SavedBankCard>[];
      for (final item in decoded) {
        try {
          if (item is Map<String, dynamic>) {
            result.add(SavedBankCard.fromJson(item));
          } else if (item is Map) {
            result.add(SavedBankCard.fromJson(Map<String, dynamic>.from(item)));
          }
        } catch (_) {
          // Skip malformed card item without dropping the rest of the vault
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveCard(SavedBankCard card) async {
    final cleanPan = card.cleanPan;
    final current = (await loadCards())
        .where((c) => c.cleanPan != cleanPan && c.id != card.id)
        .toList();
    current.insert(0, card);
    final encoded = jsonEncode(current.map((c) => c.toJson()).toList());

    if (secureWrite != null) {
      await secureWrite!(storageKey, encoded);
      if (plainStore != null) {
        await plainStore!.remove(storageKey);
      }
    } else if (plainStore != null) {
      await plainStore!.writeString(storageKey, encoded);
    }
  }

  @override
  Future<void> deleteCard(String id) async {
    final current = (await loadCards()).where((c) => c.id != id).toList();
    final encoded = jsonEncode(current.map((c) => c.toJson()).toList());

    if (secureWrite != null) {
      if (current.isEmpty && secureDelete != null) {
        await secureDelete!(storageKey);
      } else {
        await secureWrite!(storageKey, encoded);
      }
      if (plainStore != null) {
        await plainStore!.remove(storageKey);
      }
    } else if (plainStore != null) {
      await plainStore!.writeString(storageKey, encoded);
    }
  }
}

/// In-memory implementation for tests.
class MemoryBankCardStore implements BankCardStore {
  MemoryBankCardStore([List<SavedBankCard>? initial])
      : _cards = initial != null ? List.of(initial) : [];

  final List<SavedBankCard> _cards;

  @override
  Future<List<SavedBankCard>> loadCards() async => List.unmodifiable(_cards);

  @override
  Future<void> saveCard(SavedBankCard card) async {
    _cards.removeWhere((c) => c.cleanPan == card.cleanPan || c.id == card.id);
    _cards.insert(0, card);
  }

  @override
  Future<void> deleteCard(String id) async {
    _cards.removeWhere((c) => c.id == id);
  }
}
