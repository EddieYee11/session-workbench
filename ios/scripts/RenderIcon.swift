import Foundation
import CoreGraphics
import ImageIO
import CoreImage

// Reuse the Android adaptive icon viewport: 18/108 inset on every side.
// This is the existing close-up composition, not newly generated artwork.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let source = URL(fileURLWithPath: CommandLine.arguments[2])
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Missing Android companion artwork") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ name: String, dark: Bool, tinted: Bool) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot create icon canvas") }
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.setFillColor(CGColor(red: dark ? 0.075 : 247.0/255, green: dark ? 0.075 : 247.0/255, blue: dark ? 0.075 : 249.0/255, alpha: 1))
    context.fill(rect)
    context.interpolationQuality = .high
    let viewport = CGRect(x: CGFloat(artwork.width) / 6, y: CGFloat(artwork.height) / 6,
                          width: CGFloat(artwork.width) * 2 / 3, height: CGFloat(artwork.height) * 2 / 3)
    guard let closeUp = artwork.cropping(to: viewport) else { fatalError("Invalid adaptive viewport") }
    context.draw(closeUp, in: rect)
    if tinted, let original = context.makeImage() {
        let monochrome = CIImage(cgImage: original).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        if let gray = CIContext().createCGImage(monochrome, from: rect) { context.draw(gray, in: rect) }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { fatalError("Cannot export icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon") }
}
try render("Com.png", dark: false, tinted: false)
try render("Com-dark.png", dark: true, tinted: false)
try render("Com-tinted.png", dark: false, tinted: true)
