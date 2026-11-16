import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-preview.png"

func squirclePath(rect: CGRect, n: CGFloat = 5.0, steps: Int = 720) -> CGMutablePath {
    let cx = rect.midX
    let cy = rect.midY
    let a = rect.width / 2
    let b = rect.height / 2
    let path = CGMutablePath()
    for i in 0..<steps {
        let t = (2.0 * CGFloat.pi * CGFloat(i)) / CGFloat(steps)
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> CGMutablePath {
    let path = CGMutablePath()
    let count = pts.count
    for i in 0..<count {
        let prev = pts[(i - 1 + count) % count]
        let curr = pts[i]
        let next = pts[(i + 1) % count]
        let v1 = CGVector(dx: prev.x - curr.x, dy: prev.y - curr.y)
        let v2 = CGVector(dx: next.x - curr.x, dy: next.y - curr.y)
        let l1 = hypot(v1.dx, v1.dy)
        let l2 = hypot(v2.dx, v2.dy)
        let r = min(radius, l1 * 0.45, l2 * 0.45)
        let p1 = CGPoint(x: curr.x + v1.dx / l1 * r, y: curr.y + v1.dy / l1 * r)
        let p2 = CGPoint(x: curr.x + v2.dx / l2 * r, y: curr.y + v2.dy / l2 * r)
        if i == 0 {
            path.move(to: p1)
        } else {
            path.addLine(to: p1)
        }
        path.addQuadCurve(to: p2, control: curr)
    }
    path.closeSubpath()
    return path
}

func catSilhouettePath() -> CGMutablePath {
    // Symmetric minimalist geometric cat head centered at x=512, y=268..748 (top-down coords)
    let path = CGMutablePath()
    // Start at left cheek mid-upper (vertical tangent at x=260, y=506)
    path.move(to: CGPoint(x: 260, y: 506))
    // Left ear outer edge up to rounded tip
    path.addCurve(to: CGPoint(x: 312, y: 280),
                  control1: CGPoint(x: 260, y: 416),
                  control2: CGPoint(x: 278, y: 318))
    path.addCurve(to: CGPoint(x: 360, y: 284),
                  control1: CGPoint(x: 324, y: 262),
                  control2: CGPoint(x: 344, y: 264))
    // Left ear inner slope down to calm forehead
    path.addCurve(to: CGPoint(x: 444, y: 372),
                  control1: CGPoint(x: 390, y: 318),
                  control2: CGPoint(x: 420, y: 354))
    // Forehead bridge
    path.addCurve(to: CGPoint(x: 580, y: 372),
                  control1: CGPoint(x: 482, y: 362),
                  control2: CGPoint(x: 542, y: 362))
    // Right ear inner slope up to rounded tip
    path.addCurve(to: CGPoint(x: 664, y: 284),
                  control1: CGPoint(x: 604, y: 354),
                  control2: CGPoint(x: 634, y: 318))
    path.addCurve(to: CGPoint(x: 712, y: 280),
                  control1: CGPoint(x: 680, y: 264),
                  control2: CGPoint(x: 700, y: 262))
    // Right ear outer edge down to right cheek (vertical tangent at x=764, y=506)
    path.addCurve(to: CGPoint(x: 764, y: 506),
                  control1: CGPoint(x: 746, y: 318),
                  control2: CGPoint(x: 764, y: 416))
    // Right cheek & chin (continuous vertical tangent from (764, 506))
    path.addCurve(to: CGPoint(x: 512, y: 748),
                  control1: CGPoint(x: 764, y: 656),
                  control2: CGPoint(x: 658, y: 748))
    // Left chin & cheek back to start (continuous vertical tangent to (260, 506))
    path.addCurve(to: CGPoint(x: 260, y: 506),
                  control1: CGPoint(x: 366, y: 748),
                  control2: CGPoint(x: 260, y: 656))
    path.closeSubpath()
    return path
}

func boltCutoutPath() -> CGPath {
    // Crisp, balanced lightning bolt centered optically at (512, 552)
    let pts: [CGPoint] = [
        CGPoint(x: 550, y: 418),
        CGPoint(x: 422, y: 568),
        CGPoint(x: 502, y: 568),
        CGPoint(x: 474, y: 688),
        CGPoint(x: 602, y: 538),
        CGPoint(x: 522, y: 538),
    ]
    return roundedPolygon(pts, radius: 10)
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil,
                          width: Int(size),
                          height: Int(size),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Failed to create CGContext")
}

// Flip to top-left origin
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = squirclePath(rect: tileRect, n: 5.0)

// 1. Base warm terracotta-amber gradient (Claude-inspired satin surface)
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

let gradColors = [
    CGColor(srgbRed: 0.945, green: 0.424, blue: 0.188, alpha: 1.0), // #F16C30
    CGColor(srgbRed: 0.867, green: 0.314, blue: 0.106, alpha: 1.0), // #DD501B
    CGColor(srgbRed: 0.722, green: 0.220, blue: 0.067, alpha: 1.0), // #B83811
] as CFArray
let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 0.52, 1.0])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 200, y: 100),
                       end: CGPoint(x: 824, y: 924),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Subtle top ambient sheen
let sheenColors = [
    CGColor(srgbRed: 1.0, green: 0.82, blue: 0.68, alpha: 0.24),
    CGColor(srgbRed: 1.0, green: 0.82, blue: 0.68, alpha: 0.0),
] as CFArray
let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(sheen,
                       startCenter: CGPoint(x: 512, y: 210),
                       startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 210),
                       endRadius: 480,
                       options: [])

// Crisp inner 1.5px rim highlight
ctx.addPath(tile)
ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
ctx.setLineWidth(3.0) // clipped to inside, so 1.5px visible
ctx.strokePath()
ctx.restoreGState()

// 2. Geometric Cat + Negative-space Lightning emblem in crisp Ivory White
let emblem = catSilhouettePath()
emblem.addPath(boltCutoutPath())

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8),
              blur: 18,
              color: CGColor(srgbRed: 0.35, green: 0.08, blue: 0.0, alpha: 0.20))
ctx.addPath(emblem)
ctx.setFillColor(CGColor(srgbRed: 0.992, green: 0.988, blue: 0.980, alpha: 1.0)) // #FCFBF9
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

guard let cgImage = ctx.makeImage() else { fatalError("Failed to make image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else { fatalError("Failed to encode PNG") }
try pngData.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
