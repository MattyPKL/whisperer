import Foundation
import CWhisper

public struct TranscribeOptions: Sendable {
    /// "en", "auto" (any language), or a comma list such as "en,pl": detect, but only between these.
    public var language: String = "en"
    /// Silero VAD model. When set, whisper only sees the speech: no silence to hallucinate over, which is
    /// what stops long talks looping ("The way I've pasted the screenshot." x21 on an 11 minute clip).
    public var vadModelPath: String?
    /// VAD runs only on recordings at least this long. Measured 2026-09-28 on 24 of Matty's clips: on short
    /// dictation it cost accuracy (94.6% -> 93.8% agreement, clipped "I've" at a word onset) for no gain,
    /// while every loop seen was on long audio.
    public var vadMinSeconds: Double = 30
    /// 0...100 while a long recording transcribes. Called on the transcribe thread.
    public var onProgress: (@Sendable (Int) -> Void)?
    public var prompt: String = ""
    public var translate: Bool = false
    public var beamSearch: Bool = false
    public var threads: Int = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    public init() {}
}

public struct Transcript {
    public var text: String
    public var segments: [(start: Double, end: Double, text: String)]
    /// Whisper's own "this window was not speech" probability, one per segment.
    public var noSpeech: [Float]
    public var processingMs: Int
    public var language: String
    public var usedVAD: Bool = false
}

public enum TranscriberError: Error, LocalizedError {
    case modelMissing(String), loadFailed(String), failed(Int32)
    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return "Model file not found: \(p)"
        case .loadFailed(let p): return "Could not load model: \(p)"
        case .failed(let c): return "Transcription failed (code \(c))"
        }
    }
}

private let silentLog: ggml_log_callback = { _, _, _ in }

private final class ProgressBox { let f: @Sendable (Int) -> Void; init(_ f: @escaping @Sendable (Int) -> Void) { self.f = f } }
private let progressTrampoline: whisper_progress_callback = { _, _, progress, user in
    guard let user else { return }
    Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue().f(Int(progress))
}

public enum Language {
    /// "en,pl" -> ["en", "pl"]; "auto" and "" -> [] (any language); "en" -> ["en"].
    public static func candidates(_ setting: String) -> [String] {
        let parts = setting.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0 != "auto" }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }
    }

    /// Picks the most likely candidate from whisper's per-language probabilities (indexed by whisper id).
    public static func pick(_ candidates: [String], probability: (String) -> Float) -> String? {
        candidates.max { probability($0) < probability($1) }
    }
}

/// In-process whisper.cpp. One model stays loaded until `unload()`; every call is serialised.
public final class Transcriber: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var _loadedPath: String?
    private let lock = NSLock()
    public var loadedPath: String? { lock.lock(); defer { lock.unlock() }; return _loadedPath }

    /// ggml ships its CPU/Metal backends as plugins; they must be registered once before any model loads.
    /// The app bundle carries its own copies in Contents/Frameworks/ggml-backends (see build.sh);
    /// command-line builds fall back to Homebrew's.
    private static let backends: Void = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/ggml-backends")
        if FileManager.default.fileExists(atPath: bundled.path) { ggml_backend_load_all_from_path(bundled.path) }
        else { ggml_backend_load_all() }
    }()

    public init(quiet: Bool = true) {
        if quiet { whisper_log_set(silentLog, nil) }
        Transcriber.backends
    }
    deinit { if let c = ctx { whisper_free(c) } }

    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return ctx != nil }

    public func load(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        try loadLocked(path)
    }

    private func loadLocked(_ path: String) throws {
        if _loadedPath == path, ctx != nil { return }
        guard FileManager.default.fileExists(atPath: path) else { throw TranscriberError.modelMissing(path) }
        if let c = ctx { whisper_free(c); ctx = nil; _loadedPath = nil }
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        guard let c = whisper_init_from_file_with_params(path, cp) else { throw TranscriberError.loadFailed(path) }
        ctx = c
        _loadedPath = path
    }

    public func unload() {
        lock.lock(); defer { lock.unlock() }
        if let c = ctx { whisper_free(c) }
        ctx = nil; _loadedPath = nil
    }

    /// Unloads only if nothing is running right now. Returns false when busy (the caller must not block).
    public func tryUnload() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        if let c = ctx { whisper_free(c) }
        ctx = nil; _loadedPath = nil
        return true
    }

    public func transcribe(_ samples: [Float], modelPath: String, options: TranscribeOptions = TranscribeOptions()) throws -> Transcript {
        lock.lock(); defer { lock.unlock() }
        try loadLocked(modelPath)
        guard let c = ctx else { throw TranscriberError.loadFailed(modelPath) }
        let t0 = Date()
        var p = whisper_full_default_params(options.beamSearch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(options.threads)
        p.print_progress = false
        p.print_realtime = false
        p.print_special = false
        p.print_timestamps = false
        p.translate = options.translate
        p.no_context = true
        p.suppress_blank = true
        p.beam_search.beam_size = 5
        p.greedy.best_of = 5
        // Whisper needs >= 1 s of audio; pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 + 1_600 { audio += [Float](repeating: 0, count: 16_000 + 1_600 - audio.count) }
        let lang = try resolveLanguage(c, audio: audio, setting: options.language, threads: options.threads)
        p.detect_language = false
        var box: Unmanaged<ProgressBox>?
        if let f = options.onProgress {
            box = Unmanaged.passRetained(ProgressBox(f))
            p.progress_callback = progressTrampoline
            p.progress_callback_user_data = box?.toOpaque()
        }
        defer { box?.release() }
        let longEnough = Double(samples.count) / 16_000 >= options.vadMinSeconds
        let vadPath = options.vadModelPath.flatMap { longEnough && FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if vadPath != nil {
            p.vad = true
            var vp = whisper_vad_default_params()
            vp.speech_pad_ms = 200          // default 30 ms clips quiet word onsets
            p.vad_params = vp
        }
        let rc: Int32 = lang.withCString { l in
            options.prompt.withCString { pr in
                (vadPath ?? "").withCString { vp in
                    p.language = l
                    p.initial_prompt = options.prompt.isEmpty ? nil : pr
                    if vadPath != nil { p.vad_model_path = vp }
                    return audio.withUnsafeBufferPointer { whisper_full(c, p, $0.baseAddress, Int32($0.count)) }
                }
            }
        }
        guard rc == 0 else { throw TranscriberError.failed(rc) }
        var segs: [(Double, Double, String)] = []
        var noSpeech: [Float] = []
        for i in 0..<whisper_full_n_segments(c) {
            noSpeech.append(whisper_full_get_segment_no_speech_prob(c, i))
            let text = String(cString: whisper_full_get_segment_text(c, i))
            segs.append((Double(whisper_full_get_segment_t0(c, i)) / 100, Double(whisper_full_get_segment_t1(c, i)) / 100, text))
        }
        let langID = whisper_full_lang_id(c)
        let detected = lang != "auto" ? lang : (langID >= 0 ? String(cString: whisper_lang_str(langID)) : lang)
        return Transcript(text: segs.map { $0.2 }.joined(), segments: segs, noSpeech: noSpeech,
                          processingMs: Int(Date().timeIntervalSince(t0) * 1000), language: detected, usedVAD: vadPath != nil)
    }

    /// One candidate: use it. Several: whisper's language detector on the opening 30 s, restricted to the
    /// candidates, so an English "Yes." can never come back as Welsh. None: whisper's own "auto".
    private func resolveLanguage(_ c: OpaquePointer, audio: [Float], setting: String, threads: Int) throws -> String {
        let cands = Language.candidates(setting).filter { whisper_lang_id($0) >= 0 }
        if cands.isEmpty { return "auto" }
        if cands.count == 1 { return cands[0] }
        // Judge the language on the speech: a locked recording can open with 30 s of silence, and a detector
        // fed silence answers "en" (Medium then translated Polish into English, stress test 2026-09-28).
        let speechLevel = max(0.005, AudioLevel.peakWindowRMS(audio) * 0.2)   // room noise stays below this
        let start = AudioLevel.firstVoice(audio, threshold: speechLevel).map { max(0, $0 - 8_000) } ?? 0
        let head = Array(audio[start..<min(audio.count, start + 16_000 * 30)])
        let ok = head.withUnsafeBufferPointer { whisper_pcm_to_mel(c, $0.baseAddress, Int32($0.count), Int32(threads)) }
        guard ok == 0 else { return cands[0] }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(c, 0, Int32(threads), &probs) >= 0 else { return cands[0] }
        return Language.pick(cands) { probs[Int(whisper_lang_id($0))] } ?? cands[0]
    }
}
