package work.eddie.sessions

/** The avatar never invents task progress or celebrates a cached, completed session. */
fun companionVisualState(
    status: String,
    connected: Boolean,
    hasApproval: Boolean = false,
    previousStatus: String? = null,
): String = when {
    !connected -> "idle"
    status in setOf("failed", "error") -> "error"
    hasApproval || status == "waiting" -> "curious"
    status == "running" -> "thinking"
    status == "completed" && previousStatus in setOf("running", "waiting") -> "happy"
    else -> "idle"
}
