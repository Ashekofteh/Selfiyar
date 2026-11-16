package ir.ac.uk.bahonar_nut

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The portal's timezone: UTC+3:30, all year round.
 *
 * Every date comparison in the native reminder path is made in this frame, not
 * the device's. A student travelling abroad would otherwise get a digest for
 * the wrong day — or none at all — because the Kotlin side would be matching
 * the portal's civil dates against a device-local "today".
 */
internal const val PORTAL_TIME_ZONE_ID = "GMT+03:30"

/** The portal's timezone. */
internal fun portalTimeZone(): TimeZone = TimeZone.getTimeZone(PORTAL_TIME_ZONE_ID)

/** The alarm request codes shared with `ReminderService` in Dart. */
internal object ReminderAlarmCodes {
    const val LUNCH = 4201
    const val EVENING = 4202
    const val NUDGE = 4203
}

/** One configurable daily slot, with its fire time in portal-local time. */
internal data class ReminderSlotSettings(
    val enabled: Boolean,
    val hour: Int,
    val minute: Int,
) {
    companion object {
        val lunchDefault = ReminderSlotSettings(enabled = true, hour = 10, minute = 30)
        val eveningDefault = ReminderSlotSettings(enabled = true, hour = 16, minute = 30)
    }
}

/**
 * The reminder configuration, as the native side needs it.
 *
 * Mirrors `ReminderConfig` in `lib/core/reminder/reminder.dart`. The native
 * reader cannot import Dart, so the fields are named identically and the
 * defaults are the same; drift between the two is what makes a switch the
 * user can see fail to change what actually fires.
 */
internal data class ReminderConfigSnapshot(
    val masterEnabled: Boolean = true,
    val accountIds: Set<String> = emptySet(),
    val nudgeAccountIds: Set<String>? = null,
    val lunch: ReminderSlotSettings = ReminderSlotSettings.lunchDefault,
    val evening: ReminderSlotSettings = ReminderSlotSettings.eveningDefault,
    val nextWeekNudgeEnabled: Boolean = true,
    val liveCheckEnabled: Boolean = false,
    val excludedFromSlot: Map<String, Set<String>> = emptyMap(),
    val dismissedNudgeWeekSaturday: String? = null,
) {
    /** Accounts included in [slot], after per-slot exclusions. */
    fun accountsFor(slot: String): Set<String> =
        accountIds - (excludedFromSlot[slot] ?: emptySet())

    /** True when [slot] should fire at all. */
    fun isSlotActive(slot: String): Boolean {
        if (!masterEnabled) return false
        val settings = when (slot) {
            "lunch" -> lunch
            "evening" -> evening
            else -> return false
        }
        return settings.enabled && accountsFor(slot).isNotEmpty()
    }

    /** The accounts selected for the next-week nudge. */
    val activeNudgeAccounts: Set<String>
        get() = nudgeAccountIds ?: accountIds
}

/** Reads and parses `reminders.config`. */
internal object ReminderConfigParser {

    /**
     * Reads the stored configuration, or null when it is absent or unreadable.
     *
     * Null is meaningful: the boot receiver uses it to decide that the alarms
     * must be left to the Dart side, which owns the reconciliation.
     */
    fun parse(raw: String?): ReminderConfigSnapshot? {
        if (raw.isNullOrEmpty()) return null
        return try {
            val json = JSONObject(raw)
            ReminderConfigSnapshot(
                masterEnabled = json.optBoolean("masterEnabled", true),
                accountIds = stringSet(json.optJSONArray("accountIds")),
                nudgeAccountIds = if (json.has("nudgeAccountIds") && !json.isNull("nudgeAccountIds")) {
                    stringSet(json.optJSONArray("nudgeAccountIds"))
                } else {
                    null
                },
                lunch = slot(json.optJSONObject("lunch"), ReminderSlotSettings.lunchDefault),
                evening = slot(json.optJSONObject("evening"), ReminderSlotSettings.eveningDefault),
                nextWeekNudgeEnabled = json.optBoolean("nextWeekNudgeEnabled", true),
                liveCheckEnabled = json.optBoolean("liveCheckEnabled", false),
                excludedFromSlot = excludedSlots(json.optJSONObject("excludedFromSlot")),
                dismissedNudgeWeekSaturday = json.opt("dismissedNudgeWeekSaturday") as? String,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun stringSet(array: JSONArray?): Set<String> {
        if (array == null) return emptySet()
        val out = mutableSetOf<String>()
        for (i in 0 until array.length()) {
            val value = array.optString(i, "")
            if (value.isNotEmpty() && value != "null") out.add(value)
        }
        return out
    }

    private fun slot(json: JSONObject?, fallback: ReminderSlotSettings): ReminderSlotSettings {
        if (json == null) return fallback
        val parsed = parseTime(json.opt("time") as? String) ?: (fallback.hour to fallback.minute)
        return ReminderSlotSettings(
            enabled = json.optBoolean("enabled", fallback.enabled),
            hour = parsed.first,
            minute = parsed.second,
        )
    }

    private fun parseTime(raw: String?): Pair<Int, Int>? {
        if (raw == null) return null
        val parts = raw.split(":")
        if (parts.size < 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].toIntOrNull() ?: return null
        if (hour !in 0..23 || minute !in 0..59) return null
        return hour to minute
    }

    private fun excludedSlots(json: JSONObject?): Map<String, Set<String>> {
        if (json == null) return emptyMap()
        val out = mutableMapOf<String, Set<String>>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val slot = keys.next()
            out[slot] = stringSet(json.optJSONArray(slot))
        }
        return out
    }
}

/** Reads the reminder configuration from the shared preferences store. */
internal object ReminderConfigStoreReader {
    const val PREFS_NAME = "bahonar_nut.store"

    /** The key both the Dart side and the native side write. */
    const val PRIMARY_KEY = "reminders.config"

    /** The pre-migration key, still read so an upgrade keeps its settings. */
    const val LEGACY_KEY = "reminder.config"

    fun readRaw(context: Context): String? = try {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(PRIMARY_KEY, null) ?: prefs.getString(LEGACY_KEY, null)
    } catch (_: Exception) {
        null
    }

    fun read(context: Context): ReminderConfigSnapshot? =
        ReminderConfigParser.parse(readRaw(context))
}

/** One held meal, as read from `meals.held`. */
internal data class HeldMealSnapshot(
    val accountId: String,
    val date: String,
    val slot: String,
    val dishName: String?,
    val hallName: String?,
    val isConsumed: Boolean,
)

/** Parses the offline meal mirror. */
internal object HeldMealParser {
    fun parse(raw: String?): List<HeldMealSnapshot> {
        if (raw.isNullOrEmpty()) return emptyList()
        return try {
            val array = JSONArray(raw)
            val out = mutableListOf<HeldMealSnapshot>()
            for (i in 0 until array.length()) {
                val json = array.optJSONObject(i) ?: continue
                val accountId = json.optString("accountId", "")
                if (accountId.isEmpty()) continue
                out.add(
                    HeldMealSnapshot(
                        accountId = accountId,
                        date = json.optString("date", ""),
                        slot = json.optString("slot", ""),
                        dishName = text(json, "dishName"),
                        hallName = text(json, "hallName"),
                        isConsumed = json.optBoolean("isConsumed", false),
                    )
                )
            }
            out
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun text(json: JSONObject, key: String): String? {
        val value = json.optString(key, "")
        return value.takeIf { it.isNotEmpty() && it != "null" }
    }
}

/** The windows and date arithmetic the native reminders use. */
internal object PortalDates {
    private const val DATE_PATTERN = "yyyy-MM-dd"

    private val parsePatterns = listOf(
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        DATE_PATTERN,
    )

    fun calendar(nowMillis: Long): Calendar =
        Calendar.getInstance(portalTimeZone()).apply { timeInMillis = nowMillis }

    fun dateKey(date: Date): String = SimpleDateFormat(DATE_PATTERN, Locale.US).apply {
        timeZone = portalTimeZone()
    }.format(date)

    fun dateKey(nowMillis: Long): String = dateKey(calendar(nowMillis).time)

    /** Parses an ISO instant from `meals.held`. Dates without a zone are UTC. */
    fun instant(raw: String?): Date? {
        if (raw.isNullOrEmpty()) return null
        val text = raw.trim()
        for (pattern in parsePatterns) {
            try {
                val parser = SimpleDateFormat(pattern, Locale.US).apply {
                    isLenient = false
                    timeZone = TimeZone.getTimeZone("UTC")
                }
                val parsed = parser.parse(text)
                if (parsed != null) return parsed
            } catch (_: Exception) {
                // Try the next shape.
            }
        }
        return null
    }

    /** The portal-local civil date of [raw], or null when unreadable. */
    fun dateKeyOf(raw: String?): String? = instant(raw)?.let { dateKey(it) }

    fun dayStart(nowMillis: Long): Calendar = calendar(nowMillis).apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }

    fun addDays(calendar: Calendar, days: Int): Calendar =
        (calendar.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, days) }

    fun at(calendar: Calendar, hour: Int, minute: Int): Calendar =
        (calendar.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }

    /** The coming Saturday, which is the first day of the next week. */
    fun nextWeekStart(nowMillis: Long): Calendar {
        val today = dayStart(nowMillis)
        val weekday = today.get(Calendar.DAY_OF_WEEK)
        val daysUntilSaturday =
            if (weekday == Calendar.SATURDAY) 7 else (Calendar.SATURDAY - weekday + 7) % 7
        return addDays(today, daysUntilSaturday)
    }

    fun nextWeekWindow(nowMillis: Long): Pair<Calendar, Calendar> {
        val start = nextWeekStart(nowMillis)
        return start to addDays(start, 6)
    }
}

/** One re-armed alarm, as planned for the boot receiver. */
internal data class ReminderAlarmPlan(
    val requestCode: Int,
    val payload: String,
    val triggerAtMillis: Long,
)

/**
 * What the boot receiver should do after a reboot or an app update.
 *
 * Android clears every alarm when the device restarts, so the receiver either
 * re-arms the reminders itself from the readable configuration or — when the
 * configuration cannot be read — leaves a [PendingRequest.KIND_REARM] for the
 * Dart side, which owns the reconciliation.
 */
internal data class BootRearmPlan(
    val alarms: List<ReminderAlarmPlan>,
    val needsDartReconciliation: Boolean,
)

/** The boot receiver's decision, kept free of Android types for JVM tests. */
internal object BootRearm {
    /** Every reminder alarm, cancelled before a plan is armed. */
    val allRequestCodes = listOf(
        ReminderAlarmCodes.LUNCH,
        ReminderAlarmCodes.EVENING,
        ReminderAlarmCodes.NUDGE,
    )

    /**
     * Plans the boot re-arm.
     *
     * A null [config] means the stored configuration was absent or unreadable.
     * The native side must not guess in that case: the Dart side owns the
     * settings, so the request stays owed until it can reconcile them.
     */
    fun plan(config: ReminderConfigSnapshot?, nowMillis: Long): BootRearmPlan {
        if (config == null) {
            return BootRearmPlan(
                alarms = emptyList(),
                needsDartReconciliation = true,
            )
        }
        return BootRearmPlan(
            alarms = NativeReminderSchedule.bootAlarms(config, nowMillis),
            needsDartReconciliation = false,
        )
    }
}

/** Why a nudge did not notify. */
internal enum class NudgeSkipReason {
    MASTER_DISABLED,
    NUDGE_DISABLED,
    NO_ACCOUNTS,
    DISMISSED_FOR_WEEK,
    ALREADY_RESERVED,
}

/** The outcome of one nudge check. */
internal data class NudgeDecision(
    val notify: Boolean,
    val skipReason: NudgeSkipReason?,
    val nextCheckAtMillis: Long?,
    val weekStartKey: String,
    val weekEndKey: String,
    val reservedMealCount: Int,
)

/** One of the six nudge check times. */
internal data class NudgeCheck(val calendarWeekday: Int, val hour: Int, val minute: Int)

/**
 * The native reminder schedule and message rules.
 *
 * Kept free of Android types (apart from the timezone, which is `java.util`)
 * so the date matching and the nudge decision can be exercised by JVM tests.
 * `AlarmManager` and `NotificationManager` have no JVM implementation; the
 * arithmetic that decides *when* and *whether* a reminder fires is the part
 * that silently regressed before, and that is this object.
 */
internal object NativeReminderSchedule {

    /** The six checks, in the order the Dart schedule defines them. */
    val nudgeChecks = listOf(
        NudgeCheck(Calendar.WEDNESDAY, 12, 0),
        NudgeCheck(Calendar.WEDNESDAY, 16, 0),
        NudgeCheck(Calendar.WEDNESDAY, 21, 0),
        NudgeCheck(Calendar.THURSDAY, 9, 0),
        NudgeCheck(Calendar.THURSDAY, 12, 0),
        NudgeCheck(Calendar.THURSDAY, 17, 0),
    )

    /** Whether [meal] is the meal [payload] reports on, in portal-local time. */
    fun matchesMeal(
        payload: String,
        meal: HeldMealSnapshot,
        nowMillis: Long,
    ): Boolean {
        val todayKey = PortalDates.dateKey(nowMillis)
        val tomorrowKey = PortalDates.dateKey(
            PortalDates.addDays(PortalDates.calendar(nowMillis), 1).timeInMillis
        )
        val mealKey = PortalDates.dateKeyOf(meal.date) ?: return false
        return when (payload) {
            "lunch" -> meal.slot == "lunch" && mealKey == todayKey
            "evening" -> when (meal.slot) {
                "dinner" -> mealKey == todayKey
                "breakfast" -> mealKey == tomorrowKey
                else -> false
            }
            else -> false
        }
    }

    /** The next occurrence of [hour]:[minute], today if still ahead. */
    fun nextOccurrenceMillis(hour: Int, minute: Int, nowMillis: Long): Long {
        val candidate = PortalDates.at(PortalDates.calendar(nowMillis), hour, minute)
        val next = if (candidate.timeInMillis > nowMillis) candidate else PortalDates.addDays(candidate, 1)
        return next.timeInMillis
    }

    /** Tomorrow at [hour]:[minute], portal-local. */
    fun rearmForTomorrowMillis(hour: Int, minute: Int, nowMillis: Long): Long {
        val tomorrow = PortalDates.addDays(PortalDates.dayStart(nowMillis), 1)
        return PortalDates.at(tomorrow, hour, minute).timeInMillis
    }

    /**
     * The next nudge check, or null once Thursday 17:00 has passed.
     *
     * The check's weekday is this week's occurrence, so the difference is
     * signed — the same rule as `nextNudgeCheck` in Dart. A check at exactly
     * `now` counts as passed: the alarm that just fired is the check itself,
     * and arming it again would fire twice.
     */
    fun nextNudgeCheckMillis(nowMillis: Long): Long? {
        val now = PortalDates.calendar(nowMillis)
        val today = now.get(Calendar.DAY_OF_WEEK)
        val nowMinutes = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)

        for (check in nudgeChecks) {
            val dayDelta = check.calendarWeekday - today
            val checkMinutes = check.hour * 60 + check.minute
            if (dayDelta < 0) continue
            if (dayDelta == 0 && checkMinutes <= nowMinutes) continue

            val candidate = PortalDates.addDays(PortalDates.dayStart(nowMillis), dayDelta)
            return PortalDates.at(candidate, check.hour, check.minute).timeInMillis
        }
        return null
    }

    /** The alarms the boot receiver should arm from [config]. */
    fun bootAlarms(config: ReminderConfigSnapshot, nowMillis: Long): List<ReminderAlarmPlan> {
        if (!config.masterEnabled) return emptyList()
        val out = mutableListOf<ReminderAlarmPlan>()

        if (config.isSlotActive("lunch")) {
            out.add(
                ReminderAlarmPlan(
                    requestCode = ReminderAlarmCodes.LUNCH,
                    payload = ReminderPayloads.LUNCH,
                    triggerAtMillis = nextOccurrenceMillis(
                        config.lunch.hour,
                        config.lunch.minute,
                        nowMillis,
                    ),
                )
            )
        }

        if (config.isSlotActive("evening")) {
            out.add(
                ReminderAlarmPlan(
                    requestCode = ReminderAlarmCodes.EVENING,
                    payload = ReminderPayloads.EVENING,
                    triggerAtMillis = nextOccurrenceMillis(
                        config.evening.hour,
                        config.evening.minute,
                        nowMillis,
                    ),
                )
            )
        }

        if (config.nextWeekNudgeEnabled && config.activeNudgeAccounts.isNotEmpty()) {
            val nextCheck = nextNudgeCheckMillis(nowMillis)
            if (nextCheck != null) {
                out.add(
                    ReminderAlarmPlan(
                        requestCode = ReminderAlarmCodes.NUDGE,
                        payload = ReminderPayloads.NUDGE,
                        triggerAtMillis = nextCheck,
                    )
                )
            }
        }

        return out
    }

    /**
     * Whether the nudge should speak, from the offline store alone.
     *
     * A single meal reserved for the coming week is enough to stay silent: the
     * student has already acted on the week, and a notification that repeats
     * an action they took trains them to ignore the next one.
     */
    fun nudgeDecision(
        config: ReminderConfigSnapshot,
        meals: List<HeldMealSnapshot>,
        nowMillis: Long,
    ): NudgeDecision {
        val (start, end) = PortalDates.nextWeekWindow(nowMillis)
        val startKey = PortalDates.dateKey(start.time)
        val endKey = PortalDates.dateKey(end.time)
        val activeAccounts = config.activeNudgeAccounts

        val reservedMeals = meals.count { meal ->
            !meal.isConsumed &&
                meal.accountId in activeAccounts &&
                PortalDates.dateKeyOf(meal.date)?.let { it >= startKey && it <= endKey } == true
        }

        val skipReason = when {
            !config.masterEnabled -> NudgeSkipReason.MASTER_DISABLED
            !config.nextWeekNudgeEnabled -> NudgeSkipReason.NUDGE_DISABLED
            activeAccounts.isEmpty() -> NudgeSkipReason.NO_ACCOUNTS
            isDismissedForWeek(config.dismissedNudgeWeekSaturday, startKey) ->
                NudgeSkipReason.DISMISSED_FOR_WEEK
            reservedMeals > 0 -> NudgeSkipReason.ALREADY_RESERVED
            else -> null
        }

        return NudgeDecision(
            notify = skipReason == null,
            skipReason = skipReason,
            nextCheckAtMillis = nextNudgeCheckMillis(nowMillis),
            weekStartKey = startKey,
            weekEndKey = endKey,
            reservedMealCount = reservedMeals,
        )
    }

    /** The digest body for a daily reminder, including the empty-slot message. */
    fun digestBody(
        payload: String,
        meals: List<HeldMealSnapshot>,
        accountNames: Map<String, String>,
    ): String {
        if (meals.isEmpty()) return emptyBody(payload)

        return meals.joinToString("\n") { meal ->
            val displayName = accountNames[meal.accountId] ?: meal.accountId
            when (payload) {
                "lunch" -> {
                    val dish = meal.dishName ?: "ناهار"
                    if (meal.hallName != null) {
                        "• $displayName — $dish — ${meal.hallName}"
                    } else {
                        "• $displayName — $dish"
                    }
                }
                "evening" -> {
                    val slotName = if (meal.slot == "breakfast") "صبحانه فردا" else "شام"
                    val dish = meal.dishName ?: slotName
                    if (meal.hallName != null) {
                        "• $displayName ($slotName) — $dish — ${meal.hallName}"
                    } else {
                        "• $displayName ($slotName) — $dish"
                    }
                }
                else -> ""
            }
        }
    }

    private fun emptyBody(payload: String): String = when (payload) {
        "lunch" -> "امروز هیچ وعده رزروشده‌ای برای ناهار ندارید."
        "evening" -> "امروز هیچ وعده رزروشده‌ای برای شام یا صبحانه فردا ندارید."
        else -> "امروز هیچ وعده رزروشده‌ای ندارید."
    }

    private fun isDismissedForWeek(raw: String?, weekStartKey: String): Boolean {
        val dismissedKey = PortalDates.dateKeyOf(raw) ?: return false
        return dismissedKey == weekStartKey
    }
}
