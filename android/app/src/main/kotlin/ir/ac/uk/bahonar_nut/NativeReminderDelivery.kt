package ir.ac.uk.bahonar_nut

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Delivers reminder notifications natively when the app's Dart side is not running.
 *
 * Reads held meals, account names, and reminder configuration directly from the
 * app's persistent SharedPreferences (`bahonar_nut.store`), formats the digest,
 * and posts the notification immediately to the notification shade.
 */
object NativeReminderDelivery {
    private const val TAG = "NativeReminderDelivery"
    private const val PREFS_NAME = "bahonar_nut.store"
    private const val KEY_MEALS = "meals.held"
    private const val KEY_REMINDERS_CONFIG = "reminders.config"
    private const val PREFIX_ACCOUNT = "account."

    private const val LUNCH_NOTIFICATION_ID = 4101
    private const val EVENING_NOTIFICATION_ID = 4102
    private const val NUDGE_NOTIFICATION_ID = 4103

    private const val LUNCH_ALARM_CODE = 4201
    private const val EVENING_ALARM_CODE = 4202

    fun deliver(context: Context, payload: String) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

            // 1. Check if reminders are enabled in config
            val configRaw = prefs.getString(KEY_REMINDERS_CONFIG, null)
            var masterEnabled = true
            var lunchEnabled = true
            var eveningEnabled = true
            var lunchTime = "10:30"
            var eveningTime = "16:30"
            val excludedAccountsForSlot = mutableSetOf<String>()

            if (configRaw != null) {
                try {
                    val configJson = JSONObject(configRaw)
                    masterEnabled = configJson.optBoolean("masterEnabled", true)
                    val lunchJson = configJson.optJSONObject("lunch")
                    if (lunchJson != null) {
                        lunchEnabled = lunchJson.optBoolean("enabled", true)
                        lunchTime = lunchJson.optString("time", "10:30")
                    }
                    val eveningJson = configJson.optJSONObject("evening")
                    if (eveningJson != null) {
                        eveningEnabled = eveningJson.optBoolean("enabled", true)
                        eveningTime = eveningJson.optString("time", "16:30")
                    }

                    val excludedJson = configJson.optJSONObject("excludedFromSlot")
                    if (excludedJson != null) {
                        val arr = excludedJson.optJSONArray(payload)
                        if (arr != null) {
                            for (i in 0 until arr.length()) {
                                excludedAccountsForSlot.add(arr.getString(i))
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Error parsing reminder config", e)
                }
            }

            if (!masterEnabled) {
                Log.d(TAG, "Master reminders disabled; skipping native delivery for $payload")
                PendingDelivery.remove(context, listOf(payload))
                return
            }

            if (payload == "lunch" && !lunchEnabled) {
                PendingDelivery.remove(context, listOf(payload))
                return
            }
            if (payload == "evening" && !eveningEnabled) {
                PendingDelivery.remove(context, listOf(payload))
                return
            }

            // 2. Load account display names
            val accountNames = mutableMapOf<String, String>()
            for (key in prefs.all.keys) {
                if (key.startsWith(PREFIX_ACCOUNT)) {
                    val accRaw = prefs.getString(key, null) ?: continue
                    try {
                        val accJson = JSONObject(accRaw)
                        val id = accJson.optString("id")
                        val alias = accJson.optString("alias").takeIf { it.isNotEmpty() && it != "null" }
                        val profileName = accJson.optString("profileName").takeIf { it.isNotEmpty() && it != "null" }
                        val name = alias ?: profileName ?: id
                        if (id.isNotEmpty()) {
                            accountNames[id] = name
                        }
                    } catch (_: Exception) {}
                }
            }

            // 3. Compute target date strings
            val cal = Calendar.getInstance()
            val dfIso = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                timeZone = TimeZone.getDefault()
            }
            val todayStr = dfIso.format(cal.time)

            cal.add(Calendar.DAY_OF_YEAR, 1)
            val tomorrowStr = dfIso.format(cal.time)

            data class MealInfo(
                val accountId: String,
                val slot: String,
                val dishName: String?,
                val hallName: String?
            )

            // 4. Load held meals
            val mealsRaw = prefs.getString(KEY_MEALS, null)
            val matchingMeals = mutableListOf<MealInfo>()

            if (!mealsRaw.isNullOrEmpty()) {
                try {
                    val arr = JSONArray(mealsRaw)
                    for (i in 0 until arr.length()) {
                        val obj = arr.getJSONObject(i)
                        val accId = obj.optString("accountId")
                        if (excludedAccountsForSlot.contains(accId)) continue

                        val slot = obj.optString("slot")
                        val dateRaw = obj.optString("date") // e.g. "2026-11-01T00:00:00.000Z"
                        val datePrefix = if (dateRaw.length >= 10) dateRaw.substring(0, 10) else ""

                        val isMatch = when (payload) {
                            "lunch" -> slot == "lunch" && matchesDate(dateRaw, datePrefix, todayStr)
                            "evening" -> {
                                (slot == "dinner" && matchesDate(dateRaw, datePrefix, todayStr)) ||
                                (slot == "breakfast" && matchesDate(dateRaw, datePrefix, tomorrowStr))
                            }
                            else -> false
                        }

                        if (isMatch) {
                            matchingMeals.add(
                                MealInfo(
                                    accountId = accId,
                                    slot = slot,
                                    dishName = obj.optString("dishName").takeIf { it.isNotEmpty() && it != "null" },
                                    hallName = obj.optString("hallName").takeIf { it.isNotEmpty() && it != "null" }
                                )
                            )
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Error parsing meals.held", e)
                }
            }

            // 5. Build Title and Body and Post Notification
            val notifier = ReminderNotifier(context)

            when (payload) {
                "lunch" -> {
                    val title = "🍽 یادآور ناهار"
                    val body = if (matchingMeals.isNotEmpty()) {
                        val lines = matchingMeals.map { m ->
                            val displayName = accountNames[m.accountId] ?: m.accountId
                            val dish = m.dishName ?: "ناهار"
                            if (m.hallName != null) "• $displayName — $dish — ${m.hallName}"
                            else "• $displayName — $dish"
                        }
                        lines.joinToString("\n")
                    } else {
                        "امروز هیچ وعده رزروشده‌ای برای ناهار ندارید."
                    }

                    notifier.post(LUNCH_NOTIFICATION_ID, title, body, "reminder/lunch")
                    rearmForTomorrow(context, LUNCH_ALARM_CODE, "lunch", lunchTime)
                    PendingDelivery.remove(context, listOf("lunch"))
                }
                "evening" -> {
                    val title = "🌙 یادآور شام"
                    val body = if (matchingMeals.isNotEmpty()) {
                        val lines = matchingMeals.map { m ->
                            val displayName = accountNames[m.accountId] ?: m.accountId
                            val slotFa = if (m.slot == "breakfast") "صبحانه فردا" else "شام"
                            val dish = m.dishName ?: slotFa
                            if (m.hallName != null) "• $displayName ($slotFa) — $dish — ${m.hallName}"
                            else "• $displayName ($slotFa) — $dish"
                        }
                        lines.joinToString("\n")
                    } else {
                        "امروز هیچ وعده رزروشده‌ای برای شام یا صبحانه فردا ندارید."
                    }

                    notifier.post(EVENING_NOTIFICATION_ID, title, body, "reminder/evening")
                    rearmForTomorrow(context, EVENING_ALARM_CODE, "evening", eveningTime)
                    PendingDelivery.remove(context, listOf("evening"))
                }
                "nudge" -> {
                    val title = "🍽 رزرو غذای هفته آینده"
                    val body = "مهلت رزرو غذا برای هفته آینده امشب به پایان می‌رسد. لطفاً در صورت تمایل نسبت به رزرو اقدام کنید."
                    notifier.post(NUDGE_NOTIFICATION_ID, title, body, "reminder/nudge")
                    PendingDelivery.remove(context, listOf("nudge"))
                }
            }

            Log.i(TAG, "Native reminder delivered successfully for $payload")
        } catch (e: Exception) {
            Log.e(TAG, "Error in native reminder delivery", e)
        }
    }

    private fun matchesDate(dateRaw: String, datePrefix: String, targetDateStr: String): Boolean {
        if (datePrefix == targetDateStr || dateRaw.contains(targetDateStr)) return true
        try {
            val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val cleanRaw = if (dateRaw.length >= 19) dateRaw.substring(0, 19) else dateRaw
            val parsed = parser.parse(cleanRaw)
            if (parsed != null) {
                val localDf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
                if (localDf.format(parsed) == targetDateStr) return true
            }
        } catch (_: Exception) {}
        return false
    }

    private fun rearmForTomorrow(context: Context, requestCode: Int, payload: String, timeStr: String) {
        try {
            val scheduler = AlarmScheduler(context)
            val cal = Calendar.getInstance()
            cal.add(Calendar.DAY_OF_YEAR, 1)

            if (timeStr.contains(":")) {
                val parts = timeStr.split(":")
                val hour = parts[0].toIntOrNull() ?: cal.get(Calendar.HOUR_OF_DAY)
                val minute = parts[1].toIntOrNull() ?: cal.get(Calendar.MINUTE)
                cal.set(Calendar.HOUR_OF_DAY, hour)
                cal.set(Calendar.MINUTE, minute)
                cal.set(Calendar.SECOND, 0)
                cal.set(Calendar.MILLISECOND, 0)
            }

            scheduler.scheduleExact(requestCode, cal.timeInMillis, payload)
            Log.d(TAG, "Re-armed alarm $requestCode for tomorrow at ${cal.time}")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to rearm alarm $requestCode", e)
        }
    }
}
