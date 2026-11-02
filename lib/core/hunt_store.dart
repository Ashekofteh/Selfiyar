/// Persistence for the hunt configuration.
///
/// One hunt per account, so the store is keyed by account. The configuration
/// names dishes and halls and carries the rate — none of it secret — so it
/// lives in the plain store, beside the account list and the reminder
/// configuration.
library;

import 'dart:convert';

import 'hunt_config.dart';
import 'models.dart';
import 'time.dart';

/// Where a hunt configuration is persisted.
abstract class HuntConfigStore {
  /// The configuration for an account, or null when it has none.
  ///
  /// Null is different from "a default configuration": null means the user
  /// has never set one up, and the UI should offer to create one rather than
  /// showing a hunt that would never fire.
  Future<HuntConfig?> load(AccountId accountId);

  /// Stores (or replaces) the configuration for an account.
  Future<void> save(AccountId accountId, HuntConfig config);

  /// Removes the configuration for an account.
  Future<void> remove(AccountId accountId);
}

/// Serialises a hunt configuration.
///
/// The **dish names** are stored, not just the option ids, because the market
/// renumbers option ids: an id saved from the official menu would not match
/// the market's listing of the same dish. The name is what survives the
/// renumbering, so it is what is stored — the id is kept only as a hint.
String encodeHuntConfig(HuntConfig config) => jsonEncode({
      'windowStart': '${config.windowStart.hour}:${config.windowStart.minute}',
      'windowEnd': '${config.windowEnd.hour}:${config.windowEnd.minute}',
      'targetSlot': config.targetSlot.name,
      'targetDate': config.targetDate?.toIso8601String(),
      'startDate': config.startDate?.toIso8601String(),
      'dishes': config.dishPriority
          .map((d) => {
                'optionId': d.optionId,
                'name': d.name,
                'priceRial': d.priceRial,
              })
          .toList(),
      'halls': config.hallPriority
          .map((h) => {'id': h.id, 'name': h.name})
          .toList(),
      'peakIntervalSeconds': config.rate.peakInterval.inSeconds,
      'offPeakIntervalSeconds': config.rate.offPeakInterval.inSeconds,
      'enabled': config.enabled,
      'requestBudget': config.requestBudget,
      'riskAcknowledged': config.riskAcknowledged,
    });

/// Reads a hunt configuration back, or null when it is unreadable.
///
/// An unreadable configuration returns null rather than a default, because a
/// default hunt would start polling and buying dishes the user never chose.
/// Failing closed is the only safe reading of a corrupt record.
HuntConfig? decodeHuntConfig(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;

    final dishes = <HuntDish>[];
    for (final entry in (decoded['dishes'] as List<dynamic>? ?? const [])) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;
      dishes.add(HuntDish(
        optionId: entry['optionId'] as String? ?? '',
        name: name,
        priceRial: entry['priceRial'] as int? ?? 0,
      ));
    }

    final halls = <HuntHall>[];
    for (final entry in (decoded['halls'] as List<dynamic>? ?? const [])) {
      if (entry is! Map<String, dynamic>) continue;
      final id = entry['id'] as String?;
      if (id == null || id.isEmpty) continue;
      halls.add(HuntHall(id: id, name: entry['name'] as String? ?? ''));
    }

    return HuntConfig(
      windowStart: _decodeTime(decoded['windowStart'], const ClockTime(16, 30)),
      windowEnd: _decodeTime(decoded['windowEnd'], const ClockTime(20, 30)),
      targetSlot: MealSlot.values.firstWhere(
        (s) => s.name == decoded['targetSlot'],
        orElse: () => MealSlot.dinner,
      ),
      targetDate: _decodeDate(decoded['targetDate']),
      startDate: _decodeDate(decoded['startDate']),
      dishPriority: dishes,
      hallPriority: halls,
      rate: HuntRate(
        peakInterval: Duration(
          seconds: decoded['peakIntervalSeconds'] as int? ?? 10,
        ),
        offPeakInterval: Duration(
          seconds: decoded['offPeakIntervalSeconds'] as int? ?? 900,
        ),
      ),
      enabled: decoded['enabled'] as bool? ?? false,
      requestBudget: decoded['requestBudget'] as int? ?? 400,
      riskAcknowledged: decoded['riskAcknowledged'] as bool? ?? false,
    );
  } catch (_) {
    return null;
  }
}

ClockTime _decodeTime(Object? raw, ClockTime fallback) {
  if (raw is! String) return fallback;
  final parts = raw.split(':');
  if (parts.length != 2) return fallback;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return fallback;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
  return ClockTime(hour, minute);
}

DateTime? _decodeDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
