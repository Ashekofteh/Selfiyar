package ir.ac.uk.bahonar_nut

import android.content.Context
import android.util.Log
import org.json.JSONObject

/**
 * Delivers reminder notifications natively when the app's Dart side is not running.
 *
 * Reads held meals, account names, and reminder configuration directly from the
 * app's persistent SharedPreferences (`bahonar_nut.store`), formats the digest,
 * and posts the notification immediately to the notification shade.
 *
 * All date matching is done in the portal's timezone (`GMT+03:30`), never the
 * device's, so a phone set to another timezone still matches the portal's
 * civil dates.
 */
object NativeReminderDelivery {
    private const val TAG = "NativeReminderDelivery"
    private const val PREFS_NAME = "bahonar_nut.store"
    private const val KEY_MEALS = "meals.held"
    private const val PREFIX_ACCOUNT = "account."

    private const val LUNCH_NOTIFICATION_ID = 4101
    private const val EVENING_NOTIFICATION_ID = 4102
    private const val NUDGE_NOTIFICATION_ID = 4103

    fun deliver(context: Context, payload: String) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val config = ReminderConfigStoreReader.read(context) ?: ReminderConfigSnapshot()
            val nowMillis = System.currentTimeMillis()

            if (!config.masterEnabled) {
                Log.d(TAG, "Master reminders disabled; skipping native delivery for $payload")
                PendingDelivery.remove(context, listOf(payload))
                return
            }

            if ((payload == ReminderPayloads.LUNCH && !config.isSlotActive(ReminderPayloads.LUNCH)) ||
                (payload == ReminderPayloads.EVENING && !config.isSlotActive(ReminderPayloads.EVENING))
            ) {
                Log.d(TAG, "Slot $payload is not active; removing pending delivery")
                PendingDelivery.remove(context, listOf(payload))
                return
            }

            val accountNames = readAccountNames(prefs)
            val meals = HeldMealParser.parse(prefs.getString(KEY_MEALS, null))
            val notifier = ReminderNotifier(context)

            when (payload) {
                ReminderPayloads.LUNCH -> {
                    val accounts = config.accountsFor(ReminderPayloads.LUNCH)
                    val matching = meals.filter { meal ->
                        meal.accountId in accounts &&
                            NativeReminderSchedule.matchesMeal(payload, meal, nowMillis)
                    }
                    val body = NativeReminderSchedule.digestBody(payload, matching, accountNames)

                    notifier.post(LUNCH_NOTIFICATION_ID, "🍽 یادآور ناهار", body, "reminder/lunch")
                    rearmForTomorrow(
                        context,
                        ReminderAlarmCodes.LUNCH,
                        ReminderPayloads.LUNCH,
                        config.lunch,
                        nowMillis,
                    )
                    PendingDelivery.remove(context, listOf(ReminderPayloads.LUNCH))
                }

                ReminderPayloads.EVENING -> {
                    val accounts = config.accountsFor(ReminderPayloads.EVENING)
                    val matching = meals.filter { meal ->
                        meal.accountId in accounts &&
                            NativeReminderSchedule.matchesMeal(payload, meal, nowMillis)
                    }
                    val body = NativeReminderSchedule.digestBody(payload, matching, accountNames)

                    notifier.post(EVENING_NOTIFICATION_ID, "🌙 یادآور شام", body, "reminder/evening")
                    rearmForTomorrow(
                        context,
                        ReminderAlarmCodes.EVENING,
                        ReminderPayloads.EVENING,
                        config.evening,
                        nowMillis,
                    )
                    PendingDelivery.remove(context, listOf(ReminderPayloads.EVENING))
                }

                ReminderPayloads.NUDGE -> {
                    val decision = NativeReminderSchedule.nudgeDecision(config, meals, nowMillis)
                    if (decision.notify) {
                        notifier.post(
                            NUDGE_NOTIFICATION_ID,
                            "🍽 رزرو غذای هفته آینده",
                            "مهلت رزرو غذا برای هفته آینده امشب به پایان می‌رسد. " +
                                "لطفاً در صورت تمایل نسبت به رزرو اقدام کنید.",
                            "reminder/nudge",
                        )
                    } else {
                        Log.d(TAG, "Nudge silent: ${decision.skipReason}")
                    }

                    // Always answered, so the next app launch does not deliver
                    // the same nudge again.
                    PendingDelivery.remove(context, listOf(ReminderPayloads.NUDGE))
                    scheduleNextNudge(context, decision.nextCheckAtMillis)
                }

                else -> Log.d(TAG, "Unknown reminder payload: $payload")
            }

            Log.i(TAG, "Native reminder handled for $payload")
        } catch (e: Exception) {
            Log.e(TAG, "Error in native reminder delivery", e)
        }
    }

    /** Reads the account display names stored by the Dart side. */
    private fun readAccountNames(prefs: android.content.SharedPreferences): Map<String, String> {
        val names = mutableMapOf<String, String>()
        for (key in prefs.all.keys) {
            if (!key.startsWith(PREFIX_ACCOUNT)) continue
            val raw = prefs.getString(key, null) ?: continue
            try {
                val json = JSONObject(raw)
                val id = json.optString("id", "")
                if (id.isEmpty()) continue
                val alias = json.optString("alias", "")
                    .takeIf { it.isNotEmpty() && it != "null" }
                val profileName = json.optString("profileName", "")
                    .takeIf { it.isNotEmpty() && it != "null" }
                names[id] = alias ?: profileName ?: id
            } catch (_: Exception) {
                // A corrupt account record must not hide the other accounts.
            }
        }
        return names
    }

    /** Re-arms a daily slot for tomorrow at its configured portal-local time. */
    private fun rearmForTomorrow(
        context: Context,
        requestCode: Int,
        payload: String,
        settings: ReminderSlotSettings,
        nowMillis: Long,
    ) {
        try {
            val scheduler = AlarmScheduler(context)
            val triggerAt = NativeReminderSchedule.rearmForTomorrowMillis(
                settings.hour,
                settings.minute,
                nowMillis,
            )
            scheduler.scheduleExact(requestCode, triggerAt, payload)
            Log.d(TAG, "Re-armed alarm $requestCode for tomorrow at ${settings.hour}:${settings.minute}")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to rearm alarm $requestCode", e)
        }
    }

    /** Arms the next nudge check, or cancels it once the window has passed. */
    private fun scheduleNextNudge(context: Context, nextCheckAtMillis: Long?) {
        try {
            val scheduler = AlarmScheduler(context)
            if (nextCheckAtMillis == null) {
                scheduler.cancel(ReminderAlarmCodes.NUDGE)
                Log.d(TAG, "Nudge window is over; no next check to arm")
            } else {
                scheduler.scheduleExact(
                    ReminderAlarmCodes.NUDGE,
                    nextCheckAtMillis,
                    ReminderPayloads.NUDGE,
                )
                Log.d(TAG, "Armed the next nudge check")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to arm the next nudge check", e)
        }
    }
}
