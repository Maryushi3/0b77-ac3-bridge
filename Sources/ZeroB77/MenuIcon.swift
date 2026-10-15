import AppKit

/// Menu-bar grid: the 0x0B77 sync word as 4x4 EL dots (MSB first, row-major).
/// Idle = template image (dim ghosts, follows the menu-bar theme);
/// streaming = full-color cyan.
enum MenuIcon {
    private static let bits = [
        [0, 0, 0, 0],
        [1, 0, 1, 1],
        [0, 1, 1, 1],
        [0, 1, 1, 1],
    ]

    static func image(streaming: Bool) -> NSImage {
        let pt: CGFloat = 22
        let px = Int(pt * 4) // supersampled backing store
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        let pad = s * 0.12
        let cell = (s - pad * 2) / 4
        for r in 0..<4 {
            for c in 0..<4 {
                let cx = pad + (CGFloat(c) + 0.5) * cell
                let cy = s - (pad + (CGFloat(r) + 0.5) * cell)
                let rad = cell * 0.32
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                if streaming {
                    let a: CGFloat = bits[r][c] == 1 ? 1.0 : 0.25
                    NSColor(red: 0.30, green: 0.91, blue: 1.0, alpha: a).setFill()
                } else {
                    NSColor(white: 1.0, alpha: bits[r][c] == 1 ? 0.85 : 0.30).setFill()
                }
                dot.fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.addRepresentation(rep)
        img.isTemplate = !streaming
        return img
    }
}
