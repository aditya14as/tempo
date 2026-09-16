// Draws the Tempo app icon: a dark rounded square with a gradient
// progress ring at 75% and a bright "now" dot at its tip.
// Run:  swift Tools/icongen.swift   → writes Assets/icon-1024.png
import AppKit
import CoreGraphics
import ImageIO

let size = 1024
let margin: CGFloat = 100
let cornerRadius: CGFloat = 210

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Squircle-ish background with a soft dark vertical gradient.
let bgRect = CGRect(x: margin, y: margin, width: CGFloat(size) - 2 * margin, height: CGFloat(size) - 2 * margin)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()
let bgGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 512, y: CGFloat(size) - margin),
    end: CGPoint(x: 512, y: margin),
    options: []
)

// Faint full track so the ring reads as "progress".
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 262
let lineWidth: CGFloat = 92
ctx.setLineCap(.round)
ctx.setLineWidth(lineWidth)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()

// Gradient arc: start at 12 o'clock, sweep 270° clockwise, teal → indigo.
// CoreGraphics has no gradient stroke, so draw many short round-capped segments.
let startAngle = CGFloat.pi / 2
let sweep = 1.5 * CGFloat.pi  // 75%
let steps = 240
let from = (r: 0.35, g: 0.92, b: 0.76)
let to = (r: 0.45, g: 0.45, b: 0.98)
var tipPoint = CGPoint.zero
for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps)
    let t1 = CGFloat(i + 1) / CGFloat(steps)
    let a0 = startAngle - sweep * t0
    let a1 = startAngle - sweep * t1
    let t = Double(t0)
    ctx.setStrokeColor(CGColor(
        red: from.r + (to.r - from.r) * t,
        green: from.g + (to.g - from.g) * t,
        blue: from.b + (to.b - from.b) * t,
        alpha: 1
    ))
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
    if i == steps - 1 {
        tipPoint = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    }
}

// Bright "now" dot at the tip of the arc.
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
let dotRadius: CGFloat = 30
ctx.fillEllipse(in: CGRect(
    x: tipPoint.x - dotRadius, y: tipPoint.y - dotRadius,
    width: dotRadius * 2, height: dotRadius * 2
))

let image = ctx.makeImage()!
let outURL = URL(fileURLWithPath: "Assets/icon-1024.png")
try? FileManager.default.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
