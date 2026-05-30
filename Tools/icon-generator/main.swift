import CoreGraphics
import Foundation
import ImageIO

// Renders the MovieStats app icon: a modern, fun take on the original iPhone
// YouTube icon — a retro TV with a recessed glossy screen, a red play badge,
// two dials and a speaker grille — drawn in a macOS squircle.
//
// Output: a 1024×1024 PNG at the path given as the first argument.
// Coordinates use CoreGraphics' default origin (bottom-left, y up).

let S: CGFloat = 1024

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: icon-generator <output.png>\n".utf8))
    exit(2)
}
let outputPath = CommandLine.arguments[1]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: Int(S),
    height: Int(S),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
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

/// Fills `path` with a vertical gradient from `top` (high y) to `bottom`.
func fillVertical(_ path: CGPath, top: CGColor, bottom: CGColor, in rect: CGRect) {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()
}

// MARK: - Body (the TV)

let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(bodyRect, 185)

// Drop shadow to lift the icon off the surface.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: color(0, 0, 0, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(240, 240, 244))
ctx.fillPath()
ctx.restoreGState()

// Body gradient: a clean, light brushed-metal/plastic shell.
fillVertical(bodyPath, top: color(252, 252, 254), bottom: color(206, 208, 214), in: bodyRect)

// Soft top sheen across the shell.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(255, 255, 255, 0.55), color(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
    end: CGPoint(x: bodyRect.midX, y: bodyRect.maxY - 260),
    options: []
)
ctx.restoreGState()

// MARK: - Screen

let screenRect = CGRect(x: 180, y: 346, width: 664, height: 498)
let screenPath = roundedRect(screenRect, 70)

// Recessed bezel: a dark frame seated into the shell with a soft shadow.
let bezelRect = screenRect.insetBy(dx: -12, dy: -12)
let bezelPath = roundedRect(bezelRect, 82)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0, 0, 0, 0.45))
ctx.addPath(bezelPath)
ctx.setFillColor(color(18, 18, 24))
ctx.fillPath()
ctx.restoreGState()

// Screen face: a deep, slightly cool gradient.
fillVertical(screenPath, top: color(42, 44, 54), bottom: color(18, 19, 26), in: screenRect)

// MARK: - Glossy screen reflection (skeuomorphic nod, kept subtle)
// Drawn before the reel so the reel reads crisply on top.

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
let reflection = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(255, 255, 255, 0.16), color(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    reflection,
    start: CGPoint(x: screenRect.midX, y: screenRect.maxY),
    end: CGPoint(x: screenRect.midX, y: screenRect.maxY - 230),
    options: []
)
ctx.restoreGState()

// MARK: - Film strip (trails out from behind the reel)

func drawFilmStrip(at p: CGPoint, length L: CGFloat, height H: CGFloat, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: angle)

    let body = CGRect(x: -L / 2, y: -H / 2, width: L, height: H)
    ctx.addPath(roundedRect(body, 10))
    ctx.setFillColor(color(28, 28, 33))
    ctx.fillPath()

    // Image frames: a slightly lighter band between the sprocket rows.
    let frame = CGRect(x: -L / 2 + 4, y: -H / 2 + 22, width: L - 8, height: H - 44)
    ctx.addPath(CGPath(rect: frame, transform: nil))
    ctx.setFillColor(color(58, 58, 66))
    ctx.fillPath()

    // Frame dividers.
    ctx.setStrokeColor(color(28, 28, 33))
    ctx.setLineWidth(3)
    let frameCount = 4
    for i in 1..<frameCount {
        let x = frame.minX + frame.width * CGFloat(i) / CGFloat(frameCount)
        ctx.move(to: CGPoint(x: x, y: frame.minY))
        ctx.addLine(to: CGPoint(x: x, y: frame.maxY))
    }
    ctx.strokePath()

    // Sprocket holes along both edges.
    let pw: CGFloat = 12
    let ph: CGFloat = 9
    let step: CGFloat = 24
    var x = -L / 2 + 12
    while x <= L / 2 - 12 - pw {
        ctx.addPath(roundedRect(CGRect(x: x, y: H / 2 - 16, width: pw, height: ph), 2))
        ctx.addPath(roundedRect(CGRect(x: x, y: -H / 2 + 7, width: pw, height: ph), 2))
        x += step
    }
    ctx.setFillColor(color(226, 224, 215))
    ctx.fillPath()

    // Crisp edge.
    ctx.addPath(roundedRect(body, 10))
    ctx.setStrokeColor(color(72, 72, 80))
    ctx.setLineWidth(2)
    ctx.strokePath()

    ctx.restoreGState()
}

drawFilmStrip(at: CGPoint(x: 690, y: 470), length: 220, height: 88, angle: -0.55)

// MARK: - Movie reel (the hero, centered on the screen)

func drawReel(center c: CGPoint, radius R: CGFloat) {
    let holeCount = 6
    let holeDistance = R * 0.575
    let holeRadius = R * 0.25
    let bbox = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)

    func holeCenter(_ i: Int) -> CGPoint {
        let a = Double(i) / Double(holeCount) * 2 * .pi + .pi / 6
        return CGPoint(x: c.x + holeDistance * CGFloat(cos(a)),
                       y: c.y + holeDistance * CGFloat(sin(a)))
    }

    // Compound body: a disc with the holes punched out (even-odd).
    let body = CGMutablePath()
    body.addEllipse(in: bbox)
    for i in 0..<holeCount {
        let h = holeCenter(i)
        body.addEllipse(in: CGRect(x: h.x - holeRadius, y: h.y - holeRadius,
                                   width: holeRadius * 2, height: holeRadius * 2))
    }

    // Silver face with a vertical gradient and an upper-left metallic glint.
    let silver = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(240, 241, 244), color(150, 152, 161)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(
        silver,
        start: CGPoint(x: c.x, y: bbox.maxY),
        end: CGPoint(x: c.x, y: bbox.minY),
        options: []
    )
    let glint = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(255, 255, 255, 0.55), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    let glintCenter = CGPoint(x: c.x - R * 0.38, y: c.y + R * 0.38)
    ctx.drawRadialGradient(
        glint,
        startCenter: glintCenter, startRadius: 0,
        endCenter: glintCenter, endRadius: R * 1.1,
        options: []
    )
    ctx.restoreGState()

    // Bevel the holes for depth.
    for i in 0..<holeCount {
        let h = holeCenter(i)
        ctx.addEllipse(in: CGRect(x: h.x - holeRadius, y: h.y - holeRadius,
                                  width: holeRadius * 2, height: holeRadius * 2))
        ctx.setStrokeColor(color(92, 94, 102))
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    // Raised flange ring near the outer edge.
    let flange = CGMutablePath()
    flange.addEllipse(in: bbox)
    flange.addEllipse(in: bbox.insetBy(dx: R * 0.12, dy: R * 0.12))
    let flangeGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(252, 252, 254), color(186, 188, 196)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(flange)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(
        flangeGrad,
        start: CGPoint(x: c.x, y: bbox.maxY),
        end: CGPoint(x: c.x, y: bbox.minY),
        options: []
    )
    ctx.restoreGState()

    // Crisp outer edge.
    ctx.addEllipse(in: bbox)
    ctx.setStrokeColor(color(120, 122, 130))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Center hub: ring, bolts, and a center pin.
    let hubR = R * 0.2
    ctx.addEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
    ctx.setStrokeColor(color(96, 98, 106))
    ctx.setLineWidth(3)
    ctx.strokePath()

    for i in 0..<6 {
        let a = Double(i) / 6 * 2 * .pi
        let bx = c.x + R * 0.1 * CGFloat(cos(a))
        let by = c.y + R * 0.1 * CGFloat(sin(a))
        let br = R * 0.028
        ctx.addEllipse(in: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
    }
    ctx.setFillColor(color(96, 98, 106))
    ctx.fillPath()

    let pinR = R * 0.05
    ctx.addEllipse(in: CGRect(x: c.x - pinR, y: c.y - pinR, width: pinR * 2, height: pinR * 2))
    ctx.setFillColor(color(80, 82, 90))
    ctx.fillPath()
}

drawReel(center: CGPoint(x: 470, y: 622), radius: 162)

// MARK: - Bottom bezel details: speaker grille + two dials

let stripY: CGFloat = 223 // vertical center of the lower bezel strip

// Speaker grille: three rounded bars on the left.
for i in 0..<3 {
    let barRect = CGRect(x: 196, y: stripY + 26 - CGFloat(i) * 26, width: 188, height: 14)
    ctx.addPath(roundedRect(barRect, 7))
    ctx.setFillColor(color(150, 152, 160))
    ctx.fillPath()
}

// Two dials on the right, each a soft silver disc with a highlight.
func dial(centerX: CGFloat) {
    let r: CGFloat = 34
    let rect = CGRect(x: centerX - r, y: stripY - r, width: r * 2, height: r * 2)
    let disc = CGPath(ellipseIn: rect, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: color(0, 0, 0, 0.3))
    ctx.addPath(disc)
    ctx.setFillColor(color(228, 229, 233))
    ctx.fillPath()
    ctx.restoreGState()

    fillVertical(disc, top: color(248, 249, 251), bottom: color(196, 198, 205), in: rect)

    // Inner dot/marker.
    let inner = rect.insetBy(dx: 20, dy: 20)
    ctx.addPath(CGPath(ellipseIn: inner, transform: nil))
    ctx.setFillColor(color(120, 122, 130))
    ctx.fillPath()
}
dial(centerX: 752)
dial(centerX: 846)

// MARK: - Write PNG

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outputPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("wrote \(outputPath)")
