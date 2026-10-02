// Renders the app icon (piano keys + note) into an .iconset, then iconutil builds the .icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.55, alpha: 1),
                        NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.75, alpha: 1)])!.draw(in: bg, angle: 90)
    // Keys
    let keysRect = NSRect(x: 170 * s, y: 170 * s, width: 684 * s, height: 360 * s)
    let w = keysRect.width / 7
    for i in 0..<7 {
        let r = NSRect(x: keysRect.minX + CGFloat(i) * w + 4 * s, y: keysRect.minY, width: w - 8 * s, height: keysRect.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: 18 * s, yRadius: 18 * s).fill()
    }
    for i in [0, 1, 3, 4, 5] {
        let r = NSRect(x: keysRect.minX + CGFloat(i + 1) * w - w * 0.3, y: keysRect.minY + keysRect.height * 0.38, width: w * 0.6, height: keysRect.height * 0.62)
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10 * s, yRadius: 10 * s).fill()
    }
    // Note
    let note = NSAttributedString(string: "♪", attributes: [.font: NSFont.systemFont(ofSize: 330 * s, weight: .bold),
                                                              .foregroundColor: NSColor.white])
    note.draw(at: NSPoint(x: 390 * s, y: 500 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
