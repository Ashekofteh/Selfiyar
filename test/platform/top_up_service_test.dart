import 'package:test/test.dart';

import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/core/top_up.dart';
import 'package:bahonar_nut/platform/top_up_service.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

/// A portal stub that can also fail, so the service's error handling is
/// exercised rather than assumed.
class _FailingTopUpPortal extends FakePortalClient {
  Object? beginError;

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) async {
    final error = beginError;
    if (error != null) throw error;
    return super.fetchTopUpPage(session);
  }

  @override
  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) async {
    final error = beginError;
    if (error != null) throw error;
    return super.beginTopUp(session, amountRial, bank);
  }

  int verifyCallCount = 0;
  List<TopUpPayment>? Function(int callCount)? onVerify;

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) async {
    verifyCallCount++;
    if (onVerify != null) {
      final res = onVerify!(verifyCallCount);
      if (res != null) return res;
    }
    return super.verifyTopUpPayment(session);
  }
}

void main() {
  const accountId = 'a1';

  const bank = TopUpBank(
    id: r'ctl00$cphMain$dataLstBank$ctl00$imgBankLogo',
    name: 'درگاه سداد',
    logoPath: null,
  );

  SessionManager managerWith(_FailingTopUpPortal portal) => SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21, 12)),
      );

  group('starting a top-up', () {
    test('an amount below the bound is refused before any request', () async {
      // The portal refuses an out-of-range amount SILENTLY (F56), so the
      // check has to happen here — before the request, not after it.
      final portal = _FailingTopUpPortal();
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 50000,
        bank: bank,
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, TopUpFailure.amountOutOfRange);
      expect(outcome.message, isNotNull);

      // And nothing was sent.
      expect(portal.topUpRequestedAmountRial, isNull);
    });

    test('an amount above the bound is refused before any request', () async {
      final portal = _FailingTopUpPortal();
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 6000000,
        bank: bank,
      );

      expect(outcome.failure, TopUpFailure.amountOutOfRange);
      expect(portal.topUpRequestedAmountRial, isNull);
    });

    test('a valid amount starts the top-up and returns the gateway', () async {
      final portal = _FailingTopUpPortal();
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 150000,
        bank: bank,
      );

      expect(outcome.succeeded, isTrue);
      expect(outcome.gateway, isNotNull);
      expect(portal.topUpRequestedAmountRial, 150000);
      expect(portal.topUpRequestedBank, bank);
    });

    test('a top-up larger than the balance is allowed', () async {
      // The student may be topping up BECAUSE the balance is short. A
      // top-up that costs more than the balance is the normal case, and
      // refusing it would make the feature useless.
      final portal = _FailingTopUpPortal()..balanceRial = 75000;
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 1000000,
        bank: bank,
      );

      expect(outcome.succeeded, isTrue);
    });

    test('the portal\'s own refusal is reported, not swallowed', () async {
      final portal = _FailingTopUpPortal()
        ..beginError = const TopUpRejectedException('این مبلغ پذیرفته نشد.');
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 150000,
        bank: bank,
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, TopUpFailure.rejected);
      expect(outcome.message, 'این مبلغ پذیرفته نشد.');
    });

    test('a network failure is reported', () async {
      final portal = _FailingTopUpPortal()
        ..beginError = const PortalUnreachableException('offline');
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final outcome = await service.begin(
        accountId: accountId,
        amountRial: 150000,
        bank: bank,
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.message, isNotNull);
    });
  });

  group('settling a top-up', () {
    test('the payment list is the proof, not the balance', () async {
      // The credit is applied asynchronously: the gateway answers first, and
      // the portal re-queries the bank afterwards. So a balance read taken
      // right after the handoff still shows the OLD figure even when the
      // money is on its way (F58).
      final portal = _FailingTopUpPortal()
        ..topUpPayments = [
          const TopUpPayment(
            amountRial: 150000,
            status: TopUpStatus.paid,
            message: 'پرداخت موفق',
          ),
        ];

      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final report = await service.settle(
        accountId: accountId,
        amountRial: 150000,
      );

      expect(report.isPaid, isTrue);
      expect(report.matched?.status, TopUpStatus.paid);
    });

    test('a pending payment is not reported as a failure', () async {
      final portal = _FailingTopUpPortal()
        ..topUpPayments = [
          const TopUpPayment(amountRial: 150000, status: TopUpStatus.pending),
        ];

      final service = TopUpService(
        client: portal,
        sessions: managerWith(portal),
        verifyDelays: const [Duration.zero, Duration.zero],
      );

      final report = await service.settle(
        accountId: accountId,
        amountRial: 150000,
      );

      expect(report.isPaid, isFalse);
      expect(report.matched?.status.isPending, isTrue);
    });

    test('settle retries verifyTopUpPayment and succeeds once paid', () async {
      final portal = _FailingTopUpPortal()
        ..topUpPayments = [
          const TopUpPayment(amountRial: 150000, status: TopUpStatus.pending),
        ]
        ..onVerify = (count) {
          if (count >= 3) {
            return [
              const TopUpPayment(amountRial: 150000, status: TopUpStatus.paid),
            ];
          }
          return [
            const TopUpPayment(amountRial: 150000, status: TopUpStatus.pending),
          ];
        };

      final service = TopUpService(
        client: portal,
        sessions: managerWith(portal),
        verifyDelays: const [Duration.zero, Duration.zero, Duration.zero, Duration.zero],
      );

      final report = await service.settle(
        accountId: accountId,
        amountRial: 150000,
      );

      expect(portal.verifyCallCount, equals(3));
      expect(report.isPaid, isTrue);
      expect(report.matched?.status, TopUpStatus.paid);
    });

    test('a payment that is not in the list is not claimed', () async {
      final portal = _FailingTopUpPortal()
        ..topUpPayments = [
          const TopUpPayment(amountRial: 50000, status: TopUpStatus.paid),
        ];

      final service = TopUpService(
        client: portal,
        sessions: managerWith(portal),
        verifyDelays: const [Duration.zero],
      );

      final report = await service.settle(
        accountId: accountId,
        amountRial: 150000,
      );

      expect(report.matched, isNull);
      expect(report.isPaid, isFalse);
    });

    test('a portal that cannot be read does not claim the payment failed',
        () async {
      // The money may well have arrived. Saying "failed" would be a lie.
      final portal = _FailingTopUpPortal()
        ..beginError = const PortalUnreachableException('offline');

      final service = TopUpService(
        client: portal,
        sessions: managerWith(portal),
        verifyDelays: const [Duration.zero],
      );

      final report = await service.settle(
        accountId: accountId,
        amountRial: 150000,
      );

      expect(report.payments, isEmpty);
      expect(report.matched, isNull);
      expect(report.isPaid, isFalse);
    });
  });

  group('the top-up page', () {
    test('the balance and the banks are read', () async {
      final portal = _FailingTopUpPortal()..balanceRial = 75000;
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      final page = await service.page(accountId);

      expect(page, isNotNull);
      expect(page!.balanceRial, 75000);
      expect(page.banks, isNotEmpty);
    });

    test('a page that cannot be read is null, not an exception', () async {
      final portal = _FailingTopUpPortal()
        ..beginError = const PortalUnreachableException('offline');
      final service = TopUpService(client: portal, sessions: managerWith(portal));

      expect(await service.page(accountId), isNull);
    });
  });
}
