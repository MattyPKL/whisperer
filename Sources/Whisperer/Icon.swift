import AppKit

/// Draws the app icon (waveform on a violet squircle) into an .iconset folder for iconutil.
enum IconRenderer {
    static func renderIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                if let png = draw(px) { try? png.write(to: dir.appendingPathComponent(name)) }
            }
        }
    }

    static func draw(_ px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        let inset = s * 0.1
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(colors: [NSColor(red: 0.42, green: 0.30, blue: 0.95, alpha: 1),
                            NSColor(red: 0.13, green: 0.10, blue: 0.30, alpha: 1)])?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.95).setFill()
        let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.36, 0.52, 0.28, 0.16]
        let barW = rect.width * 0.07, gap = rect.width * 0.045
        let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        var x = rect.midX - total / 2
        for h in heights {
            let bh = rect.height * h
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
