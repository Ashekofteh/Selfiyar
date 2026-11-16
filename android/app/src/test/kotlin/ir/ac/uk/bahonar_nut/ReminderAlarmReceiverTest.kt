package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The receiver's route table is the guard against the bug the old code had:
 * an unrecognised payload was treated as a hunt, so a reminder that lost its
 * identity could start a foreground hunt for an account nobody named.
 */
class ReminderAlarmReceiverTest {

    @Test
    fun `ACTION_HUNT routes to the hunt even when the payload looks like a reminder`() {
        assertEquals(
            AlarmRoute.HUNT,
            AlarmRouting.route(AlarmScheduler.ACTION_HUNT, ReminderPayloads.LUNCH),
        )
        assertEquals(
            AlarmRoute.HUNT,
            AlarmRouting.route(AlarmScheduler.ACTION_HUNT, ReminderPayloads.EVENING),
        )
        assertEquals(
            AlarmRoute.HUNT,
            AlarmRouting.route(AlarmScheduler.ACTION_HUNT, ReminderPayloads.NUDGE),
        )
    }

    @Test
    fun `ACTION_HUNT with an account payload or no payload still routes to the hunt`() {
        assertEquals(
            AlarmRoute.HUNT,
            AlarmRouting.route(AlarmScheduler.ACTION_HUNT, "acc/400123456"),
        )
        assertEquals(
            AlarmRoute.HUNT,
            AlarmRouting.route(AlarmScheduler.ACTION_HUNT, null),
        )
    }

    @Test
    fun `each known reminder payload routes to reminder delivery`() {
        for (payload in listOf(
            ReminderPayloads.LUNCH,
            ReminderPayloads.EVENING,
            ReminderPayloads.NUDGE,
        )) {
            assertEquals(
                "payload $payload must be a reminder",
                AlarmRoute.REMINDER,
                AlarmRouting.route(AlarmScheduler.ACTION_REMINDER, payload),
            )
        }
    }

    @Test
    fun `an unknown reminder payload is ignored rather than treated as a hunt`() {
        assertEquals(
            AlarmRoute.IGNORED,
            AlarmRouting.route(AlarmScheduler.ACTION_REMINDER, "eaten"),
        )
        assertEquals(
            AlarmRoute.IGNORED,
            AlarmRouting.route(AlarmScheduler.ACTION_REMINDER, null),
        )
    }

    @Test
    fun `an unknown action with an unknown payload is ignored`() {
        assertEquals(
            AlarmRoute.IGNORED,
            AlarmRouting.route("ir.ac.uk.bahonar_nut.SOMETHING_ELSE", "acc-1"),
        )
    }

    @Test
    fun `a known payload without the hunt action is a reminder`() {
        // The action is what distinguishes a hunt; a reminder payload is still
        // a reminder on an intent that carries no action at all.
        assertEquals(
            AlarmRoute.REMINDER,
            AlarmRouting.route(null, ReminderPayloads.LUNCH),
        )
    }

    @Test
    fun `the reminder vocabulary is exactly lunch, evening and nudge`() {
        assertTrue(ReminderPayloads.isReminder(ReminderPayloads.LUNCH))
        assertTrue(ReminderPayloads.isReminder(ReminderPayloads.EVENING))
        assertTrue(ReminderPayloads.isReminder(ReminderPayloads.NUDGE))
        assertFalse(ReminderPayloads.isReminder(null))
        assertFalse(ReminderPayloads.isReminder(""))
        assertFalse(ReminderPayloads.isReminder("Lunch"))
        assertFalse(ReminderPayloads.isReminder("acc-1"))
    }
}
