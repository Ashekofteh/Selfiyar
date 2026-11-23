# Senior Review Council — Architectural Evaluation & Blueprint
## Bahonar-Nut (Selfiyar) — Food Hunt (شکار) Optimization
**Reviewer:** Senior Review Council — Gemini 3.8 Flash (Antigravity)  
**Date:** 2026-11-23  
**Scope:** 5 Pillars — Network Latency, Infinity (∞) Mode, Multi-Account Concurrency, Hunt-Success Persistence, Conflict Guard  

---

## Executive Summary

The university meal market (بازار سبد غذا) is a high-contention, millisecond-critical environment. In peak distribution hours, available meal listings are claimed within fractions of a second.

Our comprehensive architectural evaluation of `Bahonar-Nut` reveals five core architectural areas that must be upgraded to ensure maximum competitive advantage, complete multi-account independence, and portal compliance:

| # | Pillar | Current State | Target State | Impact |
|---|--------|---------------|--------------|--------|
| **1** | **Zero-Overhead Sniping** | 2–4 HTTP roundtrips per claim (redundant GET & POSTs) | **Exactly 1 HTTP POST** using cached viewstate/form state from the poll | **Latency drops from ~1.5s–3s to ~150ms–300ms** |
| **2** | **Infinity (∞) Mode** | Hard floor of 2s (`HuntBounds.minPeakInterval`) | **0s interval (`Duration.zero`)** — server-paced continuous polling | Zero artificial idle time between requests |
| **3** | **Multi-Account Concurrency** | Single-listener overwrite in engine, global boolean in UI, premature foreground service kill | **Fully isolated per-account hunt runs**, independent UI status maps, and ref-counted Android service | Multiple accounts hunt simultaneously in background & foreground |
| **4** | **Hunt-Success Banner & Deep Link** | Ephemeral dialog on notification click only, no persistence | **Persistent `LastHuntSuccess`** in storage + prominent header card on Hunt Screen | Details (food, hall, price, date) always visible on app resume |
| **5** | **Reservation Conflict Guard** | No prior reservation check for target slot | **LocalMealStore pre-check** for target `(date, slot)` | Prevents illegal double-reservation attempts and futile hunts |

---

## Pillar 1: Network & WebForms Latency Optimization (Zero-Overhead Sniping)

### 1.1 Root Cause of Current Claim Latency
In `lib/adapter/cullinan/cullinan_basket_buy.dart`:
1. Polling via `fetchBasket` retrieves `FoodBasketBuy.aspx` using a single date-filtered POST (`_postDateFilter`), obtaining fresh `__VIEWSTATE`, `__EVENTVALIDATION`, and parsing available listings from `drpFood`.
2. When `DefaultSnipeEngine` detects a winning listing, it calls `claimer.execute(...)`, which calls `CullinanBasketBuy.claim(...)`.
3. Currently, `claim` (lines 262–267) **completely discards** the HTML and form state that `fetchBasket` just retrieved! Instead, it invokes:
   ```dart
   final html = await _readBuyPage(session, parts.date);
   return await _submitBasketRow(session, html, parts);
   ```
4. `_readBuyPage` executes:
   - Request 1: `transport.get(session.account, CullinanPaths.basketBuy)` (HTTP GET!)
   - Request 2: If the default date != listing date, `transport.post` (date-filter POST!)
5. Then `_submitBasketRow` executes:
   - Request 3: If hall differs from default rendered hall, `transport.post` (hall-switch POST!)
   - Request 4: `transport.post` submitting `btnSave` with the selected option!

**Total Penalty:** 2 to 4 HTTP roundtrips. On typical Iranian university mobile networks (200–500ms RTT), this adds **800ms to 2000ms of latency**, during which another user inevitably snatches the food.

### 1.2 Feasibility of "Blind" POST vs Cached-State POST
- **ASP.NET WebForms Architecture:**
  - ASP.NET WebForms requires cryptographic tokens (`__VIEWSTATE` and `__EVENTVALIDATION`).
  - An invented or fabricated POST without these tokens causes ASP.NET to reject the request with HTTP 500 (`Validation of viewstate MAC failed`) or an error page.
  - Furthermore, `__EVENTVALIDATION` validates that the selected value of `drpFood` existed in the rendered control tree on the server.
- **The Optimal 1-RTT Sniping Strategy:**
  - We do **not** need a blind POST. We already have the exact, valid, server-issued `__VIEWSTATE`, `__EVENTVALIDATION`, and page HTML from the poll that detected the listing!
  - By enriching `_BasketFormState` with `lastPageHtml` and `lastPageJalaliDate`, `claim()` checks:
    ```dart
    final cached = _formState;
    final html = (cached != null &&
            cached.belongsTo(session) &&
            cached.htmlIsFor(wantedJalali))
        ? cached.lastPageHtml!
        : await _readBuyPage(session, parts.date);
    ```
  - When matching, `claim()` skips `_readBuyPage` entirely and calls `_submitBasketRow` directly.
  - **Latency reduction:** 2–4 RTTs → **1 single HTTP POST** (~150ms–300ms).

---

## Pillar 2: Sub-2-Second Peak Interval with Infinity (∞) Mode

### 2.1 Semantics of `Duration.zero`
In `HuntBounds`:
- Add `static const Duration infinityInterval = Duration.zero;`
- Update `clampPeak`:
  ```dart
  static Duration clampPeak(Duration interval) {
    if (interval == Duration.zero) return Duration.zero;
    if (interval < minPeakInterval) return minPeakInterval;
    if (interval > maxPeakInterval) return maxPeakInterval;
    return interval;
  }
  ```
- In `DefaultSnipeEngine._runLoop`:
  ```dart
  final elapsed = clock.now().difference(pollStart);
  final remaining = interval - elapsed;
  final sleepDuration = remaining.isNegative ? Duration.zero : remaining;
  if (sleepDuration > Duration.zero) {
    await Future.any([_sleep(sleepDuration), run.cancelled]);
  }
  ```
  When `interval == Duration.zero`, `sleepDuration` is `Duration.zero`. The `if` guard evaluates to `false`, completely bypassing sleep. The next poll initiates immediately after the HTTP response arrives.

### 2.2 Safety & Guardrails
- **Division by Zero:** In `HuntConfig.projectedRequests` and `computeBudget`, protect against `rate.peakInterval.inSeconds == 0` (return budget cap).
- **Request Budget:** The 400-request budget (`defaultRequestBudget`) serves as the ultimate safety backstop to prevent accidental infinite loops.
- **UI Representation:**
  - Discrete slider values: `[Duration.zero, 2s, 5s, 10s, 15s, 20s, 30s, 60s]`.
  - Leftmost label: `∞` (بی‌نهایت).
  - Persian descriptor: «سریع‌ترین حالت: بدون وقفه مصنوعی، با حداکثر سرعت پاسخ سرور».

---

## Pillar 3: Concurrent Multi-Account Hunting Engine

### 3.1 Architectural Deficiencies in Current Code
1. `DefaultSnipeEngine`: Holds a single `HuntOutcomeListener _listener`. Starting Account B overwrites Account A's listener, causing Account A's purchase notification to misroute or drop.
2. `HuntService`: `_releaseService()` calls `bridge.stopHuntService()` on ANY outcome or stop. Stopping Account A kills the Android foreground service for Account B!
3. `HuntState`: Tracks `_huntRunning` as a single `bool` and `_huntStatus` as a single `SnipeRunStatus`. Switching accounts in the UI shows incorrect state.
4. `_HomeShellState`: Manages a single `_huntStatusSub` subscription.

### 3.2 Solution Blueprint
1. **Engine Listener Map:**
   In `DefaultSnipeEngine`:
   ```dart
   final Map<String, HuntOutcomeListener> _listeners = {};
   void setListener(String ruleId, HuntOutcomeListener listener) => _listeners[ruleId] = listener;
   ```
2. **Ref-Counted Service in `HuntService`:**
   ```dart
   final Set<AccountId> _activeHuntingAccounts = {};
   void _releaseServiceIfIdle(AccountId accountId) {
     _activeHuntingAccounts.remove(accountId);
     if (_activeHuntingAccounts.isEmpty) {
       unawaited(_releaseService());
     }
   }
   ```
3. **Per-Account UI State in `HuntState`:**
   ```dart
   final Map<AccountId, bool> _huntRunning = {};
   final Map<AccountId, SnipeRunStatus?> _huntStatus = {};
   bool isHuntRunning(AccountId id) => _huntRunning[id] ?? false;
   SnipeRunStatus? huntStatusFor(AccountId id) => _huntStatus[id];
   ```
4. **Subscription Pool in `_HomeShellState`:**
   ```dart
   final Map<AccountId, StreamSubscription<SnipeRunStatus>> _huntStatusSubs = {};
   ```

---

## Pillar 4: Successful Hunt Persistence, Header Banner, and Deep Link Navigation

### 4.1 Persistence Model (`LastHuntSuccess`)
Store in `PlainStore` under key `hunt_success_$accountId`:
```dart
class LastHuntSuccess {
  final AccountId accountId;
  final String dishName;
  final String hallName;
  final int priceRial;
  final DateTime date;
  final MealSlot slot;
  final DateTime claimedAt;
}
```
- Saved on `HuntNotifier.onClaimed`.
- Loaded in `HuntState.loadConfigs()` into `Map<AccountId, LastHuntSuccess>`.

### 4.2 UI Header Card (`_HuntSuccessBanner`)
Rendered at the top of `HuntScreen` when `lastSuccessFor(activeId) != null` and the account is not actively hunting:
- Celebratory banner with green checkmark.
- Displays: نوع غذا (`dishName`), نوع سلف (`hallName`), قیمت به تومان (`formatTomanPersian(priceRial)`), و تاریخ و وعده شمسی.

### 4.3 Deep Link Navigation
- On clicking the success notification (`nut://hunt-success?...`), `_HomeShellState._handleDeepLink` routes to the Hunt Screen with the account pre-selected and triggers `HuntSuccessDialog`.

---

## Pillar 5: Conflict Guard (Duplicate Reservation Prevention)

### 5.1 Business Logic
Under university portal rules, a student cannot hold two meal reservations for the same meal slot on the same day.
- A user who already holds a weekly reservation or purchased basket item for `(targetDate, targetSlot)` must not be allowed to hunt for that same slot.

### 5.2 Implementation
1. Scan `ReservationsState.mealsFor(accountId)` for any active unconsumed meal where `date == targetDate && slot == targetSlot`.
2. Check `ReservationsState.isListedInBasket(accountId, targetDate, targetSlot)`.
3. If an existing reservation is found:
   - Set `enableRefusal`:
     «شما برای این وعده (${mealSlotPersian(slot)}) در تاریخ (${formatPersianDate(date)}) از قبل غذا رزرو کرده‌اید. طبق قوانین سلف، امکان داشتن دو غذا در یک وعده وجود ندارد.»
   - Disable the Start/Arm button.
   - Display a prominent amber warning card in `HuntScreen`.

---

## Conclusion & Implementation Roadmap

The council unanimously recommends executing this upgrade across three focused stages:
1. **Stage 1 (Domain Core & Engine):** Zero-overhead 1-RTT claim caching, `Duration.zero` (∞) interval support, and multi-account engine listener map.
2. **Stage 2 (Platform & State):** Ref-counted Android service in `HuntService`, per-account maps in `HuntState`, and `LastHuntSuccess` persistence.
3. **Stage 3 (UI Presentation):** `_HuntSuccessBanner` header, infinity slider step, reservation conflict warning card, and notification deep link wiring.
