package work.eddie.sessions

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Uses Android's actual JSONObject implementation, including JSON.NULL behavior. */
class OutgoingMessagesUiTest {
    @get:Rule val ui = createComposeRule()

    private fun row(id: String, text: String, time: Double, request: Any = JSONObject.NULL) = JSONObject()
        .put("id", id).put("role", "user").put("text", text).put("time", time).put("request_id", request)

    @Test fun jsonNullRequestIdsProduceDistinctRealLazyListKeys() {
        val messages = listOf(
            row("assistant-first", "第一条回复", 1.0).put("role", "assistant").put("motion_id", JSONObject.NULL),
            row("assistant-second", "第二条回复", 2.0).put("role", "assistant"),
            row("assistant-third", "第三条回复", 3.0, "null").put("role", "assistant").put("motion_id", "null")
        )
        assertEquals(listOf("assistant-first", "assistant-second", "assistant-third"), messages.map(::messageMotionId))
        ui.setContent {
            MaterialTheme(colorScheme = Palette) {
                LazyColumn {
                    items(messages, key = ::messageMotionId) { message ->
                        Text(message.getString("text"), Modifier.testTag("identity-${messageMotionId(message)}"))
                    }
                }
            }
        }
        // The old JSON.NULL bug failed during LazyColumn layout with duplicate keys.
        listOf("assistant-first", "assistant-second", "assistant-third").forEach {
            ui.onNodeWithTag("identity-$it").assertIsDisplayed()
        }
    }

    @Test fun lateHistoryAndSameTextCandidateNeverStealAnExactReceipt() {
        val incoming = listOf(
            row("late-old-history", "你好", 10.0),
            row("new-other-message", "你好", 101.0),
            row("accepted-native", "你好", 102.0, "request-exact")
        )
        val merged = mergeOutgoingMessages(incoming, listOf(
            OutgoingMessage("request-exact", "pi:session", "你好", createdAt = 100.0)
        ))
        assertEquals(3, merged.size)
        assertFalse(merged[0].has("motion_id"))
        assertFalse(merged[1].has("motion_id"))
        assertEquals("request-exact", messageMotionId(merged[2]))
        // Native source JSON remains unchanged when UI identity is attached.
        assertFalse(incoming[2].has("motion_id"))
    }

    @Test fun repeatedTextRequestsClaimDifferentNativeRowsAtMostOnce() {
        val a = OutgoingMessage("same-text-request-a", "pi:session", "好的", status = "sent", createdAt = 100.0)
        val b = OutgoingMessage("same-text-request-b", "pi:session", "好的", status = "sent", createdAt = 100.0)
        val incoming = listOf(row("native-a", "好的", 101.0, a.id), row("native-b", "好的", 102.0, b.id))
        val twoNative = mergeOutgoingMessages(incoming, listOf(a, b))
        assertEquals(2, twoNative.size)
        assertEquals(listOf(a.id, b.id), twoNative.map(::messageMotionId))
        assertEquals(2, twoNative.map(::messageMotionId).distinct().size)
        val oneNative = mergeOutgoingMessages(incoming.take(1), listOf(a, b))
        assertEquals(2, oneNative.size)
        assertEquals(a.id, messageMotionId(oneNative[0]))
        assertEquals(b.id, messageMotionId(oneNative[1]))
        assertTrue(oneNative[1].getBoolean("local"))
    }

    @Test fun unknownNativeTimeAndHermesSameTextKeepTheirLocalIdentityUntilAReceipt() {
        val native = row("older-or-unverified", "继续", 0.0)
        for (scope in listOf("pi:session", "personal-main")) {
            val merged = mergeOutgoingMessages(listOf(native), listOf(
                OutgoingMessage("not-yet-accepted", scope, "继续", status = "sent", createdAt = 100.0)
            ))
            assertEquals(2, merged.size)
            assertFalse(merged[0].has("motion_id"))
            assertTrue(merged[1].getBoolean("local"))
        }
        val hermes = mergeOutgoingMessages(listOf(row("another-new-hermes-message", "继续", 101.0)), listOf(
            OutgoingMessage("not-yet-accepted", "personal-main", "继续", status = "sent", createdAt = 100.0)
        ))
        assertEquals(2, hermes.size)
        assertFalse(hermes[0].has("motion_id"))
    }

    @Test fun earlierUnconfirmedSameTextCannotClaimALaterRequestsExactRow() {
        val a = OutgoingMessage("request-a-awaiting-receipt", "pi:session", "好的", createdAt = 100.0)
        val b = OutgoingMessage("request-b-accepted", "pi:session", "好的", status = "sent", createdAt = 100.0)
        val merged = mergeOutgoingMessages(listOf(row("native-b", "好的", 101.0, b.id)), listOf(a, b))
        assertEquals(2, merged.size)
        val accepted = merged.single { it.optString("id") == "native-b" }
        assertEquals("A's fallback must not steal B's native receipt", b.id, messageMotionId(accepted))
        val awaiting = merged.single { it.optString("id") == a.id }
        assertTrue(awaiting.getBoolean("local"))
    }

    @Test fun identicalUnboundTextNeverGuessesReceiptForSendingSentOrUnknown() {
        for (status in listOf("sending", "sent", "unknown")) {
            val pending = OutgoingMessage("local-$status", "pi:session", "完全一样", status = status, createdAt = 100.0)
            val merged = mergeOutgoingMessages(listOf(row("unbound-native", pending.text, 101.0)), listOf(pending))
            assertEquals("Native identity requires an exact receipt even for $status", 2, merged.size)
            assertFalse(merged[0].has("motion_id"))
            assertEquals(status, merged[1].getString("status"))
            assertTrue(merged[1].getBoolean("local"))
        }
    }

    @Test fun unknownDeliveryOnlySettlesAfterExactReceiptWithoutDuplicateKey() {
        val pending = OutgoingMessage("unknown-request", "pi:session", "待核实", status = "unknown", createdAt = 100.0)
        val merged = mergeOutgoingMessages(listOf(row("native-after-reconnect", pending.text, 0.0, pending.id)), listOf(pending))
        assertEquals(1, merged.size)
        assertEquals(pending.id, messageMotionId(merged.single()))
        assertFalse(merged.single().optBoolean("local"))
    }
}
