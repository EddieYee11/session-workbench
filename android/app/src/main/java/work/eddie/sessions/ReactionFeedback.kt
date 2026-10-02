package work.eddie.sessions

/** Feedback belongs to a new live event, never to opening cached conversation history. */
data class ReactionFeedback(val messageId: String, val eventId: String, val emoji: String)

class ReactionFeedbackTracker {
    private val seen = LinkedHashSet<String>()
    private var initialized = false

    fun baseline(events: List<ReactionFeedback>) {
        events.forEach { remember(it.eventId) }
        initialized = true
    }

    fun live(events: List<ReactionFeedback>): ReactionFeedback? {
        val fresh = if (initialized) events.firstOrNull { it.eventId.isNotBlank() && it.eventId !in seen } else null
        events.forEach { remember(it.eventId) }
        return fresh
    }

    private fun remember(id: String) {
        if (id.isBlank()) return
        seen.add(id)
        while (seen.size > 4096) seen.remove(seen.first())
    }
}
