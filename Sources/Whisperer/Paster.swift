import AppKit

/// Puts text where the cursor is: clipboard + Cmd+V, then puts back what was on the clipboard.
enum Paster {
    static func deliver(_ text: String, paste: Bool, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let saved = (paste && restoreClipboard) ? snapshot(pb) : nil   // nil also when too large to keep
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard paste else { return }
        let ours = pb.changeCount
        postCommandV()
        guard let saved else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Only restore if nobody copied anything since our paste.
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    /// Copies the clipboard so it can be put back. Gives up (returns nil, nothing is restored) past 25 MB,
    /// so a Premiere or Photoshop clipboard never stalls a paste.
    static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        var total = 0
        var out: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for t in item.types {
                guard let d = item.data(forType: t) else { continue }
                total += d.count
                if total > 25_000_000 { return nil }
                copy.setData(d, forType: t)
            }
            out.append(copy)
        }
        return out
    }

    static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
