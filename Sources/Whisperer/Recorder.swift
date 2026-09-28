import AVFoundation
import WhispererCore

enum RecorderError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone input is available." }
}

/// Microphone to 16 kHz mono float. Levels (RMS per 20 ms) go to `onLevels` on the main thread, and every
/// chunk is also streamed to a WAV on disk while recording, so a crash never loses what was said.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    private var running = false
    private var fakeTimer: Timer?
    var onLevels: (([Float]) -> Void)?
    private var stream: WAVStream?
    private var levelCarry: [Float] = []   // tail shorter than a 20 ms window, finished by the next buffer
    /// Called on main when the input device changed and the mic could not be restarted.
    var onInterrupted: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    init() {
        // AirPods connecting or a USB mic appearing stops the engine; rebuild on the new device and carry on,
        // keeping everything captured so far.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterDeviceChange()
        }
    }

    private func restartAfterDeviceChange() {
        guard running, fakeTimer == nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        do { try installAndStart() }
        catch {
            running = false
            onInterrupted?()
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.consume(buf) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    /// Test hook: WHISPERER_FAKE_INPUT=/path/to.wav replaces the microphone with that file for ONE recording,
    /// then the variable is removed from the process, so a left-running test instance falls back to the real
    /// mic (2026-09-28: Matty dictated into one three times and got the test clip back).
    private(set) static var lastRecordingWasTestAudio = false

    private func takeFakeInput() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["WHISPERER_FAKE_INPUT"] else { return nil }
        unsetenv("WHISPERER_FAKE_INPUT")
        return URL(fileURLWithPath: path)
    }

    var isRunning: Bool { running }

    /// From now on, also stream the recording to `url` (called once a press is confirmed as dictation, so
    /// Option shortcuts never touch the disk). What was captured before is written first.
    func beginSpill(to url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard running, stream == nil, let s = try? WAVStream(url: url) else { return }
        s.append(samples)
        stream = s
    }
    /// Seconds captured so far.
    var capturedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / Double(WAV.sampleRate) }

    func start() throws {
        guard !running else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); stream?.close(); stream = nil; lock.unlock()
        levelCarry.removeAll()
        Recorder.lastRecordingWasTestAudio = false
        if let fake = takeFakeInput() {
            Recorder.lastRecordingWasTestAudio = true
            let data = try WAV.read(fake)
            lock.lock(); samples = data; stream?.append(data); lock.unlock()
            running = true
            fakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.onLevels?((0..<5).map { _ in Float.random(in: 0.004...0.05) })
            }
            return
        }
        do { try installAndStart() }
        catch { lock.lock(); stream?.close(); stream = nil; lock.unlock(); throw error }
        running = true
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); stream?.append(chunk); lock.unlock()
        let win = 320   // 20 ms at 16 kHz; only whole windows, so the meter's 50-per-second clock holds
        let pending = levelCarry + chunk
        let whole = pending.count / win * win
        let levels = stride(from: 0, to: whole, by: win).map { AudioLevel.rms(pending[$0..<$0 + win]) }
        levelCarry = Array(pending[whole...])
        DispatchQueue.main.async { [weak self] in self?.onLevels?(levels) }
    }

    /// Stops the mic and returns everything captured since `start()`.
    @discardableResult
    func stop() -> [Float] {
        if running {
            if fakeTimer != nil { fakeTimer?.invalidate(); fakeTimer = nil }
            else { engine.inputNode.removeTap(onBus: 0); engine.stop() }
            running = false
        }
        lock.lock(); defer { lock.unlock() }
        stream?.close(); stream = nil
        let out = samples
        samples.removeAll()
        return out
    }
}
