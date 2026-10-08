import Foundation
@testable import WhispererCore

struct TapDetectorTests {
    func cleanTapTogglesOnThenOff() {
        var d = TapDetector(holdThreshold: 0.35)
        expect(d.handle(.triggerDown(0)) == .startProvisional)
        expect(d.handle(.triggerUp(0.1)) == .confirm(.toggle))
        expect(d.state == .recording)
        expect(d.handle(.triggerDown(3)) == nil)
        expect(d.handle(.triggerUp(3.1)) == .stop)
        expect(d.state == .idle)
    }

    func holdIsPushToTalk() {
        var d = TapDetector(holdThreshold: 0.35)
        _ = d.handle(.triggerDown(0))
        expect(d.handle(.holdTimer(0.2)) == nil)          // early timer is ignored
        expect(d.handle(.holdTimer(0.36)) == .confirm(.pushToTalk))
        expect(d.handle(.triggerUp(4)) == .stop)
        expect(d.state == .idle)
    }

    func typingDuringHoldAborts() {
        var d = TapDetector(holdThreshold: 0.35)
        _ = d.handle(.triggerDown(0)); _ = d.handle(.holdTimer(0.4))
        expect(d.handle(.otherKey) == .abortProvisional)   // held Option, then Opt+3 for "#"
        expect(d.handle(.triggerUp(2)) == nil)
        expect(d.state == .idle)
    }

    func chordAbortsAndNeverRecords() {
        var d = TapDetector()
        _ = d.handle(.triggerDown(0))
        expect(d.handle(.otherKey) == .abortProvisional)   // Opt+Left arrow
        expect(d.handle(.holdTimer(1)) == nil)
        expect(d.handle(.triggerUp(1.2)) == nil)
        expect(d.state == .idle)
    }

    func lateReleaseWithoutTimerStillStops() {
        var d = TapDetector(holdThreshold: 0.35)
        _ = d.handle(.triggerDown(0))
        expect(d.handle(.triggerUp(2)) == .stop)
    }

    func chordWhileRecordingDoesNotStop() {
        var d = TapDetector()
        _ = d.handle(.triggerDown(0)); _ = d.handle(.triggerUp(0.1))
        _ = d.handle(.triggerDown(1)); _ = d.handle(.otherKey)
        expect(d.handle(.triggerUp(1.1)) == nil)
        expect(d.state == .recording)
    }

    func externalStartThenTapStops() {
        var d = TapDetector()
        d.recordingStartedExternally()
        _ = d.handle(.triggerDown(0))
        expect(d.handle(.triggerUp(0.1)) == .stop)
    }

    func resetFromAnywhere() {
        var d = TapDetector()
        _ = d.handle(.triggerDown(0)); _ = d.handle(.triggerUp(0.1))
        _ = d.handle(.reset)
        expect(d.state == .idle)
        expect(d.handle(.triggerUp(1)) == nil)
    }

    func doubleTapLocksInsteadOfStopping() {
        var d = TapDetector(holdThreshold: 0.35)
        expect(d.handle(.triggerDown(0)) == .startProvisional)
        expect(d.handle(.triggerUp(0.1)) == .confirm(.toggle))
        expect(d.handle(.triggerDown(0.3)) == nil)          // 0.2 s after the first tap: a double tap
        expect(d.handle(.triggerUp(0.38)) == .lock)
        expect(d.state == .recording)
        expect(d.handle(.triggerDown(0.6)) == nil)          // after a lock, any single tap stops
        expect(d.handle(.triggerUp(0.7)) == .stop)
    }

    func slowSecondTapStillStops() {
        var d = TapDetector(holdThreshold: 0.35)
        _ = d.handle(.triggerDown(0)); _ = d.handle(.triggerUp(0.1))
        expect(d.handle(.triggerDown(0.6)) == nil)          // outside the 0.4 s window
        expect(d.handle(.triggerUp(0.7)) == .stop)
    }

    func externalStartIsNeverADoubleTap() {
        var d = TapDetector()
        d.recordingStartedExternally()
        _ = d.handle(.triggerDown(0.05))
        expect(d.handle(.triggerUp(0.1)) == .stop)
    }

    func tapThenHoldIsAStopNotALock() {
        var d = TapDetector(holdThreshold: 0.35)
        _ = d.handle(.triggerDown(0)); _ = d.handle(.triggerUp(0.1))
        expect(d.handle(.triggerDown(0.3)) == nil)          // inside the double-tap window...
        expect(d.handle(.triggerUp(3.3)) == .stop)          // ...but held for 3 s: a stop press
        expect(d.state == .idle)
    }

    func strayUpInIdleIsIgnored() {
        var d = TapDetector()
        expect(d.handle(.triggerUp(0)) == nil)
        expect(d.handle(.otherKey) == nil)
        expect(d.state == .idle)
    }
}

struct V11Tests {
    func languageCandidates() {
        expect(Language.candidates("en,pl") == ["en", "pl"])
        expect(Language.candidates(" EN , pl ,en") == ["en", "pl"])
        expect(Language.candidates("auto").isEmpty)
        expect(Language.candidates("").isEmpty)
        expect(Language.candidates("en") == ["en"])
        let probs: [String: Float] = ["en": 0.2, "pl": 0.7, "cy": 0.9]   // Welsh is likelier but not allowed
        expect(Language.pick(["en", "pl"]) { probs[$0] ?? 0 } == "pl")
    }

    func modelFamilies() {
        expect(ModelWatch.family("ggml-large-v3-turbo-q8_0.bin") == "large-v3-turbo")
        expect(ModelWatch.family("ggml-medium.en-q5_0.bin") == "medium")
        expect(ModelWatch.family("ggml-small.en.bin") == "small")
        expect(ModelWatch.family("ggml-large-v3-encoder.mlmodelc.zip") == nil)
        expect(ModelWatch.family("ggml-silero-v5.1.2.bin") == nil)
        expect(ModelWatch.family("README.md") == nil)
        expect(ModelWatch.family("ggml-large-v3-turbo-q4_K.bin") == "large-v3-turbo")
        expect(ModelWatch.family("ggml-medium-q5_K_M.bin") == "medium")
    }

    func modelWatchFlagsOnlyNewFamilies() {
        let json = #"{"siblings":[{"rfilename":"ggml-large-v3-turbo-q5_0.bin"},{"rfilename":"ggml-large-v2.bin"},{"rfilename":"ggml-tiny.en-q8_0.bin"},{"rfilename":"ggml-large-v4.bin"},{"rfilename":"ggml-large-v4-q5_0.bin"},{"rfilename":"README.md"}]}"#
        expect(ModelWatch.newModels(fromHuggingFace: Data(json.utf8)) == ["large-v4"])
        expect(ModelWatch.newModels(fromHuggingFace: Data("not json".utf8)).isEmpty)
    }

    func versionsAndDue() {
        expect(ModelWatch.versionLess("1.9.4", "v1.10.0"))
        expect(!ModelWatch.versionLess("1.9.4", "v1.9.4"))
        expect(!ModelWatch.versionLess("2.0", "1.9.9"))
        let now = Date()
        var r = ModelWatchReport(lastChecked: now.addingTimeInterval(-6 * 24 * 3600), newModels: [], latestEngine: "v1.9.4", bundledEngine: "1.9.4")
        expect(!ModelWatch.isDue(r, now: now))
        r.lastChecked = now.addingTimeInterval(-7 * 24 * 3600 - 1)
        expect(ModelWatch.isDue(r, now: now))
        expect(ModelWatch.isDue(nil, now: now))
        expect(!r.engineUpdate)
    }

    func migrationMovesMediumToBestAndAddsPolish() {
        var s = AppSettings()
        s.modes = [Mode(key: "a", name: "A", voiceModelID: "medium", language: "en"),
                   Mode(key: "b", name: "B", voiceModelID: "small", language: "de"),
                   Mode(key: "c", name: "C", voiceModelID: "medium", language: "en", translateToEnglish: true)]
        s.starredModelIDs = ["medium"]
        SettingsMigration.apply(&s) { _ in true }
        expect(s.modes[0].voiceModelID == ModelCatalog.best && s.modes[0].language == "en,pl")
        expect(s.modes[1].voiceModelID == "small" && s.modes[1].language == "de")
        expect(s.modes[2].language == "en")                 // translate modes keep their setting
        expect(s.starredModelIDs.first == ModelCatalog.best)
        expect(s.settingsVersion == SettingsMigration.current)
        s.modes[0].language = "en"                          // later user choice survives a second launch
        SettingsMigration.apply(&s) { _ in true }
        expect(s.modes[0].language == "en")
    }

    func migrationKeepsMediumWhenBestIsNotDownloaded() {
        var s = AppSettings()
        s.modes = [Mode(key: "a", name: "A", voiceModelID: "medium", language: "en")]
        SettingsMigration.apply(&s) { $0 != ModelCatalog.best }
        expect(s.modes[0].voiceModelID == "medium")
        var u = AppSettings()
        u.modes = [Mode(key: "a", name: "A", voiceModelID: "small", language: "EN")]
        SettingsMigration.apply(&u) { _ in true }
        expect(u.modes[0].language == "en,pl")
    }

    func storedFileWithoutVersionIsMigrated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wchk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("settings.json")
        try Data(#"{"modes":[{"key":"v","name":"V","voiceModelID":"medium","language":"en"}]}"#.utf8).write(to: f)
        var s = LenientJSON.load(f, defaults: AppSettings())
        expect(s.settingsVersion == 1)
        SettingsMigration.apply(&s) { _ in true }
        expect(s.modes[0].voiceModelID == ModelCatalog.best)
    }

    func firstVoiceSkipsLeadingSilence() {
        let silence = [Float](repeating: 0, count: 16_000 * 31)
        let voice = (0..<16_000).map { Float(sin(Double($0) / 7)) * 0.1 }
        expect(AudioLevel.firstVoice(silence + voice).map { $0 >= 16_000 * 31 - 480 && $0 <= 16_000 * 31 } == true)
        expect(AudioLevel.firstVoice(silence) == nil)
    }

    func streamSurvivesACrashAndClosesClean() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wchk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("output.wav")
        let a = (0..<16_000).map { Float(sin(Double($0) / 20)) * 0.5 }
        let st = try WAVStream(url: url)
        st.append(a); st.append(a)
        // Before close (a crash): the header says "to end of file" and everything written reads back.
        Thread.sleep(forTimeInterval: 0.2)
        expect(try WAV.read(url).count == 32_000)
        st.close()
        let back = try WAV.read(url)
        expect(back.count == 32_000)
        expect(abs(back[100] - a[100]) < 0.001)
        let d = try Data(contentsOf: url)
        expect(d.count == 44 + 64_000)
        expect(d[40] == 0x00 && d[41] == 0xFA)   // data size 64000 = 0xFA00, little-endian
    }
}

struct TextTests {
    let reps = [Replacement(original: "super whisper", with: "Superwhisper"),
                Replacement(original: "claude code", with: "Claude Code")]

    func replacementsAreWholeWordCaseInsensitive() {
        expect(TextProcessing.applyReplacements("I use Super Whisper daily", reps) == "I use Superwhisper daily")
        expect(TextProcessing.applyReplacements("supersuper whisperer", reps) == "supersuper whisperer")
        expect(TextProcessing.applyReplacements("open claude code.", reps) == "open Claude Code.")
    }

    func replacementTextIsLiteral() {
        let r = [Replacement(original: "price", with: "$5 \\1")]
        expect(TextProcessing.applyReplacements("the price", r) == "the $5 \\1")
    }

    func regexCharsInOriginalAreLiteral() {
        let r = [Replacement(original: "c++", with: "C plus plus")]
        expect(TextProcessing.applyReplacements("I write c++ code", r) == "I write C plus plus code")
    }

    func longestOriginalWins() {
        let r = [Replacement(original: "super", with: "X"), Replacement(original: "super whisper", with: "Superwhisper")]
        expect(TextProcessing.applyReplacements("super whisper and super", r) == "Superwhisper and X")
    }

    func finalizeStripsTagsTrimsCapitalises() {
        expect(TextProcessing.finalize(" [BLANK_AUDIO] hello there (music) ", replacements: [], autocapitalize: true) == "Hello there")
        expect(TextProcessing.finalize(" hello", replacements: [], autocapitalize: false) == "hello")
        expect(TextProcessing.finalize("um so um yes", replacements: [Replacement(original: "um", with: "")], autocapitalize: true) == "So yes")
        expect(TextProcessing.finalize("hello , world", replacements: [], autocapitalize: false) == "hello, world")
        expect(TextProcessing.finalize("iPhone is here", replacements: [], autocapitalize: true) == "iPhone is here")
        expect(TextProcessing.finalize("ßa", replacements: [], autocapitalize: true) == "ßa")
        expect(TextProcessing.finalize("say (for example) this", replacements: [], autocapitalize: false) == "say (for example) this")
    }

    func hallucinationFilter() {
        let vocab = ["Superwhisper", "Donde", "Claude Code", "Skill"]
        expect(SpeechFilter.isHallucination("Don't forget to subscribe to our channel for more videos.", vocabulary: vocab, peakRMS: 0.007))
        expect(SpeechFilter.isHallucination(",", vocabulary: vocab, peakRMS: 0.03))
        expect(SpeechFilter.isHallucination("Superwhisper, Donde, Claude Code, Skill.", vocabulary: vocab, peakRMS: 0.01))
        expect(SpeechFilter.isHallucination("Thank you.", vocabulary: vocab, peakRMS: 0.01))
        expect(!SpeechFilter.isHallucination("Thank you.", vocabulary: vocab, peakRMS: 0.2))          // said clearly: keep
        expect(!SpeechFilter.isHallucination("Ask Donde about Claude Code.", vocabulary: vocab, peakRMS: 0.01))
        expect(!SpeechFilter.isHallucination("And then we cut it.", vocabulary: vocab, peakRMS: 0.01))
        expect(!SpeechFilter.isHallucination("Donde.", vocabulary: vocab, peakRMS: 0.2))              // one word said clearly
        expect(SpeechFilter.isHallucination("Donde.", vocabulary: vocab, peakRMS: 0.01))
        expect(!SpeechFilter.isHallucination("Yes.", vocabulary: vocab, peakRMS: 0.01))
        expect(TextProcessing.finalize("*click* *thump*", replacements: [], autocapitalize: true) == "")
    }

    func promptFromVocabulary() {
        expect(TextProcessing.prompt(vocabulary: ["Donde", " ", "Claude Code"]) == "Donde, Claude Code.")
        expect(TextProcessing.prompt(vocabulary: []) == "")
    }
}

struct WAVTests {
    func roundTrip() throws {
        let x: [Float] = (0..<1600).map { sin(Float($0) / 10) * 0.5 }
        let back = try WAV.decode(WAV.encode(x))
        expect(back.count == x.count)
        expect(zip(x, back).allSatisfy { abs($0 - $1) < 0.001 })
    }

    func rejectsGarbage() {
        expectThrows { _ = try WAV.decode(Data("hello world!".utf8)) }
    }

    func resamplesAndDownmixes() throws {
        // 48 kHz stereo 16-bit, 0.1 s: should come back as 1600 mono samples.
        var d = Data()
        func p32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func p16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let frames = 4800
        d.append(contentsOf: Array("RIFF".utf8)); p32(UInt32(36 + frames * 4)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("LIST".utf8)); p32(4); d.append(contentsOf: Array("INFO".utf8))   // unknown chunk first
        d.append(contentsOf: Array("fmt ".utf8)); p32(16); p16(1); p16(2); p32(48000); p32(48000 * 4); p16(4); p16(16)
        d.append(contentsOf: Array("data".utf8)); p32(UInt32(frames * 4))
        for _ in 0..<frames { p16(UInt16(bitPattern: 16384)); p16(UInt16(bitPattern: -16384)) }
        let s = try WAV.decode(d)
        expect(s.count == 1600)
        expect(s.allSatisfy { abs($0) < 0.001 })   // L and R cancel
    }

    func voiceDetection() {
        expect(!AudioLevel.hasVoice([Float](repeating: 0.001, count: 16000)))
        expect(!AudioLevel.hasVoice([Float](repeating: 0.004, count: 16000)))      // his true silence: 0.0037-0.0045
        expect(AudioLevel.hasVoice([Float](repeating: 0.0106, count: 16000)))      // his quietest real speech
        var x = [Float](repeating: 0, count: 16000)
        for i in 8000..<8960 { x[i] = sin(Float(i)) * 0.2 }
        expect(AudioLevel.hasVoice(x))
        expect(!AudioLevel.hasVoice([]))
    }
}

struct StoreTests {
    func tempPaths() -> Paths {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("whisperer-test-\(UUID().uuidString)")
        return Paths(root: base.appendingPathComponent("Whisperer"), superwhisperRoot: base.appendingPathComponent("superwhisper"))
    }

    func saveThenLoadBothSources() throws {
        let p = tempPaths()
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        try HistoryStore.save(paths: p, samples: [0, 0.1], date: d, meta: ["result": "hello world", "duration": 60_000, "appBundleID": "com.apple.TextEdit"])
        try HistoryStore.save(paths: p, samples: [0], date: d, meta: ["result": "second"])   // same second: bumped folder
        let sw = p.superwhisperRecordings.appendingPathComponent("1790000100")
        try FileManager.default.createDirectory(at: sw, withIntermediateDirectories: true)
        try Data(#"{"result":"from superwhisper","llmResult":"From Superwhisper, polished.","datetime":"2026-09-28T16:22:01","duration":23373,"processingTime":957,"modelName":"Whisper Medium","promptContext":{"applicationContext":{"name":"Antigravity IDE"}}}"#.utf8)
            .write(to: sw.appendingPathComponent("meta.json"))
        let broken = p.superwhisperRecordings.appendingPathComponent("999")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: broken.appendingPathComponent("meta.json"))

        let all = HistoryStore.loadAll(paths: p, includeSuperwhisper: true)
        expect(all.count == 3)
        expect(all.first?.source == .superwhisper)            // newest first
        expect(all.filter { $0.source == .whisperer }.count == 2)
        expect(HistoryStore.loadAll(paths: p, includeSuperwhisper: false).count == 2)
        expect(HistoryStore.search(all, "POLISHED").count == 1)                  // llmResult is what was pasted
        expect(all.first?.appName == "Antigravity IDE")
        expect(all.first?.date == Date(timeIntervalSince1970: 1790000100))        // folder epoch wins over the UTC stamp
        // A folder without an epoch name falls back to the stamp, read as UTC.
        let named = p.superwhisperRecordings.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try Data(#"{"result":"a","datetime":"2026-09-28T16:43:52"}"#.utf8).write(to: named.appendingPathComponent("meta.json"))
        expect(HistoryStore.parse(folder: named, source: .superwhisper)?.date == Date(timeIntervalSince1970: 1790613832))
        // Ours are written in UTC too.
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: all.last!.metaURL)) as? [String: Any]
        expect(meta?["datetime"] as? String == "2026-09-21T14:13:20")
        let ours = all.first { $0.result == "hello world" }!
        expect(try WAV.read(ours.audioURL).count == 2)
        try HistoryStore.update(ours, fields: ["result": "edited"])
        expect(HistoryStore.parse(folder: ours.folder, source: .whisperer)?.result == "edited")
        expectThrows { try HistoryStore.update(all.first!, fields: ["result": "x"]) }
    }

    func statsMatchSuperwhisperFormula() {
        let p = URL(fileURLWithPath: "/tmp/x")
        func rec(_ words: Int, _ ms: Int, _ app: String) -> Recording {
            Recording(folder: p, source: .whisperer, date: Date(), result: Array(repeating: "w", count: words).joined(separator: " "),
                      rawResult: "", durationMs: ms, processingMs: 0, modelName: "", modeName: "", appName: "",
                      appBundleID: app, noVoice: words == 0)
        }
        let s = UsageStats.compute([rec(93, 60_000, "a"), rec(93, 60_000, "b"), rec(0, 5_000, "c")])
        expect(s.words == 186)
        expect(s.averageWPM == 93)
        expect(s.appsUsed == 2)
        // 186 words at 40 wpm = 4.65 min typed, minus 2 min spoken = 2.65 min.
        expect(abs(s.hoursSaved - 2.65 / 60) < 0.0001)
    }

    func settingsSurviveMissingKeysAndImportSuperwhisper() throws {
        let p = tempPaths()
        try FileManager.default.createDirectory(at: p.root, withIntermediateDirectories: true)
        try Data(#"{"triggerKey":"leftOption","unknownKey":1}"#.utf8).write(to: p.settingsFile)
        var s = LenientJSON.load(p.settingsFile, defaults: AppSettings())
        expect(s.triggerKey == .leftOption)
        expect(s.pasteResult == true)

        try FileManager.default.createDirectory(at: p.superwhisperModes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: p.superwhisperSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"vocabulary":["Donde","Skill"],"replacements":[{"id":"1","original":"super whisper","with":"Superwhisper"}]}"#.utf8).write(to: p.superwhisperSettings)
        try Data(#"{"type":"voice","name":"Voice to text","voiceModelID":"medium","language":"en"}"#.utf8).write(to: p.superwhisperModes.appendingPathComponent("a.json"))
        try Data(#"{"type":"voice","name":"Default","voiceModelID":"sv-1","language":"en"}"#.utf8).write(to: p.superwhisperModes.appendingPathComponent("b.json"))
        try Data(#"{"type":"message","name":"Message","voiceModelID":"sv-1"}"#.utf8).write(to: p.superwhisperModes.appendingPathComponent("c.json"))
        SuperwhisperImport.apply(p, to: &s)
        SuperwhisperImport.apply(p, to: &s)   // idempotent
        expect(s.vocabulary == ["Donde", "Skill"])
        expect(s.replacements.count == 1)
        expect(s.modes.map(\.name) == ["Voice to text", "Default"])   // existing kept, message mode skipped
        expect(s.modes.last?.voiceModelID == ModelCatalog.best)       // cloud id falls back to the best local model
        try LenientJSON.save(s, to: p.settingsFile)
        expect(LenientJSON.load(p.settingsFile, defaults: AppSettings()) == s)
    }

    func brokenModeDoesNotWipeSettings() throws {
        let p = tempPaths()
        try FileManager.default.createDirectory(at: p.root, withIntermediateDirectories: true)
        try Data(#"{"vocabulary":["Donde"],"modes":[{"name":"Voice to text"},{"key":"x","name":"X","voiceModelID":"small"}],"replacements":[{"original":"a"}]}"#.utf8).write(to: p.settingsFile)
        let r = LenientJSON.loadChecked(p.settingsFile, defaults: AppSettings())
        expect(!r.unreadable)
        // One bad field falls back alone.
        try Data(#"{"vocabulary":["Keep"],"triggerKey":"rightControl","holdThreshold":"0.35"}"#.utf8).write(to: p.root.appendingPathComponent("b.json"))
        let b = LenientJSON.loadChecked(p.root.appendingPathComponent("b.json"), defaults: AppSettings())
        expect(!b.unreadable && b.value.vocabulary == ["Keep"] && b.value.triggerKey == .rightOption && b.value.holdThreshold == 0.35)
        expect(r.value.vocabulary == ["Donde"])
        expect(r.value.modes.count == 2 && r.value.modes[0].key == "voice-to-text" && r.value.modes[0].voiceModelID == ModelCatalog.best)
        expect(r.value.replacements.first?.with == "")
        try Data("{ not json".utf8).write(to: p.settingsFile)
        expect(LenientJSON.loadChecked(p.settingsFile, defaults: AppSettings()).unreadable)
        expect(!LenientJSON.loadChecked(p.root.appendingPathComponent("missing.json"), defaults: AppSettings()).unreadable)
    }

    func modeForApp() {
        var s = AppSettings()
        s.modes.append(Mode(key: "slack", name: "Slack", voiceModelID: "small", activationApps: ["com.tinyspeck.slackmacgap"]))
        expect(s.mode(forApp: "com.tinyspeck.slackmacgap").key == "slack")
        expect(s.mode(forApp: "com.apple.TextEdit").key == "voice-to-text")
        expect(s.mode(forApp: nil).key == "voice-to-text")
    }

    func catalogInstalledNeedsCompleteFile() throws {
        let p = tempPaths()
        try FileManager.default.createDirectory(at: p.models, withIntermediateDirectories: true)
        let tiny = ModelCatalog.find("tiny")!
        try Data(count: 1000).write(to: p.modelFile("tiny"))
        expect(!ModelCatalog.isInstalled(tiny, paths: p))
        expect(ModelCatalog.find("sv-1") == nil)
    }
}

// Generated list: every check in this file runs from main.swift.
struct PillPlacementTests {
    let laptop = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    let monitor = CGRect(x: 1800, y: -200, width: 2560, height: 1410)

    func defaultIsBottomCentre() {
        let a = PillPlacement.anchor([], in: laptop)
        expect(a.x == 900 && a.y == 28)
    }

    func savedSpotRoundTripsAndScalesAcrossScreens() {
        let f = PillPlacement.fractions(CGPoint(x: 1339, y: 759), in: laptop)
        let back = PillPlacement.anchor(f, in: laptop)
        expect(abs(back.x - 1339) < 0.001 && abs(back.y - 759) < 0.001)
        let big = PillPlacement.anchor(f, in: monitor)          // same relative spot on the other screen
        expect(abs(big.x - (1800 + 2560 * 1339 / 1800)) < 0.01 && abs(big.y - (-200 + 1410 * 759 / 1130)) < 0.01)
    }

    func dropOffScreenIsPulledBackOn() {
        let a = PillPlacement.anchor(PillPlacement.fractions(CGPoint(x: -500, y: 5000), in: laptop), in: laptop)
        expect(a.x == PillPlacement.halfWidth && a.y == 1130 - PillPlacement.height)
        let b = PillPlacement.anchor(PillPlacement.fractions(CGPoint(x: 9000, y: -40), in: laptop), in: laptop)
        expect(b.x == 1800 - PillPlacement.halfWidth && b.y == 4)
    }

    func badStoredValuesFallBackToDefault() throws {
        for bad in ["[0.5]", "[0.5, 2]", "[-1, 0.3]", "\"left\""] {
            let json = "{\"pillPosition\": \(bad), \"soundVolume\": 0.4}".data(using: .utf8)!
            let s = try JSONDecoder().decode(AppSettings.self, from: json)
            expect(s.pillPosition.isEmpty && s.soundVolume == 0.4)
        }
        let ok = try JSONDecoder().decode(AppSettings.self, from: "{\"pillPosition\": [0.7, 0.6]}".data(using: .utf8)!)
        expect(ok.pillPosition == [0.7, 0.6])
    }
}

let allChecks: [(String, () throws -> Void)] = [
    ("TapDetectorTests.cleanTapTogglesOnThenOff", { TapDetectorTests().cleanTapTogglesOnThenOff() }),
    ("TapDetectorTests.holdIsPushToTalk", { TapDetectorTests().holdIsPushToTalk() }),
    ("TapDetectorTests.typingDuringHoldAborts", { TapDetectorTests().typingDuringHoldAborts() }),
    ("TapDetectorTests.chordAbortsAndNeverRecords", { TapDetectorTests().chordAbortsAndNeverRecords() }),
    ("TapDetectorTests.lateReleaseWithoutTimerStillStops", { TapDetectorTests().lateReleaseWithoutTimerStillStops() }),
    ("TapDetectorTests.chordWhileRecordingDoesNotStop", { TapDetectorTests().chordWhileRecordingDoesNotStop() }),
    ("TapDetectorTests.externalStartThenTapStops", { TapDetectorTests().externalStartThenTapStops() }),
    ("TapDetectorTests.resetFromAnywhere", { TapDetectorTests().resetFromAnywhere() }),
    ("TapDetectorTests.doubleTapLocksInsteadOfStopping", { TapDetectorTests().doubleTapLocksInsteadOfStopping() }),
    ("TapDetectorTests.slowSecondTapStillStops", { TapDetectorTests().slowSecondTapStillStops() }),
    ("TapDetectorTests.externalStartIsNeverADoubleTap", { TapDetectorTests().externalStartIsNeverADoubleTap() }),
    ("V11Tests.languageCandidates", { V11Tests().languageCandidates() }),
    ("V11Tests.modelFamilies", { V11Tests().modelFamilies() }),
    ("V11Tests.modelWatchFlagsOnlyNewFamilies", { V11Tests().modelWatchFlagsOnlyNewFamilies() }),
    ("V11Tests.versionsAndDue", { V11Tests().versionsAndDue() }),
    ("V11Tests.migrationMovesMediumToBestAndAddsPolish", { V11Tests().migrationMovesMediumToBestAndAddsPolish() }),
    ("V11Tests.migrationKeepsMediumWhenBestIsNotDownloaded", { V11Tests().migrationKeepsMediumWhenBestIsNotDownloaded() }),
    ("V11Tests.storedFileWithoutVersionIsMigrated", { try V11Tests().storedFileWithoutVersionIsMigrated() }),
    ("V11Tests.firstVoiceSkipsLeadingSilence", { V11Tests().firstVoiceSkipsLeadingSilence() }),
    ("TapDetectorTests.tapThenHoldIsAStopNotALock", { TapDetectorTests().tapThenHoldIsAStopNotALock() }),
    ("V11Tests.streamSurvivesACrashAndClosesClean", { try V11Tests().streamSurvivesACrashAndClosesClean() }),
    ("TapDetectorTests.strayUpInIdleIsIgnored", { TapDetectorTests().strayUpInIdleIsIgnored() }),
    ("TextTests.replacementsAreWholeWordCaseInsensitive", { TextTests().replacementsAreWholeWordCaseInsensitive() }),
    ("TextTests.replacementTextIsLiteral", { TextTests().replacementTextIsLiteral() }),
    ("TextTests.regexCharsInOriginalAreLiteral", { TextTests().regexCharsInOriginalAreLiteral() }),
    ("TextTests.longestOriginalWins", { TextTests().longestOriginalWins() }),
    ("TextTests.finalizeStripsTagsTrimsCapitalises", { TextTests().finalizeStripsTagsTrimsCapitalises() }),
    ("TextTests.hallucinationFilter", { TextTests().hallucinationFilter() }),
    ("TextTests.promptFromVocabulary", { TextTests().promptFromVocabulary() }),
    ("WAVTests.roundTrip", { try WAVTests().roundTrip() }),
    ("WAVTests.rejectsGarbage", { WAVTests().rejectsGarbage() }),
    ("WAVTests.resamplesAndDownmixes", { try WAVTests().resamplesAndDownmixes() }),
    ("WAVTests.voiceDetection", { WAVTests().voiceDetection() }),
    ("StoreTests.saveThenLoadBothSources", { try StoreTests().saveThenLoadBothSources() }),
    ("StoreTests.statsMatchSuperwhisperFormula", { StoreTests().statsMatchSuperwhisperFormula() }),
    ("StoreTests.settingsSurviveMissingKeysAndImportSuperwhisper", { try StoreTests().settingsSurviveMissingKeysAndImportSuperwhisper() }),
    ("StoreTests.brokenModeDoesNotWipeSettings", { try StoreTests().brokenModeDoesNotWipeSettings() }),
    ("StoreTests.modeForApp", { StoreTests().modeForApp() }),
    ("StoreTests.catalogInstalledNeedsCompleteFile", { try StoreTests().catalogInstalledNeedsCompleteFile() }),
    ("PillPlacementTests.defaultIsBottomCentre", { PillPlacementTests().defaultIsBottomCentre() }),
    ("PillPlacementTests.savedSpotRoundTripsAndScalesAcrossScreens", { PillPlacementTests().savedSpotRoundTripsAndScalesAcrossScreens() }),
    ("PillPlacementTests.dropOffScreenIsPulledBackOn", { PillPlacementTests().dropOffScreenIsPulledBackOn() }),
    ("PillPlacementTests.badStoredValuesFallBackToDefault", { try PillPlacementTests().badStoredValuesFallBackToDefault() }),
]
