import Foundation

public enum WAVError: Error, Equatable { case notRIFF, noFormat, noData, unsupported(String) }

/// Minimal RIFF/WAVE reader and writer. Whisper wants 16 kHz mono float; Superwhisper stores 16 kHz mono Int16.
public enum WAV {
    public static let sampleRate = 16_000

    public static func read(_ url: URL) throws -> [Float] { try decode(Data(contentsOf: url)) }

    public static func decode(_ data: Data) throws -> [Float] {
        let b = [UInt8](data)
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i+1]) << 8 }
        guard b.count >= 12, b[0...3] == [0x52,0x49,0x46,0x46], b[8...11] == [0x57,0x41,0x56,0x45] else { throw WAVError.notRIFF }
        var fmt: (tag: UInt16, ch: Int, rate: Int, bits: Int)?
        var p = 12
        while p + 8 <= b.count {
            let id = String(bytes: b[p..<p+4], encoding: .ascii) ?? ""
            let size = Int(u32(p + 4))
            let body = p + 8
            if id == "fmt " {
                guard body + 16 <= b.count else { throw WAVError.noFormat }
                var tag = u16(body)
                if tag == 0xFFFE, body + 26 <= b.count { tag = u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
                fmt = (tag, Int(u16(body + 2)), Int(u32(body + 4)), Int(u16(body + 14)))
            } else if id == "data" {
                guard let f = fmt else { throw WAVError.noFormat }
                let end = min(b.count, body + size)
                let mono = try samples(b, body, end, f)
                return f.rate == sampleRate ? mono : resample(mono, from: f.rate, to: sampleRate)
            }
            p = body + size + (size & 1)
        }
        throw fmt == nil ? WAVError.noFormat : WAVError.noData
    }

    static func samples(_ b: [UInt8], _ start: Int, _ end: Int, _ f: (tag: UInt16, ch: Int, rate: Int, bits: Int)) throws -> [Float] {
        guard f.ch >= 1 else { throw WAVError.unsupported("0 channels") }
        let bytes = f.bits / 8
        let frame = bytes * f.ch
        guard frame > 0 else { throw WAVError.unsupported("bits \(f.bits)") }
        let n = (end - start) / frame
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for c in 0..<f.ch {
                let o = start + i * frame + c * bytes
                switch (f.tag, f.bits) {
                case (1, 16): acc += Float(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o+1]) << 8)) / 32768
                case (1, 24):
                    let v = Int32(bitPattern: (UInt32(b[o]) << 8 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 24)) >> 8
                    acc += Float(v) / 8_388_608
                case (1, 32): acc += Float(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24)) / 2_147_483_648
                case (3, 32): acc += Float(bitPattern: UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24)
                case (1, 8): acc += (Float(b[o]) - 128) / 128
                default: throw WAVError.unsupported("format \(f.tag) \(f.bits)-bit")
                }
            }
            out[i] = acc / Float(f.ch)
        }
        return out
    }

    /// Linear resample; fine for speech into Whisper.
    public static func resample(_ x: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !x.isEmpty, from > 0 else { return x }
        let n = Int((Double(x.count) * Double(to) / Double(from)).rounded(.down))
        let step = Double(from) / Double(to)
        return (0..<n).map { i in
            let pos = Double(i) * step
            let j = Int(pos), frac = Float(pos - Double(j))
            let a = x[min(j, x.count - 1)], c = x[min(j + 1, x.count - 1)]
            return a + (c - a) * frac
        }
    }

    /// 16 kHz mono Int16, same as Superwhisper's output.wav.
    public static func encode(_ samples: [Float]) -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        d.append(pcm16(samples))
        return d
    }

    /// Header for a file whose length is not known yet (a recording in progress). Both sizes say "to the
    /// end of the file", which `decode` honours, so a file cut short by a crash still reads back whole.
    public static func streamingHeader() -> Data {
        var d = encode([])
        d.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        d.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        return d
    }

    public static func pcm16(_ samples: [Float]) -> Data {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { out[i] = Int16(max(-1, min(1, samples[i])) * 32767).littleEndian }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func write(_ samples: [Float], to url: URL) throws { try encode(samples).write(to: url, options: .atomic) }
}

/// Writes a recording to disk as it is captured, so nothing said is lost to a crash, a quit or a failed
/// transcription. Appends happen on its own queue, never on the audio thread.
public final class WAVStream: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "whisperer.wavstream")
    private var dataBytes: UInt64 = 0
    private var closed = false

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WAV.streamingHeader().write(to: url)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard !self.closed else { return }
            let d = WAV.pcm16(samples)
            try? self.handle.write(contentsOf: d)
            self.dataBytes += UInt64(d.count)
        }
    }

    /// Writes the real sizes into the header and closes. Waits for queued appends.
    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            let data = UInt32(min(dataBytes, UInt64(UInt32.max - 36)))
            var riff = (36 + data).littleEndian, size = data.littleEndian
            try? handle.seek(toOffset: 4); try? handle.write(contentsOf: Data(bytes: &riff, count: 4))
            try? handle.seek(toOffset: 40); try? handle.write(contentsOf: Data(bytes: &size, count: 4))
            try? handle.close()
        }
    }
}

public enum AudioLevel {
    /// RMS over the whole buffer.
    public static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(x.count)).squareRoot()
    }

    /// Quiet mics come through at a fraction of full scale; lift the peak toward 0.9 (at most 8x gain).
    public static func normalize(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0.0001, peak < 0.5 else { return x }
        let gain = min(8, 0.9 / peak)
        return x.map { $0 * gain }
    }

    /// Loudest 30 ms window (RMS).
    public static func peakWindowRMS(_ x: [Float]) -> Float {
        let win = 480
        var best: Float = 0, i = 0
        while i + win <= x.count { best = max(best, rms(x[i..<i+win])); i += win }
        return best
    }

    /// True when some 30 ms window is loud enough to plausibly be speech. Tuned on Matty's own mic:
    /// real speech never peaked below 0.0106, true silence sat at 0.0037-0.0045.
    /// Sample index where the first 30 ms window loud enough to be speech starts (nil = none).
    public static func firstVoice(_ x: [Float], threshold: Float = 0.005) -> Int? {
        let win = 480
        var i = 0
        while i + win <= x.count {
            if rms(x[i..<i + win]) >= threshold { return i }
            i += win
        }
        return nil
    }

    public static func hasVoice(_ x: [Float], threshold: Float = 0.005) -> Bool {
        let win = 480
        guard x.count >= win else { return false }
        var i = 0
        while i + win <= x.count {
            if rms(x[i..<i+win]) >= threshold { return true }
            i += win
        }
        return false
    }
}
