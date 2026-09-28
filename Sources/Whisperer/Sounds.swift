import AppKit

enum Sounds {
    enum Cue { case start, stop, cancel, done }

    static func play(_ cue: Cue, style: String, volume: Double) {
        guard style != "off" else { return }
        let name: String
        switch (style, cue) {
        case ("simple", .cancel): name = "Funk"
        case ("simple", _): name = "Tink"
        case (_, .start): name = "Pop"
        case (_, .stop): name = "Bottle"
        case (_, .cancel): name = "Funk"
        case (_, .done): name = "Tink"
        }
        guard let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = Float(volume)
        s.play()
    }
}
