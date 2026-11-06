package ir.ac.uk.bahonar_nut

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart <-> platform bridge.
 *
 * Deliberately narrow: the platform does storage, scheduling and notification
 * posting, and nothing else. Every decision about *what* to do stays in
 * `lib/core`, where it is unit-tested on the VM. A method channel that could
 * make decisions would put the domain rules somewhere they cannot be tested.
 */
class PlatformChannel(
    private val context: Context,
    private val notifier: ReminderNotifier,
    private val alarms: AlarmScheduler,
) : MethodChannel.MethodCallHandler {

    private val secureStore = SecureCredentialStore(context)

    private val battery = BatteryExemption(context)

    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // --- secure store ---
                "secureRead" -> {
                    val accountId = call.argument<String>("accountId")!!
                    val stored = secureStore.read(accountId)
                    if (stored == null) {
                        result.success(null)
                    } else {
                        result.success(
                            mapOf("studentId" to stored.first, "password" to stored.second),
                        )
                    }
                }

                "secureWrite" -> {
                    secureStore.write(
                        call.argument<String>("accountId")!!,
                        call.argument<String>("studentId")!!,
                        call.argument<String>("password")!!,
                    )
                    result.success(null)
                }

                "secureDelete" -> {
                    secureStore.delete(call.argument<String>("accountId")!!)
                    result.success(null)
                }

                "secureList" -> result.success(secureStore.listAccountIds())

                // --- secure string store ---
                "secureReadString" -> {
                    val key = call.argument<String>("key")!!
                    result.success(secureStore.readString(key))
                }

                "secureWriteString" -> {
                    val key = call.argument<String>("key")!!
                    val value = call.argument<String>("value")!!
                    secureStore.writeString(key, value)
                    result.success(null)
                }

                "secureDeleteString" -> {
                    val key = call.argument<String>("key")!!
                    secureStore.deleteString(key)
                    result.success(null)
                }

                // --- biometric authentication ---
                "authenticateBiometric" -> {
                    val reason = call.argument<String>("reason") ?: "تأیید هویت برای استفاده از اطلاعات کارت بانکی"
                    authenticateBiometric(reason, result)
                }

                // --- plain store ---
                "plainReadString" -> result.success(
                    preferences.getString(call.argument<String>("key"), null),
                )

                "plainWriteString" -> {
                    val key = call.argument<String>("key")!!
                    val value = call.argument<String>("value")
                    preferences.edit().apply {
                        if (value == null) remove(key) else putString(key, value)
                    }.apply()
                    result.success(null)
                }

                "plainReadInt" -> {
                    val value = preferences.getInt(call.argument<String>("key"), -1)
                    result.success(if (value == -1) null else value)
                }

                "plainWriteInt" -> {
                    preferences.edit()
                        .putInt(call.argument<String>("key")!!, call.argument<Int>("value")!!)
                        .apply()
                    result.success(null)
                }

                "plainReadBool" -> {
                    val value = preferences.getBoolean(call.argument<String>("key"), false)
                    result.success(value)
                }

                "plainWriteBool" -> {
                    preferences.edit()
                        .putBoolean(call.argument<String>("key")!!, call.argument<Boolean>("value")!!)
                        .apply()
                    result.success(null)
                }

                "plainRemove" -> {
                    preferences.edit().remove(call.argument<String>("key")!!).apply()
                    result.success(null)
                }

                "plainKeys" -> result.success(preferences.all.keys.toList())

                // --- pending deliveries ---
                // The deliveries the app owes, recorded by the alarm receiver
                // when the process was dead and the Dart side could not be
                // reached. The Dart side reads them, delivers them, and
                // clears them.
                "pendingDeliveries" -> result.success(
                    PendingDelivery.read(context),
                )

                "clearPendingDeliveries" -> {
                    PendingDelivery.remove(
                        context,
                        call.argument<List<String>>("payloads") ?: emptyList(),
                    )
                    result.success(null)
                }

                // --- pending requests ---
                // The requests the platform made that the Dart side has not
                // answered: a hunt wake-up with the app killed, and the
                // re-arm after a reboot. Both used to be delivered through a
                // channel that only exists while the app is open, so both
                // were lost — and the reboot one could never arrive even in
                // principle, because a boot happens with the process dead.
                "pendingRequests" -> result.success(
                    PendingRequest.read(context),
                )

                "clearPendingRequests" -> {
                    PendingRequest.remove(
                        context,
                        call.argument<List<String>>("entries") ?: emptyList(),
                    )
                    result.success(null)
                }

                "getInitialDeepLink" -> {
                    result.success(MainActivity.consumeInitialDeepLink())
                }

                // --- notifications ---
                "postNotification" -> {
                    notifier.post(
                        id = call.argument<Int>("id")!!,
                        title = call.argument<String>("title")!!,
                        body = call.argument<String>("body")!!,
                        deepLink = call.argument<String>("deepLink"),
                    )
                    result.success(null)
                }

                "cancelNotification" -> {
                    notifier.cancel(call.argument<Int>("id")!!)
                    result.success(null)
                }

                "notificationPermission" -> result.success(notifier.hasPermission())

                "requestNotificationPermission" -> {
                    notifier.requestPermission(result)
                }

                // --- alarms ---
                "scheduleAlarm" -> {
                    alarms.scheduleExact(
                        requestCode = call.argument<Int>("requestCode")!!,
                        triggerAtMillis = call.argument<Long>("triggerAtMillis")!!,
                        payload = call.argument<String>("payload"),
                    )
                    result.success(null)
                }

                "cancelAlarm" -> {
                    alarms.cancel(call.argument<Int>("requestCode")!!)
                    result.success(null)
                }

                // --- the hunt's own wake-up ---
                // The hunt's alarm is armed per account, and the account is
                // part of the pending intent's identity — so one account's
                // hunt never replaces another's, and cancelling one does not
                // cancel the other.
                "scheduleHuntAlarm" -> {
                    alarms.scheduleHunt(
                        call.argument<String>("accountId")!!,
                        call.argument<Long>("triggerAtMillis")!!,
                    )
                    result.success(null)
                }

                "cancelHuntAlarm" -> {
                    alarms.cancelHunt(call.argument<String>("accountId")!!)
                    result.success(null)
                }

                "canScheduleExactAlarms" -> result.success(alarms.canScheduleExact())

                "requestExactAlarmPermission" -> {
                    alarms.requestExactAlarmPermission(result)
                }

                // --- battery optimisation ---
                // The Doze exemption, which the spec asks for with an
                // explanation rather than silently.
                "isIgnoringBatteryOptimizations" -> result.success(battery.isExempt())

                "requestIgnoreBatteryOptimizations" -> {
                    result.success(battery.request())
                }

                // --- foreground service ---
                "startHuntService" -> {
                    // The service keeps the process alive for the length of the
                    // hunt, and asks the Dart side to run it. The payload
                    // identifies which account's hunt, so the Dart side knows
                    // whose configuration to read.
                    //
                    // The start is marked as the Dart side's own, so it is not
                    // recorded as a request the Dart side still owes.
                    HuntService.start(
                        context,
                        call.argument<String>("payload"),
                        fromDart = true,
                    )
                    result.success(null)
                }

                "stopHuntService" -> {
                    // Called on every exit path, including a purchase: the
                    // service is released the moment there is nothing left to
                    // hunt for, so it never becomes a battery drain.
                    HuntService.stop(context)
                    result.success(null)
                }

                // --- sharing & messaging ---
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: "ارسال فیش فراموشی"
                    val sendIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                        putExtra(Intent.EXTRA_SUBJECT, title)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    val chooser = Intent.createChooser(sendIntent, title).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(chooser)
                    result.success(null)
                }

                "sendSms" -> {
                    val text = call.argument<String>("text") ?: ""
                    val smsIntent = Intent(Intent.ACTION_SENDTO).apply {
                        data = Uri.parse("smsto:")
                        putExtra("sms_body", text)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(smsIntent)
                    result.success(null)
                }

                "openUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(browserIntent)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("PLATFORM_ERROR", e.message, null)
        }
    }

    private fun authenticateBiometric(reason: String, result: MethodChannel.Result) {
        val activity = context as? Activity
        if (activity == null) {
            result.success(true)
            return
        }

        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard == null || !keyguard.isDeviceSecure) {
            result.success(true)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val builder = BiometricPrompt.Builder(activity)
                    .setTitle("تأیید هویت سلف‌یار")
                    .setSubtitle(reason)

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    builder.setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_WEAK or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
                    )
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    @Suppress("DEPRECATION")
                    builder.setDeviceCredentialAllowed(true)
                } else {
                    builder.setNegativeButton("انصراف", activity.mainExecutor) { _, _ ->
                        result.success(false)
                    }
                }

                var finished = false
                val prompt = builder.build()
                prompt.authenticate(
                    CancellationSignal(),
                    activity.mainExecutor,
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult?) {
                            if (!finished) {
                                finished = true
                                result.success(true)
                            }
                        }

                        override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                            if (!finished) {
                                finished = true
                                result.success(false)
                            }
                        }
                    }
                )
                return
            } catch (e: Exception) {
                // If BiometricPrompt fails for unexpected reasons, allow proceeding
            }
        }

        result.success(true)
    }

    private companion object {
        const val PREFERENCES_NAME = "bahonar_nut.store"
    }
}
