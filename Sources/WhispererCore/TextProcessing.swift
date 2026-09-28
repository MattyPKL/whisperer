import Foundation

public struct Replacement: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var original: String
    public var with: String
    enum CodingKeys: String, CodingKey { case id, original, with }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        original = try c.decodeIfPresent(String.self, forKey: .original) ?? ""
        with = try c.decodeIfPresent(String.self, forKey: .with) ?? ""
    }

    public init(id: String = UUID().uuidString, original: String, with: String) {
        self.id = id; self.original = original; self.with = with
    }
}

public enum TextProcessing {
    /// Tokens whisper emits for non-speech ("[BLANK_AUDIO]", "(music)", "[ Silence ]").
    /// Square brackets are always non-speech; round brackets only when they hold a known sound tag,
    /// so a spoken "(for example)" survives.
    static let nonSpeech = try! NSRegularExpression(
        pattern: #"\s*(\[[^\]]{0,40}\]|\*[^*]{1,40}\*|\((?:music|silence|applause|laughs?|laughter|inaudible|blank[ _]audio|sighs?|coughs?|background noise|noise|beeps?|static|wind|clears throat|breathing)\))\s*"#,
        options: [.caseInsensitive])

    /// Whisper's full post-pass: strip non-speech tags, collapse whitespace, apply replacements, capitalise.
    public static func finalize(_ raw: String, replacements: [Replacement], autocapitalize: Bool) -> String {
        var s = raw
        let r = NSRange(s.startIndex..., in: s)
        s = nonSpeech.stringByReplacingMatches(in: s, range: r, withTemplate: " ")
        s = applyReplacements(s, replacements)
        // Tidy after replacements, so a replacement to "" leaves no double or leading space.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if autocapitalize, let first = s.first, first.isLowercase {
            let second = s.dropFirst().first
            let upper = first.uppercased()
            // Leave "iPhone" alone, and skip letters that uppercase to two ("ß" -> "SS").
            if !(second?.isUppercase ?? false), upper.count == 1 { s = upper + s.dropFirst() }
        }
        return s
    }

    /// Case-insensitive, whole-word replacement. Longer originals run first so "super whisper app"
    /// wins over "super whisper".
    public static func applyReplacements(_ text: String, _ list: [Replacement]) -> String {
        var s = text
        for rep in list.sorted(by: { $0.original.count > $1.original.count }) {
            let orig = rep.original.trimmingCharacters(in: .whitespaces)
            guard !orig.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: orig)
            // \b only works next to word characters; fall back to whitespace/edge lookarounds otherwise.
            let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let tmpl = NSRegularExpression.escapedTemplate(for: rep.with)
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
        }
        return s
    }

    /// Whisper's initial prompt: vocabulary as a natural sentence nudges spelling of names.
    public static func prompt(vocabulary: [String]) -> String {
        let words = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return words.isEmpty ? "" : words.joined(separator: ", ") + "."
    }

    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Whisper invents text on silence and noise. Seen on Matty's own recordings: "Don't forget to subscribe to
/// our channel for more videos.", "Thank you.", "And...", a lone comma, and the vocabulary prompt echoed back.
public enum SpeechFilter {
    static let phrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you so much", "thanks for watching",
        "thank you for watching", "don't forget to subscribe to our channel for more videos",
        "please subscribe", "subscribe to my channel", "like and subscribe", "you", "and", "bye", "bye bye",
    ]

    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// `peakRMS` = loudest 30 ms window. A stock phrase only counts as invented when the clip was quiet,
    /// so a clearly spoken "Thank you." still comes through.
    public static func isHallucination(_ text: String, vocabulary: [String], peakRMS: Float) -> Bool {
        let n = normalize(text)
        if n.isEmpty { return true }
        if phrases.contains(n) && peakRMS < 0.03 { return true }
        let vocab = Set(vocabulary.map(normalize).filter { !$0.isEmpty })
        let pieces = text.split(whereSeparator: { ",.;".contains($0) }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        // Prompt echoed back: every piece is a vocabulary word. One word said clearly ("Donde.") is kept.
        let echo = !vocab.isEmpty && !pieces.isEmpty && pieces.allSatisfy { vocab.contains($0) }
        return echo && (pieces.count >= 2 || peakRMS < 0.03)
    }
}
