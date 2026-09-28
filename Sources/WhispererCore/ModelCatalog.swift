import Foundation

public struct VoiceModel: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // whisper.cpp file id: ggml-<id>.bin
    public let name: String
    public let bytes: Int64
    public let englishOnly: Bool
    public let speed: Int          // 1...5, higher = faster
    public let accuracy: Int       // 1...5
    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")! }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

public enum ModelCatalog {
    /// The default for new modes and the upgrade target. Large v3 Turbo: large-v3 accuracy (Polish
    /// included) at about 30x real time here with VAD on. Re-judged weekly by `ModelWatch`.
    public static let best = "large-v3-turbo"

    public static let all: [VoiceModel] = [
        VoiceModel(id: "large-v3-turbo", name: "Whisper Large v3 Turbo", bytes: 1_624_555_275, englishOnly: false, speed: 4, accuracy: 5),
        VoiceModel(id: "large-v3-turbo-q5_0", name: "Whisper Large v3 Turbo (compact)", bytes: 574_041_195, englishOnly: false, speed: 4, accuracy: 4),
        VoiceModel(id: "large-v3", name: "Whisper Large v3", bytes: 3_095_033_483, englishOnly: false, speed: 2, accuracy: 5),
        VoiceModel(id: "medium", name: "Whisper Medium", bytes: 1_533_763_059, englishOnly: false, speed: 3, accuracy: 4),
        VoiceModel(id: "medium.en", name: "Whisper Medium (English)", bytes: 1_533_774_781, englishOnly: true, speed: 3, accuracy: 4),
        VoiceModel(id: "small", name: "Whisper Small", bytes: 487_601_967, englishOnly: false, speed: 4, accuracy: 3),
        VoiceModel(id: "small.en", name: "Whisper Small (English)", bytes: 487_614_201, englishOnly: true, speed: 4, accuracy: 3),
        VoiceModel(id: "base", name: "Whisper Base", bytes: 147_951_465, englishOnly: false, speed: 5, accuracy: 2),
        VoiceModel(id: "base.en", name: "Whisper Base (English)", bytes: 147_964_211, englishOnly: true, speed: 5, accuracy: 2),
        VoiceModel(id: "tiny", name: "Whisper Tiny", bytes: 77_691_713, englishOnly: false, speed: 5, accuracy: 1),
        VoiceModel(id: "tiny.en", name: "Whisper Tiny (English)", bytes: 77_704_715, englishOnly: true, speed: 5, accuracy: 1),
    ]

    public static func find(_ id: String) -> VoiceModel? { all.first { $0.id == id } }

    /// A model counts as installed only when the file is complete (size within 1% of the catalog).
    public static func isInstalled(_ m: VoiceModel, paths: Paths) -> Bool {
        let url = paths.modelFile(m.id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
        return abs(size - m.bytes) <= m.bytes / 100
    }
}
