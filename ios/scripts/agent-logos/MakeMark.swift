import Foundation
import CoreGraphics
import ImageIO
// usage: mark <in> <out> <mode: alpha|dark|light> <size> <marginFraction>
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var mask = [Double](repeating: 0, count: w * h)
var minX = w, minY = h, maxX = 0, maxY = 0
for i in 0..<(w * h) {
    let al = Double(px[i*4+3]) / 255
    let lum = al > 0 ? (0.299 * Double(px[i*4]) + 0.587 * Double(px[i*4+1]) + 0.114 * Double(px[i*4+2])) / 255 / al : 0
    var m: Double
    switch a[3] { case "dark": m = al * max(0, min(1, (1 - lum) * 1.15)); case "ink": let mn = al > 0 ? Double(min(px[i*4], px[i*4+1], px[i*4+2])) / 255 / al : 1; m = al * max(0, min(1, (1 - mn) * 1.6)); case "light": m = al * max(0, min(1, (lum - 0.1) * 1.2)); default: m = al }
    if m < 0.04 { m = 0 }
    mask[i] = m
    if m > 0.2 { let x = i % w, y = i / w; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}
let size = Int(a[4])!, margin = Double(a[5])!
let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
let side = max(bw, bh) / (1 - 2 * margin)
let ox = Double(minX) - (side - bw) / 2, oy = Double(minY) - (side - bh) / 2
var out = [UInt8](repeating: 0, count: size * size * 4)
// box-filter downsample
let scale = side / Double(size)
for y in 0..<size { for x in 0..<size {
    var s = 0.0, n = 0.0
    let x0 = ox + Double(x) * scale, y0 = oy + Double(y) * scale
    let steps = max(1, Int(scale.rounded(.up)))
    for j in 0..<steps { for k in 0..<steps {
        let sx = Int(x0 + (Double(k) + 0.5) * scale / Double(steps)), sy = Int(y0 + (Double(j) + 0.5) * scale / Double(steps))
        n += 1; if sx >= 0 && sy >= 0 && sx < w && sy < h { s += mask[sy * w + sx] }
    } }
    out[(y * size + x) * 4 + 3] = UInt8(max(0, min(255, s / n * 255)))
} }
let octx = CGContext(data: &out, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, octx.makeImage()!, nil); CGImageDestinationFinalize(dst)
print(a[2], minX, minY, maxX, maxY)
