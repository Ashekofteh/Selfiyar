/// The record of a successful hunt purchase.
///
/// Persisted per account so the student can inspect what was bought even after
/// the foreground notification was dismissed or the app was closed.
library;

import '../meal/models.dart';

/// A successful basket snipe purchase.
class HuntSuccess {
  const HuntSuccess({
    required this.accountId,
    required this.dishName,
    required this.hallName,
    required this.priceRial,
    required this.date,
    required this.slot,
    required this.claimedAt,
  });

  /// The account that bought the meal.
  final AccountId accountId;

  /// The meal title as rendered by the portal (نوع غذا).
  final String dishName;

  /// The dining hall where the meal is to be collected (نوع سلف).
  final String hallName;

  /// The purchase price in Rials (displayed in Toman).
  final int priceRial;

  /// The target civil date of the meal.
  final DateTime date;

  /// The meal slot (breakfast, lunch, dinner).
  final MealSlot slot;

  /// When the purchase was confirmed.
  final DateTime claimedAt;

  /// The price converted to Tomans.
  int get priceToman => priceRial ~/ 10;

  HuntSuccess copyWith({
    AccountId? accountId,
    String? dishName,
    String? hallName,
    int? priceRial,
    DateTime? date,
    MealSlot? slot,
    DateTime? claimedAt,
  }) => HuntSuccess(
    accountId: accountId ?? this.accountId,
    dishName: dishName ?? this.dishName,
    hallName: hallName ?? this.hallName,
    priceRial: priceRial ?? this.priceRial,
    date: date ?? this.date,
    slot: slot ?? this.slot,
    claimedAt: claimedAt ?? this.claimedAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HuntSuccess &&
          runtimeType == other.runtimeType &&
          accountId == other.accountId &&
          dishName == other.dishName &&
          hallName == other.hallName &&
          priceRial == other.priceRial &&
          date == other.date &&
          slot == other.slot &&
          claimedAt == other.claimedAt;

  @override
  int get hashCode => Object.hash(
    accountId,
    dishName,
    hallName,
    priceRial,
    date,
    slot,
    claimedAt,
  );

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'dishName': dishName,
    'hallName': hallName,
    'priceRial': priceRial,
    'date': date.toIso8601String(),
    'slot': slot.name,
    'claimedAt': claimedAt.toIso8601String(),
  };

  /// Parses a persisted record, returning null on any missing or corrupt field.
  ///
  /// This parser is total: it must never throw on corrupt data.
  static HuntSuccess? fromJson(AccountId accountId, Map<String, Object?> json) {
    try {
      final dishName = json['dishName'] as String?;
      final hallName = json['hallName'] as String?;
      final priceRial = json['priceRial'] as int?;
      final dateRaw = json['date'] as String?;
      final slotRaw = json['slot'] as String?;
      final claimedAtRaw = json['claimedAt'] as String?;

      if (dishName == null ||
          hallName == null ||
          priceRial == null ||
          dateRaw == null ||
          slotRaw == null ||
          claimedAtRaw == null) {
        return null;
      }

      final date = DateTime.tryParse(dateRaw);
      final claimedAt = DateTime.tryParse(claimedAtRaw);
      if (date == null || claimedAt == null) return null;

      final slot = MealSlot.values.firstWhere(
        (s) => s.name == slotRaw,
        orElse: () => MealSlot.lunch,
      );

      return HuntSuccess(
        accountId: accountId,
        dishName: dishName,
        hallName: hallName,
        priceRial: priceRial,
        date: date,
        slot: slot,
        claimedAt: claimedAt,
      );
    } catch (_) {
      return null;
    }
  }
}
