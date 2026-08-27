package com.nkshub.nextcloudtalk.push

import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.Cipher

/**
 * Per-account RSA-2048 push device key, generated inside the Android
 * Keystore.
 *
 * The private half never leaves the keystore: it is what decrypts the
 * push-v2 `subject` a notification carries, and Nextcloud only ever sees the
 * public SubjectPublicKeyInfo returned by [generateDeviceKey]. Keys are
 * keyed by the account-derived handle the Dart coordinator passes in, so one
 * account can never read another account's notification.
 *
 * Generation runs off the main thread — an RSA-2048 keypair costs long
 * enough to drop frames — and the result is posted back on it, which is the
 * only thread a [MethodChannel.Result] may be answered on.
 */
internal class AndroidPushDeviceKeyStore : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val handle = call.argument<String>("handle")
        if (handle.isNullOrEmpty() || !HANDLE_PATTERN.matches(handle)) {
            result.error("invalid_handle", "Device key handle is not valid.", null)
            return
        }
        when (call.method) {
            "generateDeviceKey" -> runOffMainThread(result) { ensureKey(handle) }
            "destroyDeviceKey" -> runOffMainThread(result) {
                destroyKey(handle)
                null
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        worker.shutdown()
    }

    private fun runOffMainThread(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val outcome = runCatching(work)
            mainHandler.post {
                outcome
                    .onSuccess(result::success)
                    // The message deliberately carries no detail: a keystore
                    // failure string can name the alias, and the alias is the
                    // account. Dart turns any failure into a transient one and
                    // retries with backoff.
                    .onFailure {
                        result.error(
                            "device_key_unavailable",
                            "The push device key could not be provided.",
                            null,
                        )
                    }
            }
        }
    }

    private fun ensureKey(handle: String): String {
        val alias = aliasFor(handle)
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        val existing = keyStore.getCertificate(alias)?.publicKey
        if (existing != null) {
            return pem(existing.encoded)
        }
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            ANDROID_KEY_STORE,
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT,
            )
                .setKeySize(RSA_KEY_SIZE)
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                // Nextcloud encrypts the payload with PHP's openssl_public_encrypt,
                // whose default padding is PKCS#1 v1.5, so the key has to permit it
                // or the decrypt that follows a notification is rejected by the
                // keystore itself. OAEP is allowed alongside for a future server.
                .setEncryptionPaddings(
                    KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1,
                    KeyProperties.ENCRYPTION_PADDING_RSA_OAEP,
                )
                .build(),
        )
        val keyPair = generator.generateKeyPair()
        return pem(keyPair.public.encoded)
    }

    private fun destroyKey(handle: String) {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        val alias = aliasFor(handle)
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
    }

    internal companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/push_device_key"

        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val ALIAS_PREFIX = "com.nkshub.nextcloudtalk.push.devicekey."
        private const val RSA_KEY_SIZE = 2048
        private const val PEM_LINE_LENGTH = 64

        /** The handle the coordinator derives is a SHA-256 hex digest. */
        private val HANDLE_PATTERN = Regex("^[0-9a-f]{64}$")

        fun aliasFor(handle: String): String = ALIAS_PREFIX + handle

        /**
         * Decrypts a push-v2 `subject` and says which account it belongs to.
         *
         * One FCM token addresses the whole device, so the account is whichever
         * one's key opens the ciphertext — the keys are per account. Nextcloud
         * encrypts with PHP's openssl_public_encrypt, whose default padding is
         * PKCS#1 v1.5.
         */
        fun decryptSubject(
            ciphertext: ByteArray,
            accountIds: Collection<String>,
        ): Pair<String, ByteArray>? {
            if (ciphertext.size != RSA_KEY_SIZE / 8) {
                return null
            }
            val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
            for (accountId in accountIds) {
                val alias = aliasFor(handleFor(accountId))
                val key = runCatching { keyStore.getKey(alias, null) }.getOrNull() ?: continue
                val plaintext = runCatching {
                    Cipher.getInstance("RSA/ECB/PKCS1Padding")
                        .apply { init(Cipher.DECRYPT_MODE, key) }
                        .doFinal(ciphertext)
                }.getOrNull()
                if (plaintext != null) {
                    return accountId to plaintext
                }
            }
            return null
        }

        /** Mirrors the handle the Dart coordinator derives for an account. */
        fun handleFor(accountId: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(accountId.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        /**
         * Wraps a DER SubjectPublicKeyInfo as PEM. Dart re-canonicalises this
         * before it goes on the wire, so the only thing that matters here is
         * that it parses: the standard header, 64-character base64 lines, and
         * a trailing newline.
         */
        fun pem(der: ByteArray): String {
            val body = Base64.encodeToString(der, Base64.NO_WRAP)
            return buildString {
                append("-----BEGIN PUBLIC KEY-----\n")
                var offset = 0
                while (offset < body.length) {
                    val end = minOf(offset + PEM_LINE_LENGTH, body.length)
                    append(body, offset, end)
                    append('\n')
                    offset = end
                }
                append("-----END PUBLIC KEY-----\n")
            }
        }
    }
}
