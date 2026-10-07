import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ name: String, dark: Bool, tinted: Bool) throws {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let bg = dark ? NSColor(calibratedWhite: 0.075, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
    bg.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    let coral = tinted ? NSColor(calibratedWhite: dark ? 0.8 : 0.38, alpha: 1) : NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.34, alpha: 1)
    func round(_ r: NSRect, _ radius: CGFloat, _ color: NSColor) { color.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
    func ellipse(_ r: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(ovalIn: r).fill() }
    if !tinted {
        let violet = NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.94, alpha: dark ? 0.2 : 0.10)
        ellipse(NSRect(x: 140, y: 85, width: 740, height: 220), violet)
        NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.88, alpha: dark ? 0.3 : 0.13).setStroke()
        let orbit = NSBezierPath(ovalIn: NSRect(x: 116, y: 110, width: 792, height: 792)); orbit.lineWidth = 3; orbit.stroke()
    }
    for side in [-1.0, 1.0] {
        let center = 512 + side * 255
        for i in 0..<3 {
            let leg = NSBezierPath(); leg.move(to: CGPoint(x: 512 + side * 198, y: 400 + Double(i) * 30)); leg.line(to: CGPoint(x: 512 + side * (290 + Double(i) * 16), y: 310 + Double(i) * 75)); leg.lineWidth = 33; leg.lineCapStyle = .round; coral.setStroke(); leg.stroke()
        }
        round(NSRect(x: center - 31, y: 530, width: 62, height: 155), 30, coral)
        ellipse(NSRect(x: center - 79, y: 640, width: 158, height: 150), coral)
        let cut = NSBezierPath(); cut.move(to: CGPoint(x: center, y: 810)); cut.line(to: CGPoint(x: center + side * 30, y: 710)); cut.lineWidth = 18; cut.lineCapStyle = .round; bg.setStroke(); cut.stroke()
    }
    let body = NSBezierPath(roundedRect: NSRect(x: 250, y: 305, width: 524, height: 365), xRadius: 156, yRadius: 156)
    let shadow = NSShadow(); shadow.shadowColor = coral.withAlphaComponent(0.22); shadow.shadowBlurRadius = 35; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
    NSGradient(starting: coral.blended(withFraction: 0.22, of: .white)!, ending: coral.blended(withFraction: 0.23, of: .black)!)!.draw(in: body, angle: -60)
    NSShadow().set()
    ellipse(NSRect(x: 342, y: 610, width: 260, height: 28), .white.withAlphaComponent(0.18))
    for x in [394.0, 550.0] {
        round(NSRect(x: x, y: 464, width: 82, height: 116), 40, .white)
        round(NSRect(x: x + 26, y: 485, width: 32, height: 61), 16, NSColor(calibratedWhite: 0.10, alpha: 1))
        ellipse(NSRect(x: x + 28, y: 527, width: 12, height: 12), .white)
    }
    round(NSRect(x: 490, y: 411, width: 46, height: 12), 6, NSColor(calibratedWhite: 0.15, alpha: 0.75))
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
try render("Com.png", dark: false, tinted: false)
try render("Com-dark.png", dark: true, tinted: false)
try render("Com-tinted.png", dark: false, tinted: true)
