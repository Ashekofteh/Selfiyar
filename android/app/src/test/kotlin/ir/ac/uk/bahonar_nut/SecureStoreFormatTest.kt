package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the bytes [SecureCredentialStore] writes, without needing a Keystore.
 *
 * A half-written or tampered record must read as "no credentials": the login
 * screen asks for them again, it does not crash. The store's crypto wrapper
 * ([SecureStoreFormat.readSafely]) is what enforces that, so its failure paths
 * are tested here rather than only on a device.
 */
class SecureStoreFormatTest {

    private val iv = "AAECAwQFBgcICQoL" // 12 bytes, base64
    private val ciphertext = "q83vEjRWeJA=" // arbitrary base64 payload

    @Test
    fun `seal and open round-trip the two encrypted parts and the version`() {
        val stored = SecureStoreFormat.seal(iv, ciphertext)

        assertEquals(3, stored.split(SecureStoreFormat.SEPARATOR).size)
        assertEquals("$iv:$ciphertext:v1", stored)
        assertEquals(
            SecureStoreFormat.Sealed(iv, ciphertext, "v1"),
            SecureStoreFormat.open(stored),
        )
    }

    @Test
    fun `base64 padding and symbols survive the format untouched`() {
        val plusSlash = "a+b/c=="
        val stored = SecureStoreFormat.seal(plusSlash, "Zg==")

        assertEquals(plusSlash, SecureStoreFormat.open(stored)?.ivBase64)
        assertEquals("Zg==", SecureStoreFormat.open(stored)?.ciphertextBase64)
    }

    @Test
    fun `a missing or empty record reads as absent`() {
        assertNull(SecureStoreFormat.open(null))
        assertNull(SecureStoreFormat.open(""))
    }

    @Test
    fun `a record with the wrong number of parts is malformed`() {
        assertNull(SecureStoreFormat.open("$iv:$ciphertext"))
        assertNull(SecureStoreFormat.open("$iv:$ciphertext:v1:extra"))
        assertNull(SecureStoreFormat.open("v1"))
    }

    @Test
    fun `a record with an empty encrypted part is malformed`() {
        assertNull(SecureStoreFormat.open(":$ciphertext:v1"))
        assertNull(SecureStoreFormat.open("$iv::v1"))
    }

    @Test
    fun `seal refuses to write a record that open would reject`() {
        assertThrows(IllegalArgumentException::class.java) {
            SecureStoreFormat.seal("", ciphertext)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SecureStoreFormat.seal(iv, "")
        }
    }

    @Test
    fun `credentials round-trip with punctuation and spaces in the password`() {
        val plaintext = SecureStoreFormat.composeCredentials(
            "400123456",
            " p@ss:word with spaces\tand\ttabs ",
        )

        assertEquals(
            "400123456" to " p@ss:word with spaces\tand\ttabs ",
            SecureStoreFormat.splitCredentials(plaintext),
        )
    }

    @Test
    fun `an empty password is preserved, because the portal may accept one`() {
        val plaintext = SecureStoreFormat.composeCredentials("400123456", "")

        assertEquals("400123456" to "", SecureStoreFormat.splitCredentials(plaintext))
    }

    @Test
    fun `credentials without the field separator are rejected`() {
        assertNull(SecureStoreFormat.splitCredentials("400123456"))
        assertNull(SecureStoreFormat.splitCredentials(""))
    }

    @Test
    fun `the field separator is the unit separator, not a character a password can contain`() {
        assertEquals('\u001F', SecureStoreFormat.FIELD_SEPARATOR)
        assertTrue(
            SecureStoreFormat.composeCredentials("400123456", "a:b")
                .contains(SecureStoreFormat.FIELD_SEPARATOR),
        )
    }

    @Test
    fun `readSafely returns the decrypted value on success`() {
        val stored = SecureStoreFormat.seal(iv, ciphertext)

        val result = SecureStoreFormat.readSafely(stored) { sealed ->
            "decrypted:${sealed.ivBase64}"
        }

        assertEquals("decrypted:$iv", result)
    }

    @Test
    fun `readSafely returns null for a malformed record without calling the decryptor`() {
        var called = false

        val result = SecureStoreFormat.readSafely("not-a-record") { _ ->
            called = true
            "should not happen"
        }

        assertNull(result)
        assertEquals(false, called)
    }

    @Test
    fun `readSafely swallows a decryptor failure and asks for credentials again`() {
        val stored = SecureStoreFormat.seal(iv, ciphertext)

        val result = SecureStoreFormat.readSafely<Pair<String, String>>(stored) {
            throw IllegalArgumentException("Cipher: invalid IV or tampered ciphertext")
        }

        assertNull(result)
    }

    @Test
    fun `readSafely returns null when the decryptor cannot split the plaintext`() {
        val stored = SecureStoreFormat.seal(iv, ciphertext)

        val result = SecureStoreFormat.readSafely(stored) { _ ->
            SecureStoreFormat.splitCredentials("missing separator")
        }

        assertNull(result)
    }

    @Test
    fun `readSafely returns null when the decryptor itself returns null`() {
        val stored = SecureStoreFormat.seal(iv, ciphertext)

        val result = SecureStoreFormat.readSafely<String?>(stored) { null }

        assertNull(result)
    }
}
