import CoreGraphics
import Foundation
import ImageIO

// Renders the MovieStats app icon: a storage pool drawn as three stacked disks
// in 3/4 perspective, with the top disk's surface rendered as a film reel — so
// it reads as a film reel sitting on top of a stack of storage platters.
//
// Output: a 1024×1024 PNG at the path given as the first argument.
// Coordinates use CoreGraphics' default origin (bottom-left, y up); "top" of
// the stack is therefore a higher y value.

let S: CGFloat = 1024

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: icon-generator <output.png>\n".utf8))
    exit(2)
}
let outputPath = CommandLine.arguments[1]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: - Helpers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func fillLinear(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint, evenOdd: Bool = false) {
    ctx.saveGState()
    ctx.addPath(path)
    if evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

func fillRadial(_ path: CGPath, _ g: CGGradient, center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

// MARK: - Stack geometry (3/4 perspective)

let cx: CGFloat = 512
let rx: CGFloat = 320       // horizontal radius of each disk ellipse
let ratio: CGFloat = 0.24   // perspective squash (vertical radius / horizontal)
let ry = rx * ratio         // vertical radius of the ellipse
// Three disks that read as equal heights. The top disk also carries the reel
// cap's domed front lip (depth `ry`), so the seams are spaced one full `band`
// apart starting from the cap centre — that makes [dome + top band] equal to
// each lower band, instead of the top disk looking huge.
let band: CGFloat = 165     // height of each disk as seen from the front
let topY: CGFloat = 760     // center of the top face ellipse
let seam1 = topY - band
let seam2 = topY - 2 * band
let bottomY = topY - 3 * band // center of the bottom (front) rim

/// Rect bounding a perspective ellipse centered at (X, Y) with x-radius `a`.
func ellRect(_ X: CGFloat, _ Y: CGFloat, _ a: CGFloat) -> CGRect {
    CGRect(x: X - a, y: Y - a * ratio, width: 2 * a, height: 2 * a * ratio)
}
func ellipsePath(_ X: CGFloat, _ Y: CGFloat, _ a: CGFloat) -> CGPath {
    CGPath(ellipseIn: ellRect(X, Y, a), transform: nil)
}

/// Adds the front (lower) half of a perspective ellipse arc to `path`.
func addFrontArc(_ path: CGMutablePath, _ X: CGFloat, _ Y: CGFloat, _ a: CGFloat) {
    let t = CGAffineTransform(translationX: X, y: Y).scaledBy(x: 1, y: ratio)
    path.addArc(center: .zero, radius: a, startAngle: .pi, endAngle: 2 * .pi, clockwise: false, transform: t)
}

// MARK: - Background squircle

let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(bodyRect, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: color(0, 0, 0, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(40, 50, 70))
ctx.fillPath()
ctx.restoreGState()

// Deep cool gradient backdrop so the metallic stack pops.
fillLinear(
    bodyPath,
    gradient([color(78, 100, 142), color(33, 42, 62)], [0, 1]),
    from: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
    to: CGPoint(x: bodyRect.midX, y: bodyRect.minY)
)

// Soft glow behind the stack for depth.
fillRadial(
    bodyPath,
    gradient([color(150, 180, 220, 0.45), color(150, 180, 220, 0)], [0, 1]),
    center: CGPoint(x: cx, y: topY - 40),
    radius: 470
)

// MARK: - Contact shadow under the stack

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 46, color: color(0, 0, 0, 0.5))
ctx.addPath(ellipsePath(cx, bottomY - ry * 0.55, rx * 0.96))
ctx.setFillColor(color(0, 0, 0, 0.9))
ctx.fillPath()
ctx.restoreGState()

// MARK: - Disk stack body (walls)

let walls = CGMutablePath()
walls.move(to: CGPoint(x: cx - rx, y: topY))
walls.addLine(to: CGPoint(x: cx - rx, y: bottomY))
addFrontArc(walls, cx, bottomY, rx)             // rounded front of the bottom disk
walls.addLine(to: CGPoint(x: cx + rx, y: topY))
walls.closeSubpath()

// Horizontal cylinder shading: dark edges, bright centre — reads as round metal.
fillLinear(
    walls,
    gradient(
        [color(46, 60, 84), color(120, 140, 170), color(196, 210, 230), color(120, 140, 170), color(42, 56, 80)],
        [0, 0.22, 0.5, 0.78, 1]
    ),
    from: CGPoint(x: cx - rx, y: topY),
    to: CGPoint(x: cx + rx, y: topY)
)

// Vertical form shading: lower disks a touch darker.
fillLinear(
    walls,
    gradient([color(0, 0, 0, 0), color(0, 0, 0, 0.28)], [0, 1]),
    from: CGPoint(x: cx, y: topY),
    to: CGPoint(x: cx, y: bottomY - ry)
)

// MARK: - Seams between the disks

for level in [seam1, seam2] {
    // Shadow groove.
    let groove = CGMutablePath()
    addFrontArc(groove, cx, level, rx)
    ctx.saveGState()
    ctx.addPath(walls); ctx.clip()
    ctx.addPath(groove)
    ctx.setStrokeColor(color(24, 32, 48, 0.9))
    ctx.setLineWidth(6)
    ctx.strokePath()
    // Highlight ridge just above the groove (top edge of the lower disk).
    let ridge = CGMutablePath()
    addFrontArc(ridge, cx, level + 7, rx)
    ctx.addPath(ridge)
    ctx.setStrokeColor(color(225, 235, 248, 0.55))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

// Crisp front edge along the very bottom.
let bottomEdge = CGMutablePath()
addFrontArc(bottomEdge, cx, bottomY, rx)
ctx.addPath(bottomEdge)
ctx.setStrokeColor(color(26, 34, 50))
ctx.setLineWidth(4)
ctx.strokePath()

// MARK: - Top disk surface, rendered as a film reel

let reelCenter = CGPoint(x: cx, y: topY)

// Base platter (the reel body): a lit silver top.
fillRadial(
    ellipsePath(cx, topY, rx),
    gradient([color(236, 242, 250), color(150, 166, 192)], [0, 1]),
    center: CGPoint(x: cx - rx * 0.3, y: topY + ry * 0.3),
    radius: rx * 1.15
)

// Reel hole layout (in perspective).
let holeCount = 6
let holeDistance = rx * 0.58
let holeRadius = rx * 0.2

func holeCenter(_ i: Int) -> CGPoint {
    let a = Double(i) / Double(holeCount) * 2 * .pi + .pi / 6
    return CGPoint(x: cx + holeDistance * CGFloat(cos(a)),
                   y: topY + holeDistance * ratio * CGFloat(sin(a)))
}

// Punched holes: dark recesses with a thin lit far-edge.
for i in 0..<holeCount {
    let h = holeCenter(i)
    fillLinear(
        ellipsePath(h.x, h.y, holeRadius),
        gradient([color(58, 66, 80), color(20, 25, 34)], [0, 1]),
        from: CGPoint(x: h.x, y: h.y + holeRadius * ratio),
        to: CGPoint(x: h.x, y: h.y - holeRadius * ratio)
    )
    ctx.addPath(ellipsePath(h.x, h.y, holeRadius))
    ctx.setStrokeColor(color(210, 220, 235, 0.5))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

// Raised outer rim of the reel (a brighter ring near the edge).
let rim = CGMutablePath()
rim.addPath(ellipsePath(cx, topY, rx))
rim.addPath(ellipsePath(cx, topY, rx * 0.88))
fillLinear(
    rim,
    gradient([color(250, 252, 255), color(176, 190, 214)], [0, 1]),
    from: CGPoint(x: cx, y: topY + ry),
    to: CGPoint(x: cx, y: topY - ry),
    evenOdd: true
)
ctx.addPath(ellipsePath(cx, topY, rx))
ctx.setStrokeColor(color(120, 134, 158))
ctx.setLineWidth(2)
ctx.strokePath()

// Center hub: ring, bolts, and a centre pin.
let hubR = rx * 0.17
ctx.addPath(ellipsePath(cx, topY, hubR))
ctx.setStrokeColor(color(110, 124, 148))
ctx.setLineWidth(3)
ctx.strokePath()

for i in 0..<6 {
    let a = Double(i) / 6 * 2 * .pi
    let bx = cx + rx * 0.09 * CGFloat(cos(a))
    let by = topY + rx * 0.09 * ratio * CGFloat(sin(a))
    ctx.addPath(ellipsePath(bx, by, rx * 0.022))
}
ctx.setFillColor(color(110, 124, 148))
ctx.fillPath()

ctx.addPath(ellipsePath(cx, topY, rx * 0.045))
ctx.setFillColor(color(92, 106, 130))
ctx.fillPath()

// Soft top glint for a metallic sheen.
fillRadial(
    ellipsePath(cx, topY, rx),
    gradient([color(255, 255, 255, 0.4), color(255, 255, 255, 0)], [0, 1]),
    center: CGPoint(x: cx - rx * 0.35, y: topY + ry * 0.45),
    radius: rx * 0.9
)

// MARK: - Write PNG

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outputPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("wrote \(outputPath)")
