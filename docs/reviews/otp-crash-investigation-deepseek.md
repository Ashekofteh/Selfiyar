# Dynamic OTP (رمز دوم پویا) Autofill — Crash Investigation

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Date:** 2026-11-23
**Base commit:** `994aa02 fix(resilience): detect asp errors, protect meal mirror, and fix tehran date (Stage 5)`
**Working tree:** clean (`git status --short` empty) — this report is the only file written
**Reported symptom:** «برخی اوقات هنگام فراخوانی پرکردن اتوماتیک رمز دوم پویا در صفحه پرداخت برنامه کرش می‌کند»
**Method:** static audit of the whole OTP lifecycle (Dart UI → MethodChannel → `MainActivity` receiver → Play Services consent → back), plus the vendored plugin sources of `webview_flutter_android 4.14.1` in the pub cache. No device/logcat capture exists in the repo (searched `captures/`, `recon/`, `.shots/`, `scratch/` for `FATAL EXCEPTION`, `Reply already submitted`, `onRenderProcessGone`, `SIGSEGV`), so **no vector below is confirmed by a field stack trace**. Each finding therefore carries an explicit confidence and a cheap way to confirm it.
**Scope note:** v2.0.6 ([`RELEASE_NOTES_V2.0.6.md`](D:/Bahonar-Nut/.github/RELEASE_NOTES_V2.0.6.md:19)) already claims to have fixed "کرش در پرداخت‌های متوالی". That fix addressed *receiver* concurrency; it did **not** touch the two highest-severity vectors below (renderer death, and the JS `focus()`), which is consistent with the bug surviving.

---

## 1. Executive summary

The OTP autofill path is not one bug; it is a chain of independent failure domains that meet at one moment — the instant an SMS broadcast lands while a bank WebView is alive. Three of them can kill the **process** (not merely throw a Dart error), and one of them can get the user's **card blocked** without any crash at all.

**The three process-killing vectors, in order of likelihood × severity:**

| # | Vector | Location | Kills the process? | Confidence |
|---|---|---|---|---|
| **A1** | Injected JS calls `el.focus()` on the OTP input, opening the IME inside a Flutter platform view at the exact moment the consent dialog closes | [top_up_gateway_screen.dart:1178](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1178) | Yes (OEM `InputMethodManager` / renderer), or freezes | High that it is the trigger; Medium on the exact native frame |
| **A2** | No `onRenderProcessGone` handler anywhere; `webview_flutter_android 4.14.1` does not override it, so **any** renderer death is a process death by Android contract | plugin `WebViewClientProxyApi.java` (no such method) + no app-side handler | **Yes, guaranteed** | Certain (verified in plugin source) |
| **A3** | `smsVerificationReceiver.onReceive` has **no** `try/catch` around `intent.extras` / `getParcelable` / `getStringExtra`; a `BadParcelableException` or `ClassCastException` here is an uncaught main-thread exception | [MainActivity.kt:25-72](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:25) | **Yes** | Certain that it is unguarded; Medium on frequency |
| **A4** | `MethodChannel.Result` is answered from several paths with no once-guard; a second reply throws `IllegalStateException: Reply already submitted` on the main thread | [PlatformChannel.kt:386](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:386), [PlatformChannel.kt:368-370](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:368) | **Yes** | Medium (path is real, trigger is rare) |

**The card-blocking vector (no crash):** `extractOtpCode` has no notion of a *bank* OTP. Any SMS with «کد» plus a 5–8 digit number is accepted, copied to the clipboard, and injected into the bank's OTP field. Verified by probe: `کد تخفیف: 12345 → 12345`, `کد تحویل سفارش: 482913 → 482913`, and a line with no keyword at all (`رسید: 123456 → 123456`) is accepted by the "standalone number" fallback at [otp_extractor.dart:123-129](D:/Bahonar-Nut/lib/core/auth/otp_extractor.dart:123). Three wrong PIN2s in a row typically locks the card at Iranian issuers.

**The honesty problem:** `_autoFillOtp` returns `true` after merely *dispatching* `runJavaScript` ([top_up_gateway_screen.dart:1238-1239](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1238)) and `_handleIncomingSms` ignores that value while unconditionally showing «با موفقیت دریافت و در فیلد درج شد» ([top_up_gateway_screen.dart:1153-1166](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1153)). On every old WebView where the script cannot even parse, the user is told the OTP was inserted when nothing happened.

**Verdict:** the crash cannot be closed by Dart-only changes. **A2 requires a native fix (vendored plugin patch or `flutter_inappwebview`)**; A1 and A3 are small, surgical fixes; A4 is a 20-line guard class. The OTP extractor needs a "is this really a bank OTP?" gate before anything is injected.

---

## 2. What I verified is *not* a crash (so the fix list stays honest)

These were on the task's hypothesis list. They are real defects, but they do **not** terminate the process, and treating them as the crash would waste a release:

| Hypothesis | Reality |
|---|---|
| Cross-origin iframe access throws `SecurityError` | `ifr.contentDocument` returns `null` cross-origin; `contentWindow?.document` throws `SecurityError` — **caught** at [:1228](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1228). No recursion cycle is possible (the document tree is acyclic), so no stack overflow. |
| `const`/`let`/arrow functions on old WebViews | A `SyntaxError` from `evaluateJavascript` is returned as a result string, not thrown natively; Dart's `await runJavaScript` completes. **Silent no-op, not a crash** — but see §7.6. |
| CSS selector syntax errors (`[i]` flag needs Chrome 49+) | Every selector is inside a per-selector `try` at [:1213-1221](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1213), so one bad selector cannot abort the loop. |
| `Clipboard.setData` unawaited | A `PlatformException` becomes an **unhandled async error** → `PlatformDispatcher.onError` → logcat. Fatal only if a custom error handler treats it as fatal (there is none today). See §7.1. |
| `ScaffoldMessenger.of(context)` after pop | Guarded by `mounted` at [:1142](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1142). The deactivated-element assertion is **debug/profile only**; in release the inherited lookup still resolves. Not a process kill. |
| `_controller!.runJavaScript` on a destroyed WebView | Pigeon answers with a `PlatformException` (`instance was disposed`); both call sites are wrapped in `try/catch`. The worse outcome is a **hung future** (see §7.4), not a crash. |
| `extractOtpCode` ReDoS | Every quantifier is bounded (`{0,35}`, `{4,16}`); no nested ambiguity. Linear on SMS length. Not a crash. |

---

## 3. A2 — Renderer death is a guaranteed process kill (highest structural severity)

**Fact, verified in the dependency source:** `webview_flutter_android 4.14.1` (the latest; `pubspec.lock` resolves `^4.10.1` to `4.14.1`) defines `WebViewClientImpl` in
`…/webview_flutter_android-4.14.1/android/src/main/java/io/flutter/plugins/webviewflutter/WebViewClientProxyApi.java`
and **does not override `onRenderProcessGone`**. A grep for `onRenderProcessGone` across the entire package returns nothing.

**Why that matters:** `WebViewClient`'s default implementation returns `false`, and Android's contract is explicit — returning `false` means *"the application will be killed"*. On API ≥ 26 the renderer is a separate process, so a renderer `SIGSEGV`/OOM surfaces as a callback that nobody handles; on API < 26 the renderer is in-process and the app dies directly. Either way the user sees an app crash, with no Dart error and nothing in the app's logs.

**Why the OTP moment is the trigger:** the process has, at that instant, (a) a Flutter engine, (b) a hybrid-composition WebView with the bank's own scripts, (c) the injected 1.2 s `setInterval` from [`_injectGatewayScript`](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:678) doing DOM reads, (d) a fresh DOM + iframe walk from `_autoFillOtp`, and (e) a soft keyboard about to be raised. On a 1–2 GB device this is the memory high-water mark of the whole session. A second stacked gateway screen (possible — see §7.4) doubles it.

**Remediation (choose one):**

1. **Vendored patch (surgical, recommended).** Add `webview_flutter_android` as a `path:` dependency, add to `WebViewClientImpl`:
   ```java
   @Override
   public boolean onRenderProcessGone(@NonNull WebView view, @NonNull RenderProcessGoneDetail detail) {
     api.getPigeonRegistrar().runOnMainThread(
         () -> api.onRenderProcessGone(this, detail.didCrash(), reply -> null));
     return true; // keep the host process alive; the WebView is unusable
   }
   ```
   Surface it through `AndroidNavigationDelegate` and, in the screen, set a `_rendererGone` flag, show a Persian banner («صفحه درگاه از کار افتاد — بازخوانی»), disable the OTP button, and `loadRequest` a fresh controller. This is the only way to keep the process alive.
2. **Migrate to `flutter_inappwebview`**, which exposes `onRenderProcessGone` out of the box. Larger diff, but no fork to maintain.
3. **Interim only:** a JS liveness watchdog — call `runJavaScriptReturningResult('1')` with a 2 s timeout before/after filling; if it never answers, treat the WebView as dead and stop touching it. This detects the death *after* the fact; it does not prevent the kill. Do not ship this as the fix.

---

## 4. A1 — The `focus()` call is the most likely *trigger* of the crash

**Location:** [top_up_gateway_screen.dart:1178](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1178) (OTP), and the same helper at [:708](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:708) (card).

```js
function setVal(el, val) {
  if (!el || !val) return false;
  el.focus();                    // ← raises the IME inside a platform view
  ...
  el.dispatchEvent(new Event('blur', { bubbles: true }));  // ← tells the page "done"
}
```

**Why this is the prime suspect for "sometimes, at the moment of autofill":**

- It is the *only* thing the OTP path does that a normal page view does not: it moves input focus programmatically, from JS, in a renderer, while the host activity has just resumed from the consent dialog. `InputMethodManager.showSoftInput` during an activity resume/relayout is a well-known OEM crash class (MIUI/ColorOS/EMUI), and the Flutter engine also calls `setImportantForAutofill(...)` on the WebView, which interacts with the IME/autofill service.
- `focus()` + synthetic `blur` also fires the bank page's own validation, which can navigate or re-render the page *while* the JS is still running — a renderer re-entrancy the app cannot observe.
- It happens identically on the manual paths (banner button [:1449](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1449), SnackBar action [:1163](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1163)), so "button press" and "SMS arrival" produce the same symptom — exactly as reported.

**Remediation:** do not focus. A value write plus `input`/`change` is sufficient for every gateway form observed in `captures/`; the keyboard is the user's job.

```js
function setVal(el, val) {
  if (!el || !val) return false;
  try {
    const proto = Object.getPrototypeOf(el);
    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    if (setter) setter.call(el, val); else el.value = val;
  } catch (_) { try { el.value = val; } catch (_) { return false; } }
  el.dispatchEvent(new Event('input',  { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return true;                       // no focus(), no synthetic blur
}
```
If the bank page genuinely needs focus to accept the value, use `el.focus({ preventScroll: true })` **only** after the value is committed, and never dispatch a synthetic `blur`.

---

## 5. A3 — The SMS receiver can throw on the main thread (process kill)

**Location:** [MainActivity.kt:25-72](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:25)

```kotlin
override fun onReceive(context: Context, intent: Intent) {
    if (SmsRetriever.SMS_RETRIEVED_ACTION == intent.action) {
        val extras = intent.extras ?: return                                   // ← lazy unparcel, can throw
        val smsRetrieverStatus = if (SDK_INT >= TIRAMISU)
            extras.getParcelable(SmsRetriever.EXTRA_STATUS, Status::class.java) // ← BadParcelableException / CCE
        else extras.getParcelable<Status>(SmsRetriever.EXTRA_STATUS)
        ...
```

- `intent.extras` is lazily unparceled; **any** value in the bundle that fails to unparcel throws `BadParcelableException` from the *first* access — before your code even looks at a key.
- The typed `getParcelable(key, Class)` added in API 33 throws `BadParcelableException` when the class is not found, and can throw `ClassCastException` on a type mismatch.
- The receiver is registered `RECEIVER_EXPORTED` (required for GMS on 13+). The `SmsRetriever.SEND_PERMISSION` guard is correct and keeps third-party spoofing impractical, but it does not protect against a **GMS version mismatch** or an R8-mangled Parcelable.
- **R8 is on** — `isMinifyEnabled = true`, `isShrinkResources = true` ([build.gradle.kts:80-85](D:/Bahonar-Nut/android/app/build.gradle.kts:80)) with only app-package keeps ([proguard-rules.pro:8](D:/Bahonar-Nut/android/app/proguard-rules.pro:8)). GMS ships consumer rules that should keep `Status`, but nothing in *this* project asserts it, and a release-only `BadParcelableException` is precisely the "works on my machine, crashes for some users" signature.
- An uncaught exception in `BroadcastReceiver.onReceive` is **fatal**: it is the main looper, there is no caller to catch it, Android kills the process. This is the one place in the whole flow where a `try/catch` is mandatory and absent.

**Remediation:**

```kotlin
override fun onReceive(context: Context, intent: Intent) {
    try {
        if (SmsRetriever.SMS_RETRIEVED_ACTION != intent.action) return
        val extras = intent.extras ?: return
        val status = extras.getParcelableCompat<Status>(SmsRetriever.EXTRA_STATUS)
        when (status?.statusCode) {
            CommonStatusCodes.SUCCESS -> {
                val consent = extras.getParcelableCompat<Intent>(SmsRetriever.EXTRA_CONSENT_INTENT)
                ...
            }
            ...
        }
    } catch (t: Throwable) {
        // A receiver must never throw: the only sane outcome is to reset and wait
        // for the next broadcast.
        isConsentInFlight = false
        unregisterSmsReceiver()
    }
```

Add the keep rule explicitly, so a future GMS bump cannot silently break release builds:

```proguard
-keep class com.google.android.gms.common.api.Status { *; }
-keep class com.google.android.gms.auth.api.phone.** { *; }
```

---

## 6. A4 — Double `MethodChannel.Result` reply (process kill)

Two shapes of the same defect:

**(a) The catch-all can reply twice.** [`PlatformChannel.onMethodCall`](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:49) wraps the whole `when` in `try { … } catch (e: Exception) { result.error("PLATFORM_ERROR", …) }` ([:386-388](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:386)). Any method that has already called `result.success(...)` and then throws on a later line gets a **second** reply. Flutter's `Result` throws `IllegalStateException: Reply already submitted` — on the main thread, uncaught → process death.

**(b) `setWebViewCookies` posts its reply asynchronously.** [:368](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:368) posts `result.success(true)`; [:370](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:370) posts `result.error(...)` from the catch; and `applyCookies()` is invoked from **two** places — the `removeAllCookies` callback and the `catch` fallback at [:375-378](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/PlatformChannel.kt:375). `CookieManager.removeAllCookies` is documented to invoke its callback once, but multiple WebView versions have shipped double-invocation bugs, and the fallback path can race the callback. This runs on **every gateway load**, immediately before the OTP flow.

**(c) `MainActivity.startSmsUserConsent`** has five reply paths ([:158](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:158), [:161](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:161), [:173](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:173), [:178](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:178), [:183](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:183)) and no guard. Today the paths are mutually exclusive; one refactor away from a fatal double reply.

**Remediation:** a `OnceResult` decorator, applied at the top of `onMethodCall` and in `startSmsUserConsent`:

```kotlin
private class OnceResult(private val delegate: MethodChannel.Result) : MethodChannel.Result {
    private val replied = java.util.concurrent.atomic.AtomicBoolean(false)
    override fun success(result: Any?) { if (replied.compareAndSet(false, true)) delegate.success(result) }
    override fun error(code: String, msg: String?, details: Any?) { if (replied.compareAndSet(false, true)) delegate.error(code, msg, details) }
    override fun notImplemented() { if (replied.compareAndSet(false, true)) delegate.notImplemented() }
}
```
and make `applyCookies()` run at most once (`AtomicBoolean`), so the fallback cannot double-apply.

---

## 7. Dart-side and lifecycle defects (not process-killing, still must ship)

### 7.1 `Clipboard.setData` is fire-and-forget with no error path
[:1150](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1150). An OEM `SecurityException`, a missing plugin, or a background-clipboard refusal becomes an unhandled async error. There is **no** `PlatformDispatcher.onError` / `FlutterError.onError` in [`main.dart`](D:/Bahonar-Nut/lib/main.dart:34), so the only trace is logcat — which is why this class of bug is invisible in the field.

```dart
Future<void> _copyQuietly(String text) async {
  try { await Clipboard.setData(ClipboardData(text: text)); } catch (_) {}
}
```
Also: copying a live OTP to the clipboard silently, and leaving it there, is a security regression — see §7.7.

### 7.2 Success is reported without evidence
`_autoFillOtp` returns `true` when the evaluation was merely *dispatched* ([:1238-1239](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1238)), and the caller ignores the result while asserting success ([:1153-1166](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1153)). The same pattern exists for cards ([:811-822](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:811)).

**Fix:** make the IIFE return a JSON string and read it with `runJavaScriptReturningResult`:

```dart
final raw = await _controller!.runJavaScriptReturningResult(script);
final ok = raw.toString().contains('"filled":true');
if (!ok && mounted) { /* «فیلد رمز پیدا نشد؛ دستی وارد کنید» + keep the copy button */ }
```
This also gives you the **liveness signal** that A2 needs: a `TimeoutException` on that call means the renderer is gone.

### 7.3 `dispose()` leaves the controller and the OTP alive
[:1245-1251](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1245) cancels the timer and clears the handler, but `_controller` and `_receivedOtp` survive. Consequences: a SnackBar action pressed after the route pops still calls `runJavaScript` on a disposed controller (caught, but pointless), and the last OTP stays in memory until GC. Set `_controller = null; _receivedOtp = null;` in `dispose`, and gate every `_autoFillOtp` entry on `mounted`.

### 7.4 `_controller` has no "is this WebView still usable" concept
Every call site checks only `_controller == null` ([:687](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:687), [:810](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:810), [:1061](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1061), [:1237](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1237)). After a renderer death (A2) or a platform-view teardown, the controller is non-null and useless; `evaluateJavascript` may never call back, so `await` hangs forever and the SnackBar's "درج مجدد" does nothing on every press. Add `bool _webViewAlive` + a 2 s timeout around every JS call, and flip the flag on failure.

### 7.5 `isConsentInFlight` can get stuck, and the early return then lies
[MainActivity.kt:154-163](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:154): when a session is "in flight", the method answers `success(true)` **without starting a new Play Services session**. If the consent activity was silently denied (Android 10+ background-activity-start restriction) or the `onActivityResult` was lost to a process restart, the flag stays `true` and every later `startSmsUserConsent` is a no-op that reports success. The 5-minute `SmsRetriever` timeout is the only thing that heals it.

**Fix:** store `consentStartedAt`, reset it from a `Handler.postDelayed` watchdog at the Play Services timeout, and on the "already in flight" path **re-register the receiver and restart the retriever** instead of returning a hollow `true`.

### 7.6 The injected JS assumes a 2020 WebView
- `replaceAll` at [:356](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:356) needs Chrome 85 (2020).
- `?.` at [:713](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:713) and [:1226](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1226) needs Chrome 80.
- `NodeList.forEach` at [:473](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:473) needs Chrome 51.
- `[attr="x" i]` selectors need Chrome 49.

A large share of the target market runs Android 7–9 with a frozen WebView. There, `_injectGatewayScript` and `_autoFillOtp` both fail at **parse time**, the Dart `catch (_)` swallows it, and the UI still says «درج شد». This is a silent, total failure of the feature on exactly the devices most likely to be in users' hands. Either drop the modern syntax (`replaceAll` → loop, `?.` → explicit `&&`, `forEach` → `for`) or gate with a feature probe and tell the user to update Android System WebView.

### 7.7 OTP exposure
The OTP is (a) shown in a SnackBar in clear text, (b) written to the system clipboard and never cleared, (c) kept in `_receivedOtp` after the payment. The clipboard is the real issue: on Android < 10 any foreground app can read it; the OTP is valid for 60–120 s. Mask it in the UI (`۱۲••۵۶`), skip the clipboard copy when the automatic fill succeeds, and clear it after ~60 s if a copy is kept as a fallback.

### 7.8 No observability at all
There is no `PlatformDispatcher.onError`, no `FlutterError.onError`, no `onConsoleMessage` on the WebView, and every failure path is `catch (_) {}`. The reason this investigation must reason from code instead of a stack trace is this line: [top_up_gateway_screen.dart:1240](D:/Bahonar-Nut/lib/ui/features/top_up/top_up_gateway_screen.dart:1240). At minimum: log the `runJavaScript` error, add `AndroidWebViewController.setOnConsoleMessage` in debug, and persist the last N Dart errors to a ring buffer so a user can attach it to a bug report.

---

## 8. The correctness defect that is worse than the crash: wrong OTPs get injected

`extractOtpCode` ([otp_extractor.dart:14](D:/Bahonar-Nut/lib/core/auth/otp_extractor.dart:14)) is a *number finder*, not an *OTP verifier*. I ran a probe against the real implementation (temporary script under the git-ignored `tool/`, deleted afterwards):

| SMS | Result | Assessment |
|---|---|---|
| `کد تخفیف: 12345` | `12345` | **False positive** — discount code |
| `کد تحویل سفارش: 482913` | `482913` | **False positive** — delivery code |
| `کد رهگیری مرسوله پستی 9876543` | `9876543` | **False positive** |
| `کد ورود شما به دیجی‌کالا: 482913` | `482913` | **False positive** — another service's OTP |
| `خرید موفق\nرسید: 123456` | `123456` | **False positive** — Pattern 3 accepts any 5–8 digit number |
| `کد سفارش 250000` | `250000` | **False positive** — an amount |
| `رمز دوم پویا: 123 456` | `null` | **False negative** — space-grouped OTP |
| `رمز پویا: 123-456` | `null` | **False negative** — hyphen-grouped OTP |
| `بانک ملت … رمز دوم پویا: 649215 …` | `649215` | Correct |

Mechanism: the keyword regex at [:81-84](D:/Bahonar-Nut/lib/core/auth/otp_extractor.dart:81) makes the qualifier **optional** (`(?:دوم|پویا|…)?`), so bare «کد» matches; `[^0-9\n]{0,35}` then bridges any intervening words to the first 5–8 digit run. Pattern 3 ([:123-129](D:/Bahonar-Nut/lib/core/auth/otp_extractor.dart:123)) then accepts *any* 5–8 digit number on *any* line when no hint matched.

`startSmsUserConsent(null)` ([MainActivity.kt:171](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/MainActivity.kt:171)) deliberately does not filter by sender, so the consent dialog can be raised by any OTP-shaped SMS in the last five minutes — including a Digikala/Snapp login code the user requested at the same time. The app then fills it into the bank's PIN2 field, and the page may submit as soon as the field looks complete (see §11.3).

**This can block the user's card**, which is a worse outcome than a crash, and it is 100% reproducible.

**Remediation:**
1. Require a **strong** anchor for the auto-fill path: `رمز دوم|رمز پویا|رمز یکبار مصرف|کد تایید|کد اعتبارسنجی|پین ۲|CVV2 dynamic`, not bare «کد». Return `null` for `کد تخفیف|کد سفارش|کد تحویل|کد رهگیری|کد ورود` explicitly.
2. **Delete Pattern 3** (the standalone-number fallback) from the auto-fill path. Keep it behind a `strict: false` parameter for tests/manual use if needed.
3. Add a sender allow-list / bank-name check (`بانک|مهر ایران|رسالت|سامان|ملت|ملی|…`) and require it for automatic injection.
4. Normalize grouped digits (`123 456`, `123-456`) **before** matching — currently these are lost.
5. Pin all nine probe cases above as unit tests; **eight of the nine rows are wrong today** (six false positives, two false negatives).

---

## 9. Concrete remediation plan

### P0 — stop the process kills (ship together)

| ID | Change | Files |
|---|---|---|
| P0.1 | Handle `onRenderProcessGone`: vendor-patch `webview_flutter_android` (return `true`, surface to Dart, show a reload banner) **or** migrate to `flutter_inappwebview` | plugin fork / `pubspec.yaml`, `top_up_gateway_screen.dart` |
| P0.2 | Wrap `smsVerificationReceiver.onReceive` in `try/catch (Throwable)`; add `getParcelableCompat`; add explicit R8 keeps for `Status` and `com.google.android.gms.auth.api.phone.**` | `MainActivity.kt:25-72`, `proguard-rules.pro` |
| P0.3 | `OnceResult` decorator on every `MethodChannel.Result`; make `applyCookies()` idempotent | `PlatformChannel.kt:49,349-382`, `MainActivity.kt:153-185` |
| P0.4 | Remove `el.focus()` and the synthetic `blur` from both fill scripts; commit the value with the native setter only | `top_up_gateway_screen.dart:1176-1194`, `:706-726` |
| P0.5 | Guard `_startTopUp` against re-entry so two WebViews can never coexist | `home_shell.dart:1856` |

### P1 — correctness and honesty

| ID | Change |
|---|---|
| P1.1 | Return a JSON status from the fill IIFE, read it with `runJavaScriptReturningResult`, and only claim success when `filled:true`; otherwise show a manual-entry hint |
| P1.2 | 2 s timeout + `_webViewAlive` flag on every JS call; a timeout means "renderer gone" and disables the button |
| P1.3 | Tighten `extractOtpCode` (strong anchors, no Pattern 3 for autofill, digit-group normalization, explicit non-bank rejections) + the nine probe tests |
| P1.4 | Await/catch `Clipboard.setData`; mask the OTP in the SnackBar; clear the clipboard after 60 s |
| P1.5 | `isConsentInFlight` watchdog + restart the retriever on the "already in flight" path |
| P1.6 | `dispose()`: `_controller = null; _receivedOtp = null;` and invalidate `_receivedOtp` on page change |
| P1.7 | Replace `replaceAll`/`?.`/`NodeList.forEach`/`[i]` selectors, or feature-probe and degrade with a visible message |

### P2 — resilience and diagnostics

- `PlatformDispatcher.onError` + `FlutterError.onError` → persistent ring buffer + a "share diagnostics" action in About.
- `AndroidWebViewController.setOnConsoleMessage` (debug) to see the injected scripts fail.
- Replace `catch (_) {}` on the JS paths with `catch (e) { debugPrint('otp fill failed: $e'); }`.
- Instrumented test: kill the renderer (`adb shell` + `chrome://crash` equivalent) and assert the app survives and shows the banner.
- Instrumented test: send a malformed `SMS_RETRIEVED_ACTION` broadcast and assert no crash.
- Unit test: `OnceResult` answers exactly once under concurrent replies.

---

## 10. Test plan (what would have caught each finding)

| Finding | Test |
|---|---|
| A1 | Widget/integration: trigger `_handleIncomingSms` with a mocked controller whose `runJavaScript` records the script; assert it contains **no** `focus(`. |
| A2 | Instrumented: force renderer death; assert the process survives (only possible after P0.1). |
| A3 | Robolectric/JVM: `onReceive` with an `Intent` whose extras contain a `Parcelable` of a missing class → expect no throw and `isConsentInFlight == false`. |
| A4 | JVM: `OnceResult` — call `success` then `error`, assert one dispatch; `setWebViewCookies` with a cookie manager that invokes its callback twice. |
| §8 | The nine probe cases, as `test/core/auth/otp_extractor_test.dart` cases. |
| §7.2 | Widget: a controller whose `runJavaScriptReturningResult` returns `{"filled":false}` → assert the UI says «درج نشد», not «درج شد». |
| §7.5 | JVM: `startSmsUserConsent` twice with the first result never delivered → second call must re-register, not return a hollow `true`. |

The existing tests at [`top_up_gateway_otp_test.dart`](D:/Bahonar-Nut/test/ui/features/top_up/top_up_gateway_otp_test.dart:51) and [`sms_otp_bridge_test.dart`](D:/Bahonar-Nut/test/platform/sms_otp_bridge_test.dart:82) exercise only the happy path (a callback arrives, a SnackBar appears). They cannot see any of the above because the WebView is never real and the receiver is never exercised.

---

## 11. Open questions that need a device

1. **Which vector actually fires?** A single `adb logcat` from a reproduction would settle it in minutes. Look for: `InputMethodManager`, `Fatal signal 11`, `IllegalStateException: Reply already submitted`, `BadParcelableException`, `onRenderProcessGone`, or simply the process disappearing with no Java stack (renderer death signature).
2. **Device/WebView versions** of the reporters. If they are on Android 7–9 with WebView < 80, §7.6 becomes a first-order cause of *silent* failure even without the crash.
3. **Does the bank page auto-submit on six digits?** This determines how dangerous §8 is (card lock vs. just a rejected code). Worth one manual test with a deliberately wrong code on a test card.
4. **Is a second gateway screen ever stacked in practice?** Check whether any crash report shows two `TopUpGatewayScreen` pushes.

---

## 12. Bottom line

The report's premise — "the OTP autofill crashes the app" — is correct, but the cause is not one line of bad Dart. It is:

1. **A missing native callback** (`onRenderProcessGone`) that converts any WebView renderer failure into an app kill, and
2. **A `focus()` call** that is the most plausible trigger of that renderer/IME failure at exactly the reported moment, plus
3. **An unguarded broadcast receiver** that can throw on the main thread when the SMS arrives, and
4. **Unguarded `MethodChannel.Result` replies** that can throw `Reply already submitted` during gateway load.

Fixing only the Dart side will not stop the crash. Fixing P0.1–P0.4 will. And while touching this code, §8 must be fixed too: an app that silently types a discount code into a bank's PIN2 field is a worse bug than one that occasionally restarts.

**Verdict: CHANGES REQUIRED.** The OTP path is not production-safe as written; the plan above is small enough to land in one release.
