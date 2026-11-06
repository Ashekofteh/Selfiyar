package ir.ac.uk.bahonar_nut

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A [SecureCredentialStore] backed by the Android Keystore.
 *
 * ## Why the Keystore, and what it actually buys
 *
 * The password is encrypted with an AES-GCM key that **never leaves the
 * Keystore** — the app holds a handle, not the key material. The ciphertext
 * lives in SharedPreferences. On a device with a hardware-backed keystore (TEE
 * or StrongBox), the key is not extractable even from a full memory dump of
 * the app process; on a software-backed device it is still not readable by
 * another app.
 *
 * ## Why GCM, and why the IV is stored
 *
 * GCM is authenticated encryption, so a modified ciphertext fails to decrypt
 * rather than yielding garbage — the difference between "wrong password" and
 * "tampered with". Each encryption uses a **fresh random IV**; GCM requires
 * this, because reusing an IV under the same key destroys the security of both
 * messages. The IV is stored alongside the ciphertext, which is safe: the IV
 * need not be secret, only unique.
 */
class SecureCredentialStore(private val context: Context) {

    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private val keyStore: KeyStore
        get() = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    /** The account ids that have credentials stored. */
    fun listAccountIds(): List<String> =
        preferences.all.keys.filter { it.startsWith(PREFIX) }
            .map { it.removePrefix(PREFIX) }
            .sorted()

    /** Reads and decrypts the credentials for [accountId], or null. */
    fun read(accountId: String): Pair<String, String>? {
        val stored = preferences.getString(PREFIX + accountId, null) ?: return null
        return try {
            val parts = stored.split(SEPARATOR)
            if (parts.size != 3) return null
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)

            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_BITS, iv),
            )
            val plaintext = cipher.doFinal(ciphertext)
            val text = String(plaintext, Charsets.UTF_8)
            val separator = text.indexOf(FIELD_SEPARATOR)
            if (separator < 0) return null
            text.substring(0, separator) to text.substring(separator + 1)
        } catch (e: Exception) {
            // A key that was invalidated (the user changed their screen lock),
            // or a ciphertext that cannot be read, means the credentials are
            // simply gone. The app will ask for them again.
            null
        }
    }

    /** Encrypts and stores the credentials for [accountId]. */
    fun write(accountId: String, studentId: String, password: String) {
        val iv = ByteArray(GCM_IV_BYTES).also { java.security.SecureRandom().nextBytes(it) }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        val ciphertext = cipher.doFinal(
            "$studentId$FIELD_SEPARATOR$password".toByteArray(Charsets.UTF_8),
        )

        preferences.edit()
            .putString(
                PREFIX + accountId,
                listOf(
                    Base64.encodeToString(iv, Base64.NO_WRAP),
                    Base64.encodeToString(ciphertext, Base64.NO_WRAP),
                    FORMAT_VERSION,
                ).joinToString(SEPARATOR),
            )
            .apply()
    }

    /** Removes the credentials for [accountId]. */
    fun delete(accountId: String) {
        preferences.edit().remove(PREFIX + accountId).apply()
    }

    /** Reads and decrypts an arbitrary string stored under [key], or null. */
    fun readString(key: String): String? {
        val stored = preferences.getString(STRING_PREFIX + key, null) ?: return null
        return try {
            val parts = stored.split(SEPARATOR)
            if (parts.size != 3) return null
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)

            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_BITS, iv),
            )
            val plaintext = cipher.doFinal(ciphertext)
            String(plaintext, Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    /** Encrypts and stores an arbitrary [value] under [key]. */
    fun writeString(key: String, value: String) {
        val iv = ByteArray(GCM_IV_BYTES).also { java.security.SecureRandom().nextBytes(it) }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))

        preferences.edit()
            .putString(
                STRING_PREFIX + key,
                listOf(
                    Base64.encodeToString(iv, Base64.NO_WRAP),
                    Base64.encodeToString(ciphertext, Base64.NO_WRAP),
                    FORMAT_VERSION,
                ).joinToString(SEPARATOR),
            )
            .apply()
    }

    /** Removes the encrypted string under [key]. */
    fun deleteString(key: String) {
        preferences.edit().remove(STRING_PREFIX + key).apply()
    }

    /**
     * The Keystore key, created on first use.
     *
     * `setUserAuthenticationRequired` is deliberately **not** set: requiring the
     * user to unlock the device before every portal read would break background
     * operation, and the threat this defends against — another app reading the
     * password — is already handled by the key being non-extractable.
     */
    private fun getOrCreateKey(): SecretKey {
        val store = keyStore
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // The IV is supplied by the caller, so the key must permit it.
                // Without this, the Keystore rejects the operation with
                // CALLER_NONCE_PROHIBITED ("NONCE is present, although
                // CALLER_NONCE is not present") and the write fails.
                //
                // This does not weaken the encryption: the IV is still random
                // and unique per message, which is what GCM requires. It only
                // means the platform does not generate the IV for us.
                .setRandomizedEncryptionRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "bahonar_nut.credentials"
        const val PREFERENCES_NAME = "bahonar_nut.secure"
        const val PREFIX = "cred."
        const val STRING_PREFIX = "sec_str."
        const val SEPARATOR = ":"
        const val FIELD_SEPARATOR = "\u001F"
        const val FORMAT_VERSION = "v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BITS = 128
    }
}
