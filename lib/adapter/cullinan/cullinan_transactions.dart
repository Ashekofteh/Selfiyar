/// The `MyTransaction.aspx` page: the account's transaction history.
///
/// A Food Basket purchase does not appear in the weekly reservation grid
/// (verified live 2026-10-19), so the ledger is the only record of it. The
/// page's main grid holds one row (the newest transaction) while the history
/// lives in its `grdDetail_N` sub-grids, which the parser unwraps.
library;

import '../../core/portal/portal.dart';
import 'cullinan_forms.dart';
import 'cullinan_parser.dart';

/// The transaction-history area of the portal.
class CullinanTransactions extends CullinanArea {
  CullinanTransactions({required super.transport, required super.clock});

  Future<List<Transaction>> fetchTransactions(Session session) async {
    applySession(session);
    final page = await transport.get(
      session.account,
      CullinanPaths.transactions,
    );
    CullinanForms.rejectIfBounced(page);
    return CullinanParser.parseTransactions(
      page.body,
      accountId: session.account,
    );
  }
}
