import Foundation
import ComCore

@MainActor final class StreamCheck {
    var task: Task<Void, Error>?
    var first: SSEEvent?
    func record(_ event: SSEEvent) { first = event; task?.cancel() }
}
@main struct LiveProbe {
    @MainActor static func main() async throws {
        let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError(status: 0, detail: "Pass token only through stdin") }
        let api = try APIClient(base: CommandLine.arguments[1], token: token)
        let health = try await api.request("/health")
        guard health["features"]["ios_nodes_v1"].bool else { throw APIError(status: 0, detail: "iOS contract not loaded") }
        let endpoints = ["/personal/conversation", "/personal/briefing", "/personal/tasks", "/personal/memory", "/sessions"]
        for endpoint in endpoints {
            let value = try await api.request(endpoint)
            let key = endpoint == "/sessions" ? "sessions" : endpoint == "/personal/conversation" ? "messages" : endpoint == "/personal/briefing" ? "cards" : "items"
            guard !value[key].isNull else { throw APIError(status: 0, detail: "Unexpected shape at " + endpoint) }
            print(endpoint + ": " + String(value[key].array.count) + " records, actual service")
        }
        let probe = StreamCheck()
        let stream = Task { try await api.stream(after: nil) { event in await probe.record(event) } }
        probe.task = stream
        let timeout = Task { try await Task.sleep(for: .seconds(20)); stream.cancel() }
        do { try await stream.value } catch { if probe.first == nil { throw error } }
        timeout.cancel()
        guard let event = probe.first, event.name == "snapshot" || event.name == "update", !event.id.isEmpty else { throw APIError(status: 0, detail: "SSE resume identity missing") }
        print("SSE: actual " + event.name + ", event ID received; cancelled without submitting a turn")
    }
}
