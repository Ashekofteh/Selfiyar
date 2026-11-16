import 'dart:typed_data';

import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:test/test.dart';

/// Exhaustively classifies a [ClaimResult].
///
/// This function only compiles while every subtype is handled. If a fourth
/// subtype is ever added to `ClaimResult`, this switch stops compiling — which
/// is the point: the money path cannot silently acquire an unhandled case.
String classify(ClaimResult result) => switch (result) {
      ClaimSucceeded() => 'succeeded',
      ClaimRejected() => 'rejected',
      ClaimAmbiguous() => 'ambiguous',
    };

void main() {
  group('ClaimResult is exhaustively distinguishable', () {
    test('succeeded carries a reservation', () {
      final reservation = Reservation(
        id: 'm1',
        date: DateTime.utc(2026, 10, 20),
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(id: '62702', name: 'dish', priceRial: 350000),
        state: ReservationState.active,
      );
      final result = ClaimSucceeded(reservation);
      expect(classify(result), 'succeeded');
      expect(result.reservation.id, 'm1');
    });

    test('rejected carries a reason', () {
      final result = ClaimRejected('already claimed');
      expect(classify(result), 'rejected');
      expect(result.reason, 'already claimed');
    });

    test('ambiguous carries a diagnostic', () {
      final result = ClaimAmbiguous('timeout after 30s, no response body');
      expect(classify(result), 'ambiguous');
      expect(result.diagnostic, contains('timeout'));
    });

    test('the three outcomes are distinct types', () {
      const results = <ClaimResult>[
        ClaimRejected('a'),
        ClaimAmbiguous('b'),
      ];
      for (final r in results) {
        expect(r, isNot(isA<ClaimSucceeded>()));
      }
      expect(const ClaimRejected('x'), isNot(isA<ClaimAmbiguous>()));
    });

    test('an ambiguous result is NOT silently a rejection', () {
      // The guard that matters: code that treats "did not succeed" as "failed"
      // would retry and risk a double purchase. Ambiguity must be its own case.
      const ClaimResult result = ClaimAmbiguous('timeout');
      expect(result is ClaimRejected, isFalse,
          reason: 'ambiguity must never be conflatable with rejection');
      expect(result is ClaimSucceeded, isFalse);
      expect(result is ClaimAmbiguous, isTrue);
    });
  });

  group('LoginChallenge', () {
    test('carries image bytes and a kind', () {
      final challenge = LoginChallenge(
        imageBytes: Uint8List.fromList([1, 2, 3, 4]),
        kind: ChallengeKind.digits4,
      );
      expect(challenge.imageBytes.length, 4);
      expect(challenge.kind, ChallengeKind.digits4);
    });

    test('unknown kind exists so unrecognised challenges are representable', () {
      final challenge = LoginChallenge(imageBytes: Uint8List(0), kind: ChallengeKind.unknown);
      expect(challenge.kind, ChallengeKind.unknown);
    });
  });

  group('BasketPage', () {
    test('hasMore is driven by the cursor', () {
      expect(const BasketPage(listings: [], cursor: null).hasMore, isFalse);
      expect(const BasketPage(listings: [], cursor: 'abc').hasMore, isTrue);
    });
  });

  group('Session', () {
    test('holds cookie pairs without interpreting them', () {
      final session = Session(
        account: 'a1',
        cookies: const {'ASP.NET_SessionId': 'xyz', 'keyId': 'abc'},
        establishedAt: DateTime.utc(2026, 10, 18),
      );
      expect(session.cookies['ASP.NET_SessionId'], 'xyz');
      expect(session.cookies.length, 2);
    });
  });

  group('LoginFailure', () {
    test('defaults to non-retryable', () {
      const failure = LoginFailure('bad captcha');
      expect(failure.retryable, isFalse);
    });

    test('can be marked retryable for transient causes', () {
      const failure = LoginFailure('network timeout', retryable: true);
      expect(failure.retryable, isTrue);
    });
  });
}