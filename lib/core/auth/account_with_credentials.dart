/// The account model, extended with the credentials the portal needs.
///
/// ## Why the password is not on [SavedAccount]
///
/// [SavedAccount] is the *identity* of an account: a student id, a display
/// name, when it was added. It is safe to keep in plain storage and safe to
/// show in a list.
///
/// The password is different. It never appears in the account list, never goes
/// into the plain store, and lives only in the Keystore. Keeping it in a
/// separate type makes the boundary visible in the type system rather than in
/// a comment.
library;

import 'account.dart';
import '../meal/models.dart';
import 'session.dart';

/// A saved account together with the credentials needed to reach the portal.
class AccountWithCredentials {
  const AccountWithCredentials({required this.account, this.credentials});

  final SavedAccount account;

  /// The credentials, when they have been supplied. Null when the account has
  /// been added but not yet logged in.
  final Credentials? credentials;

  AccountId get id => account.id;
  String get studentId => account.studentId;
  String get displayName => account.resolvedName;

  /// A copy with the credentials attached.
  AccountWithCredentials withCredentials(Credentials? value) =>
      AccountWithCredentials(account: account, credentials: value);

  /// A copy with the account replaced.
  AccountWithCredentials withAccount(SavedAccount value) =>
      AccountWithCredentials(account: value, credentials: credentials);
}
