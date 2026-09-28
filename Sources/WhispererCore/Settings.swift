import Foundation

/// Where everything lives. Mirrors Superwhisper's `~/superwhisper` layout under `~/Whisperer`.
public struct Paths: Sendable {
    public var root: URL
    public var superwhisperRoot: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Whisperer"),
                superwhisperRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("superwhisper")) {
        self.root = root; self.superwhisperRoot = superwhisperRoot
    }
    public var recordings: URL { root.appendingPathComponent("recordings") }
    public var models: URL { root.appendingPathComponent("models") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var superwhisperRecordings: URL { superwhisperRoot.appendingPathComponent("recordings") }
    public var superwhisperSettings: URL { superwhisperRoot.appendingPathComponent("settings/settings.json") }
    public var superwhisperModes: URL { superwhisperRoot.appendingPathComponent("modes") }
    public func modelFile(_ id: String) -> URL { models.appendingPathComponent("ggml-\(id).bin") }
    /// Recordings being captured right now, streamed to disk so a crash or a failed transcription never
    /// loses the audio. Anything still here at launch is recovered into history.
    public var inProgress: URL { root.appendingPathComponent("in-progress") }
    public var modelWatchFile: URL { root.appendingPathComponent("model-watch.json") }
    public static let vadFileName = "ggml-silero-v5.1.2.bin"
    /// The app bundle carries the VAD model; command-line builds use ~/Whisperer/models.
    public var vadModel: URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(Paths.vadFileName), models.appendingPathComponent(Paths.vadFileName)]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum TriggerKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightOption, leftOption, eitherOption, rightCommand, fn
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .eitherOption: return "Either Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .fn: return "Fn / Globe"
        }
    }
    /// Hardware key codes this trigger answers to.
    public var keyCodes: Set<Int64> {
        switch self {
        case .rightOption: return [61]
        case .leftOption: return [58]
        case .eitherOption: return [58, 61]
        case .rightCommand: return [54]
        case .fn: return [63]
        }
    }
}

public struct Mode: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var voiceModelID: String
    public var language: String          // "en", "auto", or any whisper code
    public var autocapitalize: Bool
    public var translateToEnglish: Bool
    public var activationApps: [String]  // bundle IDs that auto-select this mode
    public var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, voiceModelID, language, autocapitalize, translateToEnglish, activationApps }

    /// Every field optional on read: one hand-edited or older mode must never sink the whole settings file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mode"
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? SuperwhisperImport.slug(name)
        self.name = name
        voiceModelID = try c.decodeIfPresent(String.self, forKey: .voiceModelID) ?? ModelCatalog.best
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en,pl"
        autocapitalize = try c.decodeIfPresent(Bool.self, forKey: .autocapitalize) ?? true
        translateToEnglish = try c.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
        activationApps = try c.decodeIfPresent([String].self, forKey: .activationApps) ?? []
    }

    public init(key: String, name: String, voiceModelID: String, language: String = "en,pl",
                autocapitalize: Bool = true, translateToEnglish: Bool = false, activationApps: [String] = []) {
        self.key = key; self.name = name; self.voiceModelID = voiceModelID; self.language = language
        self.autocapitalize = autocapitalize; self.translateToEnglish = translateToEnglish; self.activationApps = activationApps
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var triggerKey: TriggerKey = .rightOption
    public var holdThreshold: Double = 0.35
    public var recordingWindow: String = "classic"   // classic | mini | none
    public var pasteResult: Bool = true
    public var restoreClipboard: Bool = true
    public var keepModelWarmMinutes: Double = 1
    public var soundEffects: String = "classic"      // classic | simple | off
    public var soundVolume: Double = 1
    public var showInDock: Bool = true
    public var showSuperwhisperHistory: Bool = true
    public var beamSearch: Bool = false
    public var activeModeKey: String = "voice-to-text"
    public var modes: [Mode] = [Mode(key: "voice-to-text", name: "Voice to text", voiceModelID: ModelCatalog.best)]
    public var vocabulary: [String] = []
    public var replacements: [Replacement] = []
    public var starredModelIDs: [String] = [ModelCatalog.best]
    public var importedFromSuperwhisper: Bool = false
    /// Longest single recording. At the limit the recording stops and transcribes (never discarded).
    public var maxRecordingMinutes: Double = 30
    /// Bumped by `SettingsMigration`. Stored files without it are version 1.
    public var settingsVersion: Int = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case triggerKey, holdThreshold, recordingWindow, pasteResult, restoreClipboard, keepModelWarmMinutes,
             soundEffects, soundVolume, showInDock, showSuperwhisperHistory, beamSearch, activeModeKey, modes,
             vocabulary, replacements, starredModelIDs, importedFromSuperwhisper, maxRecordingMinutes, settingsVersion
    }

    /// Field by field: one bad or unknown value (a future trigger key, a number stored as text) falls back
    /// alone instead of resetting everything the user built.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        triggerKey = v(.triggerKey, d.triggerKey)
        holdThreshold = v(.holdThreshold, d.holdThreshold)
        recordingWindow = v(.recordingWindow, d.recordingWindow)
        pasteResult = v(.pasteResult, d.pasteResult)
        restoreClipboard = v(.restoreClipboard, d.restoreClipboard)
        keepModelWarmMinutes = v(.keepModelWarmMinutes, d.keepModelWarmMinutes)
        soundEffects = v(.soundEffects, d.soundEffects)
        soundVolume = v(.soundVolume, d.soundVolume)
        showInDock = v(.showInDock, d.showInDock)
        showSuperwhisperHistory = v(.showSuperwhisperHistory, d.showSuperwhisperHistory)
        beamSearch = v(.beamSearch, d.beamSearch)
        activeModeKey = v(.activeModeKey, d.activeModeKey)
        let loadedModes: [Mode] = v(.modes, d.modes)
        modes = loadedModes.isEmpty ? d.modes : loadedModes
        vocabulary = v(.vocabulary, d.vocabulary)
        replacements = v(.replacements, d.replacements)
        starredModelIDs = v(.starredModelIDs, d.starredModelIDs)
        importedFromSuperwhisper = v(.importedFromSuperwhisper, d.importedFromSuperwhisper)
        maxRecordingMinutes = min(240, max(1, v(.maxRecordingMinutes, d.maxRecordingMinutes)))   // a hand edit can't overflow
        settingsVersion = v(.settingsVersion, d.settingsVersion)
    }

    public var activeMode: Mode {
        modes.first(where: { $0.key == activeModeKey }) ?? modes.first
            ?? Mode(key: "voice-to-text", name: "Voice to text", voiceModelID: ModelCatalog.best)
    }

    /// Mode whose activation list names this app, else the active one.
    public func mode(forApp bundleID: String?) -> Mode {
        if let b = bundleID, let m = modes.first(where: { $0.activationApps.contains(b) }) { return m }
        return activeMode
    }
}

/// One-way upgrades of a stored settings file. Each step runs once, then `settingsVersion` records it.
public enum SettingsMigration {
    public static let current = 2

    /// v2 (2026-09-28): modes on Whisper Medium move to the best model (when it is downloaded), and
    /// English-only modes also listen for Polish.
    public static func apply(_ s: inout AppSettings, isInstalled: (String) -> Bool) {
        guard s.settingsVersion < current else { return }
        if s.settingsVersion < 2 {
            let best = ModelCatalog.best
            for i in s.modes.indices {
                if s.modes[i].voiceModelID == "medium", isInstalled(best) { s.modes[i].voiceModelID = best }
                if s.modes[i].language.lowercased() == "en", !s.modes[i].translateToEnglish { s.modes[i].language = "en,pl" }
            }
            if isInstalled(best), !s.starredModelIDs.contains(best) { s.starredModelIDs.insert(best, at: 0) }
        }
        s.settingsVersion = current
    }
}

/// JSON load that survives missing keys: stored values are merged over the defaults.
public enum LenientJSON {
    /// Like `load`, but also says whether a file that exists could not be read (so the caller can back it
    /// up instead of overwriting it with defaults).
    public static func loadChecked<T: Codable>(_ url: URL, defaults: T) -> (value: T, unreadable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (defaults, false) }
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { _, new in new }),
              let value = try? JSONDecoder().decode(T.self, from: merged) else { return (defaults, true) }
        return (value, false)
    }

    public static func load<T: Codable>(_ url: URL, defaults: T) -> T {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any]
        else { return defaults }
        let merged = base.merging(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let value = try? JSONDecoder().decode(T.self, from: mergedData) else { return defaults }
        return value
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url, options: .atomic)
    }
}

/// One-time, read-only import of Superwhisper's vocabulary, replacements and voice modes.
public enum SuperwhisperImport {
    public static func apply(_ paths: Paths, to settings: inout AppSettings) {
        if let data = try? Data(contentsOf: paths.superwhisperSettings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for w in obj["vocabulary"] as? [String] ?? [] where !settings.vocabulary.contains(w) {
                settings.vocabulary.append(w)
            }
            for r in obj["replacements"] as? [[String: Any]] ?? [] {
                guard let o = r["original"] as? String, let w = r["with"] as? String,
                      !settings.replacements.contains(where: { $0.original.lowercased() == o.lowercased() }) else { continue }
                settings.replacements.append(Replacement(id: r["id"] as? String ?? UUID().uuidString, original: o, with: w))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.superwhisperModes, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (m["type"] as? String) == "voice", let name = m["name"] as? String else { continue }
            let key = slug(name)
            guard !settings.modes.contains(where: { $0.key == key || $0.name.lowercased() == name.lowercased() }) else { continue }
            let voice = m["voiceModelID"] as? String ?? ""
            let model = ModelCatalog.find(voice) != nil ? voice : ModelCatalog.best   // their cloud ids fall back to the best local model
            settings.modes.append(Mode(key: key, name: name, voiceModelID: model,
                                       language: m["language"] as? String ?? "en",
                                       autocapitalize: m["autocapitalizeInsert"] as? Bool ?? true,
                                       translateToEnglish: m["translateToEnglish"] as? Bool ?? false,
                                       activationApps: m["activationApps"] as? [String] ?? []))
        }
        settings.importedFromSuperwhisper = true
    }

    public static func slug(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return parts.isEmpty ? UUID().uuidString : parts.joined(separator: "-")
    }
}
