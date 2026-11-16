package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/**
 * The closed-app delivery path reads the same store the Dart side writes.
 *
 * These tests cover the rules that decide *what* is said: which held meal
 * belongs to which slot in the portal's timezone, the explicit empty-slot
 * message, and the nudge's silence conditions.
 */
class NativeReminderDeliveryTest {

    private fun portal(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
    ): Long = Calendar.getInstance(portalTimeZone()).apply {
        clear()
        set(year, month - 1, day, hour, minute, 0)
    }.timeInMillis

    private fun meal(
        date: String,
        slot: String = "lunch",
        accountId: String = "a1",
        dish: String? = "چلو خورشت قیمه",
        hall: String? = "مرکزی برادران",
        consumed: Boolean = false,
    ) = HeldMealSnapshot(
        accountId = accountId,
        date = date,
        slot = slot,
        dishName = dish,
        hallName = hall,
        isConsumed = consumed,
    )

    // --- the daily slots ---------------------------------------------------

    @Test
    fun `lunch matches today's lunch in portal time`() {
        val now = portal(2026, 10, 19, 9, 0) // Monday 09:00 portal
        val todayLunch = meal("2026-10-19T05:30:00.000Z") // 09:00 portal

        assertTrue(NativeReminderSchedule.matchesMeal("lunch", todayLunch, now))
    }

    @Test
    fun `a date that is yesterday in UTC can still be today in the portal`() {
        // 20:31 UTC on Sunday is 00:01 Monday at GMT+03:30.
        val now = portal(2026, 10, 19, 9, 0)
        val justAfterMidnight = meal("2026-10-18T20:31:00.000Z")

        assertTrue(NativeReminderSchedule.matchesMeal("lunch", justAfterMidnight, now))
    }

    @Test
    fun `another day's lunch does not match`() {
        val now = portal(2026, 10, 19, 9, 0)

        assertFalse(
            NativeReminderSchedule.matchesMeal(
                "lunch",
                meal("2026-10-20T05:30:00.000Z"),
                now,
            ),
        )
        assertFalse(
            NativeReminderSchedule.matchesMeal(
                "lunch",
                meal("2026-10-19T12:00:00.000Z", slot = "dinner"),
                now,
            ),
        )
    }

    @Test
    fun `the evening slot covers tonight's dinner and tomorrow's breakfast`() {
        val now = portal(2026, 10, 19, 16, 30)

        assertTrue(
            NativeReminderSchedule.matchesMeal(
                "evening",
                meal("2026-10-19T12:00:00.000Z", slot = "dinner"),
                now,
            ),
        )
        assertTrue(
            NativeReminderSchedule.matchesMeal(
                "evening",
                meal("2026-10-20T06:00:00.000Z", slot = "breakfast"),
                now,
            ),
        )
        assertFalse(
            NativeReminderSchedule.matchesMeal(
                "evening",
                meal("2026-10-19T06:00:00.000Z", slot = "breakfast"),
                now,
            ),
        )
        assertFalse(
            NativeReminderSchedule.matchesMeal(
                "evening",
                meal("2026-10-20T12:00:00.000Z", slot = "dinner"),
                now,
            ),
        )
    }

    // --- the message -------------------------------------------------------

    @Test
    fun `an empty lunch says no lunch is reserved today`() {
        assertEquals(
            "امروز هیچ وعده رزروشده‌ای برای ناهار ندارید.",
            NativeReminderSchedule.digestBody("lunch", emptyList(), emptyMap()),
        )
    }

    @Test
    fun `an empty evening names dinner and tomorrow breakfast`() {
        assertEquals(
            "امروز هیچ وعده رزروشده‌ای برای شام یا صبحانه فردا ندارید.",
            NativeReminderSchedule.digestBody("evening", emptyList(), emptyMap()),
        )
    }

    @Test
    fun `a held lunch is a detailed digest with the account, dish and hall`() {
        val body = NativeReminderSchedule.digestBody(
            "lunch",
            listOf(meal("2026-10-19T05:30:00.000Z")),
            mapOf("a1" to "مقسمی"),
        )

        assertEquals("• مقسمی — چلو خورشت قیمه — مرکزی برادران", body)
    }

    @Test
    fun `a held breakfast is labelled as tomorrow's breakfast`() {
        val body = NativeReminderSchedule.digestBody(
            "evening",
            listOf(
                meal(
                    "2026-10-20T06:00:00.000Z",
                    slot = "breakfast",
                    dish = "شیر و حلوا شکری",
                ),
            ),
            mapOf("a1" to "مقسمی"),
        )

        assertTrue(body.contains("صبحانه فردا"))
        assertTrue(body.contains("شیر و حلوا شکری"))
    }

    @Test
    fun `an unknown dish falls back to the meal name and an unknown hall is omitted`() {
        val lunch = NativeReminderSchedule.digestBody(
            "lunch",
            listOf(meal("2026-10-19T05:30:00.000Z", dish = null, hall = null)),
            mapOf("a1" to "مقسمی"),
        )

        assertEquals("• مقسمی — ناهار", lunch)
    }

    // --- the nudge ---------------------------------------------------------

    @Test
    fun `an empty coming week makes the nudge speak`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            meals = emptyList(),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertTrue(decision.notify)
        assertNull(decision.skipReason)
        assertEquals("2026-10-24", decision.weekStartKey)
        assertEquals("2026-10-30", decision.weekEndKey)
        assertNotNull(decision.nextCheckAtMillis)
    }

    @Test
    fun `one reserved meal for the coming week is enough to stay silent`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            meals = listOf(meal("2026-10-24T05:00:00.000Z", slot = "breakfast")),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertFalse(decision.notify)
        assertEquals(NudgeSkipReason.ALREADY_RESERVED, decision.skipReason)
        assertEquals(1, decision.reservedMealCount)
    }

    @Test
    fun `a meal outside the coming week does not suppress the nudge`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            meals = listOf(
                // Friday 23:30 portal, before the window's Saturday.
                meal("2026-10-23T20:00:00.000Z"),
                // The Saturday after the window.
                meal("2026-10-31T05:00:00.000Z"),
            ),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertTrue(decision.notify)
        assertEquals(0, decision.reservedMealCount)
    }

    @Test
    fun `a consumed meal does not count as a reservation`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            meals = listOf(
                meal("2026-10-24T05:00:00.000Z", consumed = true),
            ),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertTrue(decision.notify)
    }

    @Test
    fun `a meal for an account outside the nudge selection does not count`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(
                accountIds = setOf("a1", "a2"),
                nudgeAccountIds = setOf("a2"),
            ),
            meals = listOf(meal("2026-10-24T05:00:00.000Z", accountId = "a1")),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertTrue(decision.notify)
        assertEquals(0, decision.reservedMealCount)
    }

    @Test
    fun `a nudge dismissed for the coming Saturday is silent`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(
                accountIds = setOf("a1"),
                dismissedNudgeWeekSaturday = "2026-10-24T00:00:00.000Z",
            ),
            meals = emptyList(),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertFalse(decision.notify)
        assertEquals(NudgeSkipReason.DISMISSED_FOR_WEEK, decision.skipReason)
    }

    @Test
    fun `a dismissal for a different week does not silence this one`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(
                accountIds = setOf("a1"),
                dismissedNudgeWeekSaturday = "2026-10-17T00:00:00.000Z",
            ),
            meals = emptyList(),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertTrue(decision.notify)
    }

    @Test
    fun `the skip precedence is master, nudge, accounts, dismissal, reservation`() {
        val meals = listOf(meal("2026-10-24T05:00:00.000Z"))
        val now = portal(2026, 10, 19, 9, 0)

        assertEquals(
            NudgeSkipReason.MASTER_DISABLED,
            NativeReminderSchedule.nudgeDecision(
                ReminderConfigSnapshot(
                    masterEnabled = false,
                    accountIds = setOf("a1"),
                    nextWeekNudgeEnabled = false,
                    dismissedNudgeWeekSaturday = "2026-10-24T00:00:00.000Z",
                ),
                meals,
                now,
            ).skipReason,
        )
        assertEquals(
            NudgeSkipReason.NUDGE_DISABLED,
            NativeReminderSchedule.nudgeDecision(
                ReminderConfigSnapshot(
                    accountIds = setOf("a1"),
                    nextWeekNudgeEnabled = false,
                    dismissedNudgeWeekSaturday = "2026-10-24T00:00:00.000Z",
                ),
                meals,
                now,
            ).skipReason,
        )
        assertEquals(
            NudgeSkipReason.NO_ACCOUNTS,
            NativeReminderSchedule.nudgeDecision(
                ReminderConfigSnapshot(
                    accountIds = emptySet(),
                    dismissedNudgeWeekSaturday = "2026-10-24T00:00:00.000Z",
                ),
                meals,
                now,
            ).skipReason,
        )
        assertEquals(
            NudgeSkipReason.DISMISSED_FOR_WEEK,
            NativeReminderSchedule.nudgeDecision(
                ReminderConfigSnapshot(
                    accountIds = setOf("a1"),
                    dismissedNudgeWeekSaturday = "2026-10-24T00:00:00.000Z",
                ),
                meals,
                now,
            ).skipReason,
        )
        assertEquals(
            NudgeSkipReason.ALREADY_RESERVED,
            NativeReminderSchedule.nudgeDecision(
                ReminderConfigSnapshot(accountIds = setOf("a1")),
                meals,
                now,
            ).skipReason,
        )
    }

    @Test
    fun `after Thursday evening there is no next check to arm`() {
        val decision = NativeReminderSchedule.nudgeDecision(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            meals = emptyList(),
            nowMillis = portal(2026, 10, 23, 9, 0), // Friday
        )

        assertNull(decision.nextCheckAtMillis)
    }

    // --- the configuration -------------------------------------------------

    @Test
    fun `the parser reads the JSON the Dart side writes`() {
        val raw = """
            {
              "masterEnabled": false,
              "accountIds": ["a1", "a2"],
              "lunch": {"enabled": false, "time": "11:15"},
              "evening": {"enabled": true, "time": "17:45"},
              "nextWeekNudgeEnabled": false,
              "liveCheckEnabled": true,
              "excludedFromSlot": {"lunch": ["a2"]},
              "nudgeAccountIds": ["a2"],
              "dismissedNudgeWeekSaturday": "2026-10-24T00:00:00.000Z"
            }
        """.trimIndent()

        val config = ReminderConfigParser.parse(raw)!!

        assertFalse(config.masterEnabled)
        assertEquals(setOf("a1", "a2"), config.accountIds)
        assertFalse(config.lunch.enabled)
        assertEquals(11, config.lunch.hour)
        assertEquals(15, config.lunch.minute)
        assertEquals(17, config.evening.hour)
        assertEquals(45, config.evening.minute)
        assertFalse(config.nextWeekNudgeEnabled)
        assertTrue(config.liveCheckEnabled)
        assertEquals(setOf("a2"), config.excludedFromSlot["lunch"])
        assertEquals(setOf("a2"), config.nudgeAccountIds)
        assertEquals(setOf("a2"), config.activeNudgeAccounts)
        assertNotNull(config.dismissedNudgeWeekSaturday)
    }

    @Test
    fun `an absent configuration is null`() {
        assertNull(ReminderConfigParser.parse(null))
        assertNull(ReminderConfigParser.parse(""))
        assertNull(ReminderConfigParser.parse("not json"))
    }

    @Test
    fun `missing fields take the same defaults as the Dart model`() {
        val config = ReminderConfigParser.parse("{}")!!

        assertTrue(config.masterEnabled)
        assertTrue(config.accountIds.isEmpty())
        assertTrue(config.nextWeekNudgeEnabled)
        assertFalse(config.liveCheckEnabled)
        assertEquals(10, config.lunch.hour)
        assertEquals(30, config.lunch.minute)
        assertEquals(16, config.evening.hour)
        assertEquals(30, config.evening.minute)
        assertNull(config.nudgeAccountIds)
    }

    @Test
    fun `an empty nudge account list means nobody, not everybody`() {
        val config = ReminderConfigParser.parse(
            """{"accountIds":["a1"],"nudgeAccountIds":[]}""",
        )!!

        assertEquals(emptySet<String>(), config.nudgeAccountIds)
        assertEquals(emptySet<String>(), config.activeNudgeAccounts)
    }

    @Test
    fun `an unreadable time falls back to the slot default`() {
        val config = ReminderConfigParser.parse(
            """{"lunch":{"enabled":true,"time":"not-a-time"}}""",
        )!!

        assertEquals(10, config.lunch.hour)
        assertEquals(30, config.lunch.minute)
    }

    @Test
    fun `the meal mirror parser skips unreadable entries instead of losing the rest`() {
        val raw = """
            [
              {"accountId":"a1","date":"2026-10-19T05:30:00.000Z","slot":"lunch",
               "dishName":"چلو","hallName":"مرکزی","isConsumed":false},
              {"date":"2026-10-19T05:30:00.000Z","slot":"lunch"},
              {"accountId":"a2","date":"garbage","slot":"dinner"}
            ]
        """.trimIndent()

        val meals = HeldMealParser.parse(raw)

        assertEquals(2, meals.size)
        assertEquals("a1", meals[0].accountId)
        assertEquals("چلو", meals[0].dishName)
        assertEquals("a2", meals[1].accountId)
        assertNull(meals[1].dishName)
        assertTrue(HeldMealParser.parse("not json").isEmpty())
    }
}
