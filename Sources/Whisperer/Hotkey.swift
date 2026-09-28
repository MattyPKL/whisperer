import AppKit
import WhispererCore

/// Global keyboard watcher (CGEventTap). Needs Accessibility permission.
/// Feeds trigger presses to the TapDetector, swallows Esc while recording and Opt+Shift+K (mode switch).
final class HotkeyMonitor {
    var trigger: TriggerKey = .rightOption
    var onTrigger: (TapDetector.Event) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onModeCycle: () -> Void = {}
    var isListening: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Device-specific modifier bits, so left and right keys can be told apart.
    static func mask(for keyCode: Int64) -> UInt64 {
        switch keyCode {
        case 58: return 0x20          // left option
        case 61: return 0x40          // right option
        case 54: return 0x10          // right command
        case 63: return CGEventFlags.maskSecondaryFn.rawValue
        default: return 0
        }
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; triggerDown = false
    }

    /// Event time on the same clock as ProcessInfo.systemUptime (both count from boot, excluding sleep).
    private func time(_ e: CGEvent) -> TimeInterval {
        e.timestamp > 0 ? TimeInterval(e.timestamp) / 1_000_000_000 : ProcessInfo.processInfo.systemUptime
    }

    /// The tap holds the whole system keyboard stream until it returns, so real work runs on the next
    /// main-loop turn, never inside the callback.
    private func emit(_ e: TapDetector.Event) {
        DispatchQueue.main.async { [weak self] in self?.onTrigger(e) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if trigger.keyCodes.contains(code) {
                let raw = event.flags.rawValue
                let down = trigger.keyCodes.contains { raw & HotkeyMonitor.mask(for: $0) != 0 }
                if down && !triggerDown { triggerDown = true; emit(.triggerDown(time(event))) }
                else if !down && triggerDown { triggerDown = false; emit(.triggerUp(time(event))) }
            } else if triggerDown {
                emit(.otherKey)                // Shift/Cmd/Ctrl joined the trigger: a shortcut, not dictation
            }
            return pass
        case .keyDown:
            if triggerDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { emit(.otherKey) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let f = event.flags
            if code == 53, isListening() { DispatchQueue.main.async { [weak self] in self?.onEscape() }; return nil }
            if code == 40, f.contains(.maskAlternate), f.contains(.maskShift),
               !f.contains(.maskCommand), !f.contains(.maskControl) {
                DispatchQueue.main.async { [weak self] in self?.onModeCycle() }
                return nil
            }
            return pass
        default:
            if triggerDown { emit(.otherKey) }   // Option-click etc.
            return pass
        }
    }
}
