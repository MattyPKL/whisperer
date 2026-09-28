import AppKit
import WhispererCore

/// The recording loop: key -> mic -> pill -> whisper -> paste -> history.
@MainActor
final class DictationController {
    let model: AppModel
    let recorder = Recorder()
    let hotkey = HotkeyMonitor()
    let pill: PillController
    private var detector = TapDetector()
    private var target: NSRunningApplication?
    private var mode: Mode?
    private var holdWork: DispatchWorkItem?
    private var unloadWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var limitWork: DispatchWorkItem?
    /// ~/Whisperer/in-progress/<id>: the recording streamed to disk while it is being made.
    private var spillFolder: URL?
    private var queue: DispatchQueue { model.transcribeQueue }

    init(model: AppModel) {
        self.model = model
        pill = PillController(model: model)
        recorder.onLevels = { [weak self] levels in self?.model.meter.push(levels) }
        recorder.onInterrupted = { [weak self] in
            // The mic went away mid-recording: transcribe what was captured rather than lose it.
            guard let self, case .listening = self.model.phase else { return }
            self.finish()
        }
        hotkey.onTrigger = { [weak self] e in self?.handle(e) }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        hotkey.onModeCycle = { [weak self] in self?.cycleMode() }
        hotkey.isListening = { [weak self] in
            if case .listening = self?.model.phase { return true }
            return false
        }
        model.engineUsed = { [weak self] in self?.scheduleUnload() }
        applySettings()
    }

    func applySettings() {
        hotkey.trigger = model.settings.triggerKey
        detector.holdThreshold = model.settings.holdThreshold
        if case .listening = model.phase { scheduleLimit() }   // "Longest recording" changed mid-recording
    }

    /// Starts the key watcher once Accessibility is granted; retries until it is.
    func ensureHotkey() {
        model.refreshPermissions()
        if model.axTrusted, hotkey.start() {
            model.hotkeyActive = true
            return
        }
        model.hotkeyActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.ensureHotkey() }
    }

    // MARK: key events

    private func handle(_ e: TapDetector.Event) {
        if model.phase == .transcribing, case .triggerDown = e { return }   // one at a time
        guard let action = detector.handle(e) else { return }
        perform(action)
    }

    private func perform(_ action: TapDetector.Action) {
        switch action {
        case .startProvisional:
            beginCapture()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let a = self.detector.handle(.holdTimer(ProcessInfo.processInfo.systemUptime)) else { return }
                self.perform(a)
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.holdThreshold + 0.01, execute: work)
        case .confirm(let style):
            holdWork?.cancel()
            guard recorder.isRunning else { _ = detector.handle(.reset); return }
            model.phase = .listening(style)
            pill.show()
            preload()
            startSpill()
            scheduleLimit()
            Sounds.play(.start, style: model.settings.soundEffects, volume: model.settings.soundVolume)
        case .lock:
            // Double tap: hands-free. Same recording, now only a tap stops it.
            if case .listening = model.phase { model.phase = .listening(.locked) }
        case .abortProvisional:
            holdWork?.cancel()
            if case .listening = model.phase, Date().timeIntervalSince(model.meter.startedAt) > 1.5 {
                // Another key or a click well into push-to-talk is not an Option shortcut (those come within a
                // second): keep what was said and finish normally, never throw a long recording away.
                finish()
                return
            }
            limitWork?.cancel()
            recorder.stop()
            dropSpill()
            if case .listening = model.phase {
                // Push-to-talk turned into a shortcut: drop it quietly.
                model.phase = .idle
                pill.hide()
            }
            scheduleUnload()
        case .stop:
            holdWork?.cancel()
            finish()
        }
    }

    private func beginCapture() {
        target = NSWorkspace.shared.frontmostApplication
        mode = model.settings.mode(forApp: target?.bundleIdentifier)
        model.currentModeName = mode?.name ?? ""
        model.meter.reset()
        do {
            try recorder.start()
        } catch {
            _ = detector.handle(.reset)
            showNotice("Microphone unavailable")
            model.lastError = error.localizedDescription
        }
    }

    /// Load the model while the user is still talking, so the cold load is hidden.
    private func preload() {
        unloadWork?.cancel()
        guard let mode, let path = model.modelPath(for: mode) else { return }
        let engine = model.engine
        queue.async { try? engine.load(path) }
    }

    /// First load of a freshly built binary compiles the Metal shaders (about a minute, once). Pay it at
    /// launch, not on the first dictation, then let the normal warm window unload the model.
    func warmUp() {
        guard let path = model.modelPath(for: model.settings.activeMode) else { return }
        let engine = model.engine
        model.preparingModel = true
        queue.async {
            _ = try? engine.transcribe([Float](repeating: 0, count: 16_000), modelPath: path, options: TranscribeOptions())
            DispatchQueue.main.async { [weak self] in
                self?.model.preparingModel = false
                self?.scheduleUnload()
            }
        }
    }

    // MARK: menu / external control

    func toggle() {
        switch model.phase {
        case .listening: finish()
        case .transcribing: return
        default:
            beginCapture()
            guard recorder.isRunning else { return }
            detector.recordingStartedExternally()
            perform(.confirm(.toggle))
        }
    }

    func cancel() {
        holdWork?.cancel()
        _ = detector.handle(.reset)
        guard recorder.isRunning || model.phase != .idle else { return }
        limitWork?.cancel()
        recorder.stop()
        dropSpill()
        if case .listening = model.phase {
            Sounds.play(.cancel, style: model.settings.soundEffects, volume: model.settings.soundVolume)
        }
        model.phase = .idle
        pill.hide()
        scheduleUnload()
    }

    private func cycleMode() {
        model.cycleMode()
        let active = model.settings.activeMode
        if case .listening = model.phase {
            // Mid-recording: this recording switches too; the pill keeps recording and shows the new name.
            mode = active
            model.currentModeName = active.name
            preload()
        } else if model.phase == .idle || { if case .notice = model.phase { return true }; return false }() {
            showNotice("Mode: \(active.name)")
        }
    }

    // MARK: transcription

    // MARK: safety copy and length limit

    private func startSpill() {
        let id = String(Int(model.meter.startedAt.timeIntervalSince1970 * 1000))
        let folder = model.paths.inProgress.appendingPathComponent(id)
        let session: [String: Any] = ["startedAt": model.meter.startedAt.timeIntervalSince1970, "modeKey": mode?.key ?? "",
                                      "appName": target?.localizedName ?? "", "appBundleID": target?.bundleIdentifier ?? ""]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: session).write(to: folder.appendingPathComponent("session.json"))
        recorder.beginSpill(to: folder.appendingPathComponent("output.wav"))
        spillFolder = folder
    }

    private func dropSpill() {
        if let f = spillFolder { try? FileManager.default.removeItem(at: f) }
        spillFolder = nil
    }

    /// At the limit the recording stops and transcribes like a normal stop; nothing is thrown away.
    private func scheduleLimit() {
        limitWork?.cancel()
        let seconds = max(60, model.settings.maxRecordingMinutes * 60) - Date().timeIntervalSince(model.meter.startedAt)
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .listening = self.model.phase else { return }
            self.finish()
        }
        limitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: work)
    }

    /// Recordings left in ~/Whisperer/in-progress by a crash, a force quit or a failed save: transcribe them
    /// into history (never pasted). Runs once at launch, behind the warm-up on the transcribe queue.
    func recoverInterrupted() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: model.paths.inProgress, includingPropertiesForKeys: nil), !folders.isEmpty else { return }
        let settings = model.settings
        let engine = model.engine
        let paths = model.paths
        var jobs: [(URL, Mode, String?, Date, [String: Any])] = []
        for f in folders where f.hasDirectoryPath {
            let session = (try? Data(contentsOf: f.appendingPathComponent("session.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let mode = settings.modes.first { $0.key == session["modeKey"] as? String } ?? settings.activeMode
            let started = (session["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? ((try? fm.attributesOfItem(atPath: f.path))?[.creationDate] as? Date) ?? Date()
            jobs.append((f, mode, model.modelPath(for: mode), started, session))   // no model: audio still saved
        }
        for f in folders where !f.hasDirectoryPath { try? fm.removeItem(at: f) }    // .DS_Store and the like
        let modelNames = Dictionary(jobs.compactMap { j in j.2.map { ($0, model.modelName(forPath: $0)) } }, uniquingKeysWith: { a, _ in a })
        let vad = paths.vadModel?.path
        queue.async { [weak self] in
            var recovered: [URL] = []
            for (folder, mode, path, started, session) in jobs {
                guard let samples = try? WAV.read(folder.appendingPathComponent("output.wav")), !samples.isEmpty else {
                    try? fm.removeItem(at: folder); continue
                }
                // Quit between the history save and the spill delete: history already has it.
                let already = paths.recordings.appendingPathComponent(String(Int(started.timeIntervalSince1970)))
                if fm.fileExists(atPath: already.appendingPathComponent("meta.json").path) { try? fm.removeItem(at: folder); continue }
                var t: Transcript?
                var text = ""
                if let path, AudioLevel.hasVoice(samples) {
                    var opts = TranscribeOptions()
                    opts.language = mode.language; opts.translate = mode.translateToEnglish
                    opts.prompt = TextProcessing.prompt(vocabulary: settings.vocabulary); opts.vadModelPath = vad
                    t = try? engine.transcribe(AudioLevel.normalize(samples), modelPath: path, options: opts)
                    text = t.map { TextProcessing.finalize($0.text, replacements: settings.replacements, autocapitalize: mode.autocapitalize) } ?? ""
                    if SpeechFilter.isHallucination(text, vocabulary: settings.vocabulary, peakRMS: AudioLevel.peakWindowRMS(samples)) { text = "" }
                }
                let modelKey = path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "") } ?? ""
                var meta: [String: Any] = [
                    "result": text, "rawResult": t?.text ?? "", "duration": samples.count * 1000 / WAV.sampleRate,
                    "processingTime": t?.processingMs ?? 0, "modelName": path.flatMap { modelNames[$0] } ?? "", "modelKey": modelKey,
                    "modeName": mode.name, "languageSelected": mode.language, "languageDetected": t?.language ?? "",
                    "appName": session["appName"] as? String ?? "", "appBundleID": session["appBundleID"] as? String ?? "",
                    "noVoice": text.isEmpty, "recovered": true, "appVersion": "whisperer-1.1",
                ]
                if path == nil { meta["error"] = "No voice model was installed; download one, then use Re-transcribe." }
                else if t == nil && AudioLevel.hasVoice(samples) { meta["error"] = "Recovered audio could not be transcribed; use Re-transcribe." }
                if let saved = try? HistoryStore.save(paths: paths, samples: samples, date: started, meta: meta) {
                    try? fm.removeItem(at: folder)
                    recovered.append(saved)
                }
            }
            DispatchQueue.main.async {
                guard let self, !recovered.isEmpty else { return }
                for f in recovered { if let r = HistoryStore.parse(folder: f, source: .whisperer) { self.model.insert(r) } }
                self.model.history.sort { $0.date > $1.date }
                if self.model.phase == .idle {
                    self.showNotice(recovered.count == 1 ? "Recovered an unfinished recording" : "Recovered \(recovered.count) unfinished recordings")
                }
                self.scheduleUnload()
            }
        }
    }

    private func finish() {
        limitWork?.cancel()
        let samples = recorder.stop()
        let spill = spillFolder
        spillFolder = nil
        _ = detector.handle(.reset)
        let mode = self.mode ?? model.settings.activeMode
        let startedAt = model.meter.startedAt
        let durationMs = samples.count * 1000 / WAV.sampleRate
        guard let path = model.modelPath(for: mode) else {
            model.phase = .idle
            showNotice("No voice model installed")
            model.route = .models
            return
        }
        model.phase = .transcribing
        pill.show()
        Sounds.play(.stop, style: model.settings.soundEffects, volume: model.settings.soundVolume)

        let settings = model.settings
        let engine = model.engine
        let paths = model.paths
        let app = target
        var opts = TranscribeOptions()
        opts.language = mode.language
        opts.translate = mode.translateToEnglish
        opts.prompt = TextProcessing.prompt(vocabulary: settings.vocabulary)
        opts.beamSearch = settings.beamSearch
        opts.vadModelPath = model.paths.vadModel?.path
        if durationMs > 20_000 {
            // Long talks take a while: the pill shows how far along it is.
            model.transcribeProgress = 0
            opts.onProgress = { [weak self] p in DispatchQueue.main.async { self?.model.transcribeProgress = p } }
        }
        let modelName = model.modelName(forPath: path)
        let testAudio = Recorder.lastRecordingWasTestAudio
        let modelID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")

        queue.async { [weak self] in
            var raw = "", text = "", procMs = 0, noVoice = false, failure: String?, detected = ""
            if AudioLevel.hasVoice(samples) {
                do {
                    let t = try engine.transcribe(AudioLevel.normalize(samples), modelPath: path, options: opts)
                    raw = t.text; procMs = t.processingMs; detected = t.language
                    text = TextProcessing.finalize(t.text, replacements: settings.replacements, autocapitalize: mode.autocapitalize)
                    if SpeechFilter.isHallucination(text, vocabulary: settings.vocabulary, peakRMS: AudioLevel.peakWindowRMS(samples)) {
                        text = ""
                    }
                    noVoice = text.isEmpty
                } catch { failure = error.localizedDescription }
            } else { noVoice = true }

            var meta: [String: Any] = [
                "result": text, "rawResult": raw, "duration": durationMs, "processingTime": procMs,
                "modelName": modelName, "modelKey": modelID, "modeName": mode.name,
                "languageSelected": mode.language, "languageDetected": detected, "appName": app?.localizedName ?? "",
                "appBundleID": app?.bundleIdentifier ?? "", "noVoice": noVoice, "appVersion": "whisperer-1.1",
            ]
            if testAudio { meta["testAudio"] = true }
            if let failure { meta["error"] = failure }
            let folder = samples.isEmpty ? nil : try? HistoryStore.save(paths: paths, samples: samples, date: startedAt, meta: meta)
            // The safety copy goes only once history holds the recording; if saving failed it stays and is
            // recovered at next launch.
            if let spill, folder != nil || samples.isEmpty { try? FileManager.default.removeItem(at: spill) }

            DispatchQueue.main.async {
                guard let self else { return }
                self.model.transcribeProgress = nil
                if let folder, let rec = HistoryStore.parse(folder: folder, source: .whisperer) { self.model.insert(rec) }
                if let failure {
                    self.model.lastError = failure
                    self.showNotice("Transcription failed")
                } else if noVoice {
                    self.showNotice("No voice found in recording")
                } else {
                    self.deliver(text, to: app, settings: settings)
                }
                self.scheduleUnload()
            }
        }
    }

    /// Paste into the app that was in front when recording started; anything uncertain becomes copy + notice.
    private func deliver(_ text: String, to app: NSRunningApplication?, settings: AppSettings) {
        let ours = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        guard settings.pasteResult, !ours, let app, !app.isTerminated else {
            Paster.deliver(text, paste: false, restoreClipboard: false)
            if settings.pasteResult { showNotice("Copied") } else { model.phase = .idle; pill.hide() }
            return
        }
        guard model.axTrusted else {
            Paster.deliver(text, paste: false, restoreClipboard: false)
            showNotice("Copied. Allow Accessibility to paste")
            return
        }
        var delay = 0.0
        if app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            delay = 0.25      // activation is asynchronous; let it land before Cmd+V
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // macOS may refuse the activation; never paste into whatever else is in front.
            guard NSWorkspace.shared.frontmostApplication == app else {
                Paster.deliver(text, paste: false, restoreClipboard: false)
                self.showNotice("Copied. Press ⌘V to paste")
                return
            }
            Paster.deliver(text, paste: true, restoreClipboard: settings.restoreClipboard)
            self.model.phase = .idle
            self.pill.hide()
        }
    }

    private func showNotice(_ text: String) {
        noticeWork?.cancel()
        model.phase = .notice(text)
        pill.show()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .notice = self.model.phase else { return }
            self.model.phase = .idle
            self.pill.hide()
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func scheduleUnload() {
        unloadWork?.cancel()
        let minutes = model.settings.keepModelWarmMinutes
        guard minutes > 0, minutes < 10_000 else { return }   // 0 = keep loaded
        let engine = model.engine
        let queue = self.queue
        let work = DispatchWorkItem { queue.async { engine.unload() } }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60, execute: work)
    }
}
