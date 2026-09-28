// Draws the app icon (original artwork: an abstract silver ball over two flippers on a dark
// rounded square; no game art) and writes an .iconset directory for `iconutil`.
//
//   swift app/Resources/make_icon.swift OUT.iconset
import AppKit
import CoreGraphics
import Foundation

func drawIcon(size s: CGFloat, into ctx: CGContext) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
    // macOS icon grid: the body is ~80% of the canvas, centred.
    let inset = s * 0.10
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow + background gradient (deep indigo to near black).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.45))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0.05, 0.05, 0.12)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0.16, 0.11, 0.36), color(0.03, 0.04, 0.10)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Motion arcs behind the ball (the ball's path), faint teal.
    ctx.setLineCap(.round)
    for (i, a) in [0.22, 0.14, 0.08].enumerated() {
        ctx.setStrokeColor(color(0.20, 0.85, 0.85, a))
        ctx.setLineWidth(s * (0.018 - CGFloat(i) * 0.004))
        let r = s * (0.30 + CGFloat(i) * 0.06)
        ctx.addArc(center: CGPoint(x: body.midX - s * 0.02, y: body.minY + s * 0.30), radius: r,
                   startAngle: .pi * 0.40, endAngle: .pi * 0.78, clockwise: false)
        ctx.strokePath()
    }

    // Two flippers: rounded capsules angled down towards the centre (teal left, magenta right).
    func flipper(left: Bool, _ c: CGColor) {
        let pivot = CGPoint(x: left ? body.minX + body.width * 0.20 : body.maxX - body.width * 0.20, y: body.minY + body.height * 0.30)
        let tip = CGPoint(x: left ? body.midX - body.width * 0.07 : body.midX + body.width * 0.07, y: body.minY + body.height * 0.17)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: color(0, 0, 0, 0.5))
        ctx.setStrokeColor(c); ctx.setLineWidth(s * 0.075); ctx.setLineCap(.round)
        ctx.move(to: pivot); ctx.addLine(to: tip); ctx.strokePath()
        ctx.restoreGState()
        // Highlight along the top edge and a pivot dot.
        ctx.setStrokeColor(color(1, 1, 1, 0.35)); ctx.setLineWidth(s * 0.014)
        ctx.move(to: CGPoint(x: pivot.x, y: pivot.y + s * 0.018)); ctx.addLine(to: CGPoint(x: tip.x, y: tip.y + s * 0.018)); ctx.strokePath()
        ctx.setFillColor(color(1, 1, 1, 0.85))
        ctx.fillEllipse(in: CGRect(x: pivot.x - s * 0.014, y: pivot.y - s * 0.014, width: s * 0.028, height: s * 0.028))
    }
    flipper(left: true, color(0.20, 0.85, 0.85))
    flipper(left: false, color(0.95, 0.35, 0.65))

    // The ball: chrome radial gradient with a specular highlight.
    let br = s * 0.135
    let bc = CGPoint(x: body.midX + s * 0.02, y: body.minY + body.height * 0.60)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: s * 0.01, height: -s * 0.02), blur: s * 0.04, color: color(0, 0, 0, 0.6))
    ctx.setFillColor(color(0.6, 0.6, 0.65))
    ctx.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br)); ctx.clip()
    let chrome = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1), color(0.78, 0.80, 0.86), color(0.32, 0.33, 0.40), color(0.55, 0.56, 0.62)] as CFArray,
                            locations: [0, 0.35, 0.8, 1])!
    ctx.drawRadialGradient(chrome, startCenter: CGPoint(x: bc.x - br * 0.35, y: bc.y + br * 0.4), startRadius: 0,
                           endCenter: bc, endRadius: br, options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(1, 1, 1, 0.9))
    ctx.fillEllipse(in: CGRect(x: bc.x - br * 0.55, y: bc.y + br * 0.25, width: br * 0.38, height: br * 0.26))

    // Rim light.
    ctx.addPath(bodyPath); ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(s * 0.006); ctx.strokePath()
    ctx.restoreGState()
}

func png(size px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(size: CGFloat(px), into: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift OUT.iconset\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out.path)")
