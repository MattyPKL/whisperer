import AppKit
import SwiftUI
import WhispererCore

/// `Whisperer --render-pill <dir> [recording.wav]`: draws every pill state, plus a 2 s frame sequence of
/// the live waveform driven by a real recording, to PNGs. Never starts the app or touches ~/Whisperer.
@MainActor
enum PillRender {
    static func run(dir: URL, wav: URL?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var samples: [Float] = wav.flatMap { try? WAV.read($0) } ?? []
        if samples.isEmpty {
            samples = (0..<64_000).map { (i: Int) -> Float in
                let carrier = sin(Double(i) / 9)
                let envelope = abs(sin(Double(i) / 4_000))
                return Float(carrier * envelope * 0.03)
            }
        }
        let windows = stride(from: 0, to: samples.count, by: 320).map { AudioLevel.rms(samples[$0..<min(samples.count, $0 + 320)]) }
        let meter = LiveMeter()
        meter.externallyDriven = true
        meter.reset()
        var pushed = 0
        // Mic chunks arrive every 100 ms (5 windows); the display runs at 60 fps.
        func drive(from a: Double, to b: Double, frame: ((Int) -> Void)? = nil) {
            var t = a, n = 0
            while t < b {
                let upto = min(windows.count, (Int(t * 10) + 1) * 5)
                if upto > pushed { meter.push(Array(windows[pushed..<upto])); pushed = upto }
                meter.advance(to: 1000 + t)
                frame?(n); n += 1
                t += 1.0 / 60
            }
        }
        drive(from: 0, to: 2.0)
        meter.startedAt = Date().addingTimeInterval(-42)

        func cap(_ phase: Phase, mini: Bool, preparing: Bool = false, progress: Int? = nil) -> PillCapsule {
            PillCapsule(phase: phase, mini: mini, meter: meter, presented: true, preparing: preparing, progress: progress, limitMinutes: 30)
        }
        let states: [(String, PillCapsule)] = [
            ("classic-listening", cap(.listening(.toggle), mini: false)),
            ("classic-locked", cap(.listening(.locked), mini: false)),
            ("classic-transcribing", cap(.transcribing, mini: false)),
            ("classic-transcribing-long", cap(.transcribing, mini: false, progress: 42)),
            ("classic-preparing", cap(.transcribing, mini: false, preparing: true)),
            ("classic-copied", cap(.notice("Copied. Allow Accessibility to paste"), mini: false)),
            ("classic-recovered", cap(.notice("Recovered an unfinished recording"), mini: false)),
            ("mini-listening", cap(.listening(.toggle), mini: true)),
            ("mini-locked", cap(.listening(.locked), mini: true)),
            ("mini-transcribing", cap(.transcribing, mini: true)),
            ("mini-notice", cap(.notice("Copied"), mini: true)),
        ]
        for (name, v) in states {
            save(v, to: dir.appendingPathComponent("\(name).png"))
        }
        // Final-minute countdown.
        meter.startedAt = Date().addingTimeInterval(-(30 * 60 - 42))
        save(cap(.listening(.toggle), mini: false), to: dir.appendingPathComponent("classic-countdown.png"))
        save(cap(.listening(.toggle), mini: true), to: dir.appendingPathComponent("mini-countdown.png"))
        meter.startedAt = Date().addingTimeInterval(-42)

        // Live sequence from the recording: 2 s of frames at 30 fps (every other display frame).
        let seq = dir.appendingPathComponent("sequence")
        try? FileManager.default.createDirectory(at: seq, withIntermediateDirectories: true)
        drive(from: 2.0, to: 4.0) { n in
            guard n % 2 == 0 else { return }
            save(cap(.listening(.toggle), mini: false), to: seq.appendingPathComponent(String(format: "f%03d.png", n / 2)))
        }
        print("rendered \(states.count + 2) states and a sequence to \(dir.path)")
    }

    static func save<V: View>(_ v: V, to url: URL) {
        // Drawn over a desktop-like backdrop so the shadow and edge read as they will on screen.
        let framed = ZStack {
            LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)], startPoint: .top, endPoint: .bottom)
            v
        }.frame(width: PillController.panelSize.width, height: PillController.panelSize.height)
        let r = ImageRenderer(content: framed)
        r.scale = 2
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
