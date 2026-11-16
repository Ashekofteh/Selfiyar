/// A saved account, and how its display name is resolved.
///
/// ## The name chain
///
/// The user may give an account a nickname. If they do not, the app falls back
/// to the student's real name as the portal knows it. If that is not known
/// either, it falls back to the student ID.
///
/// The chain is **alias -> profile name -> student ID**, and it never yields an
/// empty string. The student ID is captured at save time, so an account that
/// has never been logged in — and therefore has no profile name yet — still
/// displays something meaningful rather than a blank row.
///
/// ## Why the profile name is not available offline
///
/// The portal reveals `divUsername` only on authenticated pages. So a freshly
/// added account has no profile name until its first successful login. The
/// fallback exists precisely for that window, and the chain must not be
/// "optimised" into assuming a profile name is always there.
library;

import '../meal/models.dart';

/// A saved account.
class SavedAccount {
  const SavedAccount({
    required this.id,
    required this.studentId,
    this.alias,
    this.profileName,
    this.addedAt,
    this.lastLoginAt,
  });

  /// Stable local id, independent of the student ID.
  final AccountId id;

  /// The portal's username for this student. Known from the moment of saving.
  final String studentId;

  /// The name the user chose. Null when they have not chosen one.
  final String? alias;

  /// The student's real name, learned from the portal after a login. Null until
  /// then.
  final String? profileName;

  /// When the account was added.
  final DateTime? addedAt;

  /// When the account last authenticated successfully.
  final DateTime? lastLoginAt;

  /// The name to show the user.
  ///
  /// Alias first, then the portal's profile name, then the student ID. An
  /// empty or whitespace-only alias is treated as no alias, so a user who
  /// clears the field gets the fallback rather than a blank.
  String get resolvedName {
    final candidate = alias?.trim();
    if (candidate != null && candidate.isNotEmpty) return candidate;

    final profile = profileName?.trim();
    if (profile != null && profile.isNotEmpty) return profile;

    return studentId;
  }

  /// Where the resolved name came from. Useful for the UI: it can show a hint
  /// like "نام پروفایل" when the profile name is being used, so the user knows
  /// where the name came from.
  NameSource get nameSource {
    final candidate = alias?.trim();
    if (candidate != null && candidate.isNotEmpty) return NameSource.alias;

    final profile = profileName?.trim();
    if (profile != null && profile.isNotEmpty) return NameSource.profile;

    return NameSource.studentId;
  }

  /// A copy with the alias set (or cleared, when null or blank).
  SavedAccount withAlias(String? newAlias) {
    final cleaned = newAlias?.trim();
    return SavedAccount(
      id: id,
      studentId: studentId,
      alias: (cleaned == null || cleaned.isEmpty) ? null : cleaned,
      profileName: profileName,
      addedAt: addedAt,
      lastLoginAt: lastLoginAt,
    );
  }

  /// A copy with the profile name learned from the portal.
  SavedAccount withProfileName(String name) {
    final cleaned = name.trim();
    final profile = cleaned.isEmpty ? null : cleaned;
    final updatedAlias = (alias == null || alias!.trim().isEmpty)
        ? profile
        : alias;
    return SavedAccount(
      id: id,
      studentId: studentId,
      alias: updatedAlias,
      profileName: profile,
      addedAt: addedAt,
      lastLoginAt: lastLoginAt,
    );
  }

  /// A copy with the last-login time recorded.
  SavedAccount withLastLogin(DateTime at) => SavedAccount(
    id: id,
    studentId: studentId,
    alias: alias,
    profileName: profileName,
    addedAt: addedAt,
    lastLoginAt: at,
  );

  @override
  String toString() => 'SavedAccount($id, $studentId, "$resolvedName")';
}

/// Where a display name came from.
enum NameSource {
  /// The user's own nickname.
  alias,

  /// The student's real name, from the portal.
  profile,

  /// The student ID, because nothing better is known yet.
  studentId,
}

/// The account's identity, for the UI.
class AccountIdentity {
  const AccountIdentity({
    required this.id,
    required this.studentId,
    required this.displayName,
    required this.source,
    this.alias,
    this.profileName,
  });

  final AccountId id;
  final String studentId;
  final String displayName;
  final NameSource source;
  final String? alias;
  final String? profileName;

  /// True when the user has not chosen a nickname, so the screen may offer to.
  bool get hasCustomAlias => source == NameSource.alias;

  @override
  String toString() => 'AccountIdentity($id, $displayName, ${source.name})';
}

/// Builds the display identity for an account.
AccountIdentity identityOf(SavedAccount account) => AccountIdentity(
  id: account.id,
  studentId: account.studentId,
  displayName: account.resolvedName,
  source: account.nameSource,
  alias: account.alias,
  profileName: account.profileName,
);
