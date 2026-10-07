import Foundation

public struct APIError: Error, LocalizedError, Sendable {
    public let status: Int
    public let detail: String
    public var errorDescription: String? { detail }
    public init(status: Int, detail: String) { self.status = status; self.detail = detail }
}

public final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct APIClient: Sendable {
    public let base: URL
    public let token: String
    public let session: URLSession
    public init(base: String, token: String, session: URLSession? = nil) throws {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw APIError(status: 0, detail: "请填写 HTTPS 服务地址")
        }
        self.base = url; self.token = token
        if let session { self.session = session }
        else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
        }
    }
    public func makeRequest(_ path: String, body: JSON? = nil, auth: Bool = true) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              url.host == base.host, url.scheme == "https", url.port == base.port else {
            throw APIError(status: 0, detail: "无效请求地址")
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }
    public func request(_ path: String, body: JSON? = nil, auth: Bool = true) async throws -> JSON {
        let (data, response) = try await session.data(for: makeRequest(path, body: body, auth: auth))
        try check(response, data: data)
        return try JSON.decode(data)
    }
    public func check(_ response: URLResponse, data: Data = Data()) throws {
        guard let h = response as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            let detail = (try? JSON.decode(data)["detail"].string) ?? ""
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                           detail: detail.isEmpty ? "连接失败（\((response as? HTTPURLResponse)?.statusCode ?? 0)）" : detail)
        }
    }
    public func transcribe(id: String, audio: Data) async throws -> JSON {
        var req = try makeRequest("/voice/transcribe/" + id.pathEncoded)
        req.httpMethod = "POST"; req.httpBody = audio
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 100
        let (data, response) = try await session.data(for: req); try check(response, data: data)
        return try JSON.decode(data)
    }
    public func uploadAttachment(_ data: Data, name: String, mime: String, id: String) async throws -> JSON {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw APIError(status: 413, detail: "附件为空或超过 20 MB") }
        var req = try makeRequest("/personal/attachments/" + id.pathEncoded)
        req.httpMethod = "POST"; req.httpBody = data
        req.setValue(name.queryEncoded, forHTTPHeaderField: "X-Filename")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.data(for: req); try check(response, data: body)
        return try JSON.decode(body)
    }
    public func download(_ id: String, name: String, into folder: URL) async throws -> URL {
        let (tmp, response) = try await session.download(for: makeRequest("/personal/artifacts/" + id.pathEncoded))
        try check(response)
        let directory = folder.appendingPathComponent(id.pathEncoded, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        let file = directory.appendingPathComponent(safeName.isEmpty ? "成果" : safeName)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: tmp, to: file); return file
    }
    public func stream(after: Int?, onEvent: @Sendable (SSEEvent) async -> Void) async throws {
        var req = try makeRequest("/personal/conversation/stream")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept"); req.timeoutInterval = 3600
        if let after { req.setValue(String(after), forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await session.bytes(for: req); try check(response)
        var parser = SSEParser()
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            line.append(byte)
            if byte == 10 {
                for event in parser.feed(line) { await onEvent(event) }
                line.removeAll(keepingCapacity: true)
            }
        }
    }
    public func socket(_ path: String) throws -> URLSessionWebSocketTask {
        var req = try makeRequest(path)
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"; req.url = components.url
        return session.webSocketTask(with: req)
    }
}
