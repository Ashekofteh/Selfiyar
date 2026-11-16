package ir.ac.uk.bahonar_nut

/**
 * The on-disk format of [SecureCredentialStore], free of Android APIs.
 *
 * The store's job is encryption; this object's job is the bytes around it.
 * Keeping the two apart lets the format and its failure modes be tested on the
 * JVM, where a real Keystore does not exist. A malformed or half-written
 * record must read as "no credentials" rather than crash the login path, and
 * that rule is pinned by `SecureStoreFormatTest`.
 *
 * ## The format
 *
 * A stored value is three colon-separated parts:
 *
 * ```
 * <base64 IV>:<base64 ciphertext>:<format version>
 * ```
 *
 * The encrypted plaintext of an account is
 * `<student id>\u001F<password>`: the unit separator cannot appear in either
 * field, so the split is unambiguous even when the password contains spaces or
 * punctuation.
 */
internal object SecureStoreFormat {

    /** Separates the three outer parts of a stored value. */
    const val SEPARATOR = ":"

    /** Separates the student id from the password inside the ciphertext. */
    const val FIELD_SEPARATOR = '\u001F'

    /** The only format this build writes; stored for future migrations. */
    const val FORMAT_VERSION = "v1"

    private const val PART_COUNT = 3

    /** A parsed stored value, still encrypted. */
    data class Sealed(
        val ivBase64: String,
        val ciphertextBase64: String,
        val version: String,
    )

    /**
     * Packs the already-base64-encoded IV and ciphertext into the stored form.
     *
     * Encoding is the caller's job because Android's `Base64` is not available
     * on the JVM test classpath, and it is not part of this format.
     */
    fun seal(ivBase64: String, ciphertextBase64: String): String {
        require(ivBase64.isNotEmpty()) { "the IV must not be empty" }
        require(ciphertextBase64.isNotEmpty()) { "the ciphertext must not be empty" }
        return listOf(ivBase64, ciphertextBase64, FORMAT_VERSION).joinToString(SEPARATOR)
    }

    /** Parses a stored value, or null when it is absent or malformed. */
    fun open(stored: String?): Sealed? {
        if (stored.isNullOrEmpty()) return null
        val parts = stored.split(SEPARATOR)
        if (parts.size != PART_COUNT) return null
        if (parts[0].isEmpty() || parts[1].isEmpty()) return null
        return Sealed(
            ivBase64 = parts[0],
            ciphertextBase64 = parts[1],
            version = parts[2],
        )
    }

    /** Composes the plaintext that is encrypted for one account. */
    fun composeCredentials(studentId: String, password: String): String =
        "$studentId$FIELD_SEPARATOR$password"

    /**
     * Splits decrypted credentials, or null when the field separator is
     * missing (an older or corrupted record).
     */
    fun splitCredentials(plaintext: String): Pair<String, String>? {
        val separator = plaintext.indexOf(FIELD_SEPARATOR)
        if (separator < 0) return null
        return plaintext.substring(0, separator) to plaintext.substring(separator + 1)
    }

    /**
     * Opens [stored] and decrypts it with [decrypt].
     *
     * Every failure — a malformed record, an IV or ciphertext the platform
     * cannot decode, a key invalidated by a screen-lock change, a tampered
     * ciphertext — is deliberately reduced to null. The caller asks for the
     * credentials again; it never sees a crash from the login path.
     */
    fun <T> readSafely(stored: String?, decrypt: (Sealed) -> T?): T? {
        val sealed = open(stored) ?: return null
        return try {
            decrypt(sealed)
        } catch (e: Exception) {
            null
        }
    }
}
