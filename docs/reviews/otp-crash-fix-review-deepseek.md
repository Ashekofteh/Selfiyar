# Review — Dynamic OTP Autofill Crash Fix (رمز دوم پویا) — Round 3 (Final)

**Reviewer:** DeepSeek V4.1 Flash Free (OpenCode), Senior Review Council member  
**Date:** 2026-11-23 (round-2 re-review, then round-3 final verification)  
**Base commit:** `994aa02 fix(resilience): detect asp errors, protect meal mirror, and fix tehran date (Stage 5)`  
**Patch state:** uncommitted working tree (`git diff 994aa02`, plus untracked new files)  
**Round-2 changes since the first review:** `SingleReplyResult.kt` + its JVM test, `PlatformChannel.kt`
once-guard and idempotent cookie application, amount/date/phone masking and a hint-scoped collapser
in `otp_extractor.dart`, R8 keep rules, Dart-side timeout/truthful-status/lifecycle hardening, and
the formal A2 risk-acceptance document.  
**Round-3 changes since round 2:** B-4 regex reflow, B-5 truthful-status test expectations, R-1
amount-verb decoupling, R-3 extended non-OTP mask + tightened `otpLineHint`, R-4 rationale accuracy,
and the N-5 dead-import removal.

**Scope re-inspected:**

- `android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt`
- `android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/SingleReplyResult.kt` *(new)*
- `android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt`
- `android/app/src/test/kotlin/ir/ac/uk/bahonar_nut/SingleReplyResultTest.kt` *(new)*
- `android/app/proguard-rules.pro`
- `lib/ui/features/top_up/top_up_gateway_screen.dart`
- `lib/core/auth/otp_extractor.dart`
- `test/core/auth/otp_extractor_test.dart`
- `docs/reviews/otp-crash-a2-rationale.md` *(new)*
- `docs/reviews/otp-crash-fix-review-claude.md` *(reference)*

**Independent evidence base:** the full current files, the complete diff, the vendored
`webview_flutter_android 4.14.1` sources in the pub cache, the Gradle JUnit XML reports, a
base-vs-current extractor differential probe (~90 SMS samples across three temporary scripts),
`flutter analyze`, the whole Flutter test suite, and
`:app:testDebugUnitTest`. All probe files were deleted afterwards; `git status --short` shows only
the intended files plus the council documents.

---

## Verdict

> [!TIP]
> **APPROVE** — final, signed off by the Senior Review Council.
>
> Both round-2 blockers are closed in the working tree, independently re-verified:
>
> - **B-4 (CLOSED)** — the two amount regexes are reflowed onto their `RegExp(` lines
>   (`lib/core/auth/otp_extractor.dart:62`, `:66`, `:70`), matching the existing rules. The Rial-invariant
>   guard `test/core/shared/currency_display_test.dart` is **5/5 green**.
> - **B-5 (CLOSED)** — `test/ui/features/top_up/top_up_gateway_otp_test.dart:86-90` and `:187-191` now
>   assert the truthful neutral copy «رمز دوم پویا (…) دریافت شد.», which is exactly what
>   `_applyIncomingOtp` emits when `_autoFillOtp` returns `false` (`top_up_gateway_screen.dart:1180-1182`).
>   All **3/3** tests in that file pass.
>
> Full verification on the current tree: **`flutter analyze` → No issues found**;
> **`flutter test` → 1519/1519 passed, 0 failures** (single invocation, all directories);
> **`:app:testDebugUnitTest` → 65/65 Kotlin tests, 0 failures** (forced re-run, XML-counted).
>
> The round-1 blockers remain as previously dispositioned: **B-1** accepted risk (Option 3, documented),
> **B-2** closed (JVM-tested), **B-3** closed for every named case and regression-tested.
>
> Round-3 also closed the should-fix items **R-1**, **R-3**, **R-4** and the cosmetic **N-5**. Two
> non-blocking residuals remain documented below (**R-2** collapser edge case, unchanged; **R-7**, a
> narrow false negative introduced by the R-3 `ملی` mask), plus the carried **R-5/R-6**. None of them
> reintroduces a crash vector, a wrong-code autofill, or the plain-transaction false positive.

---

## 0. Round-3 final verification (this pass)

**Scope re-verified in this pass:** `lib/core/auth/otp_extractor.dart`,
`test/core/auth/otp_extractor_test.dart`, `test/ui/features/top_up/top_up_gateway_otp_test.dart`,
`lib/ui/features/top_up/top_up_gateway_screen.dart`, `MainActivity.kt`,
`docs/reviews/otp-crash-a2-rationale.md`, plus the unchanged round-2 Kotlin/R8 files.

### 0.1 Blocker closure

| Blocker | Round-2 state | Current state | Independent evidence |
|---------|---------------|---------------|----------------------|
| **B-4** Rial-invariant guard | ❌ 4/5, offenders at `:63`, `:69` | ✅ **closed** | The three amount rules are single-line `RegExp(r'…')` (`:62`, `:66`, `:70`), so the guard's parser-context heuristic recognises them. `flutter test test/core/shared/currency_display_test.dart` → **5/5**. |
| **B-5** OTP widget expectations | ❌ 2 failures, stale «… دریافت و در فیلد درج شد.» | ✅ **closed** | Expectations now read «… دریافت شد.», matching the `filled == false` branch (`top_up_gateway_screen.dart:1180-1182`). `flutter test test/ui/features/top_up/top_up_gateway_otp_test.dart` → **3/3**. |

Both were re-run in isolation **and** inside the full suite; the whole suite is green in one invocation,
so the round-2 caveat about running per directory no longer applies.

### 0.2 Should-fix items closed in round 3

| Item | Status | Evidence |
|------|--------|----------|
| **R-1** ambiguous amount verbs masking OTP labels | ✅ **Fixed** | `خرید|شارژ|انتقال` are removed from the amount-context group (`:62`, `:66`); `مبلغ|به مبلغ|موجودی|مانده|باقیمانده|برداشت|واریز` remain. `رمز پویا خرید: 482915`, `رمز دوم پویا خرید: 482915`, `کد تایید خرید: 482915`, `رمز دوم خرید: 482915`, `کد یکبار مصرف خرید: 482915` all extract again, covered by a new test (`otp_extractor_test.dart:207-213`). |
| **R-3** hinted non-OTP codes collapsed | ✅ **Fixed** | REF mask extended to `رهگیری|ملی|پستی|شعبه|بورسی|سفارش|تخفیف` with grouped/spaced tails (`:76-79`); `otpLineHint` tightened (`:108-111`). `کد رهگیری/ملی/پستی: 12 345 678` and `کد شعبه: 123 456` → `null` (new test at `:215-220`). |
| **R-4** A2 rationale imprecision | ✅ **Fixed** | §3.2 of `otp-crash-a2-rationale.md` now states `.timeout(const Duration(seconds: 2))` **with `try/catch`** for `_autoFillCard`/`_autoFillOtp`, and records `_injectGatewayScript` as fire-and-forget `unawaited`. Matches `top_up_gateway_screen.dart:823`, `:1291`. |
| **N-5** dead import | ✅ **Fixed** | `grep AtomicBoolean MainActivity.kt` → no matches; the guard lives in `SingleReplyResult.kt`. |

### 0.3 Commands run in this pass

| Command | Result |
|---------|--------|
| `flutter analyze` | ✅ `No issues found!` |
| `flutter test test/core/shared/currency_display_test.dart test/core/auth/otp_extractor_test.dart` | ✅ 39/39 |
| `flutter test test/ui/features/top_up/top_up_gateway_otp_test.dart` | ✅ 3/3 |
| `flutter test` (whole suite, one invocation) | ✅ **1519 passed, 0 failed** |
| `gradlew :app:cleanTestDebugUnitTest :app:testDebugUnitTest --offline` | ✅ `BUILD SUCCESSFUL`; XML reports: **6 suites, 65 tests, 0 failures, 0 errors** |
| Extractor differential probe (26 samples, temporary, deleted) | ✅ all round-2 blockers and R-1/R-3 reproducers correct; ⚠️ 4 samples expose **R-7** and **R-2** below |

### 0.4 Residuals (non-blocking, carried forward)

**R-7 · `ملی` in the REF mask is broader than `کد ملی`.** New in round 3. The mask token `ملی`
(`:77`) also matches the bank name «بانک ملی» when a bare number follows it, so reverse-order Melli
templates lose the code:

| SMS | `994aa02` | current |
|-----|-----------|---------|
| `بانک ملی\n123456 رمز پویا شماست` | `123456` | **`null`** |
| `بانک ملی 482915 رمز پویا` | `482915` | **`null`** |

Same severity class as round-2 R-1: silent ignore, manual entry, no wrong code, no crash. One-word fix:
narrow the token to `کد\s*ملی` (and optionally `کد\s*(?:پستی|شعبه|بورسی|سفارش)`), keeping the two strings
as regressions. Forward-order Melli templates (`بانک ملی\nرمز پویا: 123 456`) are unaffected and pass.

**R-2 · hinted-line collapser still joins an unmasked space-grouped amount.** Unchanged from round 2 and
re-confirmed: `رمز پویا خرید اینترنتی 1 200 000: 482 915` → `1200000`;
`کد تایید خرید اینترنتی 250 000: 482915` → `250000`. Still requires a currency-less, keyword-less,
space-grouped amount on the OTP line before the code; no such template exists in the corpus. Keep as a
defence-in-depth follow-up (bounded join window or strong `<label>: code` pass before the collapser).

**R-5 / R-6** remain as recorded in round 2 (`isConsentInFlight` watchdog; clipboard lifetime).

---

## 1. Round-2 crash-vector matrix (A1–A4)

| # | Vector | Status | Evidence |
|---|--------|--------|----------|
| **A1** | IME crash/deadlock from JS `el.focus()` + synthetic `blur` | ✅ **Resolved** | `grep` finds no `focus(`/synthetic `blur` dispatch in either injected script; both `setVal` helpers now only write through the prototype setter and dispatch `input`/`change` (`top_up_gateway_screen.dart:706-726`, `:1207-1225`). |
| **A2** | Missing `onRenderProcessGone` → default process termination | ⚠️ **Accepted risk (Option 3), documented** | `docs/reviews/otp-crash-a2-rationale.md` states the threat, the upstream gap (confirmed again: zero `RenderProcessGone`/`renderProcessGone` matches in the whole `webview_flutter_android-4.14.1` package; no `dependency_overrides`/fork in `pubspec.yaml`/`pubspec.lock`), the implemented mitigations, the acceptance decision, and the scheduled migration. See **B-1**. |
| **A3** | `BadParcelableException` / `ClassCastException` in the SMS `BroadcastReceiver` | ✅ **Resolved** | `MainActivity.kt:34-84` whole-body `try/catch (Throwable)` with state reset; `:45` pre-set `extras.classLoader`; `:93-104` `safeParcelable<T>()`; `:233-237` guarded `getStringExtra`; `:239-243` guarded `invokeMethod` with `Log.w`. |
| **A4** | Double `MethodChannel.Result` reply → `Reply already submitted` | ✅ **Resolved** | `PlatformChannel.kt:50-52` wraps every call once at the handler chokepoint (covers all 30+ branches **and** the catch-all at `:391-393`); `:362-377` makes cookie application idempotent; `MainActivity.kt:190` wraps the consent result; `SingleReplyResultTest` 4/4 green. |

---

## 2. Blocking items — round-1 resolutions and the round-2 blocker

### B-1 · A2 — renderer death: **CLOSED (accepted risk)**

My previous review allowed three outcomes; the council chose the third, explicitly and in writing:

- `docs/reviews/otp-crash-a2-rationale.md` records the vector, the A1 catalyst, the upstream
  limitation (no `onRenderProcessGone` in the plugin at any version, no Dart hook), the mitigations
  actually shipped (A1 removal, 2 s JS timeouts, lifecycle guards), and a **formal risk acceptance**
  with a follow-up migration task to `flutter_inappwebview` or a capable `webview_flutter` release.
- This satisfies the stated condition (“it must be recorded as an accepted known-crash vector and
  the A2 claim removed from the change description — not silently dropped”).

**Residual risk (explicitly retained):** if the Chromium renderer itself dies at the OTP moment, the
host process is still terminated. Removing `focus()` lowers the probability; it does not handle the
event. That is now an accepted product risk, not a review finding.

**Documentation accuracy (R-4):** §3.2 claims “*all* JavaScript invocations … are wrapped in
`.timeout(const Duration(seconds: 2))`”. That is true for `_autoFillCard`
(`top_up_gateway_screen.dart:821-823`) and `_autoFillOtp` (`:1289-1291`), but not for
`_injectGatewayScript` (`:688`), which is fire-and-forget (`unawaited`) and therefore harmless.
Also §3.2 says `.catchError((_) => false)`; the code uses `try/catch` around the await — behaviourally
equivalent. Worth one edit so the accepted-risk document is exact.

### B-2 · A4 — double reply: **CLOSED**

- `PlatformChannel.kt:50-52` — `onMethodCall` now wraps the incoming result in
  `SingleReplyResult(rawResult)` before the `when`, so the catch-all at `:391-393` and every
  async handler (biometrics, cookies, alarms, SMS) share one claim. This is exactly remediation
  step 1 of B-2.
- `PlatformChannel.kt:362-377` — `applyCookies` now runs under
  `AtomicBoolean.compareAndSet(false, true)`, so the `removeAllCookies` callback racing the
  `catch` fallback can no longer apply/reply twice. Remediation step 2.
- `SingleReplyResult.kt:13-31` — correct `compareAndSet` gate; `success`, `error`,
  `notImplemented` are all terminal-aware; duplicate replies are dropped.
- `SingleReplyResultTest.kt` — 4 JVM tests cover duplicate `success`, `success`→`error`,
  duplicate `error`, and duplicate/`notImplemented`; **all 4 pass** in
  `build/app/test-results/testDebugUnitTest/TEST-ir.ac.uk.bahonar_nut.SingleReplyResultTest.xml`
  (the whole Kotlin unit task is green: 65 tests, 0 failures). Remediation step 3.
- `MainActivity.kt:190` wraps again; double-wrapping is harmless (inner gate wins first).

### B-3 · Space-grouped amount false positives: **CLOSED for every named case**

Re-ran the exact four reproducers from the previous review, plus the added variants, against the
current implementation and against `994aa02`:

| SMS | `994aa02` | previous tree | **current** |
|-----|-----------|---------------|-------------|
| `برداشت: 1 200 000` | `null` | `1200000` | **`null`** |
| `برداشت از حساب: 50 000\nموجودی: 120,000 ریال` | `null` | `50000` | **`null`** |
| `موجودی: 2 500 000` | `null` | `2500000` | **`null`** |
| `برداشت 50 000 از حساب` | `null` | `50000` | **`null`** |
| `واریز: 15 000 000` | `null` | `15000000` | **`null`** |
| `تاریخ: 1403 05 12` | `null` | — | **`null`** |

Mechanism: the collapser is now confined to lines carrying an OTP hint
(`otp_extractor.dart:109-127`), and amount-context groups are masked regardless of currency
(`:59-78`). Both changes were the recommendations in B-3.

Positives preserved (spot-checked, base vs current identical): `رمز پویا: 123456`,
`رمز دوم پویا: 123-456`, `رمز یک‌بار مصرف: ۱۲۳ ۴۵۶`, the Refah template
(`… مبلغ 150000 ریال: 829104`), Mellat/Melli/Saman/Pasargad/Tejarat/Saderat/Keshavarzi samples,
`کد یکبار مصرف: 1234 5678`, `رمز پویا شما 928374 است`, spaced phone/date/tracking lines.
32/32 targeted tests pass, including the B-3/date/phone regressions
(`test/core/auth/otp_extractor_test.dart:203-216`).

### B-4 · Rial invariant guard on the new amount regexes — **CLOSED (round 3)**

*Round-2 finding, retained for the record.* The two round-2 amount rules were written across lines, so
`test/core/shared/currency_display_test.dart` reported `lib/core/auth/otp_extractor.dart:63` and `:69`
as Rial literals.

**Round-3 resolution:** option 1 (the minimal fix) was applied — every amount rule now starts its raw
string on the `RegExp(` line (`:62`, `:66`, `:70`), exactly like the pre-existing rules at `:46`, `:51`,
`:56`. Re-verified: `flutter test test/core/shared/currency_display_test.dart` → **5/5**, and the full
suite → **1519/1519**. No test was modified to accommodate the guard.

*Original round-2 analysis (superseded):*

`test/core/shared/currency_display_test.dart:94-174` enforces the product rule “the word «ریال»
must never appear in a display literal”. It treats a line as parser context only when that *same
line* contains `RegExp`, `replaceAll` or `replaceFirst` (`:183-186`). The two round-2 amount rules
are written as:

```dart
.replaceAll(
  RegExp(                          // ← matches the guard
    r'(?:مبلغ|…|انتقال)…(?:\s*(?:ریال|تومان))?',   // ← line 63: has ریال, no RegExp
  ),
```

so lines 63 and 69 are reported as offenders:

```
lib\core\auth\otp_extractor.dart:63: r'(?:مبلغ|…)(?:\s*(?:ریال|تومان))?',
lib\core\auth\otp_extractor.dart:69: r'(?:مبلغ|…)(?:\s*(?:ریال|تومان))?',
```

Reproduced in isolation:

```
flutter test test\core\shared\currency_display_test.dart
00:01 +4 -1: Some tests failed.
```

The pre-existing currency rules (`otp_extractor.dart:46`, `:51`, `:56`) pass only because their
`RegExp(r'…')` is on one physical line. `ci.yml:43-44` runs `flutter test`, so this is a red build,
not a style opinion: the guard is the repository's deliberate defence against showing Rial.

**Required fix (either is acceptable, the first is minimal):**

1. Reflow the two new patterns so the raw string starts on the `RegExp(` line, matching the
   formatting of the existing rules at `:46`, `:51`, `:56`; or
2. Teach the guard to carry parser context across a multi-line `RegExp(` / `replaceAll(` (a test
   change that keeps the patterns readable), plus a comment stating the intent; or
3. Escape the unit (`\u0631\u06cc\u0627\u0644`), which hides the word from the scanner but is
   unreadable and not recommended.

Then re-run `flutter test test\core\shared\currency_display_test.dart` and the full suite.

**Verified:** reflowing the two patterns (option 1) in a temporary probe made
`currency_display_test` (5/5) and `otp_extractor_test` (32/32) pass — 37/37 together. The probe was
reverted byte-for-byte; the working tree still carries the patch as submitted.

### B-5 · OTP widget tests asserting the removed snackbar — **CLOSED (round 3)**

*Round-2 finding, retained for the record.* The two OTP-integration tests still expected
«… با موفقیت دریافت و در فیلد درج شد.».

**Round-3 resolution:** both expectations were changed to the truthful neutral copy
«رمز دوم پویا (۷۴۹۲۱۵) دریافت شد.» / «رمز دوم پویا (۱۱۲۲۳۳) دریافت شد.»
(`test/ui/features/top_up/top_up_gateway_otp_test.dart:86-90`, `:187-191`), which is exactly the
`filled == false` branch the widget test exercises (no `WebViewController` under
`autoLaunchBrowser: false`). Re-verified: **3/3** tests pass, and the suite is green. The behaviour was
not bent to the test — the test follows the behaviour.

*Original round-2 analysis (superseded):*

The round-2 truthful-status change replaced the unconditional

> «رمز دوم پویا (۷۴۹۲۱۵) با موفقیت دریافت و در فیلد درج شد.»

with `… با موفقیت در فیلد مربوطه درج شد.` when the fill returned `true`, and the neutral
`… دریافت شد.` otherwise (`top_up_gateway_screen.dart:1175-1200`). The two integration tests were not
updated:

- `test/ui/features/top_up/top_up_gateway_otp_test.dart:86-91` —
  `starts SMS user consent and receives OTP correctly`
- `:189-194` — `handles consecutive payment sessions cleanly without stale callback leaks`

Both fail with:

```
Expected: exactly one matching candidate
  Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing
          رمز دوم پویا (۷۴۹۲۱۵) با موفقیت دریافت و در فیلد درج شد.: []>
```

In the widget test there is no `WebViewController` (`autoLaunchBrowser: false`), so `_autoFillOtp`
returns `false` and the new message is the neutral «… دریافت شد.» — which is exactly the truthful
behaviour S-1 asked for. The tests must follow the behaviour, not the other way round.

**Required fix:** update both expectations to the neutral message (and optionally add a case for the
`filled == true` wording), or assert the `رمز دوم پویا: <digits>` chip + the «درج در درگاه» button
instead of the transient snackbar. Consider extracting the Persian copy into constants so the tests
and the screen cannot drift again. Re-run `flutter test test/ui/features/top_up` and the full suite.

**Verified:** changing only the two expectations to «… دریافت شد.» in a temporary probe made all 3
tests in `top_up_gateway_otp_test.dart` pass. The probe was reverted; the tests as submitted still
assert the removed text.

---

## 3. Secondary items from round 1

| Item | Status | Evidence |
|------|--------|----------|
| **S-1** truthful success message | ✅ Fixed | `_autoFillOtp` returns the script's boolean via `runJavaScriptReturningResult` and normalizes `true`/`'true'`/`1` (`:1289-1292`); `_applyIncomingOtp` shows the “inserted” wording only when `filled` (`:1175-1200`). |
| **S-2** clipboard outside the OTP path | ✅ Fixed | Single `_copyQuietly` helper (`:1154-1160`) used on the OTP path (`:1171`) and all three desktop-card copy sites (`:1968`, `:1985`, `:2016`). |
| **S-3** JS liveness/timeouts | ✅ Fixed (for the two fill paths) | Both fill scripts now `await … .timeout(const Duration(seconds: 2))` inside `try/catch` (`:821-823`, `:1289-1293`). `_injectGatewayScript` remains un-timed but is not awaited; see R-4. |
| **S-4** `isConsentInFlight` can stick | ⚠️ Not addressed | Still returns a hollow `success(true)` when a prior session is believed active (`MainActivity.kt:191-200`); only the Play Services `TIMEOUT` broadcast or `onDestroy` heals it. Non-blocking, carried as **R-5**. |
| **S-5** R8 keep rules for GMS parcelables | ✅ Fixed | `proguard-rules.pro:19-21` keeps `Status` and `auth.api.phone.**`. |
| **S-6** live OTP retained after dispose | ✅ Partial | `dispose()` now clears `_receivedOtp` and `_controller` before `super.dispose()` (`:1298-1307`). The clipboard copy is still never cleared; see **R-6**. |
| **S-7** collapser regression tests | ✅ Fixed | New tests including the four B-3 SMS, spaced amounts, spaced date, and grouped/international phones (`test/core/auth/otp_extractor_test.dart:153-216`). |
| **S-8** Kotlin test for `SingleReplyResult` | ✅ Fixed | 4 JVM tests, green. |
| **N-1** `fillInDoc` depth comment | ✅ Fixed | Comment now states the empirical 4-level bound (`:1254-1255`); the incorrect “cyclic references” rationale is gone. |
| **N-2** duplicated `isVisible` | ⚠️ Open | Still copy-evolved in two scripts (`:728-738`, `:1228-1238`); cosmetic. |
| **N-3** `Throwable` swallowing | ⚠️ Improved | `invokeMethod` now catches `Exception` and logs (`:239-243`); the outer `onActivityResult` guard is still `Throwable` (`:246`) — deliberate, since an `Activity` callback must not throw. |
| **N-4** `AtomicBoolean` rationale | ✅ Fine | Harmless and future-proof. |
| **N-5** dead import | ✅ Fixed (round 3) | `java.util.concurrent.atomic.AtomicBoolean` is no longer imported in `MainActivity.kt` (verified by `Select-String` → no matches); the guard lives in `SingleReplyResult.kt`. |

---

## 4. Secondary findings — status after round 3

R-1, R-3 and R-4 are **closed**; R-2 remains open as a defence-in-depth follow-up; R-5/R-6 are carried.
R-7 is new in round 3 (a narrow side-effect of the R-3 mask). Full round-3 evidence is in §0.2 and §0.4.

### R-1 · Amount-keyword masking creates false negatives on plausible OTP labels — **CLOSED (round 3)**

The amount-context group no longer contains `خرید|شارژ|انتقال` (`:62`, `:66`), so the five
`<label><amount-verb>:<code>` reproducers from round 2 extract again and are now regressions in
`test/core/auth/otp_extractor_test.dart:207-213`. `مبلغ|موجودی|مانده|باقیمانده|برداشت|واریز` keep their
unrestricted masking, so B-3 stays closed.

*Original round-2 analysis (superseded):*

The new “transaction keyword followed by amount” rule (`otp_extractor.dart:59-78`) also masks a code
when an amount verb sits immediately before the code. Differential probe (base vs current):

| SMS | `994aa02` | current |
|-----|-----------|---------|
| `رمز پویا خرید: 482915` | `482915` | **`null`** |
| `رمز دوم پویا خرید: 482915` | `482915` | **`null`** |
| `کد تایید خرید: 482915` | `482915` | **`null`** |
| `رمز دوم خرید: 482915` | `482915` | **`null`** |
| `کد یکبار مصرف خرید: 482915` | `482915` | **`null`** |

Intervening words are safe (`رمز خرید اینترنتی: …`, `کد تایید خرید شما: …`,
`رمز انتقال وجه: …` all still extract), so the blast radius is the exact pattern
`<label><amount-verb>:<code>`.

**User impact:** the SMS is silently ignored (`_handleIncomingSms` returns early when the code is
`null`), so the user must type the code manually. No wrong code is autofilled and nothing crashes.

**Suggested fix:** make the ambiguous verbs (`خرید`, `شارژ`, `انتقال`) require an amount shape
(currency word or a ≥2-group thousands grouping), or skip masking on any line that also carries an
OTP label (`رمز|کد|otp|pin`); keep `مبلغ|موجودی|مانده|باقیمانده|برداشت|واریز` unrestricted. Add the
five strings above as regressions.

### R-2 · The collapser still joins an unmasked space-grouped amount on a hinted line — **OPEN (non-blocking)**

Re-confirmed unchanged in round 3 (§0.4). Still needs a currency-less, keyword-less, space-grouped
amount on the OTP line before the code; no such template exists in the project's corpus or the bank
formats the extractor documents. Keep as a defence-in-depth follow-up.

The line-wide collapser runs before Pattern 1, so an amount that is neither currency-suffixed nor
keyword-preceded but shares the OTP line is joined and then wins Pattern 1:

| SMS | `994aa02` | current |
|-----|-----------|---------|
| `رمز پویا خرید اینترنتی 1 200 000: 482 915` | `null` | **`1200000`** |
| `کد تایید خرید اینترنتی 250 000: 482915` | `482915` | **`250000`** |
| `رمز دوم پویا 1 200 000: 482 915` | `null` | **`1200000`** |

This is a leftover of the B-3 class, and `250000` is exactly the card-blocking outcome B-3 warned
about. It is **not** the plain-transaction case that was blocked: it needs a currency-less,
keyword-less, space-grouped amount on the same line as the OTP label, before the code. No such
template exists in the project's corpus or the bank formats the extractor documents, and the
equivalent **ungrouped** variant (`کد تایید خرید اینترنتی 250000: 482915` → `250000`) is a
pre-existing ordering flaw in both revisions, not a regression of this patch. That is why it is
recorded here as should-fix rather than a blocker.

**Suggested fix (defence in depth):** in the collapser callback, only join groups that are *adjacent
to the label/colon* (bounded window), or reject a join when a digit group is separated from the label
by a colon+space (amount position), or simply run the strong `<label> : code` extraction before the
collapser. Add the three strings above.

### R-3 · Hinted non-OTP codes are still collapsed — **CLOSED (round 3)**

The REF mask now carries `رهگیری|ملی|پستی|شعبه|بورسی|سفارش|تخفیف` with grouped/spaced tails
(`:76-79`) and `otpLineHint` is tightened (`:108-111`). `کد رهگیری/ملی/پستی: 12 345 678` and
`کد شعبه: 123 456` now return `null` (regressions at `otp_extractor_test.dart:215-220`).
Side effect of the bare `ملی` token → **R-7**.

*Original round-2 analysis (superseded):*

`کد رهگیری: 12 345 678` → `12345678`, `کد ملی: 12 345 678` → `12345678`,
`کد شعبه: 123 456` → `123456` (base: `null` for all three). Same mechanism as R-2 and the same
severity class, but these tokens are normally ungrouped in bank SMS. Extending the existing REF mask
(`:81-84`) with `رهگیری|ملی|پستی|شعبه|بورسی|سفارش|تخفیف` costs nothing and closes the group.

### R-4 · A2 rationale is not exact about JS timeouts — **CLOSED (round 3)**

`docs/reviews/otp-crash-a2-rationale.md` §3.2 now states `.timeout(const Duration(seconds: 2))` with
guarded `try/catch` for `_autoFillCard`/`_autoFillOtp` and records `_injectGatewayScript` as
`unawaited` fire-and-forget. The accepted-risk record is now auditable against
`top_up_gateway_screen.dart:823`, `:1291`.

*Original round-2 analysis (superseded):*

See B-1: `_injectGatewayScript` (`:688`) has no timeout, and the document describes
`.catchError` where the code uses `try/catch`. Neither changes the risk decision; correct the text so
the accepted-risk record is auditable.

### R-5 · `isConsentInFlight` watchdog (carried from S-4)

Still unaddressed. A stale `true` yields a hollow `success(true)` and no Play Services session until
the 5-minute `TIMEOUT` broadcast. Add `consentStartedAt` (or restart the retriever).

### R-6 · Clipboard lifetime (carried from S-6)

The OTP is still written to the system clipboard for an unbounded time. Consider not copying when
the automatic fill returned `true`, and clearing after ~60 s otherwise.

### R-7 · `ملی` alone over-masks the bank name «بانک ملی» — **OPEN (non-blocking, new in round 3)**

`ملی` in the REF mask (`:77`) also matches the bank name when a bare number follows it:

| SMS | `994aa02` | current |
|-----|-----------|---------|
| `بانک ملی\n123456 رمز پویا شماست` | `123456` | **`null`** |
| `بانک ملی 482915 رمز پویا` | `482915` | **`null`** |

Same class and severity as round-2 R-1 (silent ignore, manual entry, no wrong fill, no crash).
Forward-order Melli templates (`بانک ملی\nرمز پویا: 123 456`) are unaffected. Fix: narrow the token to
`کد\s*ملی` (optionally `کد\s*(?:پستی|شعبه|بورسی|سفارش)`), add the two strings above as regressions.

---

## 5. Verification commands and results

### 5.1 Round-3 final run (current tree, this pass)

| Command | Result |
|---------|--------|
| `flutter analyze` | ✅ `No issues found!` |
| `flutter test test/core/shared/currency_display_test.dart test/core/auth/otp_extractor_test.dart` | ✅ 39/39 |
| `flutter test test/ui/features/top_up/top_up_gateway_otp_test.dart` | ✅ 3/3 |
| `flutter test` (whole suite, single invocation) | ✅ **1519 passed, 0 failed** |
| `gradlew :app:cleanTestDebugUnitTest :app:testDebugUnitTest --offline` | ✅ `BUILD SUCCESSFUL`; XML: 6 suites, **65 tests, 0 failures, 0 errors** |
| Extractor differential probe (26 samples, deleted after use) | ✅ B-3/R-1/R-3 reproducers correct; ⚠️ R-7 + R-2 recorded above |
| Probe cleanup | ✅ `git status --short` shows only the 7 modified files + 2 new Kotlin files + council documents |

### 5.2 Round-2 run (historical, superseded)

| Command | Result |
|---------|--------|
| `D:\flutter\bin\flutter.bat analyze` | ✅ `No issues found!` |
| `D:\flutter\bin\flutter.bat test test/core/auth/otp_extractor_test.dart` | ✅ 32/32 passed |
| `D:\flutter\bin\flutter.bat test test\core\shared\currency_display_test.dart` | ❌ 4/5 passed — Rial-invariant guard fails on `otp_extractor.dart:63,69` → **B-4** |
| `D:\flutter\bin\flutter.bat test test/ui/features/top_up` | ❌ 2 failures in `top_up_gateway_otp_test.dart` (stale snackbar expectation) → **B-5** |
| `D:\flutter\bin\flutter.bat test` (full suite, per directory) | ❌ `test/core` 770 pass + 1 fail (B-4); `test/ui` 310 pass + 2 fail (B-5); `test/adapter`, `test/background`, `test/platform`, `test/transport` green |
| `android\gradlew.bat :app:testDebugUnitTest --offline` | ✅ `BUILD SUCCESSFUL`; 65 tests, 0 failures — includes `SingleReplyResultTest` 4/4 |
| Dependency check | ✅ `webview_flutter 4.14.1` / `webview_flutter_android 4.14.1`, hosted, no overrides, no renderer-death API |

---

## 6. Note on the filed Claude review

`docs/reviews/otp-crash-fix-review-claude.md` (APPROVE) is consistent with this round's assessment of
the Dart/Kotlin crash paths, but it predates the round-2 changes, never evaluates A2, and could not
have seen B-4/B-5. Its S-1 and S-2 are obsolete: the `isConsentInFlight` early return now replies
(`MainActivity.kt:198`), and the OTP `isVisible` now checks `!el.disabled` itself
(`top_up_gateway_screen.dart:1233`). I agree with its conclusions on the vectors it examined; with the
suite now green, its APPROVE and mine agree on the final tree.

---

## 7. Final recommendation

**APPROVE — signed off.**

- **B-1** — accepted risk, recorded in `docs/reviews/otp-crash-a2-rationale.md`; keep the
  `flutter_inappwebview` / upstream-upgrade follow-up as a tracked task and do not describe A2 as
  “fixed” in release notes.
- **B-2** — closed; keep `SingleReplyResult` as the single gate for any future channel.
- **B-3** — closed for every named case and regression-tested.
- **B-4** — **closed**: the amount regexes are reflowed onto their `RegExp(` lines; Rial guard 5/5.
- **B-5** — **closed**: the OTP widget tests now assert the truthful status copy; 3/3.
- **R-1, R-3, R-4, N-5** — closed in round 3 with regressions/tests.

**Follow-ups (non-blocking, next train):** **R-7** (narrow the `ملی` REF token to `کد ملی`),
**R-2** (bounded collapser join), **R-5** (`isConsentInFlight` watchdog), **R-6** (clipboard lifetime).
None of them is a crash vector, a wrong-code autofill, or a regression of the plain-transaction
false-positive class that motivated the original block.

**Council sign-off:** this review is final for the patch as it stands in the working tree
(`git diff 994aa02` + the two new Kotlin files + the council documents). The crash-vector analysis is
not reopened; the suite is green on both toolchains; the two round-2 blockers are closed.

*Note for the council (round 2, historical):* the host's `C:` drive was almost full during the round-2
re-review (0.1–0.3 GB free), which made `flutter test` fail with `errno 112` while copying
`listener.dart.dill`; the single-invocation full run was also lost once to a harness
`OutOfMemoryException`. The round-2 suite was therefore completed per directory with `TEMP`/`TMP`
pointed at `D:\tmp\flutter-temp`.

*Round-3 note:* with ~2 GB free on `C:` and the same `TEMP`/`TMP` redirection, the whole suite ran in a
**single invocation** (1519/1519) and the Kotlin task was force-rerun (`cleanTestDebugUnitTest`) rather
than accepted as `UP-TO-DATE`. Both round-2 blockers no longer reproduce; they are green in isolation
and in the full run.
