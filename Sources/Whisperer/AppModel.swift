import AppKit
import AVFoundation
import ServiceManagement
import WhispererCore

enum Route: String, CaseIterable, Identifiable {
    case home, modes, vocabulary, configuration, sound, models, history
    var id: String { rawValue }
}

enum Phase: Equatable {
    case idle
    case listening(TapDetector.Style)
    case transcribing
    case notice(String)
}

/// Fast-changing recording state, kept apart so audio levels only redraw the pill, never the main window.
///
/// Levels arrive as RMS per 20 ms of audio, in bursts (macOS hands the mic tap ~100 ms at a time). The
/// waveform plays them back at their real rate on every display frame, so it moves continuously instead of
/// jumping in 100 ms steps. Loudness is judged in decibels with a ceiling that follows the speaker: Matty's
/// speech sits at RMS 0.01-0.05, which a linear scale drew 2-9 px tall out of 30.
@MainActor
final class LiveMeter: ObservableObject {
    @Published var startedAt = Date()

    static let barCount = 48
    /// Set by `--render-pill`: frames are advanced by the renderer, not the display clock.
    var externallyDriven = false
    private(set) var clock: TimeInterval = 0
    // Read by the waveform canvas every frame; deliberately not @Published.
    private(set) var bars = [Float](repeating: 0, count: LiveMeter.barCount)   // newest first, 0...1
    private(set) var level: Float = 0                                         // smoothed, 0...1
    private var pending: [Float] = []
    private var due: Double = 0
    private var target: Float = 0
    private var barPeak: Float = 0
    private var lastFrame: TimeInterval = 0
    private var sinceBar: TimeInterval = 0
    private var ceilingDB: Float = LiveMeter.minCeilingDB

    static let floorDB: Float = -54        // Matty's room noise peaks at -54 dBFS (RMS 0.002)
    static let minCeilingDB: Float = -26   // Matty's speech (-31 dB) draws ~80% tall, leaving room to move
    static let windowsPerSecond = 50.0

    func reset() {
        bars = [Float](repeating: 0, count: Self.barCount)
        level = 0; target = 0; barPeak = 0; pending.removeAll(); due = 0; lastFrame = 0; sinceBar = 0
        ceilingDB = Self.minCeilingDB
        startedAt = Date()
    }

    func push(_ windows: [Float]) {
        pending.append(contentsOf: windows)
        if pending.count > 40 { pending.removeFirst(pending.count - 40) }   // never fall behind by more than 0.8 s
    }

    /// 0...1 for one window's RMS, against the speaker-following ceiling.
    func normalized(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        let x = (db - Self.floorDB) / (ceilingDB - Self.floorDB)
        return pow(min(1, max(0, x)), 1.15)
    }

    /// Advances playback to `now`. Called by the waveform once per display frame.
    func advance(to now: TimeInterval) {
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, max(0, now - lastFrame))
        lastFrame = now
        clock = now
        // Loud speakers raise the ceiling at once; it sinks back 4 dB a second.
        ceilingDB = max(Self.minCeilingDB, ceilingDB - Float(4 * dt))
        due += dt * Self.windowsPerSecond
        var take = Int(due)
        if pending.count > 8 { take = max(take, pending.count - 4) }     // catch up after a stall
        take = min(take, pending.count)
        if take > 0 {
            due -= Double(Int(due))
            let slice = pending.prefix(take)
            pending.removeFirst(take)
            if let loud = slice.max() {
                let db = 20 * log10(max(loud, 1e-7))
                if db + 3 > ceilingDB { ceilingDB = min(-3, db + 3) }   // 3 dB headroom: peaks never flatten
                target = normalized(loud)
            }
        } else if pending.isEmpty {
            due = min(due, 1)
            target *= Float(pow(0.5, dt / 0.08))   // no audio arriving: fall away, never freeze mid-bar
        }
        // Fast attack, slower release, frame-rate independent.
        let k: Float = target > level ? 1 - Float(pow(0.02, dt / 0.05)) : 1 - Float(pow(0.02, dt / 0.22))
        level += (target - level) * k
        barPeak = max(barPeak, level)
        sinceBar += dt
        if sinceBar >= 1.0 / 30 {
            sinceBar = min(sinceBar - 1.0 / 30, 1.0 / 30)
            bars.removeLast()
            bars.insert(barPeak, at: 0)
            barPeak = level
        }
        bars[0] = max(bars[0], level)
    }
}

struct StatsBundle {
    var all = UsageStats.compute([]), week = UsageStats.compute([]), today = UsageStats.compute([])
}

/// App-wide state. Everything the screens show lives here.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths = Paths()
    let engine = Transcriber()

    let meter = LiveMeter()
    /// One serial queue for every whisper call (dictation, warm-up, re-transcribe, unload).
    let transcribeQueue = DispatchQueue(label: "whisperer.transcribe", qos: .userInitiated)
    /// Set by the dictation controller: restart the "keep model loaded" timer after any use.
    var engineUsed: () -> Void = {}

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { schedulePersist(); settingsChanged?(oldValue) } }
    }
    @Published var history: [Recording] = [] { didSet { recomputeStats() } }
    @Published private(set) var stats = StatsBundle()
    private var persistWork: DispatchWorkItem?
    private var lastHistoryLoad = Date.distantPast
    @Published var historyLoaded = false
    @Published var phase: Phase = .idle
    @Published var currentModeName = ""
    /// True while the first-ever load of a new build compiles the GPU shaders (about a minute, once).
    @Published var preparingModel = false
    @Published var downloads: [String: Double] = [:]
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkeyActive = false { didSet { if hotkeyActive != oldValue { writeStatus() } } }
    @Published var route: Route = .home
    @Published var lastError: String?
    @Published var installedModelIDs: Set<String> = []
    /// 0...100 while a recording transcribes (shown for long ones).
    @Published var transcribeProgress: Int?
    /// Scale-in state of the recording pill.
    @Published var pillPresented = false
    @Published var modelWatch: ModelWatchReport?
    @Published var checkingModels = false

    var settingsChanged: ((AppSettings) -> Void)?

    private init() {
        let loaded = LenientJSON.loadChecked(paths.settingsFile, defaults: AppSettings())
        var s = loaded.value
        if loaded.unreadable {
            // Keep the unreadable file instead of silently replacing it with defaults.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = paths.root.appendingPathComponent("settings.unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: paths.settingsFile, to: backup)
            lastError = "settings.json could not be read; a copy was kept at \(backup.lastPathComponent)."
        }
        if !s.importedFromSuperwhisper { SuperwhisperImport.apply(paths, to: &s) }
        let p = paths
        SettingsMigration.apply(&s) { id in ModelCatalog.find(id).map { ModelCatalog.isInstalled($0, paths: p) } ?? false }
        settings = s
        modelWatch = ModelWatch.load(paths)
        try? FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
        persist()
        refreshInstalledModels()
        refreshPermissions()
    }

    /// Sliders and toggles fire many changes; write the file once they settle.
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func persistNow() {
        persistWork?.cancel()
        persist()
    }

    private func persist() {
        do { try LenientJSON.save(settings, to: paths.settingsFile) }
        catch { lastError = "Could not save settings: \(error.localizedDescription)" }
    }

    /// Re-reads history when the app comes forward, at most once a minute (Superwhisper may have added some).
    func reloadHistoryIfStale() {
        if Date().timeIntervalSince(lastHistoryLoad) > 60 { reloadHistory() }
    }

    func reloadHistory() {
        lastHistoryLoad = Date()
        let paths = self.paths
        let includeSW = settings.showSuperwhisperHistory
        Task.detached(priority: .userInitiated) {
            let all = HistoryStore.loadAll(paths: paths, includeSuperwhisper: includeSW)
            await MainActor.run {
                self.history = all
                self.historyLoaded = true
            }
        }
    }

    func insert(_ rec: Recording) {
        guard !history.contains(where: { $0.id == rec.id }) else { return }   // a reload may already hold it
        history.insert(rec, at: 0)
    }

    func refreshInstalledModels() {
        installedModelIDs = Set(ModelCatalog.all.filter { ModelCatalog.isInstalled($0, paths: paths) }.map(\.id))
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        // Assign only on change: every assignment redraws the window.
        guard mic != micAuthorized || ax != axTrusted else { return }
        micAuthorized = mic
        axTrusted = ax
        writeStatus()
    }

    /// `~/Whisperer/status.json`: what the running app can do right now (for scripts and diagnostics).
    func writeStatus() {
        var s: [String: Any] = ["microphone": micAuthorized, "accessibility": axTrusted, "hotkeyActive": hotkeyActive,
                                "trigger": settings.triggerKey.rawValue, "pid": ProcessInfo.processInfo.processIdentifier,
                                "updated": ISO8601DateFormatter().string(from: Date())]
        if let w = modelWatch {
            s["newVoiceModels"] = w.newModels
            s["modelWatchChecked"] = ISO8601DateFormatter().string(from: w.lastChecked)
            if w.engineUpdate { s["engineUpdate"] = w.latestEngine ?? "" }
        }
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: paths.root.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refreshPermissions() }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: weekly model check

    /// Runs the model check when a week has passed (or `force`). Called at launch and every few hours.
    func checkForBetterModels(force: Bool = false) {
        guard !checkingModels, force || ModelWatch.isDue(modelWatch) else { return }
        checkingModels = true
        let paths = self.paths
        Task {
            let report = await ModelWatch.check(paths)
            self.modelWatch = report
            self.checkingModels = false
            self.writeStatus()
        }
    }

    /// Newest finished Whisperer transcript, for "Copy last transcript".
    var lastTranscript: String? {
        history.first { $0.source == .whisperer && !$0.result.isEmpty }?.result
    }

    // MARK: modes

    func setActiveMode(_ key: String) { settings.activeModeKey = key }

    func cycleMode() {
        let modes = settings.modes
        guard let i = modes.firstIndex(where: { $0.key == settings.activeModeKey }), modes.count > 1 else { return }
        settings.activeModeKey = modes[(i + 1) % modes.count].key
    }

    func modelPath(for mode: Mode) -> String? {
        if installedModelIDs.contains(mode.voiceModelID) { return paths.modelFile(mode.voiceModelID).path }
        // Mode's model not downloaded: fall back to any installed model, preferring starred ones.
        let order = settings.starredModelIDs + ModelCatalog.all.map(\.id)
        return order.first(where: { installedModelIDs.contains($0) }).map { paths.modelFile($0).path }
    }

    func modelName(forPath path: String) -> String {
        let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        return ModelCatalog.find(id)?.name ?? id
    }

    // MARK: login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { lastError = "Launch at login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    private func recomputeStats() {
        let cal = Calendar.current
        stats = StatsBundle(all: UsageStats.compute(history),
                            week: UsageStats.compute(history, since: cal.date(byAdding: .day, value: -7, to: Date())),
                            today: UsageStats.compute(history, since: cal.startOfDay(for: Date())))
    }
}
