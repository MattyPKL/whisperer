import AppKit
import SwiftUI
import WhispererCore

/// Floating recording window. Non-activating, so the app you are typing in keeps focus. Clicks on the
/// transparent margin fall through to the app underneath; the capsule itself can be dragged anywhere.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var onDragEnd: (() -> Void)?

    /// Drag the capsule by hand (the panel never becomes key, so AppKit's own window drag is not used).
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown else { return super.sendEvent(event) }
        let start = NSEvent.mouseLocation, origin = frame.origin
        var moved = false
        while let e = nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true),
              e.type == .leftMouseDragged {
            let now = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
            moved = true
        }
        if moved { onDragEnd?() }
    }
}

/// The capsule morphs inside a fixed transparent panel (room for its widest state and its shadow), so the
/// window never resizes mid-animation.
@MainActor
final class PillController {
    private let model: AppModel
    private var panel: PillPanel?
    static let panelSize = NSSize(width: 480, height: 110)
    /// Gap between the panel's bottom edge and the capsule's (room for the capsule's shadow).
    static let capsuleInset: CGFloat = 18

    init(model: AppModel) { self.model = model }

    func show() {
        guard model.settings.recordingWindow != "none" else { return }
        // A hidden panel is rebuilt on every show. macOS can quietly pin a long-lived hidden window to one
        // desktop (seen live 2026-09-30: the pill stuck to Desktop 1 after a day up), and a fresh window
        // always joins every desktop, including full-screen apps.
        if let old = panel, !old.isVisible { old.close(); panel = nil }
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible {
            let mouse = NSEvent.mouseLocation
            place(p, on: NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
        }
        // Always animate back to full: show() can land mid-way through a hide fade.
        if !p.isVisible { p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        if !model.pillPresented { withAnimation(PillStyle.spring) { model.pillPresented = true } }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.pillPresented = false }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }) {
            Task { @MainActor in if self.model.phase == .idle { p.orderOut(nil) } }
        }
    }

    /// The saved spot (or bottom centre) on `screen`, pulled back on-screen if it would fall off.
    private func place(_ p: PillPanel, on screen: NSScreen?) {
        guard let vf = screen?.visibleFrame else { return }
        let a = PillPlacement.anchor(model.settings.pillPosition, in: vf)
        p.setFrameOrigin(NSPoint(x: a.x - Self.panelSize.width / 2, y: a.y - Self.capsuleInset))
    }

    /// Remember where the capsule was dropped, on whichever screen it landed.
    private func saveDrop(_ p: PillPanel) {
        let a = NSPoint(x: p.frame.midX, y: p.frame.minY + Self.capsuleInset)
        let screen = NSScreen.screens.first { NSMouseInRect(a, $0.frame, false) } ?? p.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        model.settings.pillPosition = PillPlacement.fractions(a, in: vf)
        place(p, on: screen)
    }

    func resetPosition() { model.settings.pillPosition = [] }

    private func makePanel() -> PillPanel {
        let p = PillPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false   // ARC owns it; close() must not free it a second time
        p.onDragEnd = { [weak self, weak p] in if let self, let p { self.saveDrop(p) } }
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false            // the capsule draws its own; a window shadow would trail the morph
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = NSHostingView(rootView: PillView().environmentObject(model))
        return p
    }
}

enum PillStyle {
    /// The Dynamic Island spring from the design library (cult-ui dynamic-island: stiffness 400, damping 30).
    static let spring = Animation.interpolatingSpring(stiffness: 400, damping: 30)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
}

struct PillView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PillCapsule(phase: model.phase, mini: model.settings.recordingWindow == "mini", meter: model.meter,
                    presented: model.pillPresented, preparing: model.preparingModel, progress: model.transcribeProgress,
                    limitMinutes: model.settings.maxRecordingMinutes)
    }
}

/// Everything the pill draws, from plain values (so `--render-pill` can draw it without the live app).
struct PillCapsule: View {
    let phase: Phase
    let mini: Bool
    let meter: LiveMeter
    let presented: Bool
    let preparing: Bool
    let progress: Int?
    let limitMinutes: Double
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if phase != .idle {
                capsule
                    .scaleEffect(presented || reduceMotion ? 1 : 0.9, anchor: .bottom)
                    .padding(.bottom, PillController.capsuleInset)
            }
        }
        .frame(width: PillController.panelSize.width, height: PillController.panelSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var height: CGFloat { mini ? 40 : 54 }

    /// Fixed widths for the recording states; nil lets text states size to their words (never truncated).
    private var width: CGFloat? {
        switch phase {
        case .listening: return mini ? 176 : 272
        case .transcribing:
            if preparing { return nil }
            return mini ? 120 : (progress != nil ? 214 : 190)
        default: return nil
        }
    }

    private var capsule: some View {
        content
            .padding(.horizontal, mini ? 16 : 20)
            .frame(width: width, height: height)
            .background {
                let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                shape.fill(Color(white: 0.035))
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : PillStyle.spring, value: stateKey)
    }

    /// Changes whenever the capsule's shape or content should morph.
    private var stateKey: String {
        switch phase {
        case .idle: return "idle"
        case .listening(let s): return "listening-\(s)"
        case .transcribing: return "transcribing-\(preparing)-\(progress != nil)"
        case .notice(let t): return "notice-\(t)"
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch phase {
            case .listening(let style):
                ListeningContent(meter: meter, style: style, mini: mini, limitMinutes: limitMinutes)
                    .transition(.blurFade)
            case .transcribing:
                TranscribingContent(meter: meter, mini: mini, preparing: preparing, progress: progress)
                    .transition(.blurFade)
            case .notice(let text):
                NoticeContent(text: text, mini: mini).id(text).transition(.blurFade)
            case .idle:
                EmptyView()
            }
        }
    }
}

// MARK: states

struct ListeningContent: View {
    let meter: LiveMeter
    let style: TapDetector.Style
    let mini: Bool
    let limitMinutes: Double

    var body: some View {
        HStack(spacing: mini ? 10 : 14) {
            StateGlyph(style: style, mini: mini)
            Waveform(meter: meter, mode: .live, barWidth: mini ? 2.6 : 3)
                .frame(height: mini ? 22 : 28)
            ElapsedLabel(meter: meter, limitMinutes: limitMinutes, mini: mini)
        }
    }
}

struct TranscribingContent: View {
    let meter: LiveMeter
    let mini: Bool
    let preparing: Bool
    let progress: Int?

    var body: some View {
        if preparing {
            Label("Preparing voice model, first run only", systemImage: "cpu")
                .font(.system(size: mini ? 12 : 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        } else {
            HStack(spacing: 12) {
                Waveform(meter: meter, mode: .thinking, barWidth: mini ? 2.6 : 3)
                    .frame(height: mini ? 18 : 22)
                if let progress, !mini {
                    Text("\(progress)%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 38, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

struct NoticeContent: View {
    let text: String
    let mini: Bool

    private var icon: (String, Color) {
        let t = text.lowercased()
        if t.hasPrefix("copied") { return ("doc.on.doc.fill", .white.opacity(0.8)) }
        if t.hasPrefix("no voice found") { return ("mic.slash.fill", .white.opacity(0.6)) }
        if t.hasPrefix("mode:") { return ("square.stack.fill", .white.opacity(0.8)) }
        if t.hasPrefix("recovered") { return ("clock.arrow.circlepath", PillStyle.amber) }
        if t.contains("fail") || t.contains("unavailable") || t.hasPrefix("no voice model") { return ("exclamationmark.triangle.fill", PillStyle.amber) }
        return ("info.circle.fill", .white.opacity(0.7))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.0).foregroundStyle(icon.1).font(.system(size: mini ? 11 : 12, weight: .semibold))
            Text(text).font(.system(size: mini ? 12 : 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Red recording dot; a lock once double-tapped into hands-free; a loud label when the test switch is on.
struct StateGlyph: View {
    let style: TapDetector.Style
    let mini: Bool

    var body: some View {
        if Recorder.lastRecordingWasTestAudio {
            // Never let the test hook pass for a real microphone (2026-09-28 mistake report).
            Text(mini ? "TEST" : "TEST AUDIO").font(.system(size: 9, weight: .heavy)).foregroundStyle(PillStyle.amber).fixedSize()
        } else if style == .locked {
            Image(systemName: "lock.fill").font(.system(size: mini ? 9 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9)).transition(.blurFade)
        } else {
            RecordingDot(size: mini ? 7 : 9)
        }
    }
}

struct RecordingDot: View {
    let size: CGFloat
    @State private var on = false
    var body: some View {
        Circle().fill(PillStyle.red).frame(width: size, height: size)
            .shadow(color: PillStyle.red.opacity(on ? 0.7 : 0.2), radius: on ? 5 : 2)
            .opacity(on ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Elapsed time; in the final minute before the length limit it turns amber and counts down.
struct ElapsedLabel: View {
    @ObservedObject var meter: LiveMeter
    let limitMinutes: Double
    let mini: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(meter.startedAt)))
            let left = Int(min(240, max(1, limitMinutes)) * 60) - s
            if left <= 60 {
                Text("\(max(0, left))s left")
                    .font(.system(size: mini ? 11 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PillStyle.amber).fixedSize()
            } else if !mini {
                Text(String(format: "%d:%02d", s / 60, s % 60))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: waveform

/// Mirrored bar field drawn every display frame. Live: the newest level sits in the centre and older ones
/// ripple outwards, so the middle reacts the instant you speak. Thinking: a soft travelling wave.
struct Waveform: View {
    enum Mode { case live, thinking }
    let meter: LiveMeter
    let mode: Mode
    let barWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                if mode == .live, !meter.externallyDriven { meter.advance(to: t) }
                let gap = barWidth * 0.9
                var count = Int((size.width + gap) / (barWidth + gap))
                if count % 2 == 0 { count -= 1 }
                guard count > 0 else { return }
                let half = count / 2
                let used = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
                let x0 = (size.width - used) / 2
                let bars = meter.bars
                for i in 0..<count {
                    let d = abs(i - half)
                    let r = half == 0 ? 0 : Double(d) / Double(half)
                    let v: Double
                    let alpha: Double
                    switch mode {
                    case .live:
                        let raw = Double(bars[min(d, bars.count - 1)])
                        v = raw * (1 - 0.45 * r * r)
                        alpha = 0.4 + 0.6 * (1 - pow(r, 1.6))
                    case .thinking:
                        let tt = meter.externallyDriven ? meter.clock : t
                        v = 0.16 + 0.26 * (0.5 + 0.5 * sin(tt * 5.2 - Double(i) * 0.5)) * (1 - 0.5 * r * r)
                        alpha = 0.35 + 0.35 * (1 - r)
                    }
                    let h = max(barWidth, CGFloat(v) * size.height)
                    let rect = CGRect(x: x0 + CGFloat(i) * (barWidth + gap), y: (size.height - h) / 2, width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

// MARK: transitions

/// Content swap: fade with a slight scale and blur, so two states read as one shape changing.
private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.blur(radius: active ? 6 : 0).opacity(active ? 0 : 1).scaleEffect(active ? 0.95 : 1)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition { .modifier(active: BlurFade(active: true), identity: BlurFade(active: false)) }
}
