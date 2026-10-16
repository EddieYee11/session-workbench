import Foundation

/// One frame from the backend's `/voice/stream/{capture_id}` relay.
///
/// The relay forwards the ASR service's JSON verbatim, so the wire shapes live here
/// where `Scripts/check-core.sh` can exercise every branch without a device.
public enum VoiceStreamEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case failure(String)

    public var text: String {
        switch self {
        case .partial(let text), .final(let text): return text
        case .failure: return ""
        }
    }
}

public enum VoiceStream {
    /// The only text frame the client sends; audio travels as binary frames.
    public static let end = #"{"type":"end"}"#

    public static func event(from data: Data) -> VoiceStreamEvent? {
        guard let value = try? JSON.decode(data) else { return nil }
        switch value["type"].string {
        case "partial": return .partial(value["text"].string)
        case "final": return .final(value["text"].string)
        case "error":
            let message = value["message"].string
            return .failure(message.isEmpty ? "语音识别中断" : message)
        default: return nil
        }
    }

    /// 16 kHz mono signed 16-bit little-endian, the only format the ASR service decodes.
    /// Microphone samples are Float32 in [-1, 1]; anything outside is clamped, not wrapped.
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
