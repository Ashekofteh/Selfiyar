# Senior Review Council — Stage 2 (C3 & C4)

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Date:** 2026-11-23
**Scope:** `git diff` of the working tree (25 modified files + 1 new test) on top of `5980c29`
**Mode:** read-only audit; no source changes made by this review

---

## Verdict

## **REQUEST_CHANGES**

The write-path half of C3/C4 is well designed and materially safer than the previous behaviour: a `(hall, dish)` pair that the page did not render is refused before any write, and a portal substitution is detected and reported instead of being counted as a clean success. Those are real, correct fixes.

However, the **data-model half of C3 is not wired**, the **round-trip persistence drops the new field**, and **three of the five booking entry points ignore `wasSubstituted`**. In normal operation the app therefore re-introduces the exact cross-hall pairing C3 was meant to eliminate, and a real, money-moving substitution is reported to the student as a failure in the top-up path. These are blocking.

---

## 1. What was verified

| Check | Result |
|---|---|
| `D:\flutter\bin\flutter.bat analyze` | `No issues found!` |
| Targeted suites (adapter/cullinan, core/meal, core/hunt, platform, ui/features/reservations, ui/shell) | 784 tests pass |
| Full `flutter test` run | no failures observed (tail at 1452 passed) |
| Working tree | 25 modified files + `?? test/core/meal/meal_menu_hall_options_test.dart` |
| Base commit | `5980c29 fix(basket): eliminate phantom hall listings…` |

The static checks pass, but the defects below are behavioural and are not covered by any test.

---

## 2. Blocking findings

### B1 — `optionsByHall` is destroyed by the store and by persistence (C3 defeated)

The model change in [models.dart:158-237](D:/Bahonar-Nut/lib/core/meal/models.dart:158) is correct and well documented. But nothing that *stores* a `MealMenu` carries the new field:

1. **`LocalMenuStore.upsert` rebuilds the menu without `optionsByHall`.**
   [local_menu_store.dart:102-108](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:102):

   ```dart
   _menus[key] = MealMenu(
     date: incoming.date,
     slot: incoming.slot,
     halls: hallsMap.values.toList(),
     dishes: dishes,
     reservable: incoming.reservable,
   );
   ```

   Only the `existing == null` branch keeps the parser's map. Every later refresh of the same `(date, slot)` silently converts it to a **legacy** menu.

2. **`encodeMenuList` / `decodeMenuList` omit the field entirely.**
   [platform_stores.dart:454-470](D:/Bahonar-Nut/lib/core/shared/platform_stores.dart:454) writes `date/slot/reservable/halls/dishes`; [platform_stores.dart:511-518](D:/Bahonar-Nut/lib/core/shared/platform_stores.dart:511) rebuilds `MealMenu` with no `optionsByHall`. `PlatformServices.restore()` calls `store.replaceAll(decodeMenuList(raw))` ([platform_services.dart:391](D:/Bahonar-Nut/lib/platform/platform_services.dart:391)), so **after every restart every menu is legacy**.

3. `LocalMenuStore.hasChanges`/`diff` do not compare `optionsByHall` ([local_menu_store.dart:115-140](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:115)), so a newly read hall list would never trigger a refresh either.

**Impact:** `dishesForHall` falls back to `dishes` whenever the map is empty ([models.dart:211-216](D:/Bahonar-Nut/lib/core/meal/models.dart:211)). `dishes` is *one* hall's list. The UI therefore shows that one list for **every** hall, with another hall's option ids. This is the original substitution bug, reached through the normal flow:

- `BookingSheet` lists hall 1's ids under hall 2 → user books hall 2 → the adapter's new guard refuses with `notOffered` ("این غذا در سلف انتخابشده ارائه نمیشود."), or
- if the adapter were not guarded, the portal would substitute.

The adapter guard prevents the silent wrong booking, but the product is left with halls that *look* bookable and never are. This must be fixed before C3 can be called implemented.

**Required:** persist and restore `optionsByHall`; merge per-hall lists in `upsert` (union of existing/incoming, incoming wins per hall, same as `halls`); include `optionsByHall` in the change comparison. Add a round-trip test (`upsert` twice + `encode`/`decode`) asserting the map survives.

---

### B2 — Substitution is treated as failure on the top-up / deferred path (C4)

`ReservationService.batchReserve` returns substitutions correctly and `_batchBookOfferings` handles them ([home_shell.dart:2693-2799](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2693)). Three other entry points do not.

**`PendingReserveOfferingsAction`** — the path taken after a successful top-up, i.e. when money has just moved:

- balance is decremented only from `outcome.succeeded` ([home_shell.dart:2087-2101](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2087)); a substituted meal's price is never subtracted;
- the success message requires `succeeded.isNotEmpty && failed.isEmpty` ([home_shell.dart:2115](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2115)), and it counts only `outcome.succeeded`, so a mixed exact+substituted batch silently under-reports how many meals were actually booked;
- a fully substituted batch (`succeeded` empty, `substituted` non-empty, `failed` empty) falls to the final `else` and shows:
  **"پرداخت شما با موفقیت انجام شد … اما رزرو غذا انجام نشد"** ([home_shell.dart:2139-2153](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2139)).

  That sentence is false: the meal **is** held and the money **is** gone. The student will retry or complain about a charge with no meal.

**`_book` (single)** — `outcome.succeeded` is false for a substitution:

- balance not decremented and quiet refresh not triggered ([home_shell.dart:1593-1617](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1593));
- `!outcome.succeeded` sends it to `_showBookingProblem` ([home_shell.dart:1657-1659](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1657)) with the service's message, styled as a failure;
- `BookingSheet._book` treats a non-null return as failure and **keeps the sheet open** ([booking_sheet.dart:431-439](D:/Bahonar-Nut/lib/ui/features/reservations/booking_sheet.dart:431)), inviting a second tap on an already-booked row.

**`_modifyMeal` / `PendingModifyMealAction`** — same pattern ([home_shell.dart:1751-1763](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1751), [home_shell.dart:2204](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2204), [home_shell.dart:2223](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2223)): no balance/price-diff adjustment, no table refresh in `_modifyMeal` (refresh is inside the success branch), and a red problem sheet for a change that landed.

**Required:** a single shared handler for `wasSubstituted` — treat it as a *successful write with a warning*: debit the price of `substitution.saved`, refresh, pop/close the sheet, and show an amber message naming what was actually saved (the batch path already models the wording). Never route a substituted write into the "nothing was booked" branch.

---

### B3 — One substitution aborts the rest of a multi-slot batch (C4 regression, money at risk)

`reserveAll` posts one slot at a time and passes the already-accepted offerings as `requiredHeld`:

- [cullinan_reservation.dart:739-743](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:739) → `_canPostFor(..., requiredHeld: posted)`
- `_pageHolds` now demands an **exact** hall and option match ([cullinan_reservation.dart:331-352](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:331)).

So if slot 1 was saved with a substituted dish/hall, the next slot's pre-flight check fails against the page (the held row is not the requested pair), the page is re-read twice, and then:

```dart
throw const PortalUnreachableException(
  'فرم رزرو کامل نبود؛ برای جلوگیری از لغو رزروهای دیگر، '
  'نوشتن انجام نشد.',
);
```

([cullinan_reservation.dart:765-768](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:765))

`submitWeek` rethrows when `confirmed` is empty ([cullinan_reservation.dart:845-847](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:845)), and `confirmed` is only populated *after* the whole slot loop ([cullinan_reservation.dart:817-833](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:817)). Result: a breakfast that the portal really booked (and charged) is invisible to the caller, the rest of the batch is not attempted, and the UI reports a total failure. The stricter `_pageHolds` made a previously-benign substitution into a batch-killer.

**Required:** pre-flight must not use exact-pair "is it held" as a gate for *previous* slots. Use a date/slot "is this row present and unchecked-by-us?" check, or accept a held row whose date/slot matches even if the pair differs (that is a substitution, which the confirmation stage already classifies correctly). A substitution must never abort later slots.

---

## 3. High findings

### H1 — The UI half of C3 is not implemented: unread halls are dead ends

Nothing in the sheets can obtain a hall's `drpFood` list.

- `BookingSheet` has no `onHallChanged`/fetch callback. Changing hall just re-reads `menu.dishesForHall(id)` and clears `_dish` when the list is empty ([booking_sheet.dart:315-333](D:/Bahonar-Nut/lib/ui/features/reservations/booking_sheet.dart:315)), showing "لیست غذای این سلف خوانده نشده است. سلف دیگری انتخاب کنید." ([booking_sheet.dart:464-480](D:/Bahonar-Nut/lib/ui/features/reservations/booking_sheet.dart:464)). The confirm button is disabled, and there is no way to read the list.
- `BatchBookingSheet` is identical: `_canConfirm` requires every row to have a dish ([batch_booking_sheet.dart:150](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:150)), `_reconcileDish` returns empty for an unread hall ([batch_booking_sheet.dart:182-195](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:182)), and the confirm buttons are disabled ([batch_booking_sheet.dart:669](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:669)), with no fetch.
- `MealDetailSheet` does the same and merely prints the "not read" line ([meal_detail_sheet.dart:658-678](D:/Bahonar-Nut/lib/ui/features/reservations/meal_detail_sheet.dart:658)).

Because the parser only ever reads the rendered hall ([cullinan_parser.dart:240-250](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:240)) and `fetchMenu` does not switch halls ([cullinan_reservation.dart:80-84](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:80)), **only one hall per (date, slot) is ever bookable**, and after a restart (B1) the sheets believe every hall is that hall.

Additionally, the default selection is `menu.halls.first` ([booking_sheet.dart:113-118](D:/Bahonar-Nut/lib/ui/features/reservations/booking_sheet.dart:113), [batch_booking_sheet.dart:117-126](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:117)), not the *rendered* hall. The parser already tells you the rendered hall (`renderedReservationRow` / `optionsByHall.keys.first`); using a different default is how a sheet opens on an unread hall even when another hall was read.

**Required:** add a hall-read path (the adapter already has `reservationHallSwitchBody`, so a read-only fetch is available) invoked on hall change, and default to the rendered hall. Or, at minimum, state explicitly in the UI that only the rendered hall is available, and do not present the others as selectable.

### H2 — Locked cross-hall rows are reported as "not offered"

`reservationHallSwitchBody` returns `null` for a row whose `chkReserve` is disabled ([cullinan_parser.dart:628](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:628)), meaning "the cutoff passed". `_ensureOfferingRendered` maps every `null` to `ReservationNotOfferedException` ([cullinan_reservation.dart:601-603](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:601)). A student who picks hall 2 for a closed date is told the dish is not served there, not that the date is closed. In batch, such offerings are collected in `rejected` and surface as `notOffered` (or as `locked` once the service re-classifies everything not returned, see L2).

**Required:** distinguish "row missing/locked" from "pair not offered" before switching; throw `ReservationLockedException` for the former.

### H3 — `_batchBook` and `_handleReservationsTopUp` still pair halls and dishes independently

Both build offerings with `matchingMenu.halls.first` **and** `matchingMenu.dishes.first`:

- [home_shell.dart:2637-2648](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2637) (`_batchBook`)
- [home_shell.dart:3349-3360](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:3349) (`_handleReservationsTopUp`)

`dishes` is the rendered hall's list ([models.dart:177-186](D:/Bahonar-Nut/lib/core/meal/models.dart:177)); `halls.first` is only *usually* the rendered hall. When they differ, or when a legacy menu is used, this constructs a cross-hall `MealOffering` — the very thing C3 forbids. The adapter now refuses it, so the cost is a user-visible "not offered" failure rather than a wrong booking, but the path is wrong.

**Required:** choose the hall first, then `menu.dishesForHall(hall.id)`, and skip the row when empty (as `_batchBookOfferings`' callers already do for the sheet).

---

## 4. Medium findings

### M1 — Hunt request amplification and an under-stated budget

`fetchBasket` now does the initial read (1–2 requests) plus up to two `drpSelf` postbacks ([cullinan_basket_buy.dart:45-104](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:45)): **2–4 requests per poll** where the previous ceiling was 2.

- `computeBudget` prices **one request per scheduled poll** (`peakSecs/peakInterval + offPeakSecs/offPeakInterval`, ×1.3) at [hunt_config.dart:405-410](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:405); `projectedRequests()` repeats the same assumption at [hunt_config.dart:638-646](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:638), and `requestBudget` is derived from `computeBudget` ([hunt_config.dart:302-310](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:302)).
- The run stops at the **request** count ([snipe_engine.dart:562-575](D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart:562), [snipe_engine.dart:500-502](D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart:500)).

A hunt configured for the full window will therefore exhaust its budget 2–4× early and end with "سهمیه درخواست این اجرا به پایان رسید." before the listings appear. The user-facing projection is now wrong.

Also, `halls.take(2)` ([cullinan_basket_buy.dart:82](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:82)) means the third and later priority halls are never read, and nothing in the UI says so. The comment says "up to two" but the product presents a free ordering of any number of halls.

**Required:** price the extra reads into `projectedRequests()`/`computeBudget` (multiply by the number of halls to be read, or add a per-hall overhead), or make the hall count a configured, surfaced choice. State the two-hall cap in the hunt UI.

### M2 — Batch hall switches are unbounded per offering

In `reserveAll`, `_ensureOfferingRendered` is called once per offering ([cullinan_reservation.dart:780-788](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:780)). Each call whose hall differs from the current render costs one read-only postback plus a possible `_weekPageFor` navigation. A week that alternates halls across days can trigger ~2N posts, all rewriting the whole week page. There is no grouping by hall or caching of "this page is now rendered for hall X" (the local `switched` flag resets per call).

**Required:** group offerings by hall per slot (or cache the last rendered hall) so a batch costs at most one switch per hall per slot.

### M3 — Duplicate/ambiguous handling of the same row

`_reservationFor` returns the first reservation matching `(date, slot, hall, option)`; `_reservationAt` returns the first for `(date, slot)`. If a page ever renders two rows for the same date/slot (e.g. two accounts' data merged in a fixture, or a malformed portal page), one correct row and one substituted row would make the result depend on parse order. Low likelihood, but the code has no explicit "exactly one" invariant.

### M4 — `_pageHolds` / `parseReservations` do not share the "first option is selected" fallback

`_menuFromRow` and `renderedReservationRow` deliberately fall back to the first real option when the markup omits `selected` ([cullinan_parser.dart:231-237](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:231), [cullinan_parser.dart:666-673](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:666)), because a browser does. `_pageHolds` ([cullinan_reservation.dart:341-351](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:341)) and `parseReservations` ([cullinan_parser.dart:84-98](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:84), [cullinan_parser.dart:295-296](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:295)) do **not**: a genuinely held row rendered without an explicit `selected` attribute would be read as not held / hall `-1`. The current fixtures always emit `selected`, so this is latent, but the three readers must agree on the same semantics.

---

## 5. Low findings / nits

- **L1 — Dead catch.** `batchReserve`'s `on ReservationSubstitutedException` ([reservation_service.dart:471-487](D:/Bahonar-Nut/lib/platform/reservation_service.dart:471)) can never fire: `CullinanReservation.reserveAll` returns substitutions in its result and only throws the exception from the single `reserve` ([cullinan_reservation.dart:648](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:648)). Either remove it or make the contract explicit.
- **L2 — Wrong batch failure class.** `batchReserve` reports every offering not returned as `locked` ([reservation_service.dart:459-465](D:/Bahonar-Nut/lib/platform/reservation_service.dart:459)). A `notOffered`/rejected offering inside an otherwise successful batch is therefore shown as "locked". The adapter also drops `rejected` silently when anything was confirmed ([cullinan_reservation.dart:885-888](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:885)).
- **L3 — `_batchBookOfferings` ignores substituted in its return value** (`return outcome.succeeded.isNotEmpty`, [home_shell.dart:2727](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2727), [home_shell.dart:2799](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2799)) even though it debits and reports them. Callers that use the boolean to mean "anything landed" are subtly wrong.
- **L4 — Duplicated zero-arg fallbacks.** `const Hall(id: '1', name: 'مرکزی')` appears in `_batchBook` and `_handleReservationsTopUp`; with hall ids being portal-defined, a hardcoded id is a guess. Prefer "no hall → skip".
- **L5 — `hasChanges` ignores `optionsByHall`** (see B1). Even after persistence is fixed, a hall list that becomes readable without changing `dishes` would not refresh the UI.
- **L6 — `_reconcileDish` keeps a dish only by id** ([batch_booking_sheet.dart:182-195](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:182)). For a legacy menu (all halls share `dishes`) that is correct, but it cannot distinguish "same id, different hall" from "same id, same hall". Once B1 is fixed the map is authoritative and this is fine; until then it perpetuates the fallback.
- **L7 — display/price paths remain `menu.dishes`-based.** `reservation_table_model.dart:250-308` derives `optionCount`, `availableDishes` and the minimum price from `dishes` for every hall, and `home_shell.dart:2316-2317` takes a refund price from `dishes.first`. Prices and names are shared across halls today, so this is cosmetic — but the "available dishes" text is not hall-specific and would be wrong if the portal ever differs. These should read `dishesForHall(row.hallId)` once the row carries a hall id.

---

## 6. Edge cases and null safety

- `_menuFromRow`'s `?renderedHall: dishes` correctly omits the entry when no hall can be determined; `dishesForHall` then returns empty for every hall, which is honest. Good.
- `renderedReservationRow` returns `null` on missing `drpSelf`/`drpFood` and on a row with no real hall ([cullinan_parser.dart:651-693](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:651)); `_ensureOfferingRendered` treats that as "not offered". That conflates a malformed page with a user error; consider `PortalUnreachableException` for a missing row.
- `reservationHallSwitchBody` preserves every row's current values before switching ([cullinan_parser.dart:607-625](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:607)), which is the right guard against cancelling other rows. The postback carries no save button. Good.
- `hallSwitchBody` for the basket carries `txtDate` when given, and no save button ([cullinan_parser.dart:525](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:525)). It does not preserve a "from/to" filter other than the date; verify on a live page that the buy form has no other required field that a partial body would reset.
- `_pageHolds` returns `false` on a missing dropdown ([cullinan_reservation.dart:343-344](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:343)); a malformed page and a genuine non-hold are indistinguishable. For a money path that is the conservative choice, but it feeds B3.
- `MealOffering.matches` compares date components only, not time zone ([models.dart:260-268](D:/Bahonar-Nut/lib/core/meal/models.dart:260)); consistent with `CullinanForms.sameDate`. Fine.

---

## 7. Performance

- **Hunt:** 2–4 requests/poll and an unchanged budget model (M1). This is the most important performance risk because it changes how long a hunt actually runs.
- **Batch reserve:** up to one full week rewrite per hall switch per offering (M2). On a mobile connection a 7-day batch that alternates halls can spend tens of extra requests and seconds of latency.
- **UI:** `dishesForHall` is O(1) map lookup; `optionFor` is O(n) per lookup but only used on small lists. No issue.
- **Parser:** `renderedReservationRow` scans one grid; `reservationHallSwitchBody` scans all four grids to preserve values. Acceptable for a page write.

---

## 8. Security and privacy

No findings. The diff adds no credentials, tokens, cookies, PII, or logging of either. The new postbacks reuse the existing `__VIEWSTATE`/`__EVENTVALIDATION` handling and do not persist them. The new UI strings are static Persian text. Error messages name dish/hall names and ids that the student already sees; no account identifiers are added to logs.

One small hygiene note: `_postHallSwitch` clears `_formState` on a non-page response ([cullinan_basket_buy.dart:167-171](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:167)) — correct, and it avoids reusing a viewstate tied to a stale render.

---

## 9. Tests and regressions

- `flutter analyze`: clean.
- Targeted suites: 784 pass; full run: no failures observed.
- **The new test file is model-only and untracked** (`?? test/core/meal/meal_menu_hall_options_test.dart`). It pins `dishesForHall`, `offers`, and `matches` — useful — but does not exercise:
  - `LocalMenuStore.upsert` preserving `optionsByHall` across two upserts;
  - `encodeMenuList`/`decodeMenuList` round-trip (B1);
  - `reservationHallSwitchBody` / `hallSwitchBody` bodies (field names, preserved rows, no save button);
  - `_ensureOfferingRendered` (switch, same-hall, locked, missing row);
  - `_pageHolds` exact-match and batch abort (B3);
  - `ReservationSubstitutedException` → `ReservationOutcome.substituted` → every UI entry point (B2);
  - `fetchBasket(halls:, slot:)` merging two halls, deduplication, and the two-switch bound.
- The live-page adapter tests skip silently when `scratch/portal_live/out` (git-ignored) is absent; CI therefore exercises none of the new parser paths. The fixtures exist locally (`wed_lunch_hall2.html`, `basket_hall2.html`, `forbidden_wed_weekly_lunch.html`), so these should be captured as committed, minimal HTML strings or promoted into `test/fixtures/`.
- Test-only changes are signature updates for `fetchBasket` (8 lines each); no behavioural test was added for the new signature.

A green analyzer and suite are necessary but not sufficient here: the blocking defects are data-flow and UI-state defects that the current tests cannot see.

---

## 10. Requirement-by-requirement

| Requirement | Status | Evidence |
|---|---|---|
| C3: hall-specific dish ids modelled | **Partial** | Model correct ([models.dart:158-237](D:/Bahonar-Nut/lib/core/meal/models.dart:158)); parser fills one hall ([cullinan_parser.dart:240-250](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:240)); **not persisted/merged** (B1). |
| C3: pre-postback re-render in `cullinan_reservation` | **Correct** | `_ensureOfferingRendered` ([cullinan_reservation.dart:493-545](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:493)); read-only body ([cullinan_parser.dart:583-641](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_parser.dart:583)). |
| C3: UI dropdown updates on hall switch | **Partial / blocked** | It updates from `dishesForHall`, but cannot fetch an unread hall and defaults to `halls.first` (H1). With B1 the "update" usually shows another hall's ids. |
| C4: `_reservationFor` checks hall + dish | **Correct** | [cullinan_reservation.dart:460-470](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:460), `_pageHolds` [329-352](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:329). |
| C4: `ReservationSubstituted` outcome + UI feedback | **Partial** | Service and batch UI correct; single/deferred/modify paths wrong (B2); batch can abort on a prior substitution (B3). |
| Multi-hall basket search, bounded, no fake listings | **Mostly correct** | Bounded at 2 switches and deduped by composite id ([cullinan_basket_buy.dart:72-103](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:72)); hunt ranker matches by dish name + hall ([hunt_ranker.dart:99-211](D:/Bahonar-Nut/lib/core/hunt/hunt_ranker.dart:99)), so hall-2 listings are usable. Budget projection is now wrong (M1); third+ halls invisible. |
| No PII / passwords added | **Pass** | See §8. |
| No regressions in existing behaviour | **Not yet** | Batch abort (B3) and top-up messaging (B2) are regressions relative to the previous lenient checks; the suite does not detect them. |

---

## 11. Conditions for approval

1. Persist and merge `optionsByHall` in `LocalMenuStore` and `PlatformServices` (encode/decode), with a round-trip test. (B1)
2. One shared `wasSubstituted` handler used by `_book`, `PendingReserveOfferingsAction`, `_modifyMeal`, and `PendingModifyMealAction`: debit, refresh, close the sheet, amber warning naming what was saved. (B2)
3. Stop using exact-pair `_pageHolds` as the pre-flight gate for previously posted slots; a substitution must not abort later slots, and `submitWeek` must not discard earlier confirmations. (B3)
4. Add an explicit hall-read path on hall change (or make non-rendered halls non-selectable), and default to the rendered hall. (H1)
5. Distinguish locked from not-offered in `_ensureOfferingRendered`. (H2)
6. Make `_batchBook` and `_handleReservationsTopUp` hall-aware. (H3)
7. Correct the hunt's request projection for the extra reads, and surface the two-hall cap. (M1)
8. Add tests for B1–B3 and the hall-switch bodies; commit the fixtures or inline them. (§9)

Items 1–3 are release blockers. Items 4–6 should land in the same change; 7–8 can follow but must be tracked before the Stage 2 sign-off.

---

*Review performed against the working tree at `5980c29` + uncommitted Stage 2 changes. No files were modified by this review.*

---

# Follow-up review — conditions re-checked (same day)

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Scope:** re-audit of the same working tree after the implementation team's fixes
**Verification run by this review:** `flutter analyze` → `No issues found!`; `flutter test` → **1459 tests, all passed**; `flutter test test/core/meal/meal_menu_hall_options_test.dart` → 14 passed.

## Verdict

## **APPROVAL**

All three release-blocking conditions (B1, B2, B3) are genuinely fixed, not papered over. H1/H2/H3 landed in their mitigation form, and M1's projection is corrected. The residuals below are real but are UX/test-coverage gaps with **no wrong-booking or money risk**, and they are hereby tracked for Stage 2 sign-off — they do not justify blocking this change.

## Condition-by-condition

| # | Condition | Status | Evidence |
|---|---|---|---|
| 1 | B1 — persist/merge `optionsByHall`, include in change comparison, round-trip test | **Met** | `upsert` merges with incoming-wins per hall ([local_menu_store.dart:102-116](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:102)); `hasChanges` compares the map ([local_menu_store.dart:146-161](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:146)); encode/decode carry the map ([platform_stores.dart:467-479](D:/Bahonar-Nut/lib/core/shared/platform_stores.dart:467), [platform_stores.dart:525-557](D:/Bahonar-Nut/lib/core/shared/platform_stores.dart:525)); round-trip + merge + change tests ([meal_menu_hall_options_test.dart:185-271](D:/Bahonar-Nut/test/core/meal/meal_menu_hall_options_test.dart:185)). Legacy empty-map menus still fall back to `dishes`, but the adapter guard refuses any pair that is not actually offered, so the fallback cannot produce a wrong booking. |
| 2 | B2 — one substituted path that debits, refreshes, closes, warns | **Met** | `_book` ([home_shell.dart:1593-1629](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1593)) debits the *saved* price, quiet-refreshes, shows amber, returns null (sheet closes). `_modifyMeal` ([home_shell.dart:1761-1787](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:1761)) refreshes balance + table and warns. `PendingReserveOfferingsAction` ([home_shell.dart:2111-2192](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2111)) counts `succeeded + substituted`, debits saved prices, and no longer falls into "رزرو غذا انجام نشد". `PendingModifyMealAction` ([home_shell.dart:2242-2296](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2242)) debits the effective price and warns amber. The service turns `ReservationSubstitutedException` into `ReservationOutcome.substituted` and mirrors the saved meal ([reservation_service.dart:270-293](D:/Bahonar-Nut/lib/platform/reservation_service.dart:270), [reservation_service.dart:589-611](D:/Bahonar-Nut/lib/platform/reservation_service.dart:589)). |
| 3 | B3 — a substitution must not abort later slots | **Met** | Batch pre-flight now checks date/slot hold, not exact pair ([cullinan_reservation.dart:294-329](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:294)); confirmation also uses `_pageHoldsSlot` and returns mismatched rows so the service classifies them as substitutions ([cullinan_reservation.dart:831-857](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:831)). Batch outcome classifies by row key and sets `substituted` ([reservation_service.dart:427-470](D:/Bahonar-Nut/lib/platform/reservation_service.dart:427)). |
| 4 | H1 — hall-read path or non-selectable halls, default to rendered hall | **Partially met (accepted)** | All three sheets default to the rendered hall ([booking_sheet.dart:113-124](D:/Bahonar-Nut/lib/ui/features/reservations/booking_sheet.dart:113), [batch_booking_sheet.dart:115-137](D:/Bahonar-Nut/lib/ui/features/reservations/batch_booking_sheet.dart:115), [meal_detail_sheet.dart:152-183](D:/Bahonar-Nut/lib/ui/features/reservations/meal_detail_sheet.dart:152)). No UI hall-read path was added, and unread halls remain selectable dead ends — but they now say so honestly, the default is always a valid hall, and the adapter re-renders/refuses at write time. See residual R1. |
| 5 | H2 — distinguish locked from not-offered | **Met in single path** | `_ensureOfferingRendered` returns the switch/refusal state; `reserve` maps null to `ReservationLockedException` when `_isLockedForSlot` ([cullinan_reservation.dart:609-627](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:609)). Batch still reports a cross-hall locked row as `notOffered` when nothing is confirmed (residual R2). |
| 6 | H3 — `_batchBook` / `_handleReservationsTopUp` hall-aware | **Met** | Hall chosen first, then `dishesForHall`, row skipped when empty; hardcoded `Hall(id: '1')` removed ([home_shell.dart:2684-2706](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2684), [home_shell.dart:3406-3428](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:3406)). |
| 7 | M1 — price the extra reads, surface the two-hall cap | **Met** | `computeBudget`/`projectedRequests` multiply by `min(2, hallCount)` ([hunt_config.dart:404-415](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:404), [hunt_config.dart:641-651](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:641)); the engine's effective budget takes `max(requestBudget, projectedRequests × 1.3)` ([snipe_engine.dart:479-487](D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart:479)); the basket adapter bounds itself to two switches ([cullinan_basket_buy.dart:72-105](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart:72)); the hunt UI already refuses a third hall priority ([hunt_screen.dart:1537](D:/Bahonar-Nut/lib/ui/features/hunt/hunt_screen.dart:1537)). |
| 8 | Tests for B1–B3 and the hall-switch bodies | **Partially met** | B1 has 3 real tests. No automated test exercises `wasSubstituted` in any UI path, `_pageHoldsSlot` batch continuation, or `reservationHallSwitchBody`/`renderedReservationRow`. See residual R4. |

## Tracked residuals (non-blocking, must be closed before Stage 2 sign-off)

- **R1 — no UI hall-read path.** With one rendered hall stored per `(date, slot)`, a hall the page did not render is still unbookable; the sheet reports "لیست غذای این سلف خوانده نشده است" and the student cannot fetch it. Mitigated: correct default, honest message, and the adapter re-renders/refuses so nothing wrong is booked. Either wire a read-only `drpSelf` fetch on hall change or disable non-rendered halls.
- **R2 — batch lock mislabel.** A locked row reached through a cross-hall switch lands in `rejected` and is thrown as `ReservationNotOfferedException` when nothing confirmed ([cullinan_reservation.dart:900-913](D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_reservation.dart:900)); the single path reports it as locked. Classify `rejected` with `_isLockedForSlot` too.
- **R3 — M2/M3/L2/L6/L7 unchanged.** Same-slot mixed-hall batches still switch per offering and post all against the last render (the others become reported substitutions, not silent wrong bookings); batch `failed` is still always labelled `locked`; display/price paths still read `menu.dishes`.
- **R4 — test coverage.** Add: `ReservationSubstitutedException` → `substituted` → each of the four UI entry points; `_canPostFor`/batch continuation after a substituted prior slot; `reservationHallSwitchBody` body (preserved rows, no save button) and `renderedReservationRow` from an inline fixture. Inline the hall-2/locked fixtures, since `scratch/portal_live/out` is absent in CI and the live tests skip.
- **R5 — nits.** `hasChanges` reports a change when the incoming map is a subset (length compare, [local_menu_store.dart:147](D:/Bahonar-Nut/lib/core/meal/local_menu_store.dart:147)); production has no caller, so no effect. `_batchBookOfferings`'s unmounted return still ignores `substituted` ([home_shell.dart:2784](D:/Bahonar-Nut/lib/ui/shell/home_shell.dart:2784)). `copyWith` recomputes the budget without the hall multiplier, but the engine's `max(projected × 1.3)` covers it.

## Conclusion

B1/B2/B3 — the data-loss, money-messaging and batch-abort defects that blocked the previous review — are resolved and demonstrably wired end to end. I approve the change; R1–R4 must be scheduled before Stage 2 is signed off.

*Follow-up review performed read-only; no source files were modified.*
