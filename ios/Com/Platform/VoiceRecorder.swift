import Foundation
import AVFoundation
import Observation
import ComCore

/// Realtime tap state. The tap fires on an audio thread, so this type owns everything
/// it touches — converter, file writer, buffers — and only hands Sendable values out.
private final class VoiceCapture: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let writer: AVAudioFile?
    private let emit: @Sendable (Data) -> Void
    private let metered: @Sendable (Double) -> Void

    init?(input: AVAudioFormat, writer: AVAudioFile?,
          emit: @escaping @Sendable (Data) -> Void, metered: @escaping @Sendable (Double) -> Void) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.target = target; self.converter = converter; self.writer = writer
        self.emit = emit; self.metered = metered
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 32
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        try? writer?.write(from: out)
        var energy = 0.0
        for index in 0..<count { energy += Double(samples[index] * samples[index]) }
        emit(VoiceStream.pcm16(Array(UnsafeBufferPointer(start: samples, count: count))))
        metered(count > 0 ? min(1, (energy / Double(count)).squareRoot() * 4) : 0)
    }
}

@MainActor @Observable final class VoiceRecorder {
    enum Phase: String { case idle, recording, recorded, transcribing, ready, failed }
    var phase: Phase = .idle
    var level: Double = 0
    var levels: [Double] = []
    var seconds = 0
    var transcript = ""
    var error = ""
    var captureID = ""
    private let engine = AVAudioEngine()
    private var capture: VoiceCapture?
    private var audio: AsyncStream<Data>.Continuation?
    private var socket: URLSessionWebSocketTask?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var streamed = ""
    private var streamFailure = ""
    private var streamSettled = false
    private var timer: Task<Void, Never>?
    private var file: URL?
    private var interruption: NSObjectProtocol?
    /// 正在申请麦克风/建会话：UI 可据此 disable 开麦，防连点叠启。
    private(set) var starting = false
    private var tapped = false
    /// Stop on its own after a pause, so a quick 记账/日程 sentence needs no second tap.
    var autoSend = UserDefaults.standard.object(forKey: "voice.autoSend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSend, forKey: "voice.autoSend") }
    }
    static var pauseToSend: TimeInterval { VoiceCommands.pauseToSend }
    /// Ambient loudness, tracked low so a fan or street noise does not count as speech.
    private var noiseFloor = 0.02
    private var lastVoiced = Date.distantFuture

    init() {
        do {
            if let saved = try SecureVault.load(JSON.self, name: "voice-capture"), !saved["id"].string.isEmpty {
                captureID = saved["id"].string
                // WAV is the streaming-era retry copy; M4A is every capture recorded before it.
                var restored = false
                for ext in ["wav", "m4a"] {
                    let url = SecureVault.directory.appendingPathComponent(captureID + "." + ext)
                    if FileManager.default.fileExists(atPath: url.path) {
                        file = url; phase = .recorded; seconds = saved["seconds"].int; error = "上次录音已保留，尚未发送"
                        restored = true
                        break
                    }
                }
                if !restored {
                    // 元数据在、文件没了：别假装还能重试这条。
                    captureID = ""
                    error = "上次录音记录在，文件已不在——不能当已保留。可再录一条。"
                }
            }
        } catch {
            self.error = "上次录音记录没读上：\(error.localizedDescription)——若有未发录音，可能找不回。不会假装已恢复。"
        }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.phase == .recording { self?.finishRecording() } }
        }
    }
    var hasCapture: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func start(using api: APIClient?) async {
        guard !starting && phase != .recording && phase != .transcribing else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "麦克风没开——到系统设置允许 Com；开麦失败不会假装在听。"
            phase = .failed
            return
        }
        do {
            cancel()
            captureID = UUID().uuidString.lowercased()
            var url = SecureVault.directory.appendingPathComponent(captureID + ".wav")
            file = url
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(status: 0, detail: "麦克风不可用") }
            let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try? url.setResourceValues(resources)
            let (pcm, sink) = AsyncStream<Data>.makeStream()
            guard let capture = VoiceCapture(input: format, writer: writer, emit: { sink.yield($0) },
                                             metered: { [weak self] value in Task { @MainActor in self?.meter(value) } }) else {
                throw APIError(status: 0, detail: "麦克风格式不支持")
            }
            self.capture = capture; audio = sink
            // `installTap`'s block parameter is not annotated @Sendable, so under Swift 6 a
            // closure written plainly here inherits VoiceRecorder's @MainActor isolation and
            // traps the instant AVFAudio fires it on its realtime messenger queue. An explicit
            // @Sendable makes it nonisolated — which is what an audio thread requires.
            input.installTap(onBus: 0, bufferSize: 1600, format: format) { @Sendable buffer, _ in capture.append(buffer) }
            tapped = true
            engine.prepare()
            try engine.start()
            if let api { listen(api: api, pcm: pcm) }
            phase = .recording; seconds = 0; levels = []; error = ""; transcript = ""; Haptics.sent()
            noiseFloor = 0.02; lastVoiced = .distantFuture
            saveCapture()
            let started = Date()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, !Task.isCancelled, self.phase == .recording else { return }
                    let elapsed = Int(Date().timeIntervalSince(started))
                    if elapsed != self.seconds { self.seconds = elapsed; self.saveCapture() }
                    if elapsed >= 60 { self.finishRecording(); self.error = "已达到 60 秒，录音已保留。"; return }
                }
            }
        } catch {
            // 开麦失败留 failed + 开口；勿停在 idle 像没试过。
            self.error = "开麦没成：" + error.localizedDescription + "——可再试"
            phase = .failed
        }
    }

    func finishRecording() {
        guard phase == .recording else { return }
        timer?.cancel(); timer = nil
        detachTap()
        engine.stop(); capture = nil; level = 0; phase = .recorded
        audio?.finish(); audio = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        saveCapture(); Haptics.selection()
    }

    func transcribe(using api: APIClient) async {
        if phase == .recording { finishRecording() }
        guard let file, phase == .recorded || phase == .failed else { return }
        phase = .transcribing; error = ""
        let id = captureID
        // The streaming service closes the utterance a few seconds after the audio ends;
        // a stalled socket falls back to uploading the recording we kept.
        let deadline = Date().addingTimeInterval(30)
        while !streamSettled && Date() < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        if streamSettled, streamFailure.isEmpty, !streamed.isEmpty {
            guard phase == .transcribing, captureID == id else { return }
            closeStream(); transcript = streamed; phase = .ready; return
        }
        closeStream()
        do {
            let data = try Data(contentsOf: file)
            let result = try await api.transcribe(id: id, audio: data, mime: file.pathExtension == "m4a" ? "audio/mp4" : "audio/wav")
            guard phase == .transcribing, captureID == id else { return }
            transcript = result["text"].string
            guard !transcript.isEmpty else { throw APIError(status: 422, detail: "没有听清——录音已保留，可重新转写") }
            phase = .ready
        } catch {
            if phase == .transcribing && captureID == id {
                self.error = "转写没成：" + error.localizedDescription + "——录音还在，可再试"
                phase = .failed
            }
        }
    }

    func cancel() {
        timer?.cancel(); timer = nil
        closeStream()
        detachTap()
        engine.stop(); capture = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; captureID = ""; phase = .idle; level = 0; levels = []; transcript = ""; error = ""; seconds = 0
        do {
            try SecureVault.save(JSON.null, name: "voice-capture")
        } catch {
            // 本地已清空；元数据清不掉下次可能误提示「已保留」。开口让人知道，不挡放弃。
            self.error = "录音已放弃，但记录没清干净：\(error.localizedDescription)——下次打开若看见旧提示，可忽略或再录覆盖。不会假装已清干净。"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func listen(api: APIClient, pcm: AsyncStream<Data>) {
        guard let ws = try? api.socket("/voice/stream/" + captureID.pathEncoded) else { return }
        socket = ws; ws.resume()
        streamed = ""; streamFailure = ""; streamSettled = false
        sender = Task { [weak self] in
            for await chunk in pcm {
                guard let self, let ws = self.socket else { return }
                do { try await ws.send(.data(chunk)) } catch { return }
            }
            // The stream drains before this runs, so `end` always trails the last
            // chunk; sending it from here keeps the server from closing the
            // utterance ahead of audio it has not seen yet.
            guard let self, let ws = self.socket, !self.streamSettled else { return }
            try? await ws.send(.string(VoiceStream.end))
        }
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ws = self.socket else { return }
                let data: Data
                do {
                    switch try await ws.receive() {
                    case .data(let raw): data = raw
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                } catch {
                    // A dropped socket mid-utterance must not pass a truncated
                    // partial off as the transcript; mark it failed so transcribe()
                    // uploads the recording we kept instead.
                    if !Task.isCancelled { self.streamFailure = "语音识别连接中断" }
                    self.streamSettled = true
                    return
                }
                switch VoiceStream.event(from: data) {
                case .partial(let text): self.streamed = text; self.transcript = text
                case .final(let text):
                    if !text.isEmpty { self.streamed = text; self.transcript = text }
                    self.streamSettled = true; return
                case .failure(let message): self.streamFailure = message; self.streamSettled = true; return
                case nil: continue
                }
            }
        }
    }

    /// AVAudioNode raises an Objective-C exception — fatal, not a Swift error — when a tap
    /// is removed from a bus that has none, so every removal is gated on one being installed.
    private func detachTap() {
        guard tapped else { return }
        tapped = false
        engine.inputNode.removeTap(onBus: 0)
    }

    private func closeStream() {
        sender?.cancel(); sender = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        audio?.finish(); audio = nil
    }

    private func meter(_ value: Double) {
        level += (value - level) * (value > level ? 0.6 : 0.15)
        levels.append(level); if levels.count > 48 { levels.removeFirst() }
        // Floor falls fast and rises slowly, so speech never drags it up to itself.
        noiseFloor += (value - noiseFloor) * (value < noiseFloor ? 0.3 : 0.004)
        if value > max(0.06, noiseFloor * 2.5) { lastVoiced = Date() }
        // Only after the service has heard words: a silent start must not send nothing.
        guard autoSend, phase == .recording, !transcript.isEmpty,
              Date().timeIntervalSince(lastVoiced) >= Self.pauseToSend else { return }
        finishRecording()
    }

    /// 落盘 capture 元数据，供杀进程后重试。失败写 `error`，不假装「已保留」。
    private func saveCapture() {
        guard !captureID.isEmpty else { return }
        do {
            try SecureVault.save(JSON.object(["id": .string(captureID), "seconds": .number(Double(seconds))]), name: "voice-capture")
            if self.error.contains("录音元数据没存上") { self.error = "" }
        } catch {
            // 录音文件可能还在目录里，但没元数据 → 冷启动找不到；开口别装已保留。
            self.error = "录音元数据没存上：\(error.localizedDescription)——杀掉 App 可能丢这条可重试录音。转写前尽量别杀。不会假装已保留。"
        }
    }
}
