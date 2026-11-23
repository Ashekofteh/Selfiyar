package ir.ac.uk.bahonar_nut

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Forwards at most one reply to the wrapped channel result.
 *
 * `success`, `error` and `notImplemented` are terminal for a MethodChannel call;
 * a second call throws on the platform thread with `IllegalStateException: Reply already submitted`.
 * Losing a duplicate reply is always better than killing the process.
 */
class SingleReplyResult(
    private val delegate: MethodChannel.Result,
) : MethodChannel.Result {
    private val replied = AtomicBoolean(false)

    private inline fun replyOnce(block: () -> Unit) {
        if (replied.compareAndSet(false, true)) block()
    }

    override fun success(result: Any?) = replyOnce { delegate.success(result) }

    override fun error(code: String, message: String?, details: Any?) =
        replyOnce { delegate.error(code, message, details) }

    override fun notImplemented() = replyOnce { delegate.notImplemented() }

    /** Returns true if a reply has already been submitted through this instance. */
    fun hasReplied(): Boolean = replied.get()
}
