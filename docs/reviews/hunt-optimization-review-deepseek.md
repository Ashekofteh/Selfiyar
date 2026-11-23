# Food Hunt (شکار غذا) Optimization — Review Council Report

**Reviewer:** Senior Review Council Member (adversarial, code-level sign-off)
**Reviewer identity:** DeepSeek V4.1 Flash (T3 Code sub-agent)
**Date:** 2026-11-23
**Scope:** Food Hunt subsystem optimization across the five architectural pillars, plus the persistence/UI additions
**Verdict:** **REQUEST CHANGES** (architecture accepted; five blocking, localized defects)

---

## 1. Scope and method

### 1.1 Files inspected (working tree, `git diff` + untracked)

| Area | Files |
| --- | --- |
| Adapter | `lib/adapter/cullinan/cullinan_basket_buy.dart` |
| Hunt domain | `lib/core/hunt/hunt_config.dart`, `hunt_store.dart`, `snipe_engine.dart`, `hunt_success.dart` (new), `hunt_success_store.dart` (new) |
| Platform | `lib/platform/hunt_service.dart`, `platform_bridge.dart`, `desktop_bridge.dart`, `platform_services.dart` |
| Background | `lib/background/hunt_entrypoint.dart` |
| UI | `lib/ui/app_state.dart`, `lib/ui/state/hunt_state.dart`, `lib/ui/features/hunt/hunt_screen.dart`, `lib/ui/shell/home_shell.dart` |
| Android | `android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/HuntService.kt`, `PlatformChannel.kt` |
| Tests | `test/core/hunt/hunt_optimization_test.dart` (new), `test/core/hunt/hunt_success_test.dart` (new), `test/adapter/cullinan/basket_polling_test.dart`, `test/platform/hunt_service_test.dart` (+ harness updates in `hunt_store_test.dart`, `home_shell_pending_test.dart`, `permissions_and_switch_test.dart`) |

The whole working tree was read, not only the diff hunks: `HomeShell`, `AppServices`, `LocalMealStoreHolder`, `SnipeClaimer`, `PreflightChecker`, `ReminderAlarmReceiver` and `AlarmScheduler` were used to validate the claims made by the diff.

### 1.2 Verification commands (executed on this machine)

| Command | Result |
| --- | --- |
| `flutter analyze` | `No issues found!` (2.4 s) |
| `flutter test` | **All 1538 tests passed** (00:29) |
| `flutter test test/core/hunt test/adapter/cullinan test/platform/hunt_service_test.dart test/ui/shell/home_shell_pending_test.dart` | 482 tests passed |
| `android/gradlew.bat :app:testDebugUnitTest --offline` | `BUILD SUCCESSFUL` (67 tasks; unit-test tasks up-to-date) |
| `android/gradlew.bat :app:compileDebugKotlin --offline` | `BUILD SUCCESSFUL` (forced Kotlin compile check: `compileDebugKotlin` executed/up-to-date, no Kotlin compile error) |
| `git diff --check` | clean (only the repo's pre-existing CRLF warning) |

The green build is a **necessary but not sufficient** condition; every numbered finding below was reproduced by reading the code path, not by trusting the tests.

---

## 2. Executive summary

The design of all five pillars is present and largely idiomatic: cached buy-page state for the snipe, an unbounded ∞ rate with a real failure floor, per-account engine listeners, a native ref-counted foreground service, a persisted success record with a UI banner, and a local meal-conflict guard. The implementation compiles and the suite is green.

However, adversarial review found **five blocking defects** that are squarely inside the pillars under review — a user-visible `‑۱ درخواست` in ∞ mode, a single cross-account notification id, two account-routing bugs on the new deep links (cold-start and outcome), and a meal-mirror write that is never persisted in-app and is silently discarded in the headless engine. Each is small and localized, but each breaks a stated pillar promise.

Additionally, the Pillar 1 fast path introduces a narrow path where a rejected cached ASP.NET state is reported as **ambiguous** (permanently tombstoning a live listing), and the Pillar 5 basket-listing guard exists only in the UI, so an alarm-started headless hunt can bypass it.

No regression was found in the pre-existing invariants (one-in-flight claim, tombstoning, budget accounting, window gating, login-bounce handling).

---

## 3. Pillar-by-pillar assessment

### Pillar 1 — Zero-overhead 1-RTT claim

**Requirement:** `claim()` must reuse `cached.lastHtml` and skip `_readBuyPage` (GET + date-filter) when the cache is valid, leaving a single purchase POST; fallbacks and session bindings must be airtight.

**Assessment: PASS with one medium risk.**

What is correct:

- `cullinan_basket_buy.dart:261-276` reuses `cached.lastHtml` only when **all** of `belongsTo(session)`, `isUsable`, `lastJalaliDate == wantedDate` and `lastHtml != null` hold. The session binding is real (`_sessionKey` uses `ASP.NET_SessionId`, falling back to `establishedAt`; `cullinan_basket_buy.dart:571-575`), so a second account's viewstate can never be posted.
- The date binding is sound: every writer of `_formState` (`_readBasketHtml` GET path, `_postDateFilter`, `_postHallSwitch`) either validated `buyPageDate(body) == wanted` or stored `lastJalaliDate` derived from the page actually rendered (`cullinan_basket_buy.dart:130-131, 178-179, 225-226, 508-524`).
- `_submitBasketRow` still independently validates the listing against the page (`_offeredListing`, slot + option + hall) and refuses to post a row the page does not offer (`cullinan_basket_buy.dart:353-403`), so a stale-for-the-wrong-hall page degrades to a hall-switch POST, not a wrong purchase.
- `_formState` is dropped in `finally` after every claim (`cullinan_basket_buy.dart:287-292`), so a post-purchase state can never be reused.
- `CullinanClient.basketBuy` is `late final` (`lib/adapter/cullinan/cullinan_client.dart:79,92`) and the engine uses the same `PortalClient` instance (`lib/platform/platform_services.dart:245-252`), so the cache actually survives between the poll and the claim. This is essential and is correct.
- Covered by `test/adapter/cullinan/basket_polling_test.dart:243-268`: one POST, zero GETs, and the POST body carries the cached `VS-POST-1`.

Findings:

- **M1 (Major) — A rejected cached state can tombstone a live listing.** `claim()` no longer validates that the cached page is still postable, and `_submitBasketRow` does not check `_isRenderedPage(response)` before deciding the outcome. If the server rejects the cached viewstate/eventvalidation (ASP.NET answers a rejected postback with a 200 error page), the response has no error text and no hold, so the claim is reported as `ClaimAmbiguous` (`cullinan_basket_buy.dart:405-439`). The claimer then permanently tombstones that listing and reconciles it as "possibly bought" (`lib/core/hunt/snipe_claimer.dart:200-236`). The read path, by contrast, *does* fall back to a fresh GET when the cache is refused (`cullinan_basket_buy.dart:114-145`). Recommendation: after the purchase POST, treat a provably-unexecuted postback (non-success / `CullinanForms.looksLikeAspError` and no hold) as `ClaimRejected` and let the poll's normal fallback re-read; keep ambiguity for genuine transport failures. At minimum, document this asymmetry and add a test with `nextPostErrorPage` around `claim()`.
- **N10 (Minor) — "1 RTT" is only guaranteed for the last hall in the poll.** `fetchBasket` ends with the last hall's form state (`cullinan_basket_buy.dart:74-104`); a listing from an earlier hall costs a read-only hall-switch POST plus the purchase POST (2 RTTs). Still a reduction, but the "single POST" claim needs this caveat.

---

### Pillar 2 — Infinity (∞) mode

**Requirement:** floor 0 peak interval, continuous polling, **no** artificial request ceiling (`computeBudget == 1_000_000_000`), a 5-second failure floor, cooperative yield when the delay is 0, `projectedRequests() == -1` without `Infinity.ceil()`, and a discrete UI stop for ∞.

**Assessment: PASS on the engine; FAIL on one user-visible UI surface.**

What is correct:

- `HuntBounds.clampPeak(Duration.zero) == Duration.zero` (`hunt_config.dart:120-130`), so ∞ is representable and survives `HuntRate` construction (`hunt_config.dart:151-156`) and decode (`hunt_store.dart` + `test/core/hunt/hunt_store_test.dart:99-105`).
- `computeBudget` returns `1000000000` for a zero peak interval (`hunt_config.dart:414-417`), and the engine's per-run allocation mirrors it (`snipe_engine.dart:511-516`), so there is **no** safety ceiling in ∞ mode, exactly as instructed.
- `projectedRequests()` returns `-1` without any `Infinity.ceil()` (`hunt_config.dart:653-673`), and the engine never feeds `-1` into the budget maths because the zero-interval branch is taken first.
- Failure backoff: when `base == 0`, `effectiveBase` becomes `Duration(seconds: 5)` before `2^n` (`snipe_engine.dart:737-747`), so a failing server is never retried at 0-delay; the first failure waits 10 s and the result is capped by `maxBackoff` (5 min). **Requirement met in behaviour.**
- Cooperative yield: when the computed delay is zero the loop awaits `Future<void>.delayed(Duration.zero)` (`snipe_engine.dart:660-666`), so the ∞ loop cannot starve the isolate's microtask/event queue.
- Fast rates bypass jitter by design (`snipe_engine.dart:749-752`), so the quoted rate is not silently slowed.
- UI: `allowInfinity` gives the peak slider a single discrete ∞ stop plus linear 2…60 s stops (`hunt_screen.dart:1754-1768, 1884-1935`), `_formatInterval(0)` renders `∞ (حداکثر سرعت)`, `_accentFor(0)` uses the released/danger colour, the rate card and the risk dialog both special-case ∞, and `confirmRiskAcknowledgement` is correctly required (`home_shell.dart:3945-3967`).

Findings:

- **B1 (Blocker) — The enable card prints a negative request count in ∞ mode.** `_PreflightCard.build` renders `projected` unguarded:

  ```dart
  // lib/ui/features/hunt/hunt_screen.dart:663-666
  'هزینه تقریبی این شکار در بازه فعلی: '
  '${toPersianDigits(projected)} درخواست',
  ```

  `toPersianDigits(-1)` yields `-۱`, so the primary card of the new feature shows **«‑۱ درخواست»**. `_RateCard` (line 1787) and `_describeReady` (`home_shell.dart:4103`) already guard `projected < 0`; this one was missed. Required fix: mirror the `projected < 0` branch (`'نامحدود (با حداکثر سرعت پاسخ‌دهی سرور)'`).
- **N1 (Minor) — `minBackoffInterval` is not a named constant.** The 5-second floor is an inline `const Duration(seconds: 5)` (`snipe_engine.dart:740`). The task names it `minBackoffInterval`; put it in `HuntBounds` and test it, so the safety floor cannot be edited away unnoticed.
- **N2 (Minor) — `HuntBounds.infinityInterval` is only half-used.** `clampPeak` compares to it, but `computeBudget`, `projectedRequests` and the engine all compare `Duration.zero` directly. Harmless today; use the constant everywhere or drop it.

---

### Pillar 3 — Multi-account concurrency

**Requirement:** Android service ref-counted per account; stopping A keeps the service for B; `SnipeEngine` routes outcomes through per-rule listeners.

**Assessment: PASS on the mechanism; FAIL on two account-routing defects aggravated by the new code.**

What is correct:

- Kotlin: the companion `active = linkedSetOf<String>()` records each started account; `stop(context, accountId)` removes only that account and calls `stopService` **only when the set is empty**; `stop(context, null)` is the explicit "stop everything" path; `onDestroy` clears the set (`HuntService.kt:50-86, 193-194`). The payload used by both producers is the raw account id (`AlarmScheduler.kt:185`, `PlatformChannel.kt:298-303`), and the headless engine's alarm payload is the same account id (`ReminderAlarmReceiver.kt:71` → entrypoint arg), so the two namespaces agree.
- `PlatformChannel.kt:306-313` forwards `accountId` and keeps the legacy null semantics.
- Dart `HuntService._activeHunts` plus `isHunting()` (`hunt_service.dart:51-55`) and account-scoped `stop`/`reportOutcome`/`_releaseService` (`hunt_service.dart:90-161`).
- `HuntState` now keeps `_huntRunning`/`_huntStatus` maps keyed by account and the shell subscribes per account (`hunt_state.dart:45-47, 100-114, 267-286`; `home_shell.dart:80-82, 260-280, 2995-3018, 4003-4035`).
- `DefaultSnipeEngine._listeners` is keyed by `ruleId` with a `NoopHuntListener` fallback, all outcome paths use `_listenerFor(...)`, and the entry is cleared in `finally` (`snipe_engine.dart:142-144, 196-216, 454-495, 569-626, 810-827, 986-992, 1254-1332`). The old global `listener` setter is retained but no longer used in production (`grep` finds no `.listener =` in `lib/`).

Findings:

- **B2 (Blocker) — One notification id for every account.** `_outcomeNotificationId = 4150` is a single constant used by `reportOutcome` for every account (`hunt_service.dart:58, 123`). With A and B hunting concurrently (the entire point of the pillar), A's success replaces B's ended/success notification and vice versa — an outcome is silently lost. Fix: derive the id per account (e.g., a stable hash of `accountId` into a reserved range) and add a test asserting distinct ids.
- **B4 (Blocker) — The `reservations://<account>` deep link clears the *active* account's running state.** `home_shell.dart:735-737` calls `widget.state.setHuntRunning(false)` with no account id, which resolves to `_activeHuntAccount` (`hunt_state.dart:266-275`). This deep link is exactly the one posted for a **non-success** outcome (`hunt_service.dart:126`), so tapping A's "hunt ended" notification while B is the active account sets B's `_huntRunning[B] = false` and drops B's status. The per-account fix already exists — pass `target`.
- **B3 (Blocker) — Cold-start `nut://hunt-success` routes the account to the wrong selector.** When accounts are not yet loaded, the handler stores `_pendingTargetAccount = account` (`home_shell.dart:766-768`), but the replay calls `widget.state.selectReservationsAccount(...)` (`home_shell.dart:226-231`), not `selectHuntAccount`. The shell then shows the Hunt tab at `_index = 4` with the **default/first** hunt account, so the success card belongs to the wrong account (or is absent). Fix: carry the intent (hunt vs reservations) with the pending account, or call `selectHuntAccount` for the hunt deep link before falling back.
- **N8 (Minor) — No success refresh on resume.** `didChangeAppLifecycleState` reloads configs and re-subscribes status, but not `loadSuccesses()`/`reloadHuntSuccess` (`home_shell.dart:260-280`). Mostly masked because in-app claims reload the success and cold starts call `loadSuccesses()`; still, add it for the killed-UI/surviving-process window.
- **M3 (Major, test) — The Kotlin ref-count has no test.** Android's `HuntService` static set is the only thing that actually keeps the service alive for B when A stops, and there is no JVM test exercising `start/stop(accountId)/stop(null)` (`android/app/src/test/kotlin/...` contains no `HuntServiceTest`). The Dart test (`hunt_optimization_test.dart:107-144`) only asserts that the bridge was *called* with `stop:acc1`; it cannot verify the ref-count. This is the single most important untested claim in Pillar 3.

---

### Pillar 4 — Successful hunt persistence and UI banner

**Requirement:** `HuntSuccess` persisted in `HuntSuccessStore` on `PlainStore`; `HuntScreen` renders `_LastHuntSuccessCard` with dish (نوع غذا), hall (نوع سلف) and price in Toman; the notification deep link routes to the Hunt screen.

**Assessment: PASS for the stated requirement; one data-integrity defect on the adjacent meal mirror.**

What is correct:

- `HuntSuccess` is a total, defensive model (`hunt_success.dart:97-139`), the store is `PlainStore`-backed with per-account keys and a corrupt-value fallback (`hunt_success_store.dart:21-50`), and `PlainStore.remove` genuinely exists (`platform_stores.dart:71-72`).
- The notifier writes the record before posting the notification (`hunt_service.dart:214-229`) and the UI path and headless path both supply a store (`platform_services.dart:237-260`, `hunt_entrypoint.dart:145-154`). Because it is a `PlainStore` write, it survives the death of the headless engine.
- `HuntState` loads, reloads and dismisses per account (`hunt_state.dart:138-171`), `AppState` wires it at startup (`app_state.dart:206`), and the shell passes the active account's record (`home_shell.dart:3017-3018`).
- `_LastHuntSuccessCard` renders dish, hall, `formatTomanPersian(priceRial)` (which prints `… تومان`; `persian.dart:342-345`) and slot+date, with a dismiss button (`hunt_screen.dart:306-430`) and `enableRefusal` is now also surfaced in the pre-flight card.
- The success deep link is `nut://hunt-success?…` (`hunt_service.dart:239-250`), handled by `_handleDeepLink` and mapped to the Hunt tab (`home_shell.dart:758-776`), which is the required routing (the old `HuntSuccessDialog` was intentionally replaced by the persistent card).
- Unit and store round-trip tests are solid (`hunt_success_test.dart`).

Findings:

- **B5 (Blocker) — The purchased meal written to the meal mirror is never persisted.** `HuntNotifier.onClaimed` calls `meals.put(StoredMeal(...))` (`hunt_service.dart:195-212`) but nobody calls `LocalMealStoreHolder.persist()` — the store is a pure value type and the disk copy is only written by `persist` (`platform_services.dart:361-369`). In the **in-app** path the record survives only until the next portal sync. In the **headless** path it is worse: `runHeadlessHunt` never calls `services.mealStore.restore()` and never persists, so the write lands in an empty in-memory store that is destroyed with the background engine — a guaranteed no-op. Consequences: offline reminders can miss a hunt purchase, and the Pillar 5 local guard cannot see a headless purchase until a sync. Fix: pass a `persist` callback into `HuntNotifier` (or have `HuntService`/the entrypoint call `mealStore.persist()` after `onClaimed`), and call `restore()` in the headless bootstrap.
- **N7 (Minor) — The card has no freshness rule.** The last success is shown indefinitely (across target-date changes and weeks) until manually dismissed. Consider a "purchased ≥ N days ago / different target date" rule or an explicit date label (the slot+date is at least shown).
- **M3 (Major, test) — No widget test for `_LastHuntSuccessCard`.** The card, its Toman formatting, its dismiss callback and its placement before the account picker are untested; `hunt_success_dialog_test.dart` only tests the now-unused legacy dialog.
- **N2 (Minor) — `lib/ui/features/hunt/hunt_success_dialog.dart` is now dead production code** (only its own test imports it). Delete it or keep it deliberately with a comment.

---

### Pillar 5 — Reservation conflict guard

**Requirement:** `_findMealConflict` must block hunting when the account holds an active meal **or is listed in the basket** for `(targetDate, targetSlot)`.

**Assessment: PASS in the UI; PARTIAL overall (headless bypass).**

What is correct:

- `_findMealConflict` (`home_shell.dart:3126-3150`) checks `reservations.mealsFor(accountId)` for a non-consumed meal whose civil date matches `config.targetDate` and whose slot matches `config.targetSlot`, and separately checks `reservations.isListedInBasket(accountId, targetDate, targetSlot)` (`reservations_state.dart:398-400`). `_sameDate` compares y/m/d only, which is the right civil-date comparison (line 3918-3922).
- The guard gates **enabling** (`_confirmHuntEnable`, `home_shell.dart:3269-3274`), **saving a config** (3183-3189), **starting** (3974-3978), and is surfaced as `enableRefusal`/`preflightRefusal` in the UI (`hunt_screen.dart:655-676`, `effectiveRefusal = widget.refusal ?? widget.enableRefusal`). It is also re-evaluated on every rebuild (`home_shell.dart:2998-3000`).
- Defense in depth already exists at the engine level: the pre-flight refuses a slot the account already holds as a **portal reservation** (`lib/core/portal/preflight.dart:214-237`, exercised by `test/core/hunt/hunt_engine_test.dart: "a hunt for a slot the account already holds never starts"`), and that pre-flight runs in the headless entrypoint and inside the run loop.

Findings:

- **M2 (Major) — The basket-listing half of the guard is UI-only.** `PreflightChecker` sees only `fetchReservations` (`snipe_engine.dart:375-390`); a meal that the account has **listed in the basket** is not a portal reservation, so an alarm/headless hunt for that `(date, slot)` is not refused by the engine. Same for a locally-known basket purchase before the next sync. Recommendation: feed the local holdings/`_basketSales` into the headless path (the headless bootstrap already builds `AppServices`; exposing a local-holdings predicate to `HuntService`/the entrypoint is enough), or document explicitly that the guard is an enable-time UX guard and that the engine's portal pre-flight remains the last line of defence.
- **M3 (Major, test) — No test for `_findMealConflict`.** There is not a single test asserting that an active weekly meal *or* a basket listing blocks enable/start and produces the refusal text. This is a pillar claim with zero direct coverage.
- **N-extra (Minor) — `_onConfigChanged` can leave a stale top-up affordance.** When the conflict is written after `_confirmHuntEnable`, `_enableNeedsTopUp` is not cleared (compare `home_shell.dart:3271-3272` with 3183-3189), so the "افزایش اعتبار" button can linger next to a conflict refusal. Cosmetic.
- **N-extra (Minor) — A conflicting hunt can still be *armed*.** With an empty dish priority list, `_confirmHuntEnable` returns true before the conflict check (`home_shell.dart:3262-3264`), so `enabled = true` is saved and the alarm is armed; the start path refuses later. Behaviourally safe (start is guarded in-app), but it creates an armed-but-never-startable configuration and a wake-up that always releases immediately.

---

## 4. Consolidated findings

### Blockers (must fix before approval)

| ID | Pillar | Location | Defect |
| --- | --- | --- | --- |
| **B1** | 2 | `lib/ui/features/hunt/hunt_screen.dart:663-666` | ∞ mode renders `‑۱ درخواست` in the enable/pre-flight card (`projected == -1` not handled). |
| **B2** | 3 | `lib/platform/hunt_service.dart:58, 115-128` | Single `_outcomeNotificationId = 4150` for all accounts; concurrent hunts overwrite each other's outcome notifications. |
| **B3** | 4 (and 3) | `lib/ui/shell/home_shell.dart:226-231, 758-776` | Cold-start `nut://hunt-success` stores `_pendingTargetAccount`, but the replay selects the **reservations** account; the Hunt tab then shows the default account's (wrong/no) success card. |
| **B4** | 3 | `lib/ui/shell/home_shell.dart:735-737` | `reservations://<accountId>` (the non-success outcome link) calls `setHuntRunning(false)` without the target account, clearing the active account's running state. |
| **B5** | 4 (and 5) | `lib/platform/hunt_service.dart:195-212`; `lib/background/hunt_entrypoint.dart:89-176` | The `StoredMeal` written on a successful claim is never persisted (`persist()` never called) and, in the headless engine, `restore()` is never called either, so the write is discarded with the engine. |

### Major (should fix; if deferred, must be documented and ticketed)

| ID | Pillar | Location | Defect |
| --- | --- | --- | --- |
| **M1** | 1 | `cullinan_basket_buy.dart:405-439` + `snipe_claimer.dart:200-236` | A rejected cached viewstate (200 ASP error page) is reported as `ClaimAmbiguous`, permanently tombstoning a listing that was never bought. The read path has a fallback; the claim path does not. |
| **M2** | 5 | `lib/core/hunt/snipe_engine.dart:354-398`; `home_shell.dart:3126-3150` | The "basket listing / local basket purchase" half of the conflict guard is UI-only; the alarm-started headless hunt only sees portal reservations. |
| **M3** | 3, 4, 5 | `android/app/src/test/kotlin/…`, `test/ui/features/hunt/…`, `test/ui/shell/home_shell_*` | No Kotlin ref-count test; no `_LastHuntSuccessCard` widget test; no `_findMealConflict` test. The three pillar claims with the least coverage. |

### Minor / nits

| ID | Location | Note |
| --- | --- | --- |
| N1 | `snipe_engine.dart:740` | 5 s floor is an inline literal, not `HuntBounds.minBackoffInterval`. |
| N2 | `lib/ui/features/hunt/hunt_success_dialog.dart` | Now dead production code (only its own test references it). |
| N3 | `hunt_success_store.dart:27` | Store key `hunt.success.<id>` is not declared in `StoreKeys`. |
| N4 | `hunt_success.dart:43` | `priceToman` truncates (`~/ 10`) while the UI rounds (`rialToToman`); harmless for real prices but two definitions of the same conversion. |
| N5 | `test/core/hunt/hunt_optimization_test.dart:17` | Imports another test file (`../../platform/hunt_service_test.dart`) to reuse fakes — couples two suites and hides them behind one `main`. |
| N6 | `lib/core/hunt/hunt_store.dart:9-10` | `hunt_store.dart` re-exports `hunt_success_store.dart`, which imports `platform_stores.dart`, which imports `hunt_store.dart`: a cycle (legal in Dart, but a layering smell; `platform_services.dart` could import the file directly). |
| N7 | `hunt_screen.dart:306-430` | Last-success card has no freshness rule and shows until manually dismissed. |
| N8 | `home_shell.dart:260-280` | No success reload on resume (masked today, but a cheap fix). |
| N9 | `home_shell.dart:775` | Deep link sets `_index = 4` without `loadMarket()`, so the Hunt screen can open with an unloaded market. |
| N10 | `cullinan_basket_buy.dart:74-104, 261-276` | "Single POST" only for the last-polled hall; an earlier-hall listing costs hall-switch + purchase. |
| N11 | `hunt_state.dart:139-151` | `loadSuccesses` awaits each account sequentially; `Future.wait` would be cleaner for N accounts. |

---

## 5. Test coverage matrix (as implemented)

| Pillar claim | Direct test | Verdict |
| --- | --- | --- |
| Claim reuses cache, skips GET | `basket_polling_test.dart:243-268` | Covered (happy path); **no** date-mismatch / stale-state case |
| ∞ clamps, budget, `projectedRequests == -1` | `hunt_optimization_test.dart:20-63` | Covered |
| ∞ failure floor ≥ 5 s | — | **Not covered** |
| ∞ cooperative yield (zero delay) | — | **Not covered** |
| ∞ UI slider discrete stop / label | — | **Not covered** |
| Per-rule listener routing | `hunt_optimization_test.dart:67-105` | Covered (invokes listener directly; not a real two-run engine test) |
| Dart service bookkeeping | `hunt_optimization_test.dart:107-144` | Covered, but only asserts bridge calls |
| Kotlin ref-count keeps service | — | **Not covered** |
| HuntSuccess model + store | `hunt_success_test.dart` | Covered |
| HuntNotifier persists success | `hunt_optimization_test.dart:148-197` | Covered |
| Banner renders dish/hall/Toman | — | **Not covered** |
| Deep link → Hunt tab | — | **Not covered** |
| Conflict guard blocks | — | **Not covered** (engine-level preflight is covered by an older test) |

---

## 6. What the review confirms is right

- The one-in-flight claim / tombstone / reconciliation contract is untouched and still enforced (`snipe_claimer.dart`, `tombstone.dart`).
- The session binding of the cached form state is genuinely airtight, not nominal: account + ASP.NET session id, with a fresh-GET fallback on every refusal in the read path.
- Budget accounting still counts **requests** from the shared ledger, and the ∞ mode's `1_000_000_000` sentinel is a data value, not an `int` overflow or a magic loop bound.
- The native ref-count uses a `Set` (idempotent starts) and keeps the legacy `stop(null)` "stop everything" semantics, so no caller is broken.
- Success persistence is a plain-store write performed *before* the notification, so a crash between the two cannot lose the record.
- The conflict guard is applied at four distinct places (enable, save, start, rebuild) and is backed by the engine's portal-holdings pre-flight, i.e. it is defence in depth, not a single UI check.

---

## 7. Required changes checklist

1. **B1** — guard `projected < 0` in `_PreflightCard` and add a widget test for the ∞ label.
2. **B2** — per-account outcome notification ids; test that A and B get distinct ids.
3. **B3** — make the pending deep-link target carry its destination (hunt vs reservations) and replay to `selectHuntAccount` for `nut://hunt-success`.
4. **B4** — pass the linked account to `setHuntRunning(false, target)` in the `reservations://` branch.
5. **B5** — persist the meal mirror after a claim (both engines) and `restore()` it in the headless bootstrap.
6. **M1** — distinguish a provably-unexecuted postback from a genuine transport ambiguity in `_submitBasketRow`; add the `nextPostErrorPage` claim test.
7. **M2** — either feed local basket holdings/listings into the headless pre-flight or document the UI-only scope in the code and the report.
8. **M3** — add a Kotlin `HuntServiceTest` for the ref-counted set, a `_LastHuntSuccessCard` widget test, and `_findMealConflict` tests (active meal, basket listing, clear case).
9. Extract `HuntBounds.minBackoffInterval` and test the 5 s floor and the zero-delay yield.
10. Sweep the minors (N2–N11) opportunistically; none is blocking on its own.

---

## 8. Formal verdict

> **REQUEST CHANGES**
>
> The five-pillar architecture is sound, the session/budget/claim invariants survive the change, `flutter analyze` is clean, all **1538** Dart tests pass, and the Android debug unit-test and Kotlin-compile tasks are green. The optimization is not rejected on design.
>
> Sign-off is withheld because five small, localized defects break stated pillar promises in the very surfaces under review: a negative request count in ∞ mode (Pillar 2), a cross-account notification collision and two account-routing bugs on the new deep links (Pillars 3–4), and a meal-mirror write that is silently discarded (Pillars 4–5); plus one Pillar 1 fallback must be hardened against a rejected cached viewstate. Each fix is a handful of lines with a targeted test, and none requires redesign.
>
> Re-review is needed only for the five blockers (`B1`–`B5`) and the three major coverage gaps (`M1`–`M3`); the minors may be deferred.

---

*Reviewer: DeepSeek V4.1 Flash — T3 Code Review Council, 2026-11-23.*
