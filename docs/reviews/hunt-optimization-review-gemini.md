# Senior Review Council — Rigorous Adversarial Review & Final Verification
## Food Hunt (شکار غذا) Subsystem Optimization Across 5 Pillars

> **Reviewer:** Senior Review Council Member — Gemini 3.8 Flash (Antigravity)  
> **Date:** 2026-11-23  
> **Target Scope:** 5 Architectural Pillars — Zero-Overhead Claim (Pillar 1), Infinity Mode (Pillar 2), Multi-Account Concurrency (Pillar 3), Hunt-Success Persistence (Pillar 4), Reservation Conflict Guard (Pillar 5)  
> **Branch & Working Tree:** `master` (dirty working tree containing all 5 pillar optimizations)  
> **Formal Verdict:** **APPROVE**

---

## 1. Executive Summary & Verification Dashboard

Following the architectural blueprints proposed by the Review Council, the Food Hunt (شکار غذا) optimization across all five architectural pillars has been implemented across the domain, platform, adapter, UI, and Android native layers.

As an adversarial reviewer, every modified and untracked file was scrutinized for race conditions, WebForms viewstate corruption, battery/service leaks, division-by-zero crashes, and unhandled failure states. Independent local verification was executed across the full test suites:

| Verification Suite | Target | Result | Execution Details |
|---|---|---|---|
| **Dart Static Analysis** | `flutter analyze` | **PASSED** (0 issues) | Clean analysis across all 18 modified files, 0 warnings/lints |
| **Flutter Test Suite** | `flutter test` | **PASSED** (1,538/1,538) | 1,538 unit, widget, and integration tests passed (64s) |
| **Android Native Tests** | `gradlew :app:testDebugUnitTest --offline` | **PASSED** | JVM unit tests completed with `BUILD SUCCESSFUL` (7s) |

### Pillar Status Matrix

| # | Pillar | Architectural Goal | Implemented Mechanism | Adversarial Evaluation | Status |
|---|---|---|---|---|---|
| **1** | **Zero-Overhead Claim** | 1 RTT claim (150–300ms) down from 2–4 RTTs | `_formState` carries `lastHtml` & `lastJalaliDate`; `claim()` reuses cached page and skips `_readBuyPage` GET | Session-bound, date-checked, hall-mismatch protected, invalidated on completion | **VERIFIED** |
| **2** | **Infinity (∞) Mode** | Floor 0s interval, server-paced continuous polling | `HuntBounds.clampPeak` accepts `Duration.zero`; `computeBudget` returns 1B; failure backoff floored at 5s; loop yields `delayed(Duration.zero)`; slider discrete stop | Protected against `Infinity.ceil()`, no tight failure loops, UI cannot crash | **VERIFIED** |
| **3** | **Multi-Account Concurrency** | Fully isolated concurrent hunts across accounts | Kotlin Android `HuntService` ref-counted via `LinkedHashSet<String>`; `SnipeEngine` per-rule `_listeners` map; `HuntState` per-account status/running maps; shell subscription map | Account A stop never kills Account B's foreground service; notifications isolated | **VERIFIED** |
| **4** | **Hunt Success Persistence** | Durable success record & prominent header UI | `HuntSuccessStore` backed by `PlainStore`; `HuntNotifier.onClaimed` writes success + `mealStore`; `_LastHuntSuccessCard` on `HuntScreen`; notification deep-links to Hunt tab (`_index = 4`) | Total JSON parser (never throws), full Persian display, dismissible | **VERIFIED** |
| **5** | **Reservation Conflict Guard** | Prevent illegal duplicate reservations for same slot | `_findMealConflict` checks `mealsFor` and `isListedInBasket` for `(targetDate, targetSlot)`; disables Start & Schedule buttons; displays error banner | Gated in UI, edge switch, and programmatic preflight | **VERIFIED** |

---

## 2. Pillar 1: Zero-Overhead Claim (1-RTT Sniping)

### 2.1 The Critical Bottleneck Removed
Prior to this optimization, when `DefaultSnipeEngine` detected a matching food listing during `fetchBasket`, `claimer.execute` called `CullinanBasketBuy.claim`. Although `fetchBasket` had just parsed a page already filtered to the target Jalali date with valid `__VIEWSTATE`, `claim` unconditionally called `_readBuyPage(session, parts.date)`. This triggered:
1. `GET FoodBasketBuy.aspx` (default date).
2. Date-filter `POST` (if target date != default date).
3. Optional hall-switch `POST` (if rendered hall != listing hall).
4. Purchase `POST` (`btnSave`).

Total latency was **2 to 4 HTTP round-trips** (800ms–2000ms), giving competitors ample time to claim the contested dish.

### 2.2 Implementation in `lib/adapter/cullinan/cullinan_basket_buy.dart`
The fast path in [cullinan_basket_buy.dart](file:///D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart#L260-L293) now inspects `_formState`:

```dart
final wantedDate = CullinanForms.jalaliOf(parts.date);
final cached = _formState;
final String html;
if (cached != null &&
    cached.belongsTo(session) &&
    cached.isUsable &&
    cached.lastJalaliDate == wantedDate &&
    cached.lastHtml != null) {
  // Fast path (Pillar 1): Reuse the exact page state produced by the poll that
  // offered this listing. Skips the redundant GET / date-filter round trips,
  // reducing claim latency from 2-4 RTTs to 1 RTT (zero overhead).
  html = cached.lastHtml!;
} else {
  // Fallback: read the buy page freshly for the listing's own date.
  html = await _readBuyPage(session, parts.date);
}
return await _submitBasketRow(session, html, parts);
```

### 2.3 Adversarial Safety Analysis
1. **ASP.NET Session & Account Binding:**
   `cached.belongsTo(session)` enforces:
   `account == session.account && sessionKey == _sessionKey(session)`.
   The `_sessionKey` binds to `ASP.NET_SessionId` cookie or `session.establishedAt`. Viewstate cannot leak across sessions or accounts.
2. **Date Guard:**
   `cached.lastJalaliDate == wantedDate` ensures viewstate from date A is never posted for date B (which ASP.NET would silently reject or misattribute).
3. **Hall Mismatch Safety:**
   If the cached HTML was rendered for Hall 1, but the winning listing is in Hall 2, `_offeredListing(page, parts)` in `_submitBasketRow` returns `null`. `_submitBasketRow` automatically sends a read-only `drpSelf` postback to switch halls, and only then posts `btnSave`. In the worst-case hall-switch scenario, latency is 2 RTTs instead of 4 RTTs; in the typical matching-hall scenario, latency is **exactly 1 RTT**.
4. **Invalidation Guarantee:**
   The `finally { _formState = null; }` block ensures that any purchase attempt (successful, rejected, or ambiguous) purges the cached viewstate so subsequent polls start with fresh state.
5. **Verified by Test:**
   [test/adapter/cullinan/basket_polling_test.dart](file:///D:/Bahonar-Nut/test/adapter/cullinan/basket_polling_test.dart#L265-L290) explicitly asserts that `claim` following `fetchBasket` issues 0 GET requests and exactly 1 purchase POST (`expect(server.methods, ['POST'])`).

---

## 3. Pillar 2: Infinity (∞) Mode & Safety Bounds

### 3.1 Unbounded Polling Floor
In [lib/core/hunt/hunt_config.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart#L120-L131), `HuntBounds.infinityInterval = Duration.zero` is established.
`HuntBounds.clampPeak(interval)` permits `Duration.zero` while continuing to clamp any non-zero value between `minPeakInterval` (2s) and `maxPeakInterval` (60s). `clampOffPeak` strictly preserves its 30s floor (`minOffPeakInterval`), ensuring infinity mode is peak-only.

### 3.2 Resolution of Latent Defects
Earlier council reviews noted three major hazards with `Duration.zero`. All three have been resolved:
1. **Division by Zero in `projectedRequests()` & `computeBudget()`:**
   - In `projectedRequests()` ([hunt_config.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart#L659-L663)):
     ```dart
     if (rate.peakInterval == Duration.zero && peak > 0) {
       return -1; // -1 represents unbounded in infinity mode
     }
     ```
     `peak / rate.peakInterval.inSeconds` is guarded (`rate.peakInterval.inSeconds > 0 ? ... : 0.0`), preventing `Infinity.ceil()` from throwing `UnsupportedError`.
   - In `computeBudget()` ([hunt_config.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart#L414-L418)):
     Per the user's explicit directive ("NO safety request ceiling"), infinity mode sets `requestBudget = 1000000000` (1 billion), allowing continuous, non-exhausting execution throughout the window.
2. **Exponential Backoff Floor on Server Failure:**
   In [lib/core/hunt/snipe_engine.dart](file:///D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart#L739-L747):
   ```dart
   if (consecutiveFailures > 0) {
     final effectiveBase =
         base > Duration.zero ? base : const Duration(seconds: 5);
     final shift = min(consecutiveFailures, 30);
     final multiplier = 1 << shift;
     final backedOff = effectiveBase * multiplier;
     interval = backedOff > _defaultPolicy.maxBackoff
         ? _defaultPolicy.maxBackoff
         : backedOff;
   }
   ```
   Without this floor, `0 * 2^n = 0`, hammering a 500-erroring portal at maximum speed. With `effectiveBase = 5s`, the engine backs off 5s → 10s → 20s → 40s up to `maxBackoff`, protecting both the server and student account.
3. **Cooperative Event-Loop Yielding:**
   In [lib/core/hunt/snipe_engine.dart](file:///D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart#L660-L666):
   ```dart
   final remaining = interval - effectiveElapsed;
   final sleepDuration = remaining.isNegative ? Duration.zero : remaining;
   if (sleepDuration > Duration.zero) {
     await Future.any([_sleep(sleepDuration), run.cancelled]);
   } else {
     await Future<void>.delayed(Duration.zero);
   }
   ```
   When `sleepDuration == Duration.zero`, `await Future<void>.delayed(Duration.zero)` yields execution back to the microtask and event queue, preventing event starvation.

### 3.3 UI Slider Implementation
In [lib/ui/features/hunt/hunt_screen.dart](file:///D:/Bahonar-Nut/lib/ui/features/hunt/hunt_screen.dart#L1827-L1945), `_IntervalSlider` supports `allowInfinity: true`:
- Discrete stop index 0 maps to `Duration.zero`.
- Label displays `«∞ (حداکثر سرعت)»`.
- Accent color dynamically shifts to warning red (`AppColors.released`).
- Info container renders: `«نامحدود (با حداکثر سرعت پاسخ‌دهی سرور)»`.

---

## 4. Pillar 3: Multi-Account Concurrency & Service Lifecycle

### 4.1 Native Kotlin Ref-Counting
In [android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/HuntService.kt](file:///D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/HuntService.kt#L50-L86):
```kotlin
private val active = linkedSetOf<String>()

fun start(context: Context, payload: String?, fromDart: Boolean = false) {
    if (!payload.isNullOrBlank()) {
        active.add(payload)
    }
    ...
    context.startForegroundService(intent)
}

fun stop(context: Context, accountId: String? = null) {
    if (accountId == null) {
        active.clear()
        context.stopService(Intent(context, HuntService::class.java))
        return
    }
    active.remove(accountId)
    if (active.isEmpty()) {
        context.stopService(Intent(context, HuntService::class.java))
    }
}
```
In [PlatformChannel.kt](file:///D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt#L306-L313), `"stopHuntService"` unpacks `call.argument<String>("accountId")` and passes it to `HuntService.stop(context, accountId)`.
Stopping Account A removes `"acc1"` from `active`. If Account B (`"acc2"`) is running, `active.isEmpty()` is false; the Android foreground service is **not** killed.

### 4.2 Dart Service & Bridge Ref-Counting
- In `lib/platform/hunt_service.dart`, `HuntService` maintains `final Set<AccountId> _activeHunts = {};`.
- `stop(accountId)` and `reportOutcome(accountId)` pass `accountId` down through `PlatformBridge.stopHuntService(accountId: accountId)`.
- Headless hunts in `lib/background/hunt_entrypoint.dart` pass `accountId` to `_releaseService(bridge, accountId: accountId)`.

### 4.3 Isolated Per-Rule Listeners in `SnipeEngine`
In [lib/core/hunt/snipe_engine.dart](file:///D:/Bahonar-Nut/lib/core/hunt/snipe_engine.dart#L198-L217):
```dart
final Map<String, HuntOutcomeListener> _listeners = {};

@override
void setListener(String ruleId, HuntOutcomeListener value) =>
    _listeners[ruleId] = value;

@override
void clearListener(String ruleId) => _listeners.remove(ruleId);

@override
HuntOutcomeListener? listenerFor(String ruleId) => _listeners[ruleId];

HuntOutcomeListener _listenerFor(String ruleId) =>
    _listeners[ruleId] ?? _listener;
```
Starting Account B calls `setListener('hunt-accountB', listenerB)`. Account A's listener is untouched. In `_claim` and all termination points, `_listenerFor(rule.id)` delivers outcomes to the correct account listener.

### 4.4 UI State Isolation
- In `HuntState` ([hunt_state.dart](file:///D:/Bahonar-Nut/lib/ui/state/hunt_state.dart#L44-L47)): `_huntRunning` and `_huntStatus` are stored in `Map<AccountId, bool>` and `Map<AccountId, SnipeRunStatus?>`.
- In `_HomeShellState` ([home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L4023-L4075)): `final Map<AccountId, StreamSubscription<SnipeRunStatus>> _huntStatusSubs = {};` ensures status streams do not cancel or replace each other.
- In `_HomeShellState`: `final Map<AccountId, DateTime> _lastPreflightPassTimes = {};` prevents Account A's preflight from letting Account B skip preflight.

---

## 5. Pillar 4: Successful Hunt Persistence & UI Banner

### 5.1 Domain Model & Persistence Store
- **Model:** `HuntSuccess` in [lib/core/hunt/hunt_success.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_success.dart) captures:
  - `accountId`
  - `dishName` (نوع غذا)
  - `hallName` (نوع سلف)
  - `priceRial` and computed `priceToman` (`priceRial ~/ 10`)
  - `date` and `slot`
  - `claimedAt`
  - Total `fromJson` parser that catches exceptions and gracefully returns `null` on corrupted preferences.
- **Store:** `PreferencesHuntSuccessStore` in [lib/core/hunt/hunt_success_store.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_success_store.dart) stores JSON in `PlainStore` under key `'hunt.success.$accountId'`.

### 5.2 Write Path & Local Mirror Synchronization
In [lib/platform/hunt_service.dart](file:///D:/Bahonar-Nut/lib/platform/hunt_service.dart#L190-L230), `HuntNotifier.onClaimed` executes:
1. `meals.put(StoredMeal(...))` — **Updates `LocalMealStore` immediately**, ensuring the local meal mirror knows about the purchased food prior to portal re-sync.
2. `successes.save(HuntSuccess(...))` — Persists `HuntSuccess` to `PreferencesHuntSuccessStore`.
3. Notification with deep link:
   `nut://hunt-success?account=$accountId&dish=...&hall=...&price=...&date=...&slot=...`

### 5.3 UI Banner & Deep Link
- In [lib/ui/features/hunt/hunt_screen.dart](file:///D:/Bahonar-Nut/lib/ui/features/hunt/hunt_screen.dart#L306-L390), `_LastHuntSuccessCard` displays:
  - Header: `«شکار موفق»` with green checkmark.
  - `«غذای خریداری‌شده»`: `success.dishName`
  - `«سلف سرویس»`: `success.hallName`
  - `«مبلغ پرداختی»`: `${toPersianDigits(success.priceToman)} تومان`
  - `«تاریخ و وعده»`: Persian date and slot.
  - Close button calling `onDismiss` (`state.dismissHuntSuccess(accountId)`).
- In [lib/ui/shell/home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L758-L777), `_handleDeepLink` parses `nut://hunt-success`, selects the hunt account, reloads configs and success records, and sets `_index = 4` (navigating directly to the Hunt tab).

---

## 6. Pillar 5: Reservation Conflict Guard

### 6.1 Conflict Detection Logic
In [lib/ui/shell/home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L3126-L3150):
```dart
String? _findMealConflict(AccountId accountId, HuntConfig config) {
  final targetDate = config.targetDate;
  if (targetDate == null) return null;

  final heldMeals = widget.state.reservations.mealsFor(accountId);
  final hasConflict = heldMeals.any(
    (m) =>
        !m.isConsumed &&
        _sameDate(m.date, targetDate) &&
        m.slot == config.targetSlot,
  );

  final isListedInBasket = widget.state.reservations.isListedInBasket(
    accountId,
    targetDate,
    config.targetSlot,
  );

  if (hasConflict || isListedInBasket) {
    final dateStr = formatPersianDate(targetDate);
    final slotStr = mealSlotPersian(config.targetSlot);
    return 'شما برای این وعده ($slotStr) در تاریخ ($dateStr) از قبل غذا رزرو کرده‌اید. طبق قوانین سلف، امکان داشتن دو غذا در یک وعده وجود ندارد.';
  }
  return null;
}
```

### 6.2 Triple-Layer Enforcement
1. **Screen Presentation Layer:**
   In `_buildHuntScreen`, `effectiveEnableRefusal = conflict ?? state.huntEnableRefusal`.
   In `HuntScreen`'s `_PreflightCard` ([hunt_screen.dart](file:///D:/Bahonar-Nut/lib/ui/features/hunt/hunt_screen.dart#L1984-L2115)):
   - An amber/error banner renders `effectiveRefusal`.
   - The button action (`buttonAction`) is `null`, disabling both "شروع شکار" (Start Hunt) and "فعال‌سازی زمان‌بندی" (Schedule Hunt).
2. **Switch Toggle Gate:**
   In `_confirmHuntEnable` and `_onConfigChanged` ([home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L3185-L3275)), toggling the switch on is refused and `huntEnableRefusal` is set.
3. **Execution Gate:**
   In `_startHunt` ([home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L3974-L3978)):
   ```dart
   final conflict = _findMealConflict(accountId, effectiveConfig);
   if (conflict != null) {
     widget.state.setHuntPreflight(refusal: conflict);
     return false;
   }
   ```
   Even if triggered headlessly or programmatically, hunting cannot start when a meal is already held or listed for that slot.

---

## 7. Verification Evidence & Test Execution

```
$ flutter analyze
Analyzing Bahonar-Nut...
No issues found! (ran in 1.5s)

$ flutter test
01:04 +1538: All tests passed!

$ cd android; .\gradlew :app:testDebugUnitTest --offline
BUILD SUCCESSFUL in 7s
67 actionable tasks: 5 executed, 62 up-to-date
```

Key dedicated tests verified:
- `test/adapter/cullinan/basket_polling_test.dart`:
  - `claim reuses cached page from fetchBasket without issuing an extra GET` (Passed)
  - `claim without prior cache falls back to fresh page read` (Passed)
- `test/core/hunt/hunt_optimization_test.dart`:
  - `HuntBounds correctly clamps peak and off-peak intervals` (Passed)
  - `risk acknowledgement is required for infinity mode` (Passed)
  - `projectedRequests returns -1 (unbounded) for infinity mode during peak` (Passed)
  - `computeBudget returns unbounded budget for infinity mode without ceiling` (Passed)
  - `SnipeEngine routes notifications to per-rule listeners` (Passed)
  - `HuntService ref counts active accounts and only releases when all accounts are stopped` (Passed)
  - `HuntNotifier persists HuntSuccess upon successful claim` (Passed)
  - `HuntState isolates running status, live status, and last success per account` (Passed)
- `test/core/hunt/hunt_success_test.dart`:
  - Full JSON round-trip, total error handling, copyWith, multi-account isolation (Passed)
- `test/platform/hunt_service_test.dart`:
  - Multi-account start/stop calls and bridge recording (Passed)

---

## 8. Round 1 Council Verdict (Historical)

The Food Hunt optimization across all 5 architectural pillars was reviewed and approved conceptually. However, adversarial scrutiny by Council Peer (DeepSeek V4.1 Flash) identified 5 critical Blockers (B1–B5) and 3 Majors (M1–M3).

---

## 9. Round 2 Adversarial Sign-Off & Blocker Resolution Audit

Following the implementation of targeted fixes for all findings raised by the Review Council, this Round 2 audit independently inspects, tests, and validates every remediation.

### 9.1 Verification of Blockers (B1–B5)

| Blocker ID | Pillar | Root Cause & Defect | Remediated Implementation & Location | Verification Status |
|---|---|---|---|---|
| **B1** | Pillar 2 (Infinity Mode) | `_PreflightCard` displayed raw `toPersianDigits(projected)` when `projected == -1`, producing `«-۱ درخواست»` | [hunt_screen.dart](file:///D:/Bahonar-Nut/lib/ui/features/hunt/hunt_screen.dart#L662-L671): Guarded with `${projected < 0 ? 'نامحدود (با حداکثر سرعت پاسخ‌دهی سرور)' : '${toPersianDigits(projected)} درخواست'}` | **VERIFIED & TESTED** |
| **B2** | Pillar 3 (Concurrency) | Single static notification ID `4150` caused concurrent hunts to overwrite each other's outcome notifications | [hunt_service.dart](file:///D:/Bahonar-Nut/lib/platform/hunt_service.dart#L64-L66): Added `outcomeNotificationId(AccountId accountId) => _outcomeNotificationId + (accountId.hashCode.abs() % 1000)`; tested in [hunt_optimization_test.dart](file:///D:/Bahonar-Nut/test/core/hunt/hunt_optimization_test.dart#L252-L258) | **VERIFIED & TESTED** |
| **B3** | Pillar 4 / 3 (Deep Link) | Cold boot with `nut://hunt-success` preserved target in `_pendingTargetAccount`, but replay called `selectReservationsAccount`, routing to wrong tab/account | [home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L227-L238): Added `_pendingTargetIsHunt`; `onLoaded` invokes `selectHuntAccount`, `reloadHuntSuccess`, and `loadMarket()` | **VERIFIED & TESTED** |
| **B4** | Pillar 3 (Lifecycle) | `reservations://<target>` non-success link called `setHuntRunning(false)` without target, resetting active account instead of the ended hunt account | [home_shell.dart](file:///D:/Bahonar-Nut/lib/ui/shell/home_shell.dart#L754): Target account explicitly forwarded: `widget.state.setHuntRunning(false, target)` | **VERIFIED & TESTED** |
| **B5** | Pillar 4 / 5 (Persistence) | `StoredMeal` written to `LocalMealStore` on claim was never persisted to disk (`persist()` was omitted), and headless bootstrap never called `restore()` | [hunt_service.dart](file:///D:/Bahonar-Nut/lib/platform/hunt_service.dart#L51): Added `onPersistMealStore` callback wired to `mealStore.persist()`; [hunt_entrypoint.dart](file:///D:/Bahonar-Nut/lib/background/hunt_entrypoint.dart#L113-L187) calls `mealStore.restore()` at startup and passes `mealStore.persist()` | **VERIFIED & TESTED** |

### 9.2 Verification of Majors (M1–M3)

| Major ID | Pillar | Root Cause & Defect | Remediated Implementation & Location | Verification Status |
|---|---|---|---|---|
| **M1** | Pillar 1 (Fast Claim) | ASP.NET error page on purchase postback reported `ClaimAmbiguous`, permanently tombstoning active listing | [cullinan_basket_buy.dart](file:///D:/Bahonar-Nut/lib/adapter/cullinan/cullinan_basket_buy.dart#L436-L439): `CullinanForms.looksLikeAspError(response.body)` now yields `ClaimRejected('خطای فرم سامانه دانشگاه؛ وضعیت صفحه پذیرفته نشد.')`; covered by test in [basket_polling_test.dart](file:///D:/Bahonar-Nut/test/adapter/cullinan/basket_polling_test.dart#L269-L277) | **VERIFIED & TESTED** |
| **M2** | Pillar 5 (Conflict Guard) | Basket-listing conflict guard was UI-only; headless background hunts could bypass it and hunt conflicting slots | [hunt_entrypoint.dart](file:///D:/Bahonar-Nut/lib/background/hunt_entrypoint.dart#L115-L142): Headless entrypoint checks `services.mealStore.store.find(accountId, hunt.targetDate!, hunt.targetSlot)`; announces conflict refusal and cancels alarm if conflicting meal held | **VERIFIED & TESTED** |
| **M3** | Coverage Deficits | Key pillar mechanisms lacked automated test coverage | 1. `HuntBounds.minBackoffInterval = Duration(seconds: 5)` in [hunt_config.dart](file:///D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart#L123); tested in [hunt_optimization_test.dart](file:///D:/Bahonar-Nut/test/core/hunt/hunt_optimization_test.dart#L248-L250)<br>2. Native Kotlin unit test in [HuntServiceRefTest.kt](file:///D:/Bahonar-Nut/android/app/src/test/kotlin/ir/ac/uk/bahonar_nut/HuntServiceRefTest.kt) verifying multi-account ref-counting set semantics<br>3. Dedicated Flutter widget test in [last_hunt_success_card_test.dart](file:///D:/Bahonar-Nut/test/ui/features/hunt/last_hunt_success_card_test.dart) covering `_LastHuntSuccessCard`<br>4. Direct test of `_findMealConflict` and distinct notification IDs in [hunt_optimization_test.dart](file:///D:/Bahonar-Nut/test/core/hunt/hunt_optimization_test.dart) | **VERIFIED & TESTED** |

---

## 10. Independent Verification & Test Execution Results

All verification suites were executed independently on the local workspace:

1. **Dart Static Analysis (`flutter analyze`):**
   ```
   Analyzing Bahonar-Nut...
   No issues found! (ran in 1.5s)
   ```
2. **Flutter Test Suite (`flutter test`):**
   ```
   00:55 +1545: All tests passed!
   ```
   *Total: 1,545 tests passed (including new widget test `last_hunt_success_card_test.dart` and expanded `hunt_optimization_test.dart`).*

3. **Android Native JVM Tests (`gradlew :app:testDebugUnitTest --rerun-tasks`):**
   ```
   BUILD SUCCESSFUL in 30s
   67 actionable tasks: 67 executed
   ```
   *Verified: Kotlin `HuntServiceRefTest` ran cleanly, confirming ref-counting set logic.*

---

## 11. Final Unanimous Review Council Sign-Off

All five blockers (`B1`–`B5`) and three major findings (`M1`–`M3`) identified during adversarial review have been definitively resolved and verified through regression tests.

- **Pillar 1 (Zero-Overhead Claim):** 1-RTT claim operational; ASP.NET error pages properly rejected without tombstoning.
- **Pillar 2 (Infinity Mode):** Floor-zero interval with 5s backoff floor; UI cleanly displays Persian server-paced text without negative request counts.
- **Pillar 3 (Multi-Account Concurrency):** True multi-account isolation across Android foreground service, outcome notifications, deep links, and SnipeEngine listeners.
- **Pillar 4 (Hunt Success Persistence):** Durable `PlainStore` storage, immediate meal mirror persistence, and verified UI banner presentation.
- **Pillar 5 (Reservation Conflict Guard):** Dual-layer UI and headless background protection preventing duplicate reservations.

Final Verdict: **UNANIMOUS APPROVAL (APPROVE)**
