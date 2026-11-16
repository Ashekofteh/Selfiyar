import 'package:bahonar_nut/core/auth/account.dart';
import 'package:test/test.dart';

SavedAccount account({
  String? alias,
  String? profileName,
  String studentId = '400123456',
}) =>
    SavedAccount(
      id: 'a1',
      studentId: studentId,
      alias: alias,
      profileName: profileName,
    );

void main() {
  group('the name chain: alias -> profile name -> student id', () {
    test('the alias wins when there is one', () {
      final a = account(alias: 'مBright', profileName: 'رضا شريفي');
      expect(a.resolvedName, 'مBright');
      expect(a.nameSource, NameSource.alias);
    });

    test('the profile name is used when there is no alias', () {
      final a = account(profileName: 'رضا شريفي');
      expect(a.resolvedName, 'رضا شريفي');
      expect(a.nameSource, NameSource.profile);
    });

    test('the student id is the last resort', () {
      final a = account();
      expect(a.resolvedName, '400123456');
      expect(a.nameSource, NameSource.studentId);
    });

    test('a never-logged-in account still shows something', () {
      // The profile name is only known after a login, so a fresh account has
      // none. It must still render a meaningful label, not a blank row.
      final a = account();
      expect(a.resolvedName, isNotEmpty);
      expect(a.resolvedName, a.studentId);
    });

    test('a blank alias falls through to the profile name', () {
      final a = account(alias: '   ', profileName: 'رضا شريفي');
      expect(a.resolvedName, 'رضا شريفي');
      expect(a.nameSource, NameSource.profile);
    });

    test('an empty alias falls through', () {
      final a = account(alias: '', profileName: 'رضا شريفي');
      expect(a.resolvedName, 'رضا شريفي');
    });

    test('a blank profile name falls through to the student id', () {
      final a = account(profileName: '   ');
      expect(a.resolvedName, '400123456');
      expect(a.nameSource, NameSource.studentId);
    });

    test('the alias is trimmed', () {
      final a = account(alias: '  برادر  ');
      expect(a.resolvedName, 'برادر');
    });
  });

  group('withAlias', () {
    test('sets the alias', () {
      final a = account().withAlias('مBright');
      expect(a.alias, 'مBright');
      expect(a.resolvedName, 'مBright');
    });

    test('clears the alias when given null', () {
      final a = account(alias: 'مBright').withAlias(null);
      expect(a.alias, isNull);
      expect(a.nameSource, NameSource.studentId);
    });

    test('clears the alias when given whitespace', () {
      final a = account(alias: 'مBright').withAlias('   ');
      expect(a.alias, isNull,
          reason: 'a whitespace-only alias is no alias, or the row goes blank');
    });

    test('preserves the profile name and other fields', () {
      final original = account(profileName: 'رضا شريفي');
      final updated = original.withAlias('مBright');
      expect(updated.profileName, 'رضا شريفي');
      expect(updated.studentId, original.studentId);
      expect(updated.id, original.id);
    });
  });

  group('withProfileName', () {
    test('records the name learned from the portal and sets alias if empty', () {
      final a = account().withProfileName('رضا شريفي');
      expect(a.profileName, 'رضا شريفي');
      expect(a.alias, 'رضا شريفي');
      expect(a.resolvedName, 'رضا شريفي');
    });

    test('does not override an existing alias', () {
      final a = account(alias: 'مBright').withProfileName('رضا شريفي');
      expect(a.alias, 'مBright');
      expect(a.resolvedName, 'مBright',
          reason: 'the user\'s own name takes precedence');
      expect(a.profileName, 'رضا شريفي',
          reason: 'but the profile name is still recorded');
    });

    test('an empty profile name is stored as null', () {
      final a = account().withProfileName('   ');
      expect(a.profileName, isNull);
    });
  });

  group('withLastLogin', () {
    test('records the login time', () {
      final at = DateTime.utc(2026, 10, 19, 12, 0);
      final a = account().withLastLogin(at);
      expect(a.lastLoginAt, at);
    });
  });

  group('identityOf', () {
    test('carries the resolved name and its source', () {
      final identity = identityOf(account(alias: 'مBright'));
      expect(identity.displayName, 'مBright');
      expect(identity.source, NameSource.alias);
      expect(identity.hasCustomAlias, isTrue);
    });

    test('reports when the name is not the user\'s own', () {
      final identity = identityOf(account(profileName: 'رضا شريفي'));
      expect(identity.hasCustomAlias, isFalse);
      expect(identity.source, NameSource.profile);
    });
  });
}
