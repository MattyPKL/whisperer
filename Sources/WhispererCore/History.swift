import Foundation

public struct Recording: Identifiable, Equatable, Hashable, Sendable {
    public enum Source: String, Sendable { case whisperer, superwhisper }
    public var id: String { "\(source.rawValue)/\(folder.lastPathComponent)" }
    public let folder: URL
    public let source: Source
    public let date: Date
    public var result: String
    public var rawResult: String
    public var durationMs: Int
    public var processingMs: Int
    public var modelName: String
    public var modeName: String
    public var appName: String
    public var appBundleID: String
    public var noVoice: Bool
    /// Stored at parse time: stats sum it over thousands of rows on every screen refresh.
    public let words: Int

    public init(folder: URL, source: Source, date: Date, result: String, rawResult: String, durationMs: Int,
                processingMs: Int, modelName: String, modeName: String, appName: String, appBundleID: String, noVoice: Bool) {
        self.folder = folder; self.source = source; self.date = date; self.result = result; self.rawResult = rawResult
        self.durationMs = durationMs; self.processingMs = processingMs; self.modelName = modelName; self.modeName = modeName
        self.appName = appName; self.appBundleID = appBundleID; self.noVoice = noVoice
        self.words = TextProcessing.wordCount(result)
    }

    public var audioURL: URL { folder.appendingPathComponent("output.wav") }
    public var metaURL: URL { folder.appendingPathComponent("meta.json") }
    public var isEditable: Bool { source == .whisperer }
}

/// Reads recordings from `recordings/<epoch>/meta.json`, ours and Superwhisper's (same layout).
/// Superwhisper's folder is only ever read.
public enum HistoryStore {
    /// Superwhisper writes `datetime` in UTC with no zone marker (checked: every one of 2,339 files equals its
    /// folder's epoch in UTC). We write ours the same way.
    static let utcStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public static func load(from dir: URL, source: Recording.Source) -> [Recording] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { parse(folder: $0, source: source) }
    }

    public static func parse(folder: URL, source: Recording.Source) -> Recording? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Folder names are epoch seconds in both apps: the most reliable clock we have.
        let date = Double(folder.lastPathComponent).map { Date(timeIntervalSince1970: $0) }
            ?? (m["datetime"] as? String).flatMap { utcStamp.date(from: String($0.prefix(19))) }
            ?? Date.distantPast
        func int(_ k: String) -> Int { (m[k] as? NSNumber)?.intValue ?? 0 }
        func str(_ k: String) -> String { m[k] as? String ?? "" }
        // Message modes paste `llmResult`; that is the text the user actually got.
        let llm = str("llmResult").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = llm.isEmpty ? str("result") : llm
        let context = (m["promptContext"] as? [String: Any])?["applicationContext"] as? [String: Any]
        let appName = str("appName").isEmpty ? (context?["name"] as? String ?? "") : str("appName")
        return Recording(folder: folder, source: source, date: date, result: result,
                         rawResult: str("rawResult"), durationMs: int("duration"), processingMs: int("processingTime"),
                         modelName: str("modelName"), modeName: str("modeName"), appName: appName,
                         appBundleID: str("appBundleID"),
                         noVoice: (m["noVoice"] as? Bool) ?? result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public static func loadAll(paths: Paths, includeSuperwhisper: Bool) -> [Recording] {
        var all = load(from: paths.recordings, source: .whisperer)
        if includeSuperwhisper { all += load(from: paths.superwhisperRecordings, source: .superwhisper) }
        return all.sorted { $0.date > $1.date }
    }

    /// Writes a new recording folder. The folder name is the epoch second, bumped if taken.
    @discardableResult
    public static func save(paths: Paths, samples: [Float], date: Date, meta: [String: Any]) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        var stamp = Int(date.timeIntervalSince1970)
        var folder = paths.recordings.appendingPathComponent(String(stamp))
        while fm.fileExists(atPath: folder.path) { stamp += 1; folder = paths.recordings.appendingPathComponent(String(stamp)) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try WAV.write(samples, to: folder.appendingPathComponent("output.wav"))
        var m = meta
        m["datetime"] = utcStamp.string(from: date)
        m["source"] = "whisperer"
        let data = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        return folder
    }

    /// Rewrites fields in one of OUR recordings (re-transcribe). Refuses Superwhisper's.
    public static func update(_ rec: Recording, fields: [String: Any]) throws {
        guard rec.isEditable else { throw CocoaError(.fileWriteNoPermission) }
        let data = try Data(contentsOf: rec.metaURL)
        var m = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        for (k, v) in fields { m[k] = v }
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: rec.metaURL, options: .atomic)
    }

    public static func search(_ list: [Recording], _ query: String) -> [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.result.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public struct UsageStats: Equatable {
    public var words: Int
    public var averageWPM: Int
    public var appsUsed: Int
    public var hoursSaved: Double
    public var recordings: Int

    /// Same model as Superwhisper's Home card: time saved = typing the words at 40 wpm minus speaking them.
    public static func compute(_ list: [Recording], typingWPM: Double = 40, since: Date? = nil) -> UsageStats {
        let use = list.filter { !$0.noVoice && (since == nil || $0.date >= since!) }
        let words = use.reduce(0) { $0 + $1.words }
        let spokenMin = use.reduce(0.0) { $0 + Double($1.durationMs) / 60_000 }
        let wpm = spokenMin > 0 ? Int((Double(words) / spokenMin).rounded()) : 0
        let apps = Set(use.map { $0.appBundleID.isEmpty ? $0.appName : $0.appBundleID }.filter { !$0.isEmpty }).count
        let saved = max(0, Double(words) / typingWPM - spokenMin) / 60
        return UsageStats(words: words, averageWPM: wpm, appsUsed: apps, hoursSaved: saved, recordings: use.count)
    }
}
