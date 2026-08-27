package com.nkshub.nextcloudtalk.push

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
import java.security.KeyStore
import javax.crypto.Cipher
import java.security.interfaces.RSAPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

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
            val alias = AndroidPushDeviceKeyStore.aliasFor(handle)
            if (keyStore.containsAlias(alias)) {
                keyStore.deleteEntry(alias)
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
        val first = call("generateDeviceKey", handleA)
        call("destroyDeviceKey", handleA)

        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertTrue(!keyStore.containsAlias(AndroidPushDeviceKeyStore.aliasFor(handleA)))
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
