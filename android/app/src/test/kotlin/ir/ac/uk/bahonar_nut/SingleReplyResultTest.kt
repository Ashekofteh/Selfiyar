package ir.ac.uk.bahonar_nut

import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SingleReplyResultTest {

    private class MockResult : MethodChannel.Result {
        var successCount = 0
        var errorCount = 0
        var notImplementedCount = 0
        var lastSuccessValue: Any? = null
        var lastErrorCode: String? = null

        override fun success(result: Any?) {
            if (successCount > 0 || errorCount > 0 || notImplementedCount > 0) {
                throw IllegalStateException("Reply already submitted")
            }
            successCount++
            lastSuccessValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (successCount > 0 || errorCount > 0 || notImplementedCount > 0) {
                throw IllegalStateException("Reply already submitted")
            }
            errorCount++
            lastErrorCode = errorCode
        }

        override fun notImplemented() {
            if (successCount > 0 || errorCount > 0 || notImplementedCount > 0) {
                throw IllegalStateException("Reply already submitted")
            }
            notImplementedCount++
        }
    }

    @Test
    fun `success is delivered once and duplicate success is safely ignored`() {
        val mock = MockResult()
        val guarded = SingleReplyResult(mock)

        assertFalse(guarded.hasReplied())
        guarded.success("first")
        assertTrue(guarded.hasReplied())

        // Second call would throw IllegalStateException on raw delegate,
        // but SingleReplyResult must swallow it safely.
        guarded.success("second")

        assertEquals(1, mock.successCount)
        assertEquals("first", mock.lastSuccessValue)
    }

    @Test
    fun `error is dropped if success was already delivered`() {
        val mock = MockResult()
        val guarded = SingleReplyResult(mock)

        guarded.success(true)
        guarded.error("ERR_CODE", "Something failed", null)

        assertEquals(1, mock.successCount)
        assertEquals(0, mock.errorCount)
    }

    @Test
    fun `error is delivered once and duplicate calls are ignored`() {
        val mock = MockResult()
        val guarded = SingleReplyResult(mock)

        guarded.error("FIRST_ERR", "First error", null)
        guarded.error("SECOND_ERR", "Second error", null)
        guarded.success("ignored")

        assertEquals(1, mock.errorCount)
        assertEquals(0, mock.successCount)
        assertEquals("FIRST_ERR", mock.lastErrorCode)
    }

    @Test
    fun `notImplemented is delivered once and duplicate calls are ignored`() {
        val mock = MockResult()
        val guarded = SingleReplyResult(mock)

        guarded.notImplemented()
        guarded.notImplemented()
        guarded.success("ignored")

        assertEquals(1, mock.notImplementedCount)
        assertEquals(0, mock.successCount)
    }
}
