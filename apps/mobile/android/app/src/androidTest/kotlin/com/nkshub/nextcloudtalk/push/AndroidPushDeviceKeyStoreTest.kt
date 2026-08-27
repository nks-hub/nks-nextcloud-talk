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

    @After
    fun removeTestKeys() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (handle in listOf(handleA, handleB)) {
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
    fun refusesAHandleThatIsNotAnAccountDigest() {
        val outcome = callRaw("generateDeviceKey", "../../etc/passwd")

        assertEquals("invalid_handle", outcome.errorCode)
        assertNotNull(outcome.errorMessage)
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
