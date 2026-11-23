# Technical Rationale & Risk Acceptance: Vector A2 (`onRenderProcessGone`)

**Date:** 2026-11-23  
**Scope:** Dynamic OTP Autofill Crash Remediation (`TopUpGatewayScreen`)  
**Component:** `webview_flutter_android` (v4.14.1)  

---

## 1. Technical Context

Vector A2 in the council investigation identified that `WebViewClient` in Android by default terminates the host process if the Chromium renderer process dies (`onRenderProcessGone` returns `false`).

Investigation of `webview_flutter_android 4.14.1` (and all upstream releases) confirms that:
1. `WebViewClientProxyApi.java` in the plugin does not implement or override `onRenderProcessGone`.
2. Flutter's official `webview_flutter` package does not expose an API or hook to handle renderer termination from Dart.

---

## 2. Root Cause & Threat Analysis

The investigation proved that the crashes observed in production during dynamic OTP autofill were catalyzed by **Vector A1**:
- During SMS User Consent dialog dismissal, injected JavaScript executed `el.focus()` and synthetic `el.dispatchEvent(new Event('blur'))` on the OTP input element inside the platform view.
- In OEM Android skins (Samsung OneUI and Xiaomi MIUI), raising the native IME concurrently with window modal dismissal caused an `InputMethodManager` race condition / renderer deadlock, killing the renderer process.
- Due to the absence of `onRenderProcessGone` in the plugin, the renderer death resulted in Android terminating the entire application process.

---

## 3. Implemented Protections & Mitigations

1. **Elimination of the Root Trigger (Vector A1):**
   Both `_autoFillCard` and `_autoFillOtp` have been cleansed of `el.focus()` and synthetic `blur` events. Value assignment is performed purely via prototype property descriptors followed by standard `input` and `change` events. This eliminates the OEM IME race condition.
2. **Execution Timeouts (Vector S-3):**
   Both `_autoFillCard` and `_autoFillOtp` invocations on `WebViewController` are wrapped in `.timeout(const Duration(seconds: 2))` with guarded `try/catch` error blocks returning `false` on failure or timeout. `_injectGatewayScript` is dispatched asynchronously as fire-and-forget (`unawaited`). In the event of an unresponsive WebView, the Dart event loop does not stall.
3. **Defensive UI & Lifecycle Guards:**
   - Asynchronous callbacks verify `mounted` and `_controller != null`.
   - `_handleIncomingSms` returns truthful UI status (`_applyIncomingOtp` shows insertion confirmation only when the script returns `true`).
   - `dispose()` zeroes `_receivedOtp` and `_controller`.

---

## 4. Formal Risk Acceptance (Option 3)

Per the Senior Review Council recommendation:
- Rather than maintaining an invasive, high-maintenance local vendor/fork of `webview_flutter_android` or performing a risky wholesale migration to `flutter_inappwebview` within this targeted bugfix patch, the council formally **accepts the known upstream limitation of Vector A2** for this release.
- A future platform migration to `flutter_inappwebview` or upgrading to a future version of `webview_flutter` that supports renderer process callbacks is scheduled as an independent task.
