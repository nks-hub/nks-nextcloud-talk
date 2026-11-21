package com.nkshub.nextcloudtalk.push

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * The device key is what decrypts an incoming push-v2 payload, so these run
 * against the real Android Keystore rather than a double.
 */
@RunWith(AndroidJUnit4::class)
class AndroidPushDeviceKeyStoreTest {
    private val store = AndroidPushDeviceKeyStore()
    private val handleA = "a".repeat(64)
    private val handleB = "b".repeat(64)
    private val extraHandles = mutableListOf<String>()

    @After
    fun removeTestKeys() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (handle in listOf(handleA, handleB) + extraHandles) {
            for (alias in listOf(
                AndroidPushDeviceKeyStore.aliasFor(handle),
                AndroidPushDeviceKeyStore.legacyAliasFor(handle),
            )) {
                if (keyStore.containsAlias(alias)) {
                    keyStore.deleteEntry(alias)
                }
            }
        }
        store.dispose()
    }

    @Test
    fun generatesAnRsa2048SubjectPublicKeyInfoNextcloudAccepts() {
        val pem = call("generateDeviceKey", handleA) as String

        assertTrue(pem.startsWith("-----BEGIN PUBLIC KEY-----\n"))
        assertTrue(pem.endsWith("-----END PUBLIC KEY-----\n"))
        val body = pem.lines().drop(1).dropLast(2)
        assertTrue(body.isNotEmpty())
        assertTrue(body.all { it.isNotEmpty() && it.length <= 64 })
        assertTrue(body.all { Regex("^[A-Za-z0-9+/]+={0,2}$").matches(it) })

        val der = Base64.decode(body.joinToString(""), Base64.DEFAULT)
        val parsed = KeyFactory.getInstance("RSA")
            .generatePublic(X509EncodedKeySpec(der)) as RSAPublicKey
        assertEquals(2048, parsed.modulus.bitLength())
        // PushController validates the PEM length, header included.
        assertTrue("unexpected PEM length ${pem.length}", pem.length in 450..451)
    }

    @Test
    fun reusesTheSameKeyForTheSameAccount() {
        val first = call("generateDeviceKey", handleA)
        val second = call("generateDeviceKey", handleA)

        assertEquals(first, second)
    }

    @Test
    fun keepsAccountsApart() {
        val first = call("generateDeviceKey", handleA)
        val second = call("generateDeviceKey", handleB)

        assertNotEquals(first, second)
    }

    @Test
    fun destroyingAKeyLeavesNothingBehind() {
        generateLegacyKey(handleA)
        val first = call("generateDeviceKey", handleA)
        call("destroyDeviceKey", handleA)

        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertTrue(!keyStore.containsAlias(AndroidPushDeviceKeyStore.aliasFor(handleA)))
        assertTrue(!keyStore.containsAlias(AndroidPushDeviceKeyStore.legacyAliasFor(handleA)))
        assertNotEquals(first, call("generateDeviceKey", handleA))
    }

    @Test
    fun opensASubjectEncryptedForOneAccountAndNamesIt() {
        val accountA = "11111111-1111-4111-8111-111111111111"
        val accountB = "22222222-2222-4222-8222-222222222222"
        val handles = listOf(accountA, accountB)
            .map(AndroidPushDeviceKeyStore::handleFor)
        extraHandles.addAll(handles)
        val pems = handles.map { call("generateDeviceKey", it) as String }

        // Nextcloud encrypts with PHP's openssl_public_encrypt, whose default
        // padding is PKCS#1 v1.5.
        val plaintext = """{"app":"spreed","type":"chat","subject":"hello","nid":7}"""
        val ciphertext = Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
            init(Cipher.ENCRYPT_MODE, publicKeyOf(pems[1]))
            doFinal(plaintext.toByteArray())
        }

        val opened = AndroidPushDeviceKeyStore.decryptSubject(
            ciphertext,
            listOf(accountA, accountB),
        )

        assertNotNull(opened)
        assertEquals(accountB, opened!!.first)
        assertEquals(plaintext, String(opened.second))
    }

    @Test
    fun opensAnOaepSha1SubjectEncryptedForOneAccountAndNamesIt() {
        val accountA = "44444444-4444-4444-8444-444444444444"
        val accountB = "55555555-5555-4555-8555-555555555555"
        val handles = listOf(accountA, accountB)
            .map(AndroidPushDeviceKeyStore::handleFor)
        extraHandles.addAll(handles)
        val pems = handles.map { call("generateDeviceKey", it) as String }
        val plaintext = """{"app":"spreed","type":"chat","subject":"oaep","nid":8}"""
        val ciphertext = Cipher.getInstance(OAEP_SHA1_TRANSFORMATION).run {
            init(Cipher.ENCRYPT_MODE, publicKeyOf(pems[1]), OAEP_SHA1_PARAMETERS)
            doFinal(plaintext.toByteArray())
        }

        val opened = AndroidPushDeviceKeyStore.decryptSubject(
            ciphertext,
            listOf(accountA, accountB),
        )

        assertNotNull(opened)
        assertEquals(accountB, opened!!.first)
        assertEquals(plaintext, String(opened.second))
    }

    @Test
    fun replacesALegacyKeyButStillOpensItsPendingPkcsSubject() {
        val account = "66666666-6666-4666-8666-666666666666"
        val handle = AndroidPushDeviceKeyStore.handleFor(account)
        extraHandles.add(handle)
        val legacyPem = generateLegacyKey(handle)
        val currentPem = call("generateDeviceKey", handle) as String
        assertNotEquals(legacyPem, currentPem)

        val plaintext = """{"app":"spreed","type":"chat","subject":"legacy","nid":9}"""
        val ciphertext = Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
            init(Cipher.ENCRYPT_MODE, publicKeyOf(legacyPem))
            doFinal(plaintext.toByteArray())
        }

        val opened = AndroidPushDeviceKeyStore.decryptSubject(ciphertext, listOf(account))

        assertNotNull(opened)
        assertEquals(account, opened!!.first)
        assertEquals(plaintext, String(opened.second))
    }

    @Test
    fun skipsAnInvalidDecryptBeforeSelectingTheValidPayload() {
        val valid = """{"delete-all":true}""".toByteArray()

        val selected = AndroidPushDeviceKeyStore.selectUniqueValidPayload(
            sequenceOf(
                "wrong-account" to byteArrayOf(0x00, 0x01, 0x02),
                "right-account" to valid,
            ),
        )

        assertNotNull(selected)
        assertEquals("right-account", selected!!.first)
        assertEquals(valid.toList(), selected.second.toList())
    }

    @Test
    fun refusesASubjectThatNoAccountKeyOpens() {
        val account = "33333333-3333-4333-8333-333333333333"
        extraHandles.add(AndroidPushDeviceKeyStore.handleFor(account))
        call("generateDeviceKey", AndroidPushDeviceKeyStore.handleFor(account))

        val opened = AndroidPushDeviceKeyStore.decryptSubject(
            ByteArray(256) { 0x41 },
            listOf(account),
        )

        assertEquals(null, opened)
    }

    @Test
    fun refusesAHandleThatIsNotAnAccountDigest() {
        val outcome = callRaw("generateDeviceKey", "../../etc/passwd")

        assertEquals("invalid_handle", outcome.errorCode)
        assertNotNull(outcome.errorMessage)
    }

    private fun publicKeyOf(pem: String) = KeyFactory.getInstance("RSA").generatePublic(
        X509EncodedKeySpec(
            Base64.decode(pem.lines().drop(1).dropLast(2).joinToString(""), Base64.DEFAULT),
        ),
    )

    private fun generateLegacyKey(handle: String): String {
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            "AndroidKeyStore",
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                AndroidPushDeviceKeyStore.legacyAliasFor(handle),
                KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT,
            )
                .setKeySize(2048)
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .setEncryptionPaddings(
                    KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1,
                    KeyProperties.ENCRYPTION_PADDING_RSA_OAEP,
                )
                .build(),
        )
        return AndroidPushDeviceKeyStore.pem(generator.generateKeyPair().public.encoded)
    }

    private companion object {
        const val OAEP_SHA1_TRANSFORMATION = "RSA/ECB/OAEPWithSHA-1AndMGF1Padding"
        val OAEP_SHA1_PARAMETERS = OAEPParameterSpec(
            "SHA-1",
            "MGF1",
            MGF1ParameterSpec.SHA1,
            PSource.PSpecified.DEFAULT,
        )
    }

    private fun call(method: String, handle: String): Any? {
        val outcome = callRaw(method, handle)
        assertEquals(null, outcome.errorCode)
        return outcome.value
    }

    private fun callRaw(method: String, handle: String): Outcome {
        val latch = CountDownLatch(1)
        val outcome = Outcome()
        store.onMethodCall(
            MethodCall(method, mapOf("handle" to handle)),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    outcome.value = result
                    latch.countDown()
                }

                override fun error(code: String, message: String?, details: Any?) {
                    outcome.errorCode = code
                    outcome.errorMessage = message
                    latch.countDown()
                }

                override fun notImplemented() {
                    outcome.errorCode = "notImplemented"
                    latch.countDown()
                }
            },
        )
        assertTrue("the channel never answered", latch.await(30, TimeUnit.SECONDS))
        return outcome
    }

    private class Outcome {
        var value: Any? = null
        var errorCode: String? = null
        var errorMessage: String? = null
    }
}
