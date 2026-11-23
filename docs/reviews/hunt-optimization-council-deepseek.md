# Senior Review Council — Architectural Evaluation & Blueprint
## Food Hunt (شکار) Optimization — Five Pillars

> **Reviewer:** DeepSeek V4.1 Flash Free (OpenCode) — independent council member
> **Date:** 2026-11-23
> **Scope:** read-only architectural review of the hunt subsystem; five requested pillars
> **Base:** working tree at `docs/reviews/hunt-optimization-council-claude.md` (untracked), HEAD otherwise clean
> **Method:** symbol-level reading of the adapter, core, UI and Android layers. No product code was modified. This file is the only artefact written.

---

## Executive Summary

The hunt subsystem is unusually well-defended for its age: irreversible purchases, ambiguity, session loss, ban risk and the one-meal invariant are all modelled explicitly. The five requested improvements are therefore **not a rewrite**; four of them are surgical, and the fifth (multi-account) is a lifecycle refactor whose risk is almost entirely in *service ownership*, not in the engine.

Three findings dominate everything else:

1. **The claim path throws away work it already has.** `fetchBasket` ends with a page that is already filtered to the target date, already parsed, and whose `__VIEWSTATE` is already cached in `_formState` — and then `claim` issues a fresh `GET` and re-filters it. The purchase is 2–3 round trips where 1 would do. Section 1 gives the exact, capture-verified repair.
2. **∞ mode is not a bounds change — it is three latent defects.** `Duration.zero` breaks `projectedRequests()` (`Infinity.ceil()` throws), silently disables failure backoff (`0 × 2ⁿ = 0`, so a failing portal is hammered at full speed), and removes the only scheduling yield in the loop. All three must be fixed *before* the sentinel is allowed through `clampPeak`.
3. **A successful hunt never updates the local meal mirror.** `HuntService` is constructed without `onOutcome` (`platform_services.dart:252`), and nothing in `snipe_engine`/`snipe_claimer` writes `mealStore`. The conflict guard of Pillar 5 would therefore be blind to the very purchase it exists to prevent — including a second hunt on the same device. This is the highest-severity finding in this review.

### Verdict

| # | Pillar | Current | Target | Complexity | Risk | Ship order |
|---|--------|---------|--------|------------|------|-----------|
| 1 | Zero-overhead claim | 2–3 RTT | 1 RTT (2 only on a hall mismatch) | Medium | **Medium** (money path) | 4 |
| 2 | ∞ peak mode | floor 2 s | server-paced, budget-bounded | Low–Medium | **High** (ban) | 3 |
| 3 | Concurrent accounts | single listener, single service kill | per-rule listeners, ref-counted service | **High** | High | 5 |
| 4 | Success persistence + banner | transient deep link only | durable per-account record + top banner | Low | Low | 1 |
| 5 | Conflict guard | preflight-only, live-read | local + live, UI-blocking | Low | Medium | 2 |

**Recommended order: 5 → 4 → 2 → 1 → 3.** Pillars 5 and 4 are additive and independently testable; 2 is a small change with outsized safety consequences and should be exercised in production before 1 lands on the money path; 3 is last because it changes lifecycle, not logic, and every other pillar is easier to verify while hunts are still single-account.

### What this review disagrees with in the sibling report

`hunt-optimization-council-claude.md` reaches broadly the same five conclusions. Detailed divergences are collected in **§7**; the material ones are: `__EVENTVALIDATION` is **not** required by this portal (the live purchase capture proves it), the cached-page fast path is **unsafe across a two-hall merge** unless gated on the listing's own hall, the Android service **does** need changes (Dart-side ref-counting is not durable across process death), and the preflight cache in `home_shell` is a **single account slot** that silently lets a second account skip preflight.

---

## 0. Verified ground truth

Everything in this report is anchored to the following, all read directly from the tree:

| Fact | Evidence |
|---|---|
| A steady-state poll is **one** request (date-filter POST using cached state) | `cullinan_basket_buy.dart:109-146` |
| The poll's final HTML is discarded; `BasketPage` carries only listings + cursor | `portal_models.dart:213-223` |
| `claim` always re-reads: `GET` then, if the date differs, a filter `POST` | `cullinan_basket_buy.dart:262`, `:291-316` |
| `_readBuyPage` never uses the cached `_formState`; it builds a fresh state from its own `GET` | `cullinan_basket_buy.dart:291-316` |
| The purchase body **omits** `__EVENTVALIDATION` | `cullinan_parser.dart:439-497` |
| The real captured purchase body also omits it | `captures/82_buy_post_body.txt` (no `__EVENTVALIDATION` key) |
| Hall switching is a separate, optional read-only `POST` | `cullinan_basket_buy.dart:339-370` |
| Success = row amount non-zero, not option disappearance | `cullinan_basket_buy.dart:318-325`, `cullinan_parser.dart:1735` |
| `_intervalFor` multiplies base by `2^failures` | `snipe_engine.dart:704-714` |
| The loop skips the sleep entirely at `Duration.zero` | `snipe_engine.dart:629-636` |
| `projectedRequests()` divides by `peakInterval.inSeconds` unguarded | `hunt_config.dart:641-652` |
| `computeBudget()` **does** guard the zero divisor | `hunt_config.dart:404-413` |
| One `HuntOutcomeListener` field for the whole engine | `snipe_engine.dart:187-190` |
| Four separate unconditional service releases | `hunt_service.dart:79`, `:113`; `home_shell.dart:4029`; `hunt_entrypoint.dart:308` |
| Preflight pass cache is a single `(account, time)` pair | `home_shell.dart:3952-3955` |
| `HuntService` is built with no `onOutcome` | `platform_services.dart:252-256` |
| Hunt success writes nothing to `mealStore` | no `mealStore.put` in `snipe_engine.dart`, `snipe_claimer.dart`, `hunt_service.dart` |
| The Start button ignores `enableRefusal` | `hunt_screen.dart:1851`, `:1886` |

---

# Pillar 1 — Zero-overhead claim

## 1.1 What the money path actually costs

Request accounting for one detected match, **as written today**:

| Step | Request | Why it exists |
|---|---|---|
| Poll N | `POST basketBuy` (date filter) | steady state, uses `_formState` |
| — match found — | | |
| 1 | `GET basketBuy` | `_readBuyPage` re-establishes page |
| 2 | `POST basketBuy` (date filter) | only if the default date ≠ target date |
| 3 | `POST basketBuy` (`drpSelf` switch) | only if the row is rendered for another hall |
| 4 | `POST basketBuy` (`btnSave`) | **the purchase** |

So the claim is **2 RTT minimum, 3 typical, 4 worst case** — and every one of steps 1 and 2 re-derives state the adapter held microseconds earlier. The end-to-end delay a student experiences is:

```
interval (2 s at peak)  +  claim RTTs (2–4 × RTT)
```

The brief's "2–4 s" is the *total* at a 2 s cadence with 300–500 ms RTTs. The claim's own share is the 2–3 wasted round trips, which is the only part worth attacking: the poll interval is a deliberate product decision and must not be shortened by accident.

## 1.2 Why `claim` discards what it just fetched

Three independent design decisions produce the waste:

1. **`BasketPage` is lossy by design.** It exposes `listings` and `cursor` only (`portal_models.dart:213-223`). The HTML, and therefore the `__VIEWSTATE` the POST must carry, stops at the adapter boundary.
2. **`_formState` is a private poll cache, not a claim input.** Its doc comment (`cullinan_basket_buy.dart:30-44`) is explicit that it exists to halve poll traffic. `_readBasketHtml` consults it; `_readBuyPage` does not.
3. **`claim` is written to be self-contained.** Its `try` block (`:260-278`) begins with `_readBuyPage`, and its `finally` nulls `_formState` because "a claim changes the page's server-side form state". That reasoning is correct about *invalidation*, but it was applied to the read it never needed to perform.

The cost is not theoretical: between the poll that saw the listing and the POST that buys it, a contested listing can be taken by someone else. Every saved round trip is directly a probability of winning.

## 1.3 Is a blind POST feasible? (ASP.NET WebForms mechanics)

A true blind POST — inventing tokens — is **not** feasible, and the code should never attempt it:

- **`__VIEWSTATE`** is a signed, base64 blob of the control tree. A stale blob from a previous *session* is rejected (MAC failure) or silently replaced with a fresh default page (200 OK, no purchase). It is unguessable and unforgeable.
- **`__VIEWSTATEGENERATOR`** is derived from the page type; it is stable, and the parser already reads it.
- **`drpFood` option ids** are **not** stable across dates: the same dish is `62737` in the weekly grid and `62798` on the buy page (the code documents this at `hunt_config.dart:185-189`). They *are* stable within one rendered page and one session.
- **`__EVENTVALIDATION`** is the field most often assumed to be mandatory. **It is not present in this portal's purchase body.** `claimFormBody` deliberately omits it (`cullinan_parser.dart:445-451`), while `hallSwitchBody` conditionally adds it (`:521-524`) — an asymmetry that reflects what the live server accepted, not an oversight. The captured successful purchase (`captures/82_buy_post_body.txt`) contains no `__EVENTVALIDATION` key at all. **Any plan that starts adding it "for safety" is adding a field the server never asked for and risks a postback rejection.**

So the correct framing is not *blind* POST but **cached-state** POST: reuse the exact `__VIEWSTATE` / `__VIEWSTATEGENERATOR` that came back with the page which offered the listing, for the same session and the same date. That is already proven to work — it is precisely what `_postDateFilter` does on every poll.

## 1.4 The design: a claim ticket, not a hidden cache

The tempting fix is "put the HTML in `_formState` and read it in `claim`". This review recommends **against** it, for two reasons:

- `_formState` is mutable adapter-global state. `SerialisedPortalClient` guarantees one operation at a time per account, but the ticket must be *provably* the page that produced the winning listing; an implicit cache cannot prove that.
- After a two-hall merge, the last page in `fetchBasket` is the **second** hall's render (`:83-102`). A listing from the first hall is not in that page's `drpFood`, so `claimFormBody` would return `null` and the claim would be rejected — a regression disguised as an optimisation.

Instead, thread an explicit, immutable snapshot from the poll to the claim.

### Step A — extend the port model

```dart
// lib/core/portal/portal_models.dart

/// The page a listing was read from, so a claim can post against the exact
/// form state that offered it instead of re-reading the page.
///
/// [html] is opaque to callers above the adapter; it is carried, not parsed.
/// [jalaliDate] and [hallId] say which page it is, because those are the two
/// things a purchase POST must agree with.
class BasketSnapshot {
  const BasketSnapshot({
    required this.html,
    required this.jalaliDate,
    required this.hallId,
    required this.accountId,
    required this.capturedAt,
  });

  final String html;
  final String jalaliDate;

  /// The hall the page's `drpFood` lists were rendered for, or null when the
  /// page offered no identifiable hall.
  final HallId? hallId;

  final AccountId accountId;
  final DateTime capturedAt;

  bool isFreshFor({required Duration maxAge, required DateTime now}) =>
      now.difference(capturedAt) <= maxAge;
}

class BasketPage {
  const BasketPage({required this.listings, this.cursor, this.snapshot});
  final List<Listing> listings;
  final String? cursor;
  final BasketSnapshot? snapshot;   // NEW
  bool get hasMore => cursor != null;
}
```

### Step B — emit the snapshot from `fetchBasket`

At the end of `fetchBasket` (`cullinan_basket_buy.dart:104`), the local `page` variable already holds the last rendered HTML and `wanted` holds its Jalali date. Emit both:

```dart
return BasketPage(
  listings: merged,
  snapshot: BasketSnapshot(
    html: page,
    jalaliDate: wanted,
    hallId: _renderedHallOf(page),      // read drpSelf's selected value from any row
    accountId: session.account,
    capturedAt: clock.nowUtc,
  ),
);
```

Because `hallSwitchBody` preserves every row (`cullinan_parser.dart:541-547`), `drpSelf`'s selected value on the returned page *is* the hall that page was rendered for. That is the gate the claim needs.

### Step C — accept the ticket in `claim`

The port signature changes from

```dart
Future<ClaimResult> claim(Session session, ListingId listingId);
```

to

```dart
Future<ClaimResult> claim(
  Session session,
  ListingId listingId, {
  BasketSnapshot? snapshot,
});
```

and the implementation becomes:

```dart
Future<ClaimResult> claim(
  Session session,
  ListingId listingId, {
  BasketSnapshot? snapshot,
}) async {
  applySession(session);
  final parts = _parseListingId(listingId);
  if (parts == null) return const ClaimRejected('شناسه آگهی معتبر نیست.');

  final wanted = CullinanForms.jalaliOf(parts.date);
  final now = clock.nowUtc;

  // The snapshot is usable only when every one of these holds. Any failure
  // falls back to today's behaviour, which is correct — just slower.
  final usable = snapshot != null &&
      snapshot.accountId == session.account &&
      snapshot.jalaliDate == wanted &&
      snapshot.isFreshFor(
        maxAge: const Duration(seconds: 15),
        now: now,
      );

  try {
    final html = usable ? snapshot.html : await _readBuyPage(session, parts.date);

    // Hall gate. When the snapshot was rendered for another hall, the row's
    // drpFood does not contain this listing, and posting it would make the
    // portal substitute that hall's first option — a wrong, irreversible buy.
    // _submitBasketRow already handles this by switching first; we simply
    // must not claim the snapshot is enough.
    return await _submitBasketRow(session, html, parts);
  } on TransportException catch (e) {
    return ClaimAmbiguous(e.message);
  } finally {
    _formState = null;
  }
}
```

`_submitBasketRow` needs no change: it already checks `_offeredListing` and issues the read-only `drpSelf` switch when the page is not rendered for the listing's hall (`:339-370`). With a snapshot, that path now costs **1 POST (same hall) or 2 POSTs (hall switch)** instead of 2–4 requests.

### Step D — pass it from the engine

The snapshot rides on the page that produced the winning listing. In `_pollOnce`, the ranker returns a `Listing`; carry the snapshot alongside it just long enough to claim:

```dart
// snipe_engine.dart, in _pollOnce after ranking
final winner = result.best;
if (winner != null) {
  await _claim(run, activeSession, winner, page.snapshot);
}
```

and in `_claim`/`SnipeClaimer.execute`, forward it to `_client.claim(session, listing.id, snapshot: snapshot)`. `SnipeClaimer.execute` is the only caller of `claim` (`snipe_claimer.dart:154`), so the plumbing is one extra parameter through one function.

### Step E — invalidation rules (all already satisfied)

| Mutation | Effect on ticket | Handled by |
|---|---|---|
| Poll writes a new page | ticket replaced next poll | snapshot is per-page |
| Claim runs | ticket consumed | engine drops it after `_claim` |
| Session refresh | `accountId` matches, but `__VIEWSTATE` is session-bound | `isFreshFor` + server rejection → fallback path next time |
| Hall merge | snapshot is the last hall only | `_offeredListing`/switch path |
| A second account | `accountId` gate | explicit |

**The one thing that must be added:** the ticket must be a *local* in `_pollOnce`, never stored on `_Run`. Persisting it across polls would reintroduce exactly the staleness the ticket is designed to bound.

## 1.5 Safety analysis of the fast path

The dangerous claim is "the page is stale, so the purchase is wrong". The ticket is gated on:

- **same account** — `__VIEWSTATE` is signed per session; a cross-account post is already rejected by the existing `belongsTo` logic;
- **same Jalali date** — the failure mode `_readBuyPage` guards against at `:304-314` (`txtDate` must agree with the rows);
- **freshness window** — 15 s is deliberately *larger* than one peak poll (2 s) and smaller than any plausible re-render cycle; tune from instrumentation, not intuition;
- **hall agreement** — enforced by the existing `claimFormBody` second-layer guard (`cullinan_parser.dart:478-482`), which returns `null` for a row not rendered for that hall. A null answer becomes a `ClaimRejected` *before any write leaves the device*, which is the property that makes this whole pillar safe.

No new failure mode is introduced. Every path that would have been unsafe is already rejected by code that exists today; the fast path only removes a read.

## 1.6 Instrumentation (do this first)

The 2–4 RTT figure is structural, not measured. Before shipping, add a stopwatch at the three boundaries and record into `SnipeLedger`:

```dart
// poll → match
// match → claim request sent
// claim request sent → ClaimResult
```

Persian ledger line, e.g. `'تأخیر شکار: ۰٫۳ ثانیه'`. Without this, no one can prove the optimisation worked, and the 15 s freshness bound is a guess.

## 1.7 Tests

- **Unit, adapter:** fake transport records calls; seed a `fetchBasket`, then `claim(..., snapshot: page.snapshot)`; assert **zero** `GET` and **one** `save` POST.
- **Unit, adapter:** same, but the listing's hall differs from `snapshot.hallId`; assert one `drpSelf` POST then one `save`, and still no `GET`.
- **Unit, adapter:** snapshot from account A used for account B; assert fallback re-read (two requests).
- **Unit, adapter:** snapshot older than `maxAge`; assert fallback.
- **Regression:** `claim` without a snapshot behaves exactly as today (existing `basket_purchase_test.dart` must pass untouched).
- **Capture replay:** replay `captures/82_buy_post_body.txt`'s fields through `claimFormBody` and assert the produced body still has no `__EVENTVALIDATION` and includes every `chkReserve`/`drpSelf`/`drpFood`/`drpFoodCount` row.

---

# Pillar 2 — ∞ peak mode

## 2.1 Where the floor lives

`HuntBounds.minPeakInterval = 2 s` (`hunt_config.dart:83`) is enforced in three places that must agree:

1. `HuntBounds.clampPeak` (`:120-124`) — called by `HuntRate`'s constructor (`:148`);
2. `HuntRate.copyWith` (`:172-176`) — re-clamps via the constructor;
3. `_IntervalSlider`'s `min:` (`hunt_screen.dart:1614`).

Because the clamp is at construction, the engine cannot receive an out-of-range value — which is exactly the property ∞ must preserve while adding `zero` as a legal value.

## 2.2 `Duration.zero` in the poll loop: verified semantics

The loop (`snipe_engine.dart:609-636`) is fixed-rate: it computes `remaining = interval - elapsed`, clamps to zero, and skips the `Future.any` when the remainder is not positive. With `interval == Duration.zero`:

```dart
final remaining = Duration.zero - elapsed;      // negative
final sleepDuration = remaining.isNegative ? Duration.zero : remaining;
if (sleepDuration > Duration.zero) { ... }      // never entered
```

So yes — `zero` means "as fast as the server answers", with no special-casing. That part of the sibling analysis is correct. But the sentinel is **not** free, and three defects appear the moment it is allowed through the clamp.

## 2.3 The three defects ∞ exposes

### Defect A — `projectedRequests()` throws

```dart
// hunt_config.dart:647-651
final requests =
    (peak / rate.peakInterval.inSeconds +
        offPeak / rate.offPeakInterval.inSeconds) *
    hallMultiplier;
return requests.ceil();
```

With `peakInterval == 0`, `peak / 0` is `double.infinity` (or `NaN` when `peak` is also 0), and `.ceil()` on either throws `UnsupportedError: Infinity or NaN toInt`. This is called from `_RateCard` (`hunt_screen.dart:1601`) and `_EnabledCard` (`:430`) — i.e. **the screen crashes as soon as the slider reaches ∞**. `computeBudget` already guards its divisor (`:409-410`), so the two functions disagree; that asymmetry is the bug.

### Defect B — failure backoff silently vanishes

```dart
// snipe_engine.dart:704-714
var interval = base;
if (consecutiveFailures > 0) {
  final multiplier = 1 << min(consecutiveFailures, 30);
  final backedOff = base * multiplier;
  interval = backedOff > _defaultPolicy.maxBackoff ? _defaultPolicy.maxBackoff : backedOff;
}
```

`0 × 2ⁿ = 0`. In ∞ mode a portal outage produces a **tight failure loop against a failing server** — the exact behaviour that gets an account flagged, at the exact moment the portal is least able to take it. The existing 5-failure circuit breaker (`:590-604`) will eventually open, but not before the requests are sent.

**This must be fixed before ∞ ships.** The backoff must have its own floor:

```dart
static const Duration minBackoffInterval = Duration(seconds: 5);

if (consecutiveFailures > 0) {
  final effectiveBase =
      base > Duration.zero ? base : HuntBounds.minBackoffInterval;
  final multiplier = 1 << min(consecutiveFailures, 30);
  final backedOff = effectiveBase * multiplier;
  interval = backedOff > _defaultPolicy.maxBackoff
      ? _defaultPolicy.maxBackoff
      : backedOff;
}
```

### Defect C — the loop can spin without yielding

The only `await` inside an iteration is `_pollOnce` and the optional sleep. With ∞ and a synchronously-failing `_pollOnce` (session unavailable, transport throwing before any I/O), the loop is a hot CPU spin. Each iteration does call `await _pollOnce`, and an `async` function that returns without awaiting still yields to the microtask queue — but a **microtask** queue is not a scheduler yield, and the event loop can starve timers and the platform channel.

Add an explicit floor to the *yield*, not the *rate*:

```dart
if (sleepDuration > Duration.zero) {
  await Future.any([_sleep(sleepDuration), run.cancelled]);
} else {
  await Future<void>.delayed(Duration.zero);   // let the event loop breathe
}
```

This is negligible (sub-millisecond) against a network round trip and removes the pathological case entirely.

## 2.4 Bounds and rate changes

```dart
abstract final class HuntBounds {
  /// The sentinel for "no artificial wait": poll at the portal's own pace.
  ///
  /// Not a rate. It is bounded by [defaultRequestBudget], by the circuit
  /// breaker, and by the transport's timeout — never by the clock.
  static const Duration infinityInterval = Duration.zero;

  static bool isInfinity(Duration interval) => interval == Duration.zero;

  /// Fastest *clock-paced* peak interval. ∞ is the only value below it.
  static const Duration minPeakInterval = Duration(seconds: 2);
  static const Duration maxPeakInterval = Duration(seconds: 60);

  static Duration clampPeak(Duration interval) {
    if (interval == infinityInterval) return infinityInterval;
    if (interval < minPeakInterval) return minPeakInterval;
    if (interval > maxPeakInterval) return maxPeakInterval;
    return interval;
  }

  static Duration clampOffPeak(Duration interval) {
    // Off-peak is never ∞: it exists to make the hunt quiet, and an ∞
    // off-peak hunt is a hunt with no quiet hours at all.
    if (interval < minOffPeakInterval) return minOffPeakInterval;
    if (interval > maxOffPeakInterval) return maxOffPeakInterval;
    return interval;
  }
}
```

`HuntBounds.needsRiskAcknowledgement(Duration.zero)` is already true (`0 < 10 s`), so ∞ inherits the existing modal — correct, and no change is needed.

`projectedRequests()` must stop pretending:

```dart
/// The requests the hunt is projected to make, or null when the peak rate is
/// ∞ and the count is therefore bounded only by [requestBudget].
int? projectedRequests() {
  if (HuntBounds.isInfinity(rate.peakInterval)) return null;
  ...
}
```

A nullable return forces every caller to decide what to say, which is better than a sentinel number that reads as "zero requests". Call sites: `_EnabledCard:430`, `_RateCard:1601`, `_describeReady` in `home_shell:4069`, `confirmRiskAcknowledgement:2006`. Render `'تا سقف ۴۰۰ درخواست (بی‌وقفه)'` in Persian for the null case, using `toPersianDigits(config.requestBudget)`.

`HuntConfig.copyWith` recomputes the budget whenever the rate changes (`:694-705`). With ∞, `computeBudget` returns `max(…, 400)` = 400, which is correct but should be documented as "the budget is the only governor".

## 2.5 The slider

The current `_IntervalSlider` is log-scaled (`_positionOf`/`_durationAt`, `hunt_screen.dart:1746-1765`) — `_log(0)` is `-∞`, so a zero stop cannot be represented: `lo` becomes `-∞`, the `(v−lo)/(hi−lo)` ratio becomes `NaN`, and `Slider` asserts on a `NaN` value. Do not patch the log scale; give the peak slider a **discrete stop list**:

```dart
const _peakStops = <Duration>[
  HuntBounds.infinityInterval,        // ∞
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

String _formatPeak(Duration d) =>
    HuntBounds.isInfinity(d) ? '∞' : '${toPersianDigits(d.inSeconds)} ثانیه';
```

The ∞ stop must render an explicit Persian caption under the slider, not only a symbol:

> «بی‌وقفه — تا وقتی سرور پاسخ می‌دهد، بی‌درنگ درخواست بعدی فرستاده می‌شود. سقف درخواست و قطع‌کننده ایمنی همچنان فعال است.»

and the accent colour must be the error band (`_accentFor` already does this for `< 10 s`, so ∞ inherits red — correct).

The off-peak slider keeps the log scale and its 30 s floor. **∞ off-peak is not offered.**

## 2.6 Backstops, in the order they bind

| Backstop | Where | ∞ behaviour |
|---|---|---|
| Per-request timeout | transport | unchanged; a slow server *is* the rate limit |
| Circuit breaker, 5 consecutive failures | `snipe_engine.dart:590-604` | trips in seconds; good |
| Failure backoff with a floor | new, §2.3-B | 5 s → doubling to `maxBackoff` |
| Request budget, 400 | `hunt_config.dart:117`, enforced by `RequestLedger` | **the only hard cap**; ~80 s at 200 ms/RTT |
| Session loss | `LoginRejectedException` → re-auth (`:1059-1074`) | unchanged |
| Window close | `isWithinWindow` | unchanged |

**Do not raise `defaultRequestBudget` for ∞.** The sibling review suggests "1000+"; this review disagrees. The budget exists to bound *the pattern the portal sees*, and that pattern is exactly what gets an account banned. The honest UI says "∞ is capped at the budget", not "∞ is uncapped". A user who wants more requests per window should widen the window, which is visible and deliberate.

## 2.7 Tests

- `projectedRequests()` with ∞ returns `null`; with 2 s returns a finite positive int.
- `HuntRate(peakInterval: Duration.zero).peakInterval == Duration.zero`; `Duration(milliseconds: 500)` clamps to 2 s.
- `clampOffPeak(Duration.zero) == 30 s` (∞ is peak-only).
- Engine: inject `sleep` that records durations; ∞ base + 3 failures ⇒ sleeps grow 5 s, 10 s, 20 s, **not** 0.
- Engine: ∞ base + `_pollOnce` returning immediately 1000× ⇒ the loop yields (assert `_sleep(Duration.zero)` or `delayed(Duration.zero)` observed at least once).
- Budget: ∞ hunt stops at exactly `requestBudget` requests.
- Widget: pump `_RateCard` with ∞ and assert no exception and the string `'∞'`.

---

# Pillar 3 — Concurrent multi-account hunting

## 3.1 Defect inventory

This is larger than the three fields the brief names. Seven defects, ordered by severity:

| # | Defect | Evidence | Consequence |
|---|---|---|---|
| D1 | **Headless release kills every account** | `hunt_entrypoint.dart:138`, `:170` → `_releaseService` → `stopHuntService()` | account A finishing headless stops account B's hunt and its notification |
| D2 | **`HuntService.stop` releases unconditionally** | `hunt_service.dart:79` | stopping A stops B |
| D3 | **`reportOutcome` releases unconditionally** | `hunt_service.dart:113` | a natural end for A stops B |
| D4 | **Single `engine.listener`** | `snipe_engine.dart:187-190`; set at `home_shell:3984` and `hunt_entrypoint:145` | B's notifier replaces A's; A's purchase is announced to B's account, or to the no-op listener |
| D5 | **Single `_huntStatusSub`** | `home_shell:4017-4020`, `:3990`, `:4003` | subscribing B cancels A's live status |
| D6 | **Global `_huntRunning` / `_huntStatus`** | `hunt_state.dart:34`, `:37`, `:209-220` | switching accounts shows the wrong run; one end clears both |
| D7 | **Preflight pass cache is one slot** | `home_shell:3952-3955` (`_lastPreflightAccount`, `_lastPreflightPassTime`) | **safety**: pass preflight for A, then start B within 15 s ⇒ B skips preflight entirely, including the already-held-meal check |

D7 is not on the requested list but is the most dangerous interaction with Pillar 5: a conflict guard that can be bypassed by starting a second account quickly is not a guard.

Two structural facts make the fix tractable:

- `_runs`, `_ledgers` and `_huntConfigs` are **already keyed by rule id** (`snipe_engine.dart:237-241`), and the rule id already encodes the account (`'hunt-$accountId'`, `hunt_service.dart:94`). The engine is 90 % multi-account already.
- `SerialisedPortalClient` already serialises **per account**, so two accounts can run genuinely concurrently without interleaving their WebForms chains.

## 3.2 Layer 1 — engine: per-rule listeners

Keep the existing `listener` as the default for rules that set none (tests and plain rules depend on it), and add a map:

```dart
// snipe_engine.dart
HuntOutcomeListener _listener;                       // unchanged fallback
final Map<String, HuntOutcomeListener> _listeners = {};

@override
void setListener(String ruleId, HuntOutcomeListener value) =>
    _listeners[ruleId] = value;

HuntOutcomeListener _listenerFor(String ruleId) =>
    _listeners[ruleId] ?? _listener;

@override
void clearListener(String ruleId) => _listeners.remove(ruleId);
```

Add `setListener`/`clearListener` to the `SnipeEngine` interface (`:90-119`). Replace **every** `_listener.onX` call site — thirteen of them (`:431`, `:452`, `:464`, `:540`, `:569`, `:597`, `:780`, `:794`, `:959`, `:1232`, `:1252`, `:1269`, `:1287`) — with a single local lookup at the top of the method that emits:

```dart
final listener = _listenerFor(rule.id);
```

`_claim` already resolves the listener at call time for exactly this reason (`:1218-1220`); that comment becomes the general rule. Clear the entry in `_runLoop`'s `finally` so a finished account does not leak a notifier.

**Why a map and not a per-run field:** the run object is created before the listener is assigned on the in-app path (`home_shell:3984` precedes `hunts.start` at `:4016`), and the headless path may attach after construction. A map keyed by rule id decouples assignment from run creation, which both callers need.

## 3.3 Layer 2 — service ownership: make Kotlin authoritative

The sibling review proposes a Dart-side ref count in `HuntService` and "no Kotlin changes". That is fragile in exactly the cases that matter:

- the headless hunt runs in a **second Dart VM** whose `HuntService` instance knows nothing about the app's;
- the app process can be killed between a hunt ending and its release;
- `reportOutcome` and `stop` can both fire for the same run (a user pressing Stop after the run naturally ended), double-decrementing any `int`.

**The foreground service is the only component guaranteed to outlive the Dart side.** Ownership belongs there.

### Kotlin (`HuntService.kt`)

```kotlin
companion object {
    const val ACTION_START = "ir.ac.uk.bahonar_nut.HUNT_START"
    const val ACTION_STOP  = "ir.ac.uk.bahonar_nut.HUNT_STOP"
    const val EXTRA_PAYLOAD = "payload"
    const val EXTRA_FROM_DART = "fromDart"

    private const val FOREGROUND_ID = 4201

    /** Accounts whose hunt currently needs this process alive. */
    private val active = linkedSetOf<String>()

    fun start(context: Context, payload: String?, fromDart: Boolean = false) {
        if (payload != null) active.add(payload)
        val intent = Intent(context, HuntService::class.java).apply {
            action = ACTION_START
            if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
            putExtra(EXTRA_FROM_DART, fromDart)
        }
        context.startForegroundService(intent)
    }

    /**
     * Releases one account, or the whole service when [accountId] is null
     * (an explicit user "stop everything").
     *
     * A null account also clears the set: the caller asked for the service
     * to be gone, not for one hunt to be gone.
     */
    fun stop(context: Context, accountId: String? = null) {
        if (accountId == null) {
            active.clear()
            context.stopService(Intent(context, HuntService::class.java))
            return
        }
        active.remove(accountId)
        if (active.isEmpty()) {
            context.stopService(Intent(context, HuntService::class.java))
        } else {
            // Someone is still hunting: refresh the count, do not stop.
            PlatformChannelMessenger.refreshServiceNotification(active.size)
        }
    }
}
```

`onStartCommand` adds `payload` to `active` and calls `startForeground(FOREGROUND_ID, notifier.buildServiceNotification(activeCount = active.size))`. The notification becomes an aggregate — «پایش سبد غذا — ۲ حساب» — which is honest and does not require one notification per account (the per-account detail lives in the outcome notification, which already carries the account).

`onDestroy` clears `active` (the process is gone; nothing is hunting).

### Dart (`platform_bridge.dart`, `hunt_service.dart`, `hunt_entrypoint.dart`)

- `stopHuntService({AccountId? accountId})` forwards `{'accountId': accountId}`.
- `HuntService.stop(accountId)` → `_releaseService(accountId)`.
- `HuntService.reportOutcome(accountId: …)` → `_releaseService(accountId)`.
- Headless `_releaseService(bridge, accountId)` — **D1's fix** — passes the account.
- `home_shell._releaseHuntService()` → `stopHuntService(accountId: accountId)`.

No `int` counter anywhere. Removal from a set is idempotent, so the Stop-after-natural-end case is harmless, and the headless VM and the app VM converge on the same Kotlin set.

## 3.4 Layer 3 — state: per-account maps

```dart
// hunt_state.dart
final Map<AccountId, bool> _huntRunning = {};
final Map<AccountId, SnipeRunStatus?> _huntStatus = {};

bool huntRunningFor(AccountId id) => _huntRunning[id] ?? false;
SnipeRunStatus? huntStatusFor(AccountId id) => _huntStatus[id];

/// The active account's view — the getters the screen already uses.
bool get huntRunning =>
    _activeHuntAccount != null && huntRunningFor(_activeHuntAccount!);
SnipeRunStatus? get huntStatus =>
    _activeHuntAccount == null ? null : huntStatusFor(_activeHuntAccount!);

void setHuntRunning(AccountId id, bool value) {
  if ((_huntRunning[id] ?? false) == value) return;
  _huntRunning[id] = value;
  if (!value) _huntStatus.remove(id);
  notifyListeners();
}

void setHuntStatus(AccountId id, SnipeRunStatus? status) {
  _huntStatus[id] = status;
  notifyListeners();
}
```

`selectHuntAccount` must no longer clear the *global* preflight fields in a way that erases another account's refusal — it should clear only the fields it owns for the newly selected account, or the per-account refusals must also be mapped. The minimal correct change: keep `_huntPreflightSummary/Refusal/EnableRefusal` as the **active account's** values and recompute them on selection (§3.6), rather than treating them as global truth.

## 3.5 Layer 4 — subscriptions

```dart
// home_shell.dart
final Map<AccountId, StreamSubscription<SnipeRunStatus>> _huntStatusSubs = {};

void _watchHunt(AccountId accountId) {
  unawaited(_huntStatusSubs.remove(accountId)?.cancel());
  _huntStatusSubs[accountId] =
      widget.services.engine.watch('hunt-$accountId').listen((status) {
    if (mounted) widget.state.setHuntStatus(accountId, status);
  });
}
```

Call `_watchHunt` from `_startHunt` **before** `hunts.start` (the engine's `watch` returns `Stream.empty()` when the run does not exist yet — `snipe_engine.dart:268-269` — so subscribing after `start` is currently load-bearing; subscribe after `start` as today, but keyed by account). Cancel every subscription in `dispose`.

`_handleDeepLink` (`:769`) calls `widget.state.setHuntRunning(false)` with no account. Change to the parsed `account`, and when absent clear only the active account.

## 3.6 Layer 5 — preflight cache (D7)

```dart
final Map<AccountId, DateTime> _lastPreflightPass = {};
...
final passed = _lastPreflightPass[accountId];
final recentlyChecked = passed != null &&
    DateTime.now().difference(passed).inSeconds < 15;
...
_lastPreflightPass[accountId] = DateTime.now();
```

The 15 s window itself deserves scrutiny for the money path: it exists to avoid a duplicate preflight when the switch flip and the Start press both fire. With Pillar 5's local conflict check in place, the window can safely shrink to 5 s, and it must never span an account change. If a local conflict is detected, the cache is ignored regardless of age.

## 3.7 Request-storm and ban considerations

Concurrency multiplies the pattern the portal sees from **one IP and one device**. The budget is per account (`hunt_config.dart:113-117`), so two accounts double it. Recommendations:

- **Stagger starts**: `HuntService.start` for account N waits `N × 1.5 s` before `engine.start`, so N accounts never open their windows in the same frame.
- **Device-wide visibility**: the hunt screen shows all running accounts (`«۲ شکار فعال»`) so the student knows the aggregate load.
- **Do not** share sessions across accounts; `Transport` already keys jars per account and must keep doing so.
- **Cap the default concurrency** at 2 in the UI ("شکار هم‌زمان برای بیش از دو حساب توصیه نمی‌شود") — a warning, not a hard limit; the product may have a legitimate three-account user.

## 3.8 Tests

- Engine: start two rules, attach two listeners, fire `onClaimed` for each; assert each listener saw its own `ruleId` and account.
- Engine: assert `_listeners` is empty after both runs end.
- `HuntService`: fake bridge; start A, start B, stop A ⇒ `stopHuntService` **not** called; stop B ⇒ called once, with B's id.
- `HuntService`: A ends naturally (`reportOutcome`) while B runs ⇒ not called.
- Headless: `_releaseService(bridge, A)` while B active ⇒ not called (D1).
- Kotlin: unit test `active` set semantics (add twice ⇒ one entry; stop unknown id ⇒ no stop; stop last ⇒ stop).
- State: `setHuntRunning(A, true)` then `setHuntRunning(B, true)` then `setHuntRunning(A, false)` ⇒ `huntRunningFor(B)` still true.
- Shell: two `_watchHunt` calls keep two subscriptions; disposing cancels both.
- Preflight cache: pass for A, start B ⇒ preflight runs for B (D7 regression).

---

# Pillar 4 — Success persistence, banner, deep link

## 4.1 The record

```dart
// lib/core/hunt/hunt_success.dart
class HuntSuccess {
  const HuntSuccess({
    required this.accountId,
    required this.dishName,
    required this.hallName,
    required this.priceRial,
    required this.date,
    required this.slot,
    required this.claimedAt,
  });

  final AccountId accountId;
  final String dishName;      // نوع غذا
  final String hallName;      // نوع سلف
  final int priceRial;        // قیمت غذا (displayed in Toman)
  final DateTime date;
  final MealSlot slot;
  final DateTime claimedAt;

  Map<String, Object?> toJson() => { ... };
  static HuntSuccess? fromJson(AccountId id, Map<String, Object?> json) { ... }
}
```

`fromJson` must be **total**: a malformed or partially-written record returns `null`, never throws. A corrupt preference must not break the hunt screen.

## 4.2 The store — follow the existing seam

The codebase already has the right pattern: an abstract store in `core`, a `Plain…` implementation in `platform`, injected into the state. Adding `HuntConfigStore`-style persistence is the low-risk choice:

```dart
// lib/core/hunt/hunt_success_store.dart
abstract class HuntSuccessStore {
  Future<HuntSuccess?> load(AccountId accountId);
  Future<void> save(HuntSuccess success);
  Future<void> remove(AccountId accountId);
}
```

`PlainHuntSuccessStore` mirrors `PlainHuntConfigStore` (`hunt_store.dart`), one plain-store key per account. Do **not** put this in the Keystore: a dish name and a price are not secrets, and the account list and reminder config are already plain for the same reason (`platform_stores.dart:1-14`).

The sibling review writes `PlainStore` directly from `HuntNotifier`. This review prefers the store seam because: it is testable on the VM without a platform fake; `HuntNotifier` already takes `configStore`, so a second injected store is consistent; and the headless VM needs the same store, which the `PlatformServices` composition root already provides.

## 4.3 The write path — exactly one place

`HuntNotifier.onClaimed` (`hunt_service.dart:171-220`) is the **only** code that runs for both the in-app and headless purchase paths. Persist there, **before** `reportOutcome` (so a notification failure cannot lose the record):

```dart
if (successStore != null) {
  try {
    await successStore!.save(HuntSuccess(
      accountId: accountId,
      dishName: listing.option.name,
      hallName: listing.hall.name,
      priceRial: listing.option.priceRial,
      date: listing.date,
      slot: listing.slot,
      claimedAt: DateTime.now().toUtc(),
    ));
  } catch (_) {
    // The meal exists; losing the banner is not worth failing the notification.
  }
}
```

Wire `successStore` through `PlatformServices` → `HuntService` → `HuntNotifier` and through the headless entrypoint's `HuntNotifier` (`hunt_entrypoint.dart:145`).

**Do not** write it from `onEnded`: an ambiguous claim that reconciled to a purchase arrives via `onClaimed`, and everything else is not a purchase (`hunt_notify.dart:8-16`).

## 4.4 The banner

Place it **first** in `HuntScreen`'s list, above the account picker, so it is the first thing visible on opening the tab:

```dart
if (widget.lastSuccess != null) ...[
  _LastHuntSuccessCard(success: widget.lastSuccess!, onDismiss: widget.onDismissSuccess),
  const SizedBox(height: 12),
],
```

Content, matching `HuntSuccessDialog`'s labels (`hunt_success_dialog.dart:116-148`) so the two never disagree:

| Row | Label | Value |
|---|---|---|
| Dish | «غذای خریداری‌شده» | `dishName` |
| Hall | «سلف سرویس» | `hallName` |
| Price | «قیمت پرداختی» | `formatTomanPersian(priceRial)` |
| When | «وعده و تاریخ» | `«${mealSlotPersian(slot)} • ${formatPersianDate(date)}»` |

Title: «آخرین شکار موفق» with `Icons.check_circle_rounded` in the primary colour; a trailing `IconButton(Icons.close)` dismisses it. It must be a `Card`/`SectionCard`, not a `SnackBar` or dialog: the requirement is *persistent*.

## 4.5 Staleness and dismissal

A banner that shows last month's lunch is noise. Show it only when:

- `success.date` is **not before** the portal's today (the meal is still ahead or today), **and**
- `claimedAt` is within 7 days (guards against a clock skew inflating the first condition).

Dismissal writes `dismissedAt` (or simply `remove`s the record); either is acceptable, but removal is simpler and matches "I have seen it".

Loading: `HuntState.reloadHuntConfig(accountId)` currently loads the config; add a parallel `successStore.load(accountId)` into `_lastSuccesses[accountId]`, and load it in `reloadHuntConfigs`. `selectHuntAccount` exposes `lastSuccessFor(activeId)` to the screen.

## 4.6 Deep link

`nut://hunt-success?account=…&dish=…&hall=…&price=…&date=…&slot=…` already exists and is already parsed (`home_shell.dart:756-801`). Two changes:

1. **The tap should land on the banner, not a modal.** A headless purchase at 16:30 is discovered hours later; a modal that must be dismissed to read a persistent card is friction. Route to the hunt tab and let the card speak:
   ```dart
   if (account != null) widget.state.selectHuntAccount(account);
   setState(() => _index = 4);
   WidgetsBinding.instance.addPostFrameCallback((_) => _scrollHuntToTop());
   ```
   Keep `HuntSuccessDialog` for the **live in-app** win (the claim callback in `home_shell:3988`), where immediate celebration is right.
2. **The deep link must not be the only carrier.** Today, dismissing the notification without tapping loses dish/hall/price forever. Persistence (§4.3) fixes that; the deep link becomes an *accelerator*, not the record.

Because the record is written before the notification, the banner is available even if the tap arrives before `HuntState` has loaded. `_handleDeepLink` should therefore also `unawaited(state.reloadHuntSuccess(account))` when the account is known — the same pattern it already uses for `reloadHuntConfig`.

## 4.7 Tests

- Round-trip `HuntSuccess` JSON; corrupt JSON ⇒ `null`, no throw.
- `HuntNotifier.onClaimed` with a fake store ⇒ one `save` with the listing's dish/hall/price/date/slot.
- `onClaimed` when the store throws ⇒ `reportOutcome` still posts the notification.
- State: after `reloadHuntSuccess(A)`, `lastSuccessFor(A) != null`, `lastSuccessFor(B) == null`.
- Widget: banner renders the four rows; hidden when `success.date` is in the past; dismiss callback fires.
- Deep link: `nut://hunt-success?account=a1&…` selects a1, sets tab 4, shows the banner.

---

# Pillar 5 — Conflict guard

## 5.1 The real gap: the mirror is never updated after a hunt

This is the finding that changes the shape of the pillar.

`PreflightChecker` already refuses `alreadyBooked` (`preflight.dart:220-237`) using **live portal holdings**. That covers a meal booked in the portal's weekly grid or in a previous session. It does **not** cover:

- a purchase made by a hunt on this device, because nothing writes it to the mirror;
- a purchase made while offline / headless, before the next sync;
- the UI requirement to disable Start **before** a network read.

Evidence that the write is missing:

- `HuntService` is constructed at `platform_services.dart:252-256` with `bridge`, `engine`, `configStore` — **no `onOutcome`**, and `onOutcome` is never assigned anywhere in `lib`.
- No `mealStore.put` / `hold` / `replaceForAccount` appears in `snipe_engine.dart`, `snipe_claimer.dart`, `hunt_service.dart`, or `hunt_entrypoint.dart`.
- `portal_sync.dart` **can** detect a basket purchase (it reads the transaction ledger, `:139-158`, and files `MealSource.basketPurchase` at `:375`), but nothing calls it after a hunt.

So today a successful hunt can leave the local mirror saying the slot is free. If a second hunt runs for the same `(date, slot)` — another account is irrelevant here, this is the *same* account — the local guard cannot see it, and only the live preflight stands in the way.

### Fix

Wire the outcome to the existing sync, which is the only code that knows how to reconcile a basket purchase into the mirror:

```dart
// platform_services.dart
late final HuntService hunts = HuntService(
  bridge: bridge,
  engine: engine,
  configStore: huntConfigStore,
  successStore: huntSuccessStore,
  onOutcome: (accountId, success) async {
    if (!success) return;
    // A basket purchase appears only in the ledger, never in the weekly grid
    // (portal_sync.dart:139-145). Re-sync so the mirror, the reminders and
    // the conflict guard all see the meal that was just bought.
    try {
      await sync.sync(accountId);
    } catch (_) {
      // The purchase is done; a failed mirror refresh must not surface as
      // a failed hunt. The next sync or preflight will catch up.
    }
  },
);
```

and the headless entrypoint must pass the same `onOutcome` (it builds its own `PlatformServices`, so this is one extra constructor argument, not new logic).

This single wiring makes Pillar 5's local guard trustworthy, and it also fixes a latent reminder bug: a headless purchase today produces no reminder for the meal it bought.

## 5.2 Detection API

Use the existing invariant, not an ad-hoc scan. `MealLedger.holds(accountId, date, slot)` (`meal_invariant.dart:149-154`) is the canonical answer, and `LocalMealStore.toLedger()` (`local_meal_store.dart:228`) builds it. But `toLedger()` is O(n) and allocates; for the UI's per-frame calls prefer the keyed lookup:

```dart
// reservations_state.dart
/// The meal [accountId] already holds for [(date, slot)], if any.
///
/// A basket sale releases the slot, so a meal that has been listed for sale
/// does not count as held. This mirrors the rule the reservations screen
/// already applies at [basketSaleKey].
StoredMeal? heldMealFor(AccountId accountId, DateTime? date, MealSlot slot) {
  if (date == null) return null;                 // "next available" cannot be judged locally
  final meal = mealStore.find(accountId, date, slot);
  if (meal == null) return null;
  if (basketSales.contains(basketSaleKey(accountId, date, slot))) return null;
  return meal;
}

bool holdsMealFor(AccountId accountId, DateTime? date, MealSlot slot) =>
    heldMealFor(accountId, date, slot) != null;
```

`mealStore.find` is the same call the reservations screen already trusts (`reservations_state.dart:415`, `:514`), and the sale-marker exclusion is the same rule the table applies — so the guard cannot contradict the screen.

## 5.3 UI: two precise bugs to fix

The brief says "disable Start, clear warning". The warning exists (`hunt_screen.dart:501-520`), but the controls do not honour it:

**Bug 1 — the enable switch is never disabled.**

```dart
// hunt_screen.dart:453-456
trailing: Switch(
  value: config.enabled,
  onChanged: (value) => onChanged(config.copyWith(enabled: value)),
),
```

`home_shell._confirmHuntEnable` reverts the flag after the fact, so the switch *springs back* — a bad affordance that reads as a glitch. Change to:

```dart
onChanged: enableRefusal != null ? null : (value) => onChanged(...),
```

**Bug 2 — the Start button ignores `enableRefusal`.**

`_PreflightCard.buttonAction` gates only on `widget.refusal` (`:1851`, `:1886`), which is the *preflight* refusal, not the enable refusal. A local conflict would therefore show the banner and leave Start **live**. Fix by passing `enableRefusal` into `_PreflightCard` and gating on both:

```dart
final blocked = widget.refusal != null || widget.enableRefusal != null;
...
buttonAction = (widget.onStart == null || blocked) ? null : ...;
```

and render the enable refusal in the preflight card when it is a conflict (so the reason sits next to the disabled button, not only in the card above).

## 5.4 Wiring and wording

`_confirmHuntEnable` already computes a refusal (`home_shell:3241`, `:3305`, `:3327`). Add a pure check before the network work:

```dart
String? _huntConflictRefusal(AccountId accountId, HuntConfig config) {
  final held = widget.state.heldMealFor(
    accountId, config.targetDate, config.targetSlot,
  );
  if (held == null) return null;
  final slot = mealSlotPersian(config.targetSlot);
  final date = config.targetDate == null
      ? ''
      : ' در تاریخ ${formatPersianDate(config.targetDate!)}';
  return 'برای $slot$date غذای دیگری در حساب شما ثبت شده است '
      '(${held.dishName ?? 'رزرو موجود'}). '
      'شکار متوقف شد تا غذای تکراری نخرید.';
}
```

Call it: (1) on `selectHuntAccount`, (2) on every `onConfigChanged` that touches `targetDate`/`targetSlot`, (3) after `mealsChanged` (a sync arriving in the background), (4) at the top of `_startHunt`. The wording deliberately echoes `describePreflightFailures`' `alreadyBooked` string (`preflight.dart:98-101`) so a local block and a live block read as the same rule.

**Order matters:** local check → set `enableRefusal` → *then* the network preflight. If both would fire, the local one is shown immediately (offline-friendly) and the live one confirms.

## 5.5 Belt and braces in the engine

The UI is not the only starter (the platform can wake a hunt — `preflight.dart:48-54`). Add the local check to `PreflightChecker` as a **new failure** rather than folding it into `alreadyBooked`, so the headless notification can say which source of truth refused:

```dart
enum PreflightFailure {
  ...
  /// The device's own mirror says the slot is filled, and no live read could
  /// contradict it.
  alreadyHeldLocally,
}
```

Pass `holdsLocally: bool` into `check(...)`. It refuses only when live `holdings == null` (unreadable) **or** live holdings are empty — never overriding a live "empty" answer, because the mirror can be stale in the other direction too (a cancelled meal). In practice: `holdingsUnreadable` already refuses, so `alreadyHeldLocally` adds value only when the live read succeeded but the mirror has a purchase the ledger has not yet been re-read to include. Given §5.1's sync wiring, that window is short — so this is genuinely belt-and-braces, and can be deferred if the team prefers fewer failure modes.

## 5.6 Tests

- `ReservationsState.holdsMealFor`: seeded weekly meal for `(d, lunch)` ⇒ true; different slot ⇒ false; different date ⇒ false; `date == null` ⇒ false; basket meal then `markBasketSale` ⇒ false.
- `heldMealFor` respects a consumed meal? Assert the chosen policy explicitly (recommend: consumed future-dated meals cannot exist; do not special-case).
- UI: `enableRefusal != null` ⇒ the switch is disabled and the Start button is disabled; clearing it re-enables both.
- Integration: after `HuntNotifier.onClaimed`, `sync.sync` is called once for that account and `mealStore.find` returns the purchased meal.
- Preflight: `alreadyHeldLocally` produces a Persian description and a headless notification, not a silent no-op.

---

# 6. Cross-cutting

## 6.1 Risk register

| Risk | Pillars | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Fast-path claim buys on a stale page | 1 | Low | **Money** | account+date+freshness+hall gates; `claimFormBody` returns null before write |
| ∞ drives a ban | 2 | Medium | **High** | 400 budget unchanged; backoff floor; circuit breaker; acknowledgement |
| ∞ crashes the screen | 2 | **Certain** if unpatched | High | nullable `projectedRequests`; widget test |
| Stopping one account stops all | 3 | **Certain** today | High | Kotlin-authoritative set; per-account release |
| A purchase announced to the wrong account | 3 | **Certain** today (two hunts) | **Money/reputation** | per-rule listener map |
| Second account skips preflight | 3+5 | **Certain** within 15 s | **Money** | per-account cache (D7) |
| Mirror blind to a hunt purchase | 5 | **Certain** today | **Money** | `onOutcome` → `sync` |
| Banner shows a stale success | 4 | Medium | Low | date + 7-day predicate; dismiss |

## 6.2 Test matrix (minimum for merge)

| Area | File | Kind |
|---|---|---|
| snapshot claim, same hall | `test/adapter/cullinan/basket_purchase_test.dart` | unit, fake transport |
| snapshot claim, hall switch | same | unit |
| snapshot fallback (account/date/age) | same | unit |
| capture replay, no `__EVENTVALIDATION` | `cullinan_parser_test.dart` | unit |
| ∞ bounds + clamp | `test/core/hunt/hunt_rate_test.dart` | unit |
| ∞ `projectedRequests` null | same | unit |
| ∞ backoff floor | `test/core/hunt/snipe_engine_*` | unit |
| per-rule listener routing | engine test | unit |
| service ref count (Kotlin semantics via fake bridge) | `test/platform/hunt_service_test.dart` | unit |
| per-account state | `test/ui/hunt_state_test.dart` | unit |
| success store round-trip + notifier write | new | unit |
| banner render + staleness | widget test | widget |
| `holdsMealFor` + sale marker | `test/ui/reservations_state_test.dart` | unit |
| Start disabled on `enableRefusal` | widget test | widget |

## 6.3 Sequencing

```
P5 (sync wiring + guard)  →  P4 (banner, store)
        ↓
P2 (∞: fix 3 defects, then bounds, then slider)
        ↓
P1 (instrument → ticket → gate → measure)
        ↓
P3 (listeners → Kotlin set → state maps → subscriptions → D7)
```

P5 must land **before** P2/P4 because the sync wiring changes what the banner and the guard read. P1 must land after instrumentation, so its benefit is provable. P3 last: it touches lifecycle only, and every test written for P1/P2/P5 becomes a regression test for it.

---

# 7. Divergences from the sibling review

Recorded for the council's benefit; these are corrections, not objections to its structure.

1. **`__EVENTVALIDATION` is not required.** The sibling treats it as a mandatory token whose absence would fail validation. `claimFormBody` never sends it, and the captured successful purchase (`captures/82_buy_post_body.txt`) contains no such key. Do not add it.
2. **The cached HTML does not belong in `_formState`.** After a two-hall merge the last page is the second hall's render; a first-hall listing is absent from its `drpFood` and the claim would be rejected. Use an explicit per-page snapshot plus the existing hall gate.
3. **`clampPeak` accepting zero needs three fixes, not one.** `projectedRequests()` throws on `∞.ceil()`, failure backoff becomes `0`, and the loop loses its yield. The sibling treats the sentinel as loop-safe, which it is — but only after these.
4. **Do not raise `defaultRequestBudget` for ∞.** The budget bounds the request *pattern*, which is the thing that gets an account banned. "∞ capped at 400" is the honest contract.
5. **The Android service must change.** A Dart-side `int` ref count is not durable across process death, and the headless hunt runs in a second VM. The Kotlin service is the only reliable owner; it should hold a `Set<String>` of active accounts.
6. **A fourth release site exists.** The sibling lists three unconditional releases; the headless entrypoint's `_releaseService` (`hunt_entrypoint.dart:138`, `:170`) is a fourth and is the one that runs when the app is closed.
7. **The preflight cache is a safety defect, not a detail.** `_lastPreflightAccount`/`_lastPreflightPassTime` are single slots (`home_shell.dart:3952-3955`); a second account started within 15 s skips preflight altogether.
8. **The Start button ignores `enableRefusal`.** `_PreflightCard` gates on `refusal` only (`:1851`, `:1886`), so the sibling's "the Start button is already disabled" is not true of this code.
9. **The mirror is never updated after a hunt.** The sibling says the live preflight covers it. It covers only the live case; the local guard is blind to a purchase the hunt itself made, which is the exact double-buy the pillar exists to prevent.

---

# 8. Appendix — symbol index

| Symbol | Location |
|---|---|
| `_formState`, `fetchBasket`, `_readBasketHtml` | `lib/adapter/cullinan/cullinan_basket_buy.dart:44`, `:46-105`, `:109-146` |
| `claim`, `_readBuyPage`, `_submitBasketRow` | `cullinan_basket_buy.dart:250-279`, `:291-316`, `:326-430` |
| `claimFormBody`, `hallSwitchBody`, `heldOnBuyPage` | `lib/adapter/cullinan/cullinan_parser.dart:439`, `:509`, `:1735` |
| `BasketPage`, `Listing`, `ClaimResult` | `lib/core/portal/portal_models.dart:213`, `:225-258` |
| `PortalClient.claim` | `lib/core/portal/portal_client.dart:158` |
| `HuntBounds`, `HuntRate`, `projectedRequests`, `computeBudget` | `lib/core/hunt/hunt_config.dart:78-136`, `:144-181`, `:641`, `:320-414` |
| `_listener`, `watch`, `_intervalFor`, `_pollOnce`, `_claim` | `lib/core/hunt/snipe_engine.dart:187`, `:267`, `:686`, `:1017`, `:1221` |
| `HuntService.stop/reportOutcome`, `HuntNotifier` | `lib/platform/hunt_service.dart:77`, `:101`, `:155-258` |
| `_huntRunning`, `_huntStatus`, `setRunning`, `setStatus` | `lib/ui/state/hunt_state.dart:34`, `:37`, `:209`, `:218` |
| `_startHunt`, `_stopHunt`, `_releaseHuntService`, `_handleDeepLink` | `lib/ui/shell/home_shell.dart:3916`, `:4038`, `:4029`, `:756` |
| `_RateCard`, `_IntervalSlider`, `_EnabledCard`, `_PreflightCard` | `lib/ui/features/hunt/hunt_screen.dart:1591`, `:1683`, `:395`, `:1782` |
| `_LiveHuntMonitorCard`, `HuntSuccessDialog` | `hunt_screen.dart:2073`; `lib/ui/features/hunt/hunt_success_dialog.dart:13` |
| `PreflightFailure`, `describePreflightFailures` | `lib/core/portal/preflight.dart:17-55`, `:94-121` |
| `MealLedger.holds`, `HeldMeal` | `lib/core/meal/meal_invariant.dart:149-154` |
| `StoredMeal`, `LocalMealStore.toLedger` | `lib/core/meal/local_meal_store.dart:31-88`, `:228` |
| `mealsFor`, `basketSaleKey` | `lib/ui/state/reservations_state.dart:83`, `:392` |
| `PortalSync.sync` (ledger → basket meals) | `lib/platform/portal_sync.dart:124`, `:139-158`, `:375` |
| `HuntService` construction (no `onOutcome`) | `lib/platform/platform_services.dart:252-256` |
| `HuntService.kt` (foreground id, start/stop) | `android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/HuntService.kt:48`, `:57-69`, `:89-161` |
| Headless hunt, `_releaseService` | `lib/background/hunt_entrypoint.dart:89-171`, `:308` |
| Live purchase capture | `captures/82_buy_post_body.txt` |
| Purchase analysis | `captures/analysis_purchase2.txt` |
