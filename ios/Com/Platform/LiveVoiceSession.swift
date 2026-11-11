import Foundation
import AVFoundation
import UIKit
import Observation
import ComCore

/// Realtime 16kHz mono PCM capture for full-duplex Live Voice (batches into ~40ms frames).
private final class LiveAudioCapture: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let emit: @Sendable (Data, Double) -> Void
    private var sampleQueue: [Float] = []
    private let batchSamples = 640 // 40ms at 16kHz (25 frames/sec)

    init?(
        input: AVAudioFormat,
        emit: @escaping @Sendable (Data, Double) -> Void
    ) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.target = target
        self.converter = converter
        self.emit = emit
        self.sampleQueue.reserveCapacity(1280)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate) + 32
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        sampleQueue.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        while sampleQueue.count >= batchSamples {
            let chunk = Array(sampleQueue.prefix(batchSamples))
            sampleQueue.removeFirst(batchSamples)
            var energy = 0.0
            for s in chunk {
                let d = Double(s)
                energy += d * d
            }
            let rms = min(1.0, (energy / Double(batchSamples)).squareRoot() * 4.2)
            emit(VoiceStream.pcm16(chunk), rms)
        }
    }
}

public struct LiveVoiceLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let isUser: Bool
    public var text: String

    public init(id: Int, isUser: Bool, text: String) {
        self.id = id
        self.isUser = isUser
        self.text = text
    }
}

public struct LiveVoiceOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let subtitle: String
    public static let all: [LiveVoiceOption] = [
        .init(id: "Aoede", label: "Aoede", subtitle: "自然温柔"),
        .init(id: "Kore", label: "Kore", subtitle: "清亮干练"),
        .init(id: "Puck", label: "Puck", subtitle: "松弛活力"),
        .init(id: "Charon", label: "Charon", subtitle: "沉稳温和"),
    ]
}

@MainActor @Observable final class LiveVoiceSession {
    enum Phase: String {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case reconnecting
        case failed
    }

    var phase: Phase = .idle
    var muted: Bool = false {
        didSet {
            if muted { userLevel = 0 }
        }
    }
    var speakerOn: Bool = true {
        didSet {
            applySpeakerOutputOverride()
        }
    }
    var showSubtitles: Bool = UserDefaults.standard.object(forKey: "liveVoice.subtitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSubtitles, forKey: "liveVoice.subtitles") }
    }
    var voiceName: String = UserDefaults.standard.string(forKey: "liveVoice.name") ?? "Aoede" {
        didSet { UserDefaults.standard.set(voiceName, forKey: "liveVoice.name") }
    }
    var userLevel: Double = 0
    var assistantLevel: Double = 0
    var userTranscript: String = ""
    var assistantTranscript: String = ""
    var lines: [LiveVoiceLine] = []
    var activeToolTitle: String = ""
    var error: String = ""
    var seconds: Int = 0
    var turnsCount: Int = 0
    var onTurnComplete: (@MainActor () -> Void)?

    // MARK: - Generation Epoch Fencing & Emotion State (Milestones M3 & M5)
    var currentEpoch: Int = 1
    var dominantEmotion: String = "calm"
    var emotionEnergy: Double = 0.5
    var bargeInTriggerCount: Int = 0
    private(set) var currentJitterThresholdMs: Double = 60.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24000,
        channels: 1,
        interleaved: false
    )!
    private var capture: LiveAudioCapture?
    private var audioStream: AsyncStream<(Data, Double)>.Continuation?
    private var activeAPI: APIClient?
    private var socket: URLSessionWebSocketTask?
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var duckRestoreTask: Task<Void, Never>?
    private var speakingHoldTask: Task<Void, Never>?
    private var tapped = false
    private var mixerTapped = false
    private var playerAttached = false
    private var pendingBuffers = 0
    private var rxAccumulator = Data()
    private var bargeInStreak = 0
    private var sessionGeneration = 0
    private var sessionId: String = ""
    private var reconnectAttempts = 0
    private var serverErrorReceived = false
    private var duckedAt: ContinuousClock.Instant?
    private var nextLineId: Int = 1
    private var forceNewAssistantLine = false

    // Lifecycle State
    private var isAudioInterrupted = false
    private var interruptionObservers: [NSObjectProtocol] = []

    func start(using api: APIClient?, uiTesting: Bool = false) async {
        stop(keepError: false)
        sessionGeneration += 1
        let gen = sessionGeneration
        phase = .connecting
        error = ""
        userTranscript = ""
        assistantTranscript = ""
        lines.removeAll()
        nextLineId = 1
        forceNewAssistantLine = false
        activeToolTitle = ""
        seconds = 0
        muted = false
        currentEpoch = 1
        dominantEmotion = "calm"
        emotionEnergy = 0.5
        bargeInTriggerCount = 0
        currentJitterThresholdMs = 60.0
        isAudioInterrupted = false
        reconnectAttempts = 0
        serverErrorReceived = false
        duckedAt = nil
        sessionId = UUID().uuidString.lowercased()
        activeAPI = api

        if uiTesting {
            phase = .speaking
            dominantEmotion = "happy"
            emotionEnergy = 0.75
            userTranscript = "今天下午还有什么安排？顺便记一笔咖啡 28 块。"
            assistantTranscript = "咖啡 28 块已经帮你记进餐饮外卖啦！今天下午三点还有一场选题讨论，别忘了带备用电池。"
            lines = [
                LiveVoiceLine(id: 1, isUser: true, text: "帮我看看今天下午还有什么安排？"),
                LiveVoiceLine(id: 2, isUser: false, text: "下午三点有一场选题讨论，别的时段都空着。"),
                LiveVoiceLine(id: 3, isUser: true, text: "好，顺便记一笔咖啡 28 块。"),
                LiveVoiceLine(id: 4, isUser: false, text: "记好啦，28 块归在餐饮外卖，去开会别忘带备用电池。")
            ]
            nextLineId = 5
            activeToolTitle = "记账 ¥28 · 咖啡"
            assistantLevel = 0.62
            seconds = 18
            startTimer(generation: gen)
            return
        }

        guard let api else {
            error = "还没连上 Mac mini——请先完成配对后再开启实时通话。"
            phase = .failed
            return
        }

        guard await AVAudioApplication.requestRecordPermission() else {
            error = "麦克风权限未开启——请到系统设置允许 Com 使用麦克风。"
            phase = .failed
            return
        }

        do {
            try configureAudioEngine()
            let path = "/voice/live?voice=" + voiceName.queryEncoded + "&session=" + sessionId.queryEncoded
            let ws = try api.socket(path)
            socket = ws
            ws.resume()
            startTimer(generation: gen)
        } catch {
            self.error = "开启实时通话失败：" + error.localizedDescription
            self.phase = .failed
            stopAudioEngine()
        }
    }

    func switchVoice(_ newVoice: String, using api: APIClient?, uiTesting: Bool = false) async {
        guard newVoice != voiceName || phase == .failed else { return }
        voiceName = newVoice
        Haptics.selection()
        await start(using: api, uiTesting: uiTesting)
    }

    func triggerBargeInFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        bargeInTriggerCount += 1
    }

    func interruptPlayback(sendInterruptSignal: Bool = false) {
        let wasActive = pendingBuffers > 0 || !rxAccumulator.isEmpty || phase == .speaking || duckedAt != nil
        guard wasActive || sendInterruptSignal else { return }
        speakingHoldTask?.cancel()
        speakingHoldTask = nil
        resetDuckingImmediately()
        pendingBuffers = 0
        rxAccumulator.removeAll(keepingCapacity: true)
        bargeInStreak = 0
        assistantLevel = 0
        if playerAttached && player.isPlaying {
            player.stop()
            player.play()
        }
        if phase == .speaking {
            phase = .listening
        }
        if sendInterruptSignal {
            currentEpoch += 1
            if let ws = socket {
                let payload = JSON.object([
                    "type": .string("interrupt"),
                    "epoch": .number(Double(currentEpoch))
                ])
                if let data = try? JSONEncoder().encode(payload), let str = String(data: data, encoding: .utf8) {
                    Task { try? await ws.send(.string(str)) }
                }
            }
        }
        if wasActive {
            triggerBargeInFeedback()
        }
    }

    func sendTextTurn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ws = socket else { return }
        interruptPlayback(sendInterruptSignal: true)
        userTranscript = trimmed
        assistantTranscript = ""
        appendOrUpdateLine(isUser: true, text: trimmed)
        phase = .thinking
        let payload = JSON.object([
            "type": .string("text"),
            "text": .string(trimmed),
            "epoch": .number(Double(currentEpoch))
        ])
        if let data = try? JSONEncoder().encode(payload), let str = String(data: data, encoding: .utf8) {
            Task { try? await ws.send(.string(str)) }
        }
    }

    func stop(keepError: Bool = false) {
        sessionGeneration += 1
        timerTask?.cancel(); timerTask = nil
        duckRestoreTask?.cancel(); duckRestoreTask = nil
        speakingHoldTask?.cancel(); speakingHoldTask = nil
        senderTask?.cancel(); senderTask = nil
        receiverTask?.cancel(); receiverTask = nil
        if let ws = socket {
            Task {
                try? await ws.send(.string(#"{"type":"end"}"#))
                ws.cancel(with: .normalClosure, reason: nil)
            }
        }
        socket = nil
        activeAPI = nil
        audioStream?.finish(); audioStream = nil
        stopAudioEngine()
        userLevel = 0
        assistantLevel = 0
        pendingBuffers = 0
        rxAccumulator.removeAll(keepingCapacity: false)
        bargeInStreak = 0
        duckedAt = nil
        reconnectAttempts = 0
        serverErrorReceived = false
        activeToolTitle = ""
        if !keepError {
            phase = .idle
            error = ""
        }
    }

    private func applySpeakerOutputOverride() {
        let session = AVAudioSession.sharedInstance()
        let externalPorts: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE,
            .usbAudio,
            .airPlay,
            .carAudio
        ]
        let hasExternalRoute = session.currentRoute.outputs.contains { externalPorts.contains($0.portType) }
        guard !hasExternalRoute else { return }
        try? session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    private func engageSoftDucking(generation: Int) {
        let now = ContinuousClock.now
        duckedAt = now
        player.volume = 0.3
        duckRestoreTask?.cancel()
        duckRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled,
                  let self,
                  self.sessionGeneration == generation,
                  self.duckedAt != nil else { return }
            let steps = 6
            let startVol = self.player.volume
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled,
                      self.sessionGeneration == generation,
                      self.duckedAt != nil else { return }
                let progress = Float(step) / Float(steps)
                self.player.volume = startVol + (1.0 - startVol) * progress
            }
            self.player.volume = 1.0
            self.duckedAt = nil
        }
    }

    private func resetDuckingImmediately() {
        duckRestoreTask?.cancel()
        duckRestoreTask = nil
        duckedAt = nil
        player.volume = 1.0
    }

    private func configureAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        applySpeakerOutputOverride()

        setupAudioSessionObservers()

        // 回声消除要在接线之前开：开启后输入/输出节点的格式会变
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                print("[LiveVoiceSession] setVoiceProcessingEnabled(true) failed, continuing without hardware AEC: \(error)")
            }
        }

        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            playerAttached = true
        }
        player.volume = 1.0

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw APIError(status: 0, detail: "麦克风输入格式不可用")
        }

        let (pcmStream, continuation) = AsyncStream<(Data, Double)>.makeStream()
        guard let cap = LiveAudioCapture(
            input: inputFormat,
            emit: { chunk, level in continuation.yield((chunk, level)) }
        ) else {
            throw APIError(status: 0, detail: "音频采样转换器初始化失败")
        }

        self.capture = cap
        self.audioStream = continuation
        if tapped {
            input.removeTap(onBus: 0)
            tapped = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { @Sendable buffer, _ in
            cap.append(buffer)
        }
        tapped = true

        let mixer = engine.mainMixerNode
        if mixerTapped {
            mixer.removeTap(onBus: 0)
            mixerTapped = false
        }
        let mixerFormat = mixer.outputFormat(forBus: 0)
        let tapFormat = (mixerFormat.sampleRate > 0 && mixerFormat.channelCount > 0) ? mixerFormat : nil
        mixer.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { @Sendable [weak self] buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
            var energy = 0.0
            for i in 0..<frameLength {
                let d = Double(samples[i])
                energy += d * d
            }
            let rms = min(1.0, (energy / Double(frameLength)).squareRoot() * 3.8)
            Task { @MainActor [weak self] in
                self?.updateAssistantLevel(rms)
            }
        }
        mixerTapped = true

        engine.prepare()
        try engine.start()
        player.play()

        let gen = sessionGeneration
        senderTask = Task { [weak self] in
            for await (chunk, rms) in pcmStream {
                guard let self, self.sessionGeneration == gen else { return }
                if self.phase == .reconnecting || self.socket == nil {
                    continue
                }
                guard let ws = self.socket else { continue }
                if self.muted || self.isAudioInterrupted {
                    self.bargeInStreak = 0
                    self.userLevel = 0
                    continue
                }
                self.updateUserLevel(rms)
                let isPlayingOut = self.phase == .speaking || self.pendingBuffers > 0
                if isPlayingOut {
                    if rms >= 0.16 {
                        self.bargeInStreak += 1
                        if self.bargeInStreak >= 2 {
                            self.engageSoftDucking(generation: gen)
                        }
                    } else {
                        self.bargeInStreak = 0
                    }
                } else {
                    self.bargeInStreak = 0
                }
                do {
                    try await ws.send(.data(chunk))
                } catch {
                    if self.sessionGeneration != gen || self.phase == .idle || self.phase == .failed {
                        return
                    }
                    continue
                }
            }
        }

        receiverTask = Task { [weak self] in
            await self?.receiveLoop(generation: gen)
        }
    }

    private func setupAudioSessionObservers() {
        removeAudioSessionObservers()
        let center = NotificationCenter.default

        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            switch type {
            case .began:
                self.handleAudioInterruptionBegan()
            case .ended:
                let optVal = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume)
                self.handleAudioInterruptionEnded(shouldResume: shouldResume)
            @unknown default:
                break
            }
        }
        interruptionObservers.append(interruptionObserver)

        let routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
            self.handleAudioRouteChange(reason: reason)
        }
        interruptionObservers.append(routeChangeObserver)
    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        for observer in interruptionObservers {
            center.removeObserver(observer)
        }
        interruptionObservers.removeAll()
    }

    private func handleAudioInterruptionBegan() {
        isAudioInterrupted = true
        if playerAttached && player.isPlaying {
            player.pause()
        }
        userLevel = 0
        assistantLevel = 0
    }

    private func handleAudioInterruptionEnded(shouldResume: Bool) {
        guard shouldResume else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            applySpeakerOutputOverride()
            if !engine.isRunning {
                try engine.start()
            }
            if phase == .speaking && playerAttached && !player.isPlaying {
                player.play()
            }
            isAudioInterrupted = false
        } catch {
            // Keep interrupted state if recovery failed
        }
    }

    private func handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Output device (e.g. AirPods) unplugged: pause playback to avoid loudspeaker blast
            if playerAttached && player.isPlaying {
                player.pause()
            }
            bargeInStreak = 0
            applySpeakerOutputOverride()
        case .newDeviceAvailable:
            try? AVAudioSession.sharedInstance().setActive(true)
            applySpeakerOutputOverride()
            if phase == .speaking && playerAttached && !player.isPlaying {
                player.play()
            }
        default:
            break
        }
    }

    private func stopAudioEngine() {
        removeAudioSessionObservers()
        speakingHoldTask?.cancel()
        speakingHoldTask = nil
        resetDuckingImmediately()
        if tapped {
            tapped = false
            engine.inputNode.removeTap(onBus: 0)
        }
        if mixerTapped {
            mixerTapped = false
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        if playerAttached && player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        capture = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func receiveLoop(generation: Int) async {
        let backoffDelays: [Duration] = [.milliseconds(500), .milliseconds(1000), .milliseconds(2000)]
        while !Task.isCancelled && sessionGeneration == generation {
            guard let ws = socket else { return }
            do {
                let message = try await ws.receive()
                guard sessionGeneration == generation else { return }
                switch message {
                case .data(let rawData):
                    guard !rawData.isEmpty else { continue }
                    // Parse epoch integer in audio frame headers if present:
                    // Header format: Magic "EPOC" (0x45, 0x50, 0x4F, 0x43) + UInt32 little-endian epoch
                    let frameEpoch: Int
                    let pcmData: Data
                    if rawData.count >= 8 && rawData.prefix(4) == Data([0x45, 0x50, 0x4F, 0x43]) {
                        let ep = rawData[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                        frameEpoch = Int(ep)
                        pcmData = rawData.subdata(in: 8..<rawData.count)
                    } else {
                        frameEpoch = currentEpoch
                        pcmData = rawData
                    }

                    // Generation Epoch Fencing: drop any received audio packets where frameEpoch < currentEpoch
                    guard frameEpoch >= currentEpoch else {
                        continue
                    }
                    enqueuePlayback(pcmData, frameEpoch: frameEpoch, generation: generation)
                case .string(let text):
                    if let data = text.data(using: .utf8), let json = try? JSON.decode(data) {
                        handleControlEvent(json)
                    }
                @unknown default:
                    continue
                }
            } catch {
                guard !Task.isCancelled,
                      sessionGeneration == generation,
                      !serverErrorReceived,
                      phase != .idle,
                      phase != .failed else { return }

                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil

                var reconnectedSocket: URLSessionWebSocketTask?
                while reconnectAttempts < backoffDelays.count {
                    let delay = backoffDelays[reconnectAttempts]
                    reconnectAttempts += 1
                    phase = .reconnecting
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled,
                          sessionGeneration == generation,
                          !serverErrorReceived,
                          phase == .reconnecting,
                          let api = activeAPI else { return }
                    let path = "/voice/live?voice=" + voiceName.queryEncoded + "&session=" + sessionId.queryEncoded + "&resume=1"
                    if let newWS = try? api.socket(path) {
                        newWS.resume()
                        reconnectedSocket = newWS
                        break
                    }
                }

                if let newWS = reconnectedSocket {
                    socket = newWS
                    continue
                }

                self.error = "实时语音连接已断开——点重试即可恢复通话。"
                self.phase = .failed
                stopAudioEngine()
                return
            }
        }
    }

    private func appendOrUpdateLine(isUser: Bool, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isUser {
            if let lastIdx = lines.indices.last, lines[lastIdx].isUser {
                lines[lastIdx].text = text
            } else {
                lines.append(LiveVoiceLine(id: nextLineId, isUser: true, text: text))
                nextLineId += 1
            }
        } else {
            if !forceNewAssistantLine, let lastIdx = lines.indices.last, !lines[lastIdx].isUser {
                lines[lastIdx].text = text
            } else {
                forceNewAssistantLine = false
                lines.append(LiveVoiceLine(id: nextLineId, isUser: false, text: text))
                nextLineId += 1
            }
        }
        if lines.count > 30 {
            lines.removeFirst(lines.count - 30)
        }
    }

    private func handleControlEvent(_ event: JSON) {
        // Generation Epoch Fencing: drop stale events tagged with older epochs
        if !event["epoch"].isNull {
            let evEpoch = event["epoch"].int
            if evEpoch < currentEpoch {
                return
            }
        }

        switch event["type"].string {
        case "ready":
            if !event["epoch"].isNull {
                currentEpoch = max(1, event["epoch"].int)
            }
            let srvSession = event["session_id"].string
            if !srvSession.isEmpty {
                sessionId = srvSession
            }
            reconnectAttempts = 0
            error = ""
            phase = .listening
            Haptics.sent()
        case "transcript":
            let role = event["role"].string
            let txt = event["text"].string
            let finished = event["finished"].bool
            if role == "user" {
                if !txt.isEmpty {
                    userTranscript = txt
                    appendOrUpdateLine(isUser: true, text: txt)
                    if phase == .listening && finished {
                        phase = .thinking
                    }
                }
            } else {
                if !txt.isEmpty {
                    assistantTranscript = txt
                    appendOrUpdateLine(isUser: false, text: txt)
                }
            }
        case "user_transcript":
            let txt = event["text"].string
            if !txt.isEmpty {
                userTranscript = txt
                appendOrUpdateLine(isUser: true, text: txt)
                if phase == .listening && event["finished"].bool {
                    phase = .thinking
                }
            }
        case "assistant_transcript":
            let txt = event["text"].string
            if !txt.isEmpty {
                assistantTranscript = txt
                appendOrUpdateLine(isUser: false, text: txt)
            }
        case "emotion":
            let rawState = event["state"].string
            let state = rawState.isEmpty
                ? (event["primary"].string.isEmpty ? event["user_emotion"].string : event["primary"].string)
                : rawState
            let energy = !event["energy"].isNull ? event["energy"].double : (!event["confidence"].isNull ? event["confidence"].double : 0.5)
            if !state.isEmpty {
                dominantEmotion = state
            }
            emotionEnergy = max(0.0, min(1.0, energy))
        case "tool_call":
            let status = event["status"].string
            let title = event["title"].string
            activeToolTitle = title
            if status == "running" || status == "executing" {
                phase = .thinking
                Haptics.selection()
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.2))
                    if self?.activeToolTitle == title {
                        self?.activeToolTitle = ""
                    }
                }
            }
        case "interrupted":
            // When interrupted arrives, immediately discard scheduled buffers, restore volume=1, and increment local epoch
            if !event["epoch"].isNull {
                let ep = event["epoch"].int
                currentEpoch = max(currentEpoch + 1, ep)
            } else {
                currentEpoch += 1
            }
            resetDuckingImmediately()
            interruptPlayback(sendInterruptSignal: false)
        case "turn_complete":
            flushPlayback(generation: sessionGeneration)
            turnsCount += 1
            forceNewAssistantLine = true
            if pendingBuffers == 0 && rxAccumulator.isEmpty {
                speakingHoldTask?.cancel()
                speakingHoldTask = nil
                assistantLevel = 0
                phase = .listening
            }
            onTurnComplete?()
        case "error":
            serverErrorReceived = true
            let msg = event["message"].string
            error = msg.isEmpty ? "实时语音出现异常" : msg
            phase = .failed
            stopAudioEngine()
        default:
            break
        }
    }

    private func enqueuePlayback(_ pcm16Data: Data, frameEpoch: Int, generation: Int) {
        guard frameEpoch >= currentEpoch else { return }
        guard !pcm16Data.isEmpty else { return }

        rxAccumulator.append(pcm16Data)

        // 24kHz 16-bit mono PCM = 48 bytes/ms: first block 60ms (2880B), subsequent blocks 60–120ms (2880..5760B)
        let minBlockBytes = 2880
        let maxBlockBytes = 5760

        while rxAccumulator.count >= minBlockBytes {
            guard frameEpoch >= currentEpoch else {
                rxAccumulator.removeAll(keepingCapacity: true)
                return
            }
            let blockBytes = pendingBuffers == 0
                ? minBlockBytes
                : (min(maxBlockBytes, rxAccumulator.count) & ~1)
            let block = rxAccumulator.prefix(blockBytes)
            rxAccumulator.removeFirst(blockBytes)
            schedulePCMBlock(Data(block), frameEpoch: frameEpoch, generation: generation)
        }
    }

    private func flushPlayback(generation: Int) {
        guard !rxAccumulator.isEmpty else { return }
        let remaining = rxAccumulator
        rxAccumulator.removeAll(keepingCapacity: true)
        schedulePCMBlock(remaining, frameEpoch: currentEpoch, generation: generation)
    }

    private func schedulePCMBlock(_ pcm16Data: Data, frameEpoch: Int, generation: Int) {
        guard frameEpoch >= currentEpoch else { return }
        let sampleCount = pcm16Data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        pcm16Data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                dst[i] = Float(Int16(littleEndian: base[i])) / 32768.0
            }
        }

        speakingHoldTask?.cancel()
        speakingHoldTask = nil
        if phase != .speaking {
            phase = .speaking
        }
        pendingBuffers += 1
        if !player.isPlaying && !isAudioInterrupted {
            player.play()
        }
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                guard frameEpoch >= self.currentEpoch else {
                    self.pendingBuffers = 0
                    return
                }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 && self.rxAccumulator.isEmpty && self.phase == .speaking {
                    self.scheduleSpeakingHoldFallback(generation: generation, epoch: frameEpoch)
                }
            }
        }
    }

    private func scheduleSpeakingHoldFallback(generation: Int, epoch: Int) {
        speakingHoldTask?.cancel()
        speakingHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  let self,
                  self.sessionGeneration == generation,
                  epoch >= self.currentEpoch,
                  self.pendingBuffers == 0,
                  self.rxAccumulator.isEmpty,
                  self.phase == .speaking else { return }
            self.assistantLevel = 0
            self.phase = .listening
        }
    }

    private func updateUserLevel(_ value: Double) {
        guard !muted && !isAudioInterrupted else {
            userLevel = 0
            return
        }
        userLevel += (value - userLevel) * (value > userLevel ? 0.55 : 0.18)
    }

    private func updateAssistantLevel(_ value: Double) {
        guard !isAudioInterrupted && (phase == .speaking || pendingBuffers > 0) else {
            assistantLevel += (0 - assistantLevel) * 0.22
            if assistantLevel < 0.005 {
                assistantLevel = 0
            }
            return
        }
        assistantLevel += (value - assistantLevel) * (value > assistantLevel ? 0.62 : 0.20)
    }

    private func startTimer(generation: Int) {
        let started = Date()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.sessionGeneration == generation, self.phase != .idle, self.phase != .failed else { return }
                self.seconds = Int(Date().timeIntervalSince(started))
            }
        }
    }
}
