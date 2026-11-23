# Stage 5 Code Review Report — Senior Review Council (Gemini 3.8 Flash)

**Reviewer:** Senior Review Council (Gemini 3.8 Flash Representative)  
**Target Milestone:** Stage 5 — Resilience, Time Handling, & API Polish  
**Verdict:** **APPROVE**  

---

## 1. Executive Summary

Stage 5 addresses critical operational resilience, timezone correctness, form postback verification, and API polish across the portal adapter and domain core:
1. **H3 (ASP.NET Error Page & Mirror Protection):** Defends against HTTP 200 error pages, dead postbacks, and wiping student offline meal mirrors.
2. **L1 (Tehran Civil Day vs UTC Day):** Corrects calendar date calculations so midnight-to-morning requests query Tehran's civil day instead of yesterday's UTC date.
3. **L3 (Basket Date Filter Verification):** Ensures basket buy/filter postbacks strictly reflect the requested Jalali date before proceeding with meal purchases.
4. **M3 (Bank Gateway Sorting):** Safely prioritizes stable gateways (Sadad) and protects students from server 500 crashes on unconfigured secondary gateways.
5. **L2, L4, L7, M2 (Deprecations, Observability & Documentation):** Deprecates legacy APIs (`fetchOfferings`), enriches snipe claimer logs with dish and hall names, clarifies the `days` parameter contract, and documents the Cafeteria system scope boundary.

After thorough inspection of all changes across `lib/` and `test/`, the implementation is verified to be sound, architecturally clean, and fully compliant with project standards. **No blocking defects (B)** were found.

---

## 2. In-Depth Technical Verification

### 2.1 H3 — ASP.NET Error Page & Mirror Protection
- **Page Validation (`CullinanForms` in `lib/adapter/cullinan/cullinan_forms.dart`):**
  - Added `looksLikeReservationPage(String html)` and `looksLikeAspError(String html)`.
  - Rejects responses containing standard ASP.NET server error signatures:
    - Yellow Screen of Death indicators: `Server Error in '/' Application`, `Runtime Error`, `Compilation Error`.
    - Stack traces and unhandled exception traces: `System.Web.HttpUnhandledException`, `System.NullReferenceException`, `Stack Trace:`.
  - Confirms the presence of genuine reservation components:
    - Checks for the main reservation grid table (`dgReservation` or `grdReserve` / `grdReservation`).
    - Validates presence of navigation postback elements (`lnkNextWeek`, `lnkPrevWeek`, `btnNext`, `btnPrev`).
- **Next-Week Navigation Verification (`CullinanReservation` in `lib/adapter/cullinan/cullinan_reservation.dart`):**
  - When traversing from current week to next week via `lnkNextWeek`, the adapter checks `_introducesLaterWeek(currentWeekHtml, nextWeekHtml)`.
  - Parses table headers / day cells using `_gridDates` to ensure the next week actually contains dates chronologically following the current week.
  - If the page re-renders the same week, contains an ASP.NET error, or lacks grid dates, it throws `PortalUnreachableException` rather than returning an empty or stale list.
- **Mirror Protection (`PortalSync` in `lib/platform/portal_sync.dart`):**
  - In `PortalSync.sync()`, `replaceForAccount(account.id, meals)` is strictly sequenced after successful completion of `fetchReservations()`.
  - Because `fetchReservations()` throws `PortalUnreachableException` on malformed HTML, error pages, or stalled week navigation, control jumps straight to catch blocks, entirely bypassing `replaceForAccount`.
  - Cached student meal records remain untouched during transient portal outages. Verified by unit test in `test/platform/portal_sync_test.dart` ("does not wipe store on unreadable weeks").
- **Partial Menus Flag (`BookableMenus.partial` in `lib/core/portal/portal_models.dart`):**
  - Added boolean `partial` field (defaulting to `false`) to `BookableMenus`.
  - In `fetchBookableMenus`, if the next-week fetch fails or bounces back to the current week, the adapter returns `BookableMenus(..., partial: true)` rather than crashing or claiming a complete schedule.

### 2.2 L1 — Tehran Civil Day vs UTC Day
- **Time Offset Calculation (`CullinanForms.todayJalali` in `lib/adapter/cullinan/cullinan_forms.dart`):**
  - `tehranCivil = current.toUtc().add(ServerClock.portalUtcOffset);`
  - Uses `ServerClock.portalUtcOffset` (`Duration(hours: 3, minutes: 30)`).
  - Converts timestamp to UTC first, then shifts by +03:30.
  - **DST Notice:** In 1402 (March 2023 legislation), daylight saving time was officially abolished in Iran. Standard time throughout the entire year is permanently fixed at UTC+03:30 (`IRST`). Therefore, a constant `Duration(hours: 3, minutes: 30)` is strictly correct and free of DST shift bugs.
  - **Midnight Boundary:** For a query executing at 01:00 AM Tehran time (21:30 UTC of prior day), standard UTC conversion would yield the previous calendar day. Applying `toUtc().add(portalUtcOffset)` correctly advances to Tehran's current civil date.

### 2.3 L3 — Basket Date Filter Verification
- **Postback Verification (`CullinanBasketBuy` in `lib/adapter/cullinan/cullinan_basket_buy.dart`):**
  - When changing the target date via `_postDateFilter`, switching halls via `_postHallSwitch`, reading the buy page in `_readBuyPage`, or submitting a row in `_submitBasketRow`, the adapter extracts the rendered page date using `buyPageDate(response.body)`.
  - Validates `buyPageDate(response.body) == wanted`.
  - If a date mismatch occurs (indicating ASP.NET session state desynchronization or a rejected postback event):
    - Immediately resets cached state: `_formState = null`.
    - Avoids submitting purchases against the wrong day.
    - Either performs a fresh page GET or raises `PortalUnreachableException('Basket date mismatch: expected $wanted, got $actualDate')`.

### 2.4 M3 — Bank Gateway Sorting & Prioritization
- **Gateway Prioritization (`workingTopUpBanks` in `lib/core/finance/top_up.dart`):**
  - Cullinan portals frequently display multiple bank logos (e.g., Sadad/Bank Melli and Mellat/Saman). However, in many deployments (including Bahonar), only one gateway is bound on the backend; clicking the other triggers an unhandled null reference exception in `topup.aspx`.
  - `workingTopUpBanks` prioritizes known stable gateways matching `sadad`, `سداد`, `melli`, `ملی`.
  - Returns `[stable.first]` when present; gracefully returns all available options if no keyword matches.
  - Thoroughly tested in `test/core/finance/top_up_test.dart`.

### 2.5 L2, L4, L7, M2 — Deprecations, Logs, & Documentation
- **L2 (`fetchOfferings` Deprecation):** Marked `@Deprecated('Use fetchBookableMenus instead')` in `portal_client.dart` and `cullinan_reservation.dart`. Cleanly delegated in `cullinan_client.dart`.
- **L4 (Enriched Snipe Claimer Logs):** In `snipe_claimer.dart`, log entries across simulation, claim attempts, successes, and rejections now consistently interpolate `${listing.option.name} از ${listing.hall.name}`.
- **L7 (`days` Parameter Advisory Documentation):** Documented on `fetchBookableMenus` in `portal_client.dart` and `cullinan_reservation.dart`: clarifies that underlying Cullinan portals render hard-coded weekly grids (Saturday to Friday), returning all menus within the active cycle.
- **M2 (Cafeteria Scope Boundary):** Documented in `cullinan_client.dart`: explains why Cafeteria (آزاد/بوفه) is separated from Self-service dining (دانشجویی) due to distinct credential scopes and billing pipelines.

---

## 3. Findings Matrix

### 3.1 Blocking Issues (B)
*None.*

### 3.2 Should-Fix / Improvements (S)
1. **S1 — Unit Test Coverage for `CullinanForms` Error and Date Utilities:**
   - There are currently no direct unit tests asserting `CullinanForms.looksLikeReservationPage` and `looksLikeAspError` against raw HTML error snippets (Yellow Screen of Death, custom ASP.NET error panels, valid grid tables) and testing `todayJalali` across UTC midnight transitions.
   - *Recommendation:* Add `test/adapter/cullinan/cullinan_forms_test.dart` in a follow-up test hardening task.
2. **S2 — Mock Test for `CullinanBasketBuy` Date Mismatch (L3):**
   - Direct mock tests in `test/adapter/cullinan/` should be added to assert that a mismatched postback date triggers `_formState = null` and raises `PortalUnreachableException`.
3. **S3 — End-of-Semester Grid Date Boundary in `_introducesLaterWeek`:**
   - At the end of a semester when next week's meal grid is empty/unentered, `_introducesLaterWeek` returns `false`, causing `fetchReservations` to throw. This correctly protects existing mirrors, but callers should document that unentered end-of-term weeks are treated as unreachable by design.

### 3.3 Nitpicks (N)
1. **N1 — Regex Delimiters in `_hasTable`:**
   - In `cullinan_forms.dart`, `_hasTable` matches `id="[^"]*${RegExp.escape(tableId)}"`. While standard ASP.NET renders double quotes, accepting single quotes or unquoted IDs (`id=['"]?...`) provides extra resilience against proxy rewrites.
2. **N2 — Doc Comment in `workingTopUpBanks`:**
   - Clarify in doc comments that returning `[stable.first]` is intentional to shield students from server 500 errors on unconfigured gateways.

---

## 4. Final Verdict

**APPROVE**  
Stage 5 is robust, secure, and production-ready. The should-fix items are non-blocking test/documentation enhancements suitable for the next test hardening iteration.
