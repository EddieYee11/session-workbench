import SwiftUI
import AppKit

// 轨道 r2-memory：App 图标 = 顶栏手绘女孩（Views/Character.swift 的 SVG 线稿，120×132 角色坐标）的头像特写。
// 黑色手绘线稿 + 青柠圆点缀 + 纸色留白；三套：浅色 / 深色 / tinted（灰阶）。
// 用法：swift scripts/RenderCharacterIcon.swift Com/Assets.xcassets/AppIcon.appiconset
// 线稿路径与 Character.swift 的 idle 态一致（闭眼微笑），整颗头放进青柠圆里，线宽与 App 内一致，60px 缩略图下五官仍清楚。

enum SVGPath {
    static func parse(_ d: String) -> Path {
        enum Token { case command(Character), number(CGFloat) }
        var tokens: [Token] = []
        var buffer = ""
        func flush() { if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }; buffer = "" }
        for character in d {
            if character.isLetter && character != "e" && character != "E" { flush(); tokens.append(.command(character)) }
            else if character == "-" && !buffer.isEmpty && !buffer.hasSuffix("e") { flush(); buffer = "-" }
            else if character == "." && buffer.contains(".") { flush(); buffer = "." }
            else if character == " " || character == "," || character == "\n" { flush() }
            else { buffer.append(character) }
        }
        flush()
        var path = Path()
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var numbers: [CGFloat] = []
        func arity(_ c: Character) -> Int {
            switch c.uppercased().first! { case "M", "L", "T": 2; case "H", "V": 1; case "Q", "S": 4; case "C": 6; default: 0 }
        }
        func run() {
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased().first! {
            case "M":
                current = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]); start = current; path.move(to: current)
                command = relative ? "l" : "L"
            case "L": current = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]); path.addLine(to: current)
            case "H": current = CGPoint(x: base.x + numbers[0], y: current.y); path.addLine(to: current)
            case "V": current = CGPoint(x: current.x, y: base.y + numbers[0]); path.addLine(to: current)
            case "Q":
                let control = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1])
                current = CGPoint(x: base.x + numbers[2], y: base.y + numbers[3]); path.addQuadCurve(to: current, control: control)
            case "C":
                let a = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]), b = CGPoint(x: base.x + numbers[2], y: base.y + numbers[3])
                current = CGPoint(x: base.x + numbers[4], y: base.y + numbers[5]); path.addCurve(to: current, control1: a, control2: b)
            default: break
            }
            numbers.removeAll(keepingCapacity: true)
        }
        for token in tokens {
            switch token {
            case .command(let c):
                if c == "Z" || c == "z" { path.closeSubpath(); current = start; numbers.removeAll() } else { command = c; numbers.removeAll() }
            case .number(let n):
                numbers.append(n)
                if numbers.count == arity(command) { run() }
            }
        }
        return path
    }
}

let ink = Color(red: 0x1B / 255, green: 0x1C / 255, blue: 0x18 / 255)
let paper = Color.white
let lime = Color(red: 0.82, green: 0.94, blue: 0.38)

struct Icon: View {
    let dark: Bool
    let tinted: Bool
    var body: some View {
        Canvas { ctx, size in
            let bg: Color = tinted ? .black : dark ? Color(red: 0.08, green: 0.08, blue: 0.075) : Color(red: 0xF4 / 255, green: 0xF3 / 255, blue: 0xEF / 255)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            // 青柠圆：头像的「光」，也是深色模式下黑线稿的衬底。
            let disc = CGRect(x: 512 - 404, y: 486 - 404, width: 808, height: 808)
            ctx.fill(Path(ellipseIn: disc), with: .color(tinted ? Color(white: 0.82) : lime))
            var c = ctx
            c.clip(to: Path(CGRect(origin: .zero, size: size)))
            let scale: CGFloat = 5.3
            c.translateBy(x: 512 - 60 * scale, y: 470 - 58 * scale)
            c.scaleBy(x: scale, y: scale)
            let k: CGFloat = 1.0
            func stroke(_ d: String, _ w: CGFloat) { c.stroke(SVGPath.parse(d), with: .color(ink), style: StrokeStyle(lineWidth: w * k, lineCap: .round, lineJoin: .round)) }
            func fill(_ d: String, _ color: Color, _ w: CGFloat = 0) { c.fill(SVGPath.parse(d), with: .color(color)); if w > 0 { stroke(d, w) } }
            // 身体（衣服）：墨色，领口一道青柠。
            fill("M22 200 Q26 106 60 104 Q94 106 98 200 Z", dark && !tinted ? Color(white: 0.24) : ink, 2)
            c.stroke(SVGPath.parse("M50 107 L60 117 L70 107"), with: .color(tinted ? Color(white: 0.9) : lime), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            // 头发后层
            stroke("M30 30 Q10 62 6 112 M27 40 Q14 76 12 120 M33 34 Q18 70 18 118 M31 50 Q22 86 22 124 M35 60 Q28 94 30 122 M24 30 Q4 58 2 96 M36 72 Q32 100 37 120 M90 30 Q110 62 114 112 M93 40 Q106 76 108 120 M87 34 Q102 70 102 118 M89 50 Q98 86 98 124 M85 60 Q92 94 90 122 M96 30 Q116 58 118 96 M84 72 Q88 100 83 120", 3.8)
            // 脸
            fill("M33 54 Q31 99 60 100 Q89 99 87 54 Q80 42 60 42 Q40 42 33 54 Z", paper)
            stroke("M33 62 Q32 99 60 100 Q88 99 87 62", 3.4)
            stroke("M24 54 Q20 10 60 8 Q100 10 96 54", 4)
            // 刘海
            fill("M30 50 Q30 18 60 15 Q90 18 90 50 L85 44 L82 52 L77 42 L73 52 L68 41 L64 53 L59 41 L54 52 L50 42 L45 52 L41 43 L37 51 L34 45 Z", ink, 2)
            stroke("M40 20 L35 50 M80 20 L85 50 M28 30 Q40 14 56 12 M92 30 Q80 14 64 12", 3.4)
            stroke("M52 12 Q46 2 36 2 M66 12 Q72 2 84 4 M58 11 Q58 3 54 -2 M46 14 Q34 6 26 10 M74 14 Q88 6 96 12", 3)
            // 眼镜
            fill("M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z", paper)
            stroke("M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M34 52 L30 47 L38 50 M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z M86 54 L90 49 M57 55 Q60 52 63 55", 3.2)
            // 闭眼笑 + 鼻子 + 嘴
            stroke("M41 60 Q45.5 64 50 60 M70 60 Q74.5 64 79 60", 3)
            stroke("M60 62 L55 75 L61 75", 3)
            stroke("M48 83 Q54 91 62 83", 3.2)
            // 两颊青柠腮红
            if !tinted {
                for x in [40.0, 80.0] { c.fill(Path(ellipseIn: CGRect(x: x - 5, y: 76, width: 10, height: 5)), with: .color(lime.opacity(0.95))) }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func export(_ view: Icon, to url: URL) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    // App 图标不能带 alpha：重画进不透明位图。
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    var image = ctx.makeImage()!
    if view.tinted {
        let gray = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)); image = gray.makeImage()!
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
MainActor.assumeIsolated {
    export(Icon(dark: false, tinted: false), to: dir.appendingPathComponent("Com.png"))
    export(Icon(dark: true, tinted: false), to: dir.appendingPathComponent("Com-dark.png"))
    export(Icon(dark: false, tinted: true), to: dir.appendingPathComponent("Com-tinted.png"))
}
