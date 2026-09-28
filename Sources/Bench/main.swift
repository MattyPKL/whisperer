import Foundation
import WhispererCore

// Agreement benchmark: re-transcribe N of Matty's Superwhisper recordings with each model and compare
// to what Superwhisper produced. Superwhisper's text is NOT ground truth, so the score is "word
// disagreement with Superwhisper", not accuracy.
// Usage: swift run -c release Bench [N] [model[:beam] ...]

func norm(_ s: String) -> [String] {
    s.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
        .split(separator: " ").map(String.init)
}

func wordErrors(_ ref: [String], _ hyp: [String]) -> Int {
    if ref.isEmpty { return hyp.count }
    var prev = Array(0...hyp.count)
    for i in 1...ref.count {
        var cur = [i] + Array(repeating: 0, count: hyp.count)
        for j in stride(from: 1, through: hyp.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (ref[i-1] == hyp[j-1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[hyp.count]
}

let args = Array(CommandLine.arguments.dropFirst())

// `Bench --voicegate N`: score the no-voice decision (energy gate + hallucination filter) on N recordings
// Superwhisper transcribed and N it marked "No voice found". Both directions must hold.
if args.first == "--voicegate" {
    let n = args.count > 1 ? Int(args[1]) ?? 40 : 40
    let paths = Paths()
    var settings = AppSettings()
    SuperwhisperImport.apply(paths, to: &settings)
    let all = HistoryStore.load(from: paths.superwhisperRecordings, source: .superwhisper)
        .filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }.sorted { $0.date > $1.date }
    let voiced = Array(all.filter { !$0.noVoice }.prefix(n)), silent = Array(all.filter { $0.noVoice }.prefix(n))
    let engine = Transcriber()
    // --voicegate N [model[:vad]]: the gate as the app runs it.
    let gateSpec = args.count > 2 ? args[2].split(separator: ":").map(String.init) : ["medium"]
    let modelPath = paths.modelFile(gateSpec[0]).path
    var o = TranscribeOptions(); o.prompt = TextProcessing.prompt(vocabulary: settings.vocabulary)
    if gateSpec.contains("vad") { o.vadModelPath = paths.vadModel?.path; o.language = "en,pl" }
    func decide(_ r: Recording) -> (Bool, String) {
        guard let a = try? WAV.read(r.audioURL) else { return (false, "unreadable") }
        guard AudioLevel.hasVoice(a) else { return (false, "gate") }
        guard let t = try? engine.transcribe(AudioLevel.normalize(a), modelPath: modelPath, options: o) else { return (false, "error") }
        let text = TextProcessing.finalize(t.text, replacements: settings.replacements, autocapitalize: true)
        if SpeechFilter.isHallucination(text, vocabulary: settings.vocabulary, peakRMS: AudioLevel.peakWindowRMS(a)) { return (false, "filter: \(text)") }
        return (true, text)
    }
    var lostSpeech = 0, keptNoise = 0
    for r in voiced { let (keep, why) = decide(r); if !keep { lostSpeech += 1; print("LOST SPEECH [\(why)] SW: \(r.result.prefix(80))") } }
    for r in silent { let (keep, why) = decide(r); if keep { keptNoise += 1; print("KEPT NOISE: \(why.prefix(80))") } }
    engine.unload()   // ggml-metal asserts at exit if a context is still alive
    print("voicegate: speech kept \(voiced.count - lostSpeech)/\(voiced.count), silence dropped \(silent.count - keptNoise)/\(silent.count)")
    exit(lostSpeech == 0 ? 0 : 1)
}
let n = args.first.flatMap(Int.init) ?? 20
let specs = args.dropFirst().isEmpty ? ["medium", "large-v3-turbo"] : Array(args.dropFirst())
let paths = Paths()
var settings = AppSettings()
SuperwhisperImport.apply(paths, to: &settings)
let prompt = TextProcessing.prompt(vocabulary: settings.vocabulary)

// Most recent recordings with speech, 4 to 90 s long, made with the Whisper Medium model.
let pool = HistoryStore.load(from: paths.superwhisperRecordings, source: .superwhisper)
    .filter { !$0.noVoice && $0.durationMs >= 4_000 && $0.durationMs <= 90_000 && $0.modelName.contains("Whisper")
              && FileManager.default.fileExists(atPath: $0.audioURL.path) }
    .sorted { $0.date > $1.date }
let sample = Array(pool.prefix(n))
print("sample: \(sample.count) recordings, \(sample.reduce(0) { $0 + $1.durationMs } / 1000) s audio, prompt: \(prompt)")

let engine = Transcriber()
var report: [[String: Any]] = []
for spec in specs {
    let parts = spec.split(separator: ":")
    // model[:beam][:vad]  (vad also turns on English/Polish detection, as the app runs it)
    let id = String(parts[0]); let beam = parts.contains("beam"); let vad = parts.contains("vad")
    let modelPath = paths.modelFile(id).path
    let t0 = Date()
    do { try engine.load(modelPath) } catch { print("\(spec): \(error)"); continue }
    let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
    var opts = TranscribeOptions(); opts.prompt = prompt; opts.beamSearch = beam
    if vad { opts.vadModelPath = paths.vadModel?.path; opts.language = "en,pl" }
    _ = try? engine.transcribe([Float](repeating: 0, count: 16_000), modelPath: modelPath, options: opts)  // warm-up (Metal compile)
    var errs = 0, refWords = 0, procMs = 0, audioMs = 0, exact = 0
    var worst: [(Int, String, String)] = []
    for r in sample {
        guard let audio = try? WAV.read(r.audioURL),
              let t = try? engine.transcribe(audio, modelPath: modelPath, options: opts) else { continue }
        let hyp = TextProcessing.finalize(t.text, replacements: settings.replacements, autocapitalize: true)
        let e = wordErrors(norm(r.result), norm(hyp))
        errs += e; refWords += norm(r.result).count; procMs += t.processingMs; audioMs += r.durationMs
        if e == 0 { exact += 1 }
        worst.append((e, r.result, hyp))
    }
    let rate = refWords > 0 ? Double(errs) / Double(refWords) * 100 : 0
    print(String(format: "%@  disagreement %.1f%%  exact %d/%d  avg %d ms per clip  %.0fx realtime  load %d ms",
                 spec, rate, exact, sample.count, procMs / max(1, sample.count), Double(audioMs) / Double(max(1, procMs)), loadMs))
    for w in worst.sorted(by: { $0.0 > $1.0 }).prefix(2) { print("   \(w.0) diffs\n     SW: \(w.1)\n     US: \(w.2)") }
    report.append(["model": spec, "disagreementPct": rate, "exact": exact, "clips": sample.count,
                   "avgProcessingMs": procMs / max(1, sample.count), "loadMs": loadMs])
    engine.unload()
}
engine.unload()
let out = URL(fileURLWithPath: "bench/results-\(ISO8601DateFormatter().string(from: Date()).prefix(16).replacingOccurrences(of: ":", with: "")).json")
try? JSONSerialization.data(withJSONObject: ["sample": sample.count, "results": report], options: [.prettyPrinted]).write(to: out)
print("wrote \(out.path)")
