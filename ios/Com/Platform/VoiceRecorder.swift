import Foundation
import AVFoundation
import Observation
import ComCore

@MainActor @Observable final class VoiceRecorder {
    enum Phase: String { case idle, recording, recorded, transcribing, ready, failed }
    var phase: Phase = .idle
    var level: Double = 0
    var levels: [Double] = []
    var seconds = 0
    var transcript = ""
    var error = ""
    var captureID = ""
    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var file: URL?
    private var interruption: NSObjectProtocol?
    private var starting = false

    init() {
        if let saved = try? SecureVault.load(JSON.self, name: "voice-capture"), !saved["id"].string.isEmpty {
            captureID = saved["id"].string
            let url = SecureVault.directory.appendingPathComponent(captureID + ".m4a")
            if FileManager.default.fileExists(atPath: url.path) {
                file = url; phase = .recorded; seconds = saved["seconds"].int; error = "上次录音已保留，尚未发送"
            }
        }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.phase == .recording { self?.finishRecording() } }
        }
    }
    var hasCapture: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    func start() async {
        guard !starting && phase != .recording && phase != .transcribing else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else { error = "请在系统设置中允许 Com 使用麦克风"; phase = .failed; return }
        do {
            cancel()
            captureID = UUID().uuidString.lowercased()
            file = SecureVault.directory.appendingPathComponent(captureID + ".m4a")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            recorder = try AVAudioRecorder(url: file!, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000.0,
                                                                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            recorder?.isMeteringEnabled = true
            guard recorder?.record() == true else { throw APIError(status: 0, detail: "录音未启动") }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file!.path)
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try? file?.setResourceValues(resources)
            phase = .recording; seconds = 0; levels = []; error = ""; transcript = ""; Haptics.sent()
            saveCapture()
            let started = Date()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, !Task.isCancelled, self.phase == .recording else { return }
                    self.recorder?.updateMeters()
                    let raw = pow(10, Double(self.recorder?.averagePower(forChannel: 0) ?? -80) / 20)
                    let normalized = min(1, max(0, raw * 4))
                    self.level += (normalized - self.level) * (normalized > self.level ? 0.6 : 0.15)
                    self.levels.append(self.level); if self.levels.count > 48 { self.levels.removeFirst() }
                    let elapsed = Int(Date().timeIntervalSince(started))
                    if elapsed != self.seconds { self.seconds = elapsed; self.saveCapture() }
                    if elapsed >= 60 { self.finishRecording(); self.error = "已达到 60 秒，录音已暂停。转写后确认发送。"; return }
                }
            }
        } catch { self.error = error.localizedDescription; phase = .failed }
    }
    func finishRecording() {
        guard phase == .recording else { return }
        timer?.cancel(); timer = nil; recorder?.stop(); recorder = nil; level = 0; phase = .recorded
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        saveCapture(); Haptics.selection()
    }
    func transcribe(using api: APIClient) async {
        if phase == .recording { finishRecording() }
        guard let file, phase == .recorded || phase == .failed else { return }
        phase = .transcribing; error = ""
        let id = captureID
        do {
            let data = try Data(contentsOf: file)
            let result = try await api.transcribe(id: id, audio: data)
            guard phase == .transcribing, captureID == id else { return }
            transcript = result["text"].string
            guard !transcript.isEmpty else { throw APIError(status: 422, detail: "没有听清，录音已保留") }
            phase = .ready
        } catch { if phase == .transcribing && captureID == id { self.error = error.localizedDescription; phase = .failed } }
    }
    func cancel() {
        timer?.cancel(); timer = nil; recorder?.stop(); recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; captureID = ""; phase = .idle; level = 0; levels = []; transcript = ""; error = ""; seconds = 0
        try? SecureVault.save(JSON.null, name: "voice-capture")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func saveCapture() {
        try? SecureVault.save(JSON.object(["id": .string(captureID), "seconds": .number(Double(seconds))]), name: "voice-capture")
    }
}
