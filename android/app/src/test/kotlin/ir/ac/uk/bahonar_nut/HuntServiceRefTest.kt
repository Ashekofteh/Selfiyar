package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Verifies the multi-account reference counting in [HuntService].
 *
 * The foreground service must remain alive as long as at least one account's
 * hunt is running, and only stop when all accounts have completed or when an
 * explicit stop-all request arrives.
 */
class HuntServiceRefTest {

    @Before
    fun setUp() {
        HuntService.active.clear()
    }

    @Test
    fun `registering an account adds it to active set`() {
        HuntService.registerAccount("user-1")
        assertEquals(setOf("user-1"), HuntService.active)

        HuntService.registerAccount("user-2")
        assertEquals(setOf("user-1", "user-2"), HuntService.active)
    }

    @Test
    fun `registering null or blank account is ignored`() {
        HuntService.registerAccount(null)
        HuntService.registerAccount("")
        HuntService.registerAccount("   ")
        assertTrue(HuntService.active.isEmpty())
    }

    @Test
    fun `unregistering one of multiple accounts keeps service alive`() {
        HuntService.registerAccount("user-1")
        HuntService.registerAccount("user-2")

        val shouldStop1 = HuntService.unregisterAccount("user-1")
        assertFalse("Service should not stop while user-2 is active", shouldStop1)
        assertEquals(setOf("user-2"), HuntService.active)

        val shouldStop2 = HuntService.unregisterAccount("user-2")
        assertTrue("Service should stop when last account finishes", shouldStop2)
        assertTrue(HuntService.active.isEmpty())
    }

    @Test
    fun `unregistering null clears all accounts and stops service immediately`() {
        HuntService.registerAccount("user-1")
        HuntService.registerAccount("user-2")
        HuntService.registerAccount("user-3")

        val shouldStop = HuntService.unregisterAccount(null)
        assertTrue("Explicit stop-all must request stopping the service", shouldStop)
        assertTrue(HuntService.active.isEmpty())
    }
}
