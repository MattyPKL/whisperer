import Foundation
import CWhisper

/// The weekly "is there a better voice model?" check. Reads the whisper.cpp model list on Hugging Face and
/// the latest whisper.cpp release on GitHub; anything newer than what Whisperer knows is reported, never
/// installed on its own (a new model gets benchmarked on real recordings before it becomes the default).
public struct ModelWatchReport: Codable, Equatable, Sendable {
    public var lastChecked: Date
    /// Model ids on Hugging Face whose family Whisperer has never seen, e.g. "large-v4".
    public var newModels: [String]
    public var latestEngine: String?
    public var bundledEngine: String
    public var error: String?

    public var engineUpdate: Bool {
        guard let latest = latestEngine else { return false }
        return ModelWatch.versionLess(bundledEngine, latest)
    }
}

public enum ModelWatch {
    public static let interval: TimeInterval = 7 * 24 * 3600
    static let modelsAPI = URL(string: "https://huggingface.co/api/models/ggerganov/whisper.cpp")!
    static let releaseAPI = URL(string: "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest")!

    public static var engineVersion: String { String(cString: whisper_version()) }

    public static func isDue(_ last: ModelWatchReport?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last.lastChecked) >= interval || last.error != nil && now.timeIntervalSince(last.lastChecked) >= 6 * 3600
    }

    /// "ggml-large-v3-turbo-q8_0.bin" -> "large-v3-turbo". Quantised copies and language-only variants of a
    /// known model are the same family and never count as new.
    public static func family(_ file: String) -> String? {
        guard file.hasPrefix("ggml-"), file.hasSuffix(".bin") else { return nil }
        var id = String(file.dropFirst(5).dropLast(4))
        if id.contains("encoder") || id.contains("tdrz") || id.contains("silero") { return nil }
        if let r = id.range(of: #"-q\d(_[0-9A-Za-z]+)*$"#, options: .regularExpression) { id.removeSubrange(r) }
        if id.hasSuffix(".en") { id.removeLast(3) }
        return id
    }

    public static func newModels(fromHuggingFace json: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let siblings = obj["siblings"] as? [[String: Any]] else { return [] }
        let known = Set(ModelCatalog.all.compactMap { family("ggml-\($0.id).bin") } + ["large-v1", "large-v2"])
        let fams = siblings.compactMap { $0["rfilename"] as? String }.compactMap(family)
        return Array(Set(fams).subtracting(known)).sorted()
    }

    /// Numeric compare of "1.9.4" style versions ("v" prefix allowed).
    public static func versionLess(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func load(_ paths: Paths) -> ModelWatchReport? {
        guard let d = try? Data(contentsOf: paths.modelWatchFile) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ModelWatchReport.self, from: d)
    }

    public static func check(_ paths: Paths) async -> ModelWatchReport {
        var report = ModelWatchReport(lastChecked: Date(), newModels: [], latestEngine: nil, bundledEngine: engineVersion)
        do {
            let (d, r) = try await URLSession.shared.data(from: modelsAPI)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            report.newModels = newModels(fromHuggingFace: d)
        } catch { report.error = "Model list: \(error.localizedDescription)" }
        if let (d, _) = try? await URLSession.shared.data(from: releaseAPI),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let tag = obj["tag_name"] as? String {
            report.latestEngine = tag
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(report).write(to: paths.modelWatchFile, options: .atomic)
        return report
    }
}
