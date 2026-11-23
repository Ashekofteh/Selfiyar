# Senior Review Council — Stage 5 (H3 / L1 / L3 / M3 / L2 / L4 / L7 / M2)

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Date:** 2026-11-23
**Scope (round 1):** uncommitted working tree — `git diff HEAD` = 14 modified files + 2 untracked test files (+ this report). Round 2 is appended at the top; see its own scope line.
**Base commit:** `3676d76 fix(finance): event-source spend summary…`
**Spec:** `docs/fix-plan.md` §۶, `docs/optimization-audit.md` (H3, L1–L7, M1–M3), acceptance tests #11–#15 and #18
**Mode:** read-only audit of the product code; two temporary probe scripts under the git-ignored `tool/` were created and deleted. This report is the only file this review wrote.

---

## Re-review (round 2) — post-fix

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode)
**Scope:** the same working tree, `git diff HEAD` against base `3676d76`, after the B1/S1–S5/N1 fixes.

### Verdict: **APPROVE** ✅

All six required items are addressed and verified independently. The fixes are small, localised, and each has a test that would fail without it. No new blocking or should-fix finding was introduced. The round-1 verdict below is retained as the historical record and is **superseded**.

### Independent verification

| Check | Result |
|---|---|
| `D:\flutter\bin\flutter.bat analyze` | `No issues found! (ran in 1.4s)` |
| `D:\flutter\bin\flutter.bat test` (whole suite) | **1507 tests, all passed** |
| `git diff HEAD --stat` | 16 modified files, `+521 / −78`, plus `test/adapter/cullinan/read_resilience_test.dart` (new) |
| `test/platform/_probe_ledger_test.dart` | **absent** (B1) |
| `grep partial lib/` | consumed at [home_shell.dart:1148](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1148) and [:1474](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1474) (S2) |
| production `fetchOfferings` callers | only the `@Deprecated` forwarder in [cullinan_client.dart:131](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_client.dart:131) (L2 unchanged) |

### Resolution of round-1 findings

| ID | Status | Evidence |
|---|---|---|
| **B1** probe test | **Fixed** | The file is gone; `git status` shows only the expected sources, two review docs and the new test. |
| **S1** `fetchMenu`/`_readMenuFor` unguarded | **Fixed** | `_readMenuFor` now shape-checks **both** the current page and the next-week page (`looksLikeReservationPage`) and requires `_introducesLaterWeek` before returning the POST body ([cullinan_reservation.dart:214-254](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:214)). Two tests pin it: error page → `PortalUnreachableException` ([read_resilience_test.dart:131](D:/Bahonar-Nut/test/adapter/cullinan/read_resilience_test.dart:131)) and silent no-op → throw ([:171](D:/Bahonar-Nut/test/adapter/cullinan/read_resilience_test.dart:171)). This closes the "error page becomes an empty market" path: `_fetchBookableMenus`/market catches `PortalUnreachableException` and shows the error rather than clearing. |
| **S2** `partial` written but never read | **Fixed (both halves)** | The flag is now consumed: `_handleMenuDiff(diff)` is skipped when `partial` is true in both call sites ([home_shell.dart:1148](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1148), [:1474](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1474)), so a partial read cannot emit a premature next-week publication notice. The doc comment was also corrected: it now states `LocalMenuStore.upsert` merges and never deletes, and describes the flag as advisory ([portal_models.dart:479-494](D:/Bahonar-Nut/lib/core/portal/portal_models.dart:479)). |
| **S3** degraded GET path mislabels rows | **Fixed** | The degraded branch returns the body only when `buyPageDate(first.body) == wanted`, otherwise `null` ([cullinan_basket_buy.dart:137-145](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:137)), which `fetchBasket` already turns into an empty page. Test at [read_resilience_test.dart:288](D:/Bahonar-Nut/test/adapter/cullinan/read_resilience_test.dart:288) removes the viewstate and requests a different date; no listings are produced. |
| **S4** unproven/over-broad gateway keywords | **Fixed** | `_stableGatewayKeywords` is now exactly `['سداد', 'sadad']` ([top_up.dart:293-296](D:/Bahonar-Nut/lib/core/finance/top_up.dart:293)). `شاپرک`/`shaparak` (the false-positive magnet) is gone, so the `[working-unknown, recognised-broken]` regression is no longer possible. The reorder case and the fallback are covered ([top_up_test.dart:101-131](D:/Bahonar-Nut/test/core/finance/top_up_test.dart:101)). |
| **S5** M1/L6/L4 undeclared | **Fixed** | `docs/fix-plan.md` §۶.۱ now records the M1 deferral (safety gate §۷.۲), the L6 raw-rule rationale, and the L4 surface ([fix-plan.md:154-159](D:/Bahonar-Nut/docs/fix-plan.md:154)); the single-meal success snackbar now names dish and hall ([home_shell.dart:2836-2844](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2836)). |
| **N1** `_hasTable` quoted-id only | **Fixed** | Regex now accepts single-, double- or unquoted ids ([cullinan_forms.dart:120-124](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_forms.dart:120)). |

### New observations (non-blocking)

1. **Dead inner check in the S3 fix.** In `_readBasketHtml`, the outer `if (buyPageDate(first.body) == wanted) return first.body;` at [:133](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:133) already returns, so the nested identical check at [:141](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:141) can never be true. Behaviour is correct; the branch can be dropped for clarity.

2. **The top-up "logo identifies Sadad" claim is still not evidence-backed.** The real page renders the Sadad row with title `درگاه سداد` and logo `NewMelli.jpg` ([top_up_write_path_test.dart:53-54](D:/Bahonar-Nut/test/adapter/cullinan/top_up_write_path_test.dart:53)). `_namesGateway` matches `sadad` against the name **or** logo, and `NewMelli.jpg` cannot match, so the logo path does not identify Sadad when the label is empty. The doc sentence "`NewMelli.jpg` / `Sadad.png` are what the page actually carries when the label is missing" and the `Images/Bank/Sadad.png` test ([top_up_test.dart:112](D:/Bahonar-Nut/test/core/finance/top_up_test.dart:112)) therefore describe an asset the portal does not serve. This is safe in practice (no match → `banks.first`, the old behaviour), but the comment/test should either be dropped or explicitly marked as hypothetical so it is not read as proof.

3. **No regression test covers the `partial` suppression itself.** The adapter-level `partial` flag is tested, and the store's merge/never-delete behaviour is tested elsewhere; the UI suppression at the two `home_shell` call sites is the one new branch without a test. Optional, but it is the exact behaviour S2 asked for.

4. **Residual assumptions from round 1 remain by design.** N2 (empty next week is indistinguishable from an unread one) and N3 (all-three-grids invariant) are unchanged. N3 now also gates `fetchMenu`, so a hypothetical account that renders fewer than three grids would fail the market read closed. Every capture carries three grids, so this is acceptable, but it is the assumption to re-check before widening the guard.

N4 (the Gemini review describes code that is not in the tree) still stands: do not cite that document as evidence.

### Final verdict

**APPROVE.** The Stage-5 core idea — an unread portal is *unknown*, never *empty*, and nothing is written until both weeks were read — now holds across `fetchReservations`, `fetchBookableMenus`, `fetchMenu` and the basket date paths, and its menu-level signal is consumed rather than inert. The remaining points are comments/tests and optional coverage, not behaviour. The stage is ready to commit.

---

## Verdict — round 1 (superseded)

## **REQUEST CHANGES**

The engineering direction is right and most of the diff is careful, evidence-backed work: every reservation capture in `captures/` that should pass the new shape check does pass, the mirror really is protected by ordering, `todayJalali` is correct through the 03:30 boundary, and the L3 checks sit on the paths that actually write. `flutter analyze` is clean and the full `flutter test` suite is green (1505 tests).

But the tree is not ready to commit:

1. a temporary, non-asserting probe test is still present and would enter CI (**B1**);
2. the headline H3/L2 fix stops one method short — the hunt's own menu read (`fetchMenu`) is still unguarded (**S1**);
3. `BookableMenus.partial` has no consumer, so the documented protection is inert and the doc comment overstates it (**S2**);
4. one L3 path still labels rows with a date the page does not carry (**S3**);
5. the M3 keyword list contains gateways with no evidence and one false-positive magnet (**S4**);
6. three declared Stage-5 items (M1, L6, L4-UI) were neither done nor visibly deferred (**S5**).

None of these is large. S1–S4 are a handful of lines plus tests; B1 is a file deletion. After they are addressed this should be a fast re-approval.

---

## 1. What was verified, and how

| Check | Result |
|---|---|
| `D:\flutter\bin\flutter.bat analyze` | `No issues found! (ran in 2.6s)` |
| `D:\flutter\bin\flutter.bat test` (whole suite) | **1505 tests, all passed** (incl. the new `read_resilience_test.dart`) |
| Targeted `dart test test/adapter/cullinan test/core/finance/top_up_test.dart test/platform/portal_sync_test.dart` | **243 tests, all passed** |
| Replayed all 35 `captures/*.html` through `CullinanForms.looksLikeReservationPage` | **21 true** (`05`, `08`, all four `23_week*`, `23_next_week`, `30`, `32`, `50`, `52`, `52b`, `60`, `62`, `63`, `70`) and **14 false** (login, cafeteria, basket buy/sale/after, receipt, both transaction pages, both ledgers, buy pages, invariant response) |
| Replayed `captures/*` grid dates through the `_gridDates` logic | every weekly page carries 21 dated rows (3 slots × 7 days); `31_cafeteria.html` carries none |
| Searched all `lib/` for a reader of `BookableMenus.partial` | **none** |
| Searched all `lib/` for production callers of `fetchOfferings` | **none** (interface + forwarders only) |
| Diff hygiene | `479 insertions / 61 deletions`, no formatting-only churn, no unrelated logic edits |

---

## 2. What is correct (confirmed, not assumed)

These are the parts I tried to break and could not:

1. **`looksLikeReservationPage` shape check** ([cullinan_forms.dart:97](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_forms.dart:97)) requires **all three** grids and rejects a body that also carries ASP error text (`looksLikeAspError` is checked first). A cached fragment with grid markup plus an error banner is refused — the test at [read_resilience_test.dart:131](D:/Bahonar-Nut/test/adapter/cullinan/read_resilience_test.dart:131) proves that ordering matters.
2. **Real fixtures pass the guard.** All 21 captured weekly/reservation pages satisfy the all-three-grids shape, so the guard does not reject the portal's real output; the 14 non-reservation captures (login, cafeteria, basket, receipt, transactions, ledgers, buy pages) are refused.
3. **Mirror protection is ordering, not luck.** `fetchReservations` throws *before* any store write ([cullinan_reservation.dart:508](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:508), [:535](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:535), [:547](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:547)), and [portal_sync.dart:126-137](D:/Bahonar-Nut/lib/platform/portal_sync.dart:126) records *why* that placement is load-bearing. The new test at [portal_sync_test.dart:348](D:/Bahonar-Nut/test/platform/portal_sync_test.dart:348) asserts the important half: after a failed grid read, the meal keeps `MealSource.weeklyReservation` and is **not** re-filed as a basket purchase.
4. **The silent next-week no-op is actually detected.** `_introducesLaterWeek` ([cullinan_reservation.dart:474](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:474)) requires a strictly later date, which handles a real page that begins mid-week and a sparse fixture. `fetchReservations` throws; `fetchBookableMenus` marks the read partial. Both behaviours have tests.
5. **`todayJalali` is correct and normalises first.** `.toUtc().add(ServerClock.portalUtcOffset)` then a `DateTime.utc(y,m,d)` civil date ([cullinan_forms.dart:136](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_forms.dart:136)) means an already-local or already-shifted instant answers the same day. Covered at 21:30 UTC (01:00 Tehran) and at midday, and the 03:30 boundary is the right one for Iran's post-2022 fixed offset.
6. **L3 checks are on the write paths.** `_postHallSwitch` ([basket_buy.dart:171](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:171)), `_postDateFilter` ([:219](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:219)), and `_readBuyPage` ([:310](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:310)) each compare `buyPageDate(...)` with `wanted` and either drop the cached form state or throw before the claim. `_readBuyPage` correctly throws instead of returning a default-date page, which is the dangerous case for a purchase.
7. **M3 selects by identity and falls back safely.** [top_up.dart:275](D:/Bahonar-Nut/lib/core/finance/top_up.dart:275) scans keywords in priority order, then banks, then falls back to `banks.first`. The real regression the audit described (portal reorders `[Sadad, Mellat]` to `[Mellat, Sadad]`) is fixed and has a test. `_workingBanks` in the UI became a one-line delegation ([home_shell.dart:1913](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1913)), so there is no second copy to drift.
8. **Deprecation is real but not coercive.** `@Deprecated` on the adapter method ([cullinan_reservation.dart:75](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:75)), `// ignore: deprecated_member_use_from_same_package` only at the delegation ([cullinan_client.dart:135](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_client.dart:135)), and **no** annotation on the `PortalClient` interface — so test fakes are not forced into suppressions. Correct call.
9. **`fetchOfferings` now navigates to the right week** instead of reading the default page ([cullinan_reservation.dart:78-90](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:78)), and it is now genuinely dead in production, which makes L2's "delete later" cheap.
10. **L7 and M2 are documented where a reader will look** ([cullinan_reservation.dart:94-104](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:94), [portal_client.dart:96-111](D:/Bahonar-Nut/lib/core/portal/portal_client.dart:96), [cullinan_client.dart:47-55](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_client.dart:47)). `days` is honestly described as advisory rather than silently ignored.
11. **`BookableMenus.partial` defaults to `false`** ([portal_models.dart:470](D:/Bahonar-Nut/lib/core/portal/portal_models.dart:470)), so every other constructor call stays source- and behaviour-compatible. The test fixtures that build `BookableMenus` without it still mean "complete".

---

## 3. Blocking finding

### B1 — A temporary probe test would be committed and would run in CI

`test/platform/_probe_ledger_test.dart` is untracked, matches the suite's `*_test.dart` pattern, and is not a test: it asserts nothing, prints two lines, and probes **ledger/status-change** behaviour that has nothing to do with Stage 5.

```dart
// TEMPORARY probe (Stage 5 review): does a ledger failure also emit a
// false "cancelled" status change?
...
print('first: count=${store.count} changes=[]');
print('ledger down: ok=${r.ok} count=${store.count} …');
```

It passes today, which is exactly why it would slip in. It also encodes a real unanswered question (does a failed ledger read emit a false `cancelled` change?) as a `print` instead of an assertion — either turn it into an assertion or delete it.

**Required:** remove `test/platform/_probe_ledger_test.dart` before commit. If the ledger-failure question matters, file it as its own item with a real `expect`.

---

## 4. Should-fix findings

### S1 — H3/L2 stops one method short: `fetchMenu` and `_readMenuFor` are unguarded

`fetchReservations` and `fetchBookableMenus` both refuse an ASP error page and a silent navigation. The shared single-date reader does neither:

[cullinan_reservation.dart:214-239](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:214)

```dart
Future<String> _readMenuFor(Session session, DateTime date) async {
  final current = await transport.get(...);
  CullinanForms.rejectIfBounced(current);
  if (_menuCovers(current.body, date)) return current.body;   // no shape check
  final next = await transport.post(...);                     // no error check
  CullinanForms.rejectIfBounced(next);
  return next.body;                                           // no later-week check
}
```

Both `fetchMenu` ([:88](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:88)) and `fetchOfferings` ([:78](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:78)) sit on it, and `fetchMenu` is the **hunt's** live menu read ([snipe_engine.dart:765](D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart:765), [:770](D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart:770)) and the market screen's read ([home_shell.dart:878](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:878)).

Two concrete consequences:

- **A `200` ASP error page parses as an empty menu.** `parseMenu` yields `[]`; `_applyMenu([])` ([home_shell.dart:3850](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:3850)) clears the dish/hall lists and sets `_marketError = null`, so the market renders empty — "nothing is served", with no error shown. That is the precise misreading H3 exists to remove — one layer above the mirror. The `PortalUnreachableException` branch at [home_shell.dart:889](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:889) is ready to say the right thing; it is simply never reached.
- **The silent no-op is back on this path.** If the next-week post answers with the current week, `_readMenuFor` returns that page anyway; `parseOfferings`/`parseMenu` then filter for `date` and find nothing. So the claim in the new doc comment — "this navigates to the week that carries `date`" — is true only when the portal cooperates, which is the case `_introducesLaterWeek` was written for.

This is pre-existing behaviour, but Stage 5's own acceptance criterion for H3 is "an ASP error page is not an empty account", and this path turns one into an empty menu. Guard it the same way (`looksLikeReservationPage` on both responses; `_introducesLaterWeek` before returning `next.body`, converting a no-op into `PortalUnreachableException`). A test mirroring [read_resilience_test.dart:119](D:/Bahonar-Nut/test/adapter/cullinan/read_resilience_test.dart:119) for `fetchMenu` would lock it.

### S2 — `BookableMenus.partial` is written and never read; the doc comment promises protection no code performs

The flag is set correctly in the adapter, including the `viewState.isEmpty` case ([cullinan_reservation.dart:144-184](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:144)). Nothing in `lib/` reads it:

- [home_shell.dart:1136-1148](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1136) takes `bookableResult.menus!.menus` and ignores `partial`;
- [home_shell.dart:1461-1473](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1461) does the same.

The model's doc comment ([portal_models.dart:479-491](D:/Bahonar-Nut/lib/core/portal/portal_models.dart:479)) says a caller "may report a missing next-week menu, **or overwrite a fuller cached answer**". The second clause is not reachable: `LocalMenuStore.upsert` merges and never deletes, and `diff` reports only `nextWeekPublished`/`changedMenus` — there is no removal path ([local_menu_store.dart:176-216](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:176)).

So today the flag is a **dead contract**: it neither protects nor informs, and the comment describes a hazard the store already prevents. Two acceptable resolutions; pick one and say so:

- **Wire it:** when `partial` is true, skip `_handleMenuDiff` and/or skip replacing the market's next-week view, and (optionally) show a quiet "next week could not be read" note. This is what "a caller cannot mistake an unread date" implies.
- **Or narrow the contract:** delete the "overwrite a fuller cached answer" sentence, state that the store merges so a partial read cannot destroy cache, and mark the flag as advisory for future callers.

As written, H3's menu-level half is a type without an effect, which will read as done to the next reviewer.

### S3 — One L3 path still parses a page for the wrong date

`_readBasketHtml` verifies the cached-POST path and the retry path, but its degraded GET path returns the body unconditionally:

[cullinan_basket_buy.dart:137-146](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:137)

```dart
// A page with no usable state cannot be posted; the GET body is still the
// best answer available, and its parser yields no listings rather than a
// false one. (A pristine buy page always carries a viewstate; this is the
// degraded path.)
if (!state.isUsable) {
  return first.body;
}
```

The comment's justification is false for the case that matters: a pristine buy page for its **default** date carries a viewstate (so `isUsable` is true) and is filtered normally; but a page whose viewstate is broken/absent can still render a **default-date grid**, and `fetchBasket` then calls `_parseBasket(html, wanted)` ([:68](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:68)) and labels every row with the requested date. The "yields no listings" claim only holds if `buyPageDate` is null; it is not checked.

Fix: return `null` (which `fetchBasket` already handles by reporting an empty page) unless `CullinanParser.buyPageDate(first.body) == wanted`. That keeps the "don't act on a page you could not read" intent and removes the last labelling hole.

### S4 — M3's keyword list mixes one proven gateway with four unproven ones, and one of them is a false-positive magnet

Only Sadad is evidence-backed (`docs/portal-reference.md` §۹.۱: Sadad works; the second — Mellat — fails with `Value cannot be null`). The list at [top_up.dart:294-306](D:/Bahonar-Nut/lib/core/finance/top_up.dart:294) adds Shaparak, Behpardakht, Parsian and Saman with no evidence, and the new test enshrines one of them:

```dart
test('a recognised gateway is chosen before an unrecognised first one', () {
  const parsian = TopUpBank(id: 'p', name: 'درگاه پارسیان', logoPath: null);
  expect(workingTopUpBanks([broken, parsian]).single.name, contains('پارسیان'));
});
```

Two problems:

1. **A regression the old code did not have.** `[working-unknown, broken-but-recognised]` now picks the broken one. With the real page's own assets this is concrete: the working gateway's logo is `NewMelli.jpg` (the `NewMelli` asset belongs to Mellat, so the **logo cannot identify Sadad**), which means Sadad is recognised **only** by the label "درگاه سداد". If that label ever empties while a second logo path contains `shaparak`, the app now prefers the unconfigured gateway that `banks.first` used to avoid.
2. **`شاپرک` / `shaparak` is the national network, not a gateway.** Any gateway's asset path or blurb may contain it, so it is the likeliest false positive in the list, and it sits at higher priority than Parsian/Saman.

Also note the Javadoc still says "when no listed gateway is recognised the behaviour falls back to the first bank", which is true, but the doc then implies the recognised set is trustworthy. Recommended: keep `سداد/sadad` (evidence), and for the rest either drop them or gate them behind the same "is this the only gateway" heuristic; add a test for `[working-with-empty-title, recognised-but-broken]` so the regression case is pinned. If a broader list is a deliberate product decision, it needs a source, because the audit's rule was "match by identity", not "match any common bank".

### S5 — M1, L6 and the L4 UI message are neither implemented nor visibly deferred

`docs/fix-plan.md` §۶.۱ lists ten items. The diff covers H3, L1, L3, L7, M2, M3 and L2. The remaining three:

- **M1 (sale/remove cycle).** Gated by §۷.۲ on explicit live permission, so deferral is legitimate — but nothing in the tree records that it is deferred. Add one line to `docs/fix-plan.md` §۸ (or a `TODO(M1)` at the sale entry point) so the next stage does not treat it as done.
- **L6 (`toSlotPreference` raw-rule decision).** No code and no note. `toSlotPreference` ([hunt_config.dart:810](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:810)) is still built from `hallPriority` alone; the audit's point was that a **raw rule** (no `HuntConfig`) reaches `preflight` with no preferences and the engine then has nothing to rank by. If the decision is "leave as is", write down why.
- **L4 (dish/hall in the basket success message).** The plan says the *UI* message. The diff enriches the **ledger** strings in [snipe_claimer.dart:130-250](D:/Bahonar-Nut/lib/core/hunt/snipe_claimer.dart:130) — good, and user-visible in the hunt log — but no UI success message changed ([home_shell.dart](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart) only gained/lost `_workingBanks`; the weekly success message at [:2835](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2835) is still "N meals were reserved successfully", with no dish or hall). If the ledger **is** the intended surface, say so in the plan; otherwise the item is open.

Not blocking, but a stage that silently shrinks its own declared scope is exactly what the next review cannot detect.

---

## 5. Nitpicks

### N1 — `_hasTable` accepts only double-quoted ids

[cullinan_forms.dart:120](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_forms.dart:120) matches `id="[^"]*<id>"`. ASP.NET always double-quotes, and all 21 reservation captures pass, so this is not a live bug — but if the guard ever fails closed on a proxy-rewritten page, the error will look like "the portal changed" rather than "our regex is narrow". `id=['"]?...` costs nothing.

### N2 — End-of-semester / unentered week: fail-closed forever, with no user-visible reason

If the next week has no dated rows, `_gridDates(next)` is empty, `_introducesLaterWeek` returns `false`, and `fetchReservations` throws — so the mirror never updates until the portal publishes the week, and the sync reports a generic failure. This is the safe direction, and the code comment says grids always carry dated rows. It is still worth a sentence in `_introducesLaterWeek` (or the portal reference) that "an empty next week is indistinguishable from an unread one by design", because the failure is permanent-looking to a student at term end.

### N3 — The all-three-grids invariant is an assumption about account shape

`looksLikeReservationPage` fails closed unless breakfast, lunch **and** dinner grids are present. That is true for every reservation capture (one account, 21 dated rows each) and matches the code comment. If any account (catering, dormitory, a sister hall per §۷.۵) renders fewer grids, every reservation read for it throws and its mirror freezes. Consider a fixture test for a one-grid page, or state the invariant where the guard lives so the next person checks before widening it.

### N4 — The existing Gemini review describes code that does not exist

`docs/reviews/stage5-council-review-gemini.md` describes a different diff. It claims the guard detects `Compilation Error`, `System.Web.HttpUnhandledException` and `Stack Trace:` (it does not); that it looks for `dgReservation` / `lnkNextWeek` (it looks for the three slot grids, and the navigation is `imgbtnNextWeek`); that `fetchBookableMenus` **throws** on a re-rendered week (it sets `partial`); that the basket path raises `PortalUnreachableException('Basket date mismatch: expected …')` (no such message exists); and that `workingTopUpBanks` matches `melli`/`ملی` and "returns all available options" on no match (it returns exactly one bank, and neither keyword is in the list). Its APPROVE is not evidence — do not cite it in the stage report.

### N5 — Positive, worth keeping

The 00:00–03:30 boundary is tested at 21:30 UTC in **both** directions (equals the Tehran day, does not equal the UTC day). That is the right shape for a timezone test: it proves the shift, not just that one call returns something.

---

## 6. Findings matrix

| ID | Severity | Area | Where | One-line |
|---|---|---|---|---|
| B1 | **B** (must fix before commit) | test hygiene | `test/platform/_probe_ledger_test.dart` | Temporary print-only probe matches `*_test.dart` and would run in CI |
| S1 | S | H3/L2 | `cullinan_reservation.dart:88,214` | `fetchMenu`/`_readMenuFor` has neither the error-page guard nor the later-week check; an error page becomes an empty market |
| S2 | S | H3 | `portal_models.dart:479`, `home_shell.dart:1136,1461` | `partial` is never read; doc claims a cache-overwrite hazard the store already prevents |
| S3 | S | L3 | `cullinan_basket_buy.dart:141` | Degraded GET path returns a page without checking `buyPageDate == wanted`; rows get mislabelled |
| S4 | S | M3 | `top_up.dart:294` | Four unproven keywords; `شاپرک` can falsely match; `[working-unknown, broken-recognised]` is a new regression |
| S5 | S | scope | `docs/fix-plan.md` §۶.۱ | M1, L6 and the L4 UI message are neither done nor recorded as deferred |
| N1 | N | H3 | `cullinan_forms.dart:120` | `_hasTable` requires double-quoted `id` |
| N2 | N | H3 | `cullinan_reservation.dart:474` | Empty next week → permanent, unexplained sync failure at term end |
| N3 | N | H3 | `cullinan_forms.dart:97` | All-three-grids invariant is an untested assumption about account shape |
| N4 | N | process | `docs/reviews/stage5-council-review-gemini.md` | Prior review approves code that is not in the diff; do not rely on it |

---

## 7. Required before commit

1. Delete `test/platform/_probe_ledger_test.dart` (**B1**).
2. Apply `looksLikeReservationPage` + `_introducesLaterWeek` in `_readMenuFor`, with a `fetchMenu` test (**S1**).
3. Either consume `BookableMenus.partial` in the two `home_shell` call sites or correct its contract (**S2**).
4. Return `null` from the degraded branch of `_readBasketHtml` unless the page is for `wanted` (**S3**).
5. Narrow `_stableGatewayKeywords` to evidence, or document the source and add the `[unknown-working, recognised-broken]` test (**S4**).
6. Add deferral notes for M1, L6 and L4-UI (or implement L4-UI) (**S5**).

Then: `flutter analyze` + full `flutter test` again (the suite is green today at 1505), and the stage can be approved.

---

## 8. Final verdict

**REQUEST CHANGES.**

Stage 5's core idea — treat an unread portal as *unknown*, never as *empty*, and write nothing until both weeks were read — is implemented correctly where it was applied. The two substantial gaps are that the same idea was not carried to the hunt's own menu read (**S1**) and that its menu-level signal is never consumed (**S2**); the rest are a stale probe file and small, localised holes. None requires redesign. All six items above are small and independently testable, and this review is ready to be re-run immediately after they land.
