import Foundation

/// Turns raw trigger-key events into recording actions. Pure: no timers, no AppKit.
///
/// - Clean tap (press + release, no other key, shorter than `holdThreshold`) = toggle recording.
/// - Clean hold (still down after `holdThreshold`) = push-to-talk, release stops.
/// - Double tap (a second press within `doubleTapWindow` of the tap that started recording) = hands-free
///   lock: recording carries on and the next single tap stops it. A stop that quick is never meant as a
///   stop (it would keep under half a second of audio), so it can only mean "lock".
/// - Any other key while the trigger is down (before or during push-to-talk) = a chord (Opt+arrow etc.),
///   so the capture is thrown away and nothing is transcribed.
///
/// Audio starts provisionally on key-down so the first word is never lost; the pill only shows
/// once the press is confirmed.
public struct TapDetector {
    public enum Event: Equatable {
        case triggerDown(TimeInterval)
        case triggerUp(TimeInterval)
        case otherKey
        case holdTimer(TimeInterval)
        case reset
    }

    public enum Style: Equatable { case toggle, pushToTalk, locked }

    public enum Action: Equatable {
        case startProvisional
        case confirm(Style)
        case abortProvisional
        case stop
        case lock
    }

    public enum State: Equatable {
        case idle
        case armed(down: TimeInterval)
        case chordWaitingUp
        case holding
        case recording
        case stopPress(chord: Bool)
        case lockPress
    }

    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval = 0.4
    public private(set) var state: State = .idle
    /// When the tap that started the current toggle recording was released (-inf when started elsewhere).
    private var confirmedAt: TimeInterval = -.infinity
    private var lockDownAt: TimeInterval = 0

    public init(holdThreshold: TimeInterval = 0.35) { self.holdThreshold = holdThreshold }

    /// Recording was started from outside the key (menu bar, notification): the next clean tap stops it.
    public mutating func recordingStartedExternally() { state = .recording; confirmedAt = -.infinity }

    public mutating func handle(_ event: Event) -> Action? {
        switch (state, event) {
        case (_, .reset):
            state = .idle
            return nil

        case (.idle, .triggerDown):
            if case .triggerDown(let t) = event { state = .armed(down: t) }
            return .startProvisional

        case (.armed, .otherKey):
            state = .chordWaitingUp
            return .abortProvisional
        case (.armed(let down), .holdTimer(let t)):
            guard t - down >= holdThreshold else { return nil }
            state = .holding
            return .confirm(.pushToTalk)
        case (.armed(let down), .triggerUp(let t)):
            if t - down < holdThreshold {
                state = .recording
                confirmedAt = t
                return .confirm(.toggle)
            }
            // Held past the threshold but the timer never fired: it was a push-to-talk press.
            state = .idle
            return .stop

        case (.chordWaitingUp, .triggerUp):
            state = .idle
            return nil

        case (.holding, .otherKey):
            // Held the key, then typed (slow Opt+arrow, Opt+3 for "#"): a shortcut, not dictation.
            state = .chordWaitingUp
            return .abortProvisional
        case (.holding, .triggerUp):
            state = .idle
            return .stop

        case (.recording, .triggerDown(let t)):
            if t - confirmedAt < doubleTapWindow { state = .lockPress; lockDownAt = t; return nil }
            state = .stopPress(chord: false)
            return nil

        case (.lockPress, .triggerUp(let t)):
            if t - lockDownAt >= holdThreshold {
                // Tapped, then pressed and HELD: a deliberate stop press, never a lock.
                state = .idle
                return .stop
            }
            state = .recording
            confirmedAt = -.infinity
            return .lock
        case (.lockPress, .otherKey):
            state = .stopPress(chord: true)   // released as a chord: keep recording, no lock
            return nil

        case (.stopPress, .otherKey):
            state = .stopPress(chord: true)
            return nil
        case (.stopPress(let chord), .triggerUp):
            if chord { state = .recording; return nil }
            state = .idle
            return .stop

        default:
            return nil
        }
    }
}
