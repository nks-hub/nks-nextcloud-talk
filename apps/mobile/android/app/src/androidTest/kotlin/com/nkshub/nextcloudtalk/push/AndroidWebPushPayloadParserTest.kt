package com.nkshub.nextcloudtalk.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class AndroidWebPushPayloadParserTest {
    @Test
    fun activationTokenIsSeparatedFromOrdinaryMessages() {
        val payload = parse(
            """{"activationToken":"9f9bcfc4-93db-4f23-a8f4-5f2403f722cc"}""",
        )

        assertTrue(payload is AndroidWebPushPayload.Activation)
    }

    @Test
    fun ordinaryMessageKeepsOnlyNotificationNavigationMetadata() {
        val payload = parse(
            """{"app":"spreed","subject":"New message","nid":42,"type":"chat","id":"room"}""",
        ) as AndroidWebPushPayload.Message

        assertEquals(42L, payload.notificationId)
        assertEquals("spreed", payload.app)
        assertEquals("New message", payload.subject)
        assertEquals("chat", payload.type)
        assertEquals("room", payload.objectId)
    }

    @Test
    fun deleteCommandsAreBoundedAndTyped() {
        assertEquals(AndroidWebPushPayload.DeleteAll, parse("""{"delete-all":true}"""))
        assertEquals(
            AndroidWebPushPayload.Delete(7L),
            parse("""{"delete":true,"nid":7}"""),
        )
        assertEquals(
            AndroidWebPushPayload.DeleteMultiple(listOf(3L, 4L)),
            parse("""{"delete-multiple":true,"nids":[3,4]}"""),
        )
    }

    @Test
    fun deleteMultipleAcceptsTenIdsAndRejectsEleven() {
        val tenIds = (1L..10L).toList()
        val accepted = parse(
            """{"delete-multiple":true,"nids":[${tenIds.joinToString(",") }]}""",
        )
        val rejected = parse(
            """{"delete-multiple":true,"nids":[${(1L..11L).joinToString(",") }]}""",
        )

        assertEquals(AndroidWebPushPayload.DeleteMultiple(tenIds), accepted)
        assertEquals(AndroidWebPushPayload.Invalid, rejected)
    }

    @Test
    fun malformedOrUndecryptedPayloadIsNeverShown() {
        assertEquals(AndroidWebPushPayload.Invalid, parse("not-json"))
        assertEquals(
            AndroidWebPushPayload.Invalid,
            AndroidWebPushPayloadParser.parse(
                """{"app":"spreed","subject":"hidden","nid":1}"""
                    .toByteArray(StandardCharsets.UTF_8),
                decrypted = false,
            ),
        )
        assertEquals(
            AndroidWebPushPayload.Invalid,
            parse("""{"app":"spreed","subject":"message","nid":0}"""),
        )
        assertEquals(
            AndroidWebPushPayload.Invalid,
            parse(" ".repeat(4096) + """{"nid":1}"""),
        )
    }

    @Test
    fun ambiguousActionsAndActivationMixAreRejected() {
        for (source in listOf(
            """{"delete":true,"delete-all":true,"nid":1}""",
            """{"delete":true,"delete-multiple":true,"nid":1,"nids":[1]}""",
            """{"activationToken":"9f9bcfc4-93db-4f23-a8f4-5f2403f722cc","app":"spreed"}""",
        )) {
            assertEquals(source, AndroidWebPushPayload.Invalid, parse(source))
        }
    }

    @Test
    fun actionFlagsMustBeTheBooleanTrue() {
        for (source in listOf(
            """{"delete":"true","nid":1}""",
            """{"delete":false,"nid":1}""",
            """{"delete-multiple":1,"nids":[1]}""",
            """{"delete-all":"true"}""",
        )) {
            assertEquals(source, AndroidWebPushPayload.Invalid, parse(source))
        }
    }

    @Test
    fun notificationIdsAreExactPositiveSignedInt64Values() {
        val maximum = Long.MAX_VALUE

        assertEquals(
            maximum,
            (parse("""{"nid":$maximum}""") as AndroidWebPushPayload.Message)
                .notificationId,
        )
        assertEquals(
            AndroidWebPushPayload.Delete(maximum),
            parse("""{"delete":true,"nid":$maximum}"""),
        )
        assertEquals(
            AndroidWebPushPayload.DeleteMultiple(listOf(maximum)),
            parse("""{"delete-multiple":true,"nids":[$maximum]}"""),
        )
        for (source in listOf(
            """{"nid":1.5}""",
            """{"nid":1e3}""",
            """{"nid":9223372036854775808}""",
            """{"delete":true,"nid":0}""",
            """{"delete-multiple":true,"nids":[1,1]}""",
        )) {
            assertEquals(source, AndroidWebPushPayload.Invalid, parse(source))
        }
    }

    @Test
    fun extraDuplicateAndIncompleteMembersAreRejected() {
        for (source in listOf(
            """{"delete-all":true,"nid":1}""",
            """{"delete":true,"nid":1,"app":"spreed"}""",
            """{"delete":true}""",
            """{"delete-multiple":true}""",
            """{"app":"spreed","unknown":true}""",
            """{"nid":1,"nid":2}""",
            """{"delete-all":true,"delete-all":true}""",
            "{}",
        )) {
            assertEquals(source, AndroidWebPushPayload.Invalid, parse(source))
        }
    }

    private fun parse(json: String): AndroidWebPushPayload {
        return AndroidWebPushPayloadParser.parse(
            json.toByteArray(StandardCharsets.UTF_8),
            decrypted = true,
        )
    }
}
