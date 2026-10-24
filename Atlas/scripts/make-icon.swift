// Draws the app icon into Resources/AppIcon.iconset, one drawing per size (build-app.sh turns it into AppIcon.icns).
//   SDKROOT=$(scripts/sdk.sh) swift scripts/make-icon.swift [folder]
// The brand's star on a Meridian squircle, over the graticule of an atlas page: meridians that meet at a pole above
// the icon and parallels around it. 16 and 32 pixel images leave the graticule out and draw a fuller star.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
/// Apple's macOS icon grid: an 824-point body with continuous corners, centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185.4

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let meridianTop = rgb(0x1D8C8B), meridian = rgb(0x16797A), meridianDeep = rgb(0x0E5A5B)
let meridianLight = rgb(0x3FB8B4), chalk = rgb(0xF6FBFA), chalkShade = rgb(0xDCEDEB)

/// The star from cloud-atlas.io's mark (traced on its 1254-pixel drawing): tips and inner corners, clockwise from the top.
let tracedStar: [CGPoint] = [(615, 62), (783, 522), (1205, 285), (884, 672), (1003, 1170),
                             (610, 808), (350, 1213), (473, 766), (185, 592), (422, 590)].map { CGPoint(x: $0.0, y: $0.1) }

/// Where a polygon's area balances, so the star sits by its weight rather than by its long arm.
func centroid(_ points: [CGPoint]) -> CGPoint {
    var area: CGFloat = 0, x: CGFloat = 0, y: CGFloat = 0
    for (a, b) in zip(points, points.dropFirst() + [points[0]]) {
        let cross = a.x * b.y - b.x * a.y
        area += cross; x += (a.x + b.x) * cross; y += (a.y + b.y) * cross
    }
    return CGPoint(x: x / (3 * area), y: y / (3 * area))
}

/// The star centered on `center`, `height` points tall, its tips rounded by `round` (the corners stay sharp).
func star(center: CGPoint, height: CGFloat, round: CGFloat) -> CGPath {
    let ys = tracedStar.map(\.y), scale = height / (ys.max()! - ys.min()!), c = centroid(tracedStar)
    let polygon = CGMutablePath()
    polygon.addLines(between: tracedStar.map { CGPoint(x: center.x + ($0.x - c.x) * scale, y: center.y + ($0.y - c.y) * scale) })
    polygon.closeSubpath()
    return polygon.union(polygon.copy(strokingWithWidth: round * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

let starCenter = CGPoint(x: 512, y: 500)
/// The pole the meridians meet at, above the icon; one parallel and the central meridian cross under the star.
let pole = CGPoint(x: 512, y: -820)

/// Fades from the star towards the edges, so the lines frame it instead of competing with it.
func graticule(_ ctx: CGContext, width: CGFloat) {
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(meridianLight.copy(alpha: 0.4)!)
    ctx.setLineWidth(width)
    let through = starCenter.y - pole.y
    for i in -3...3 {
        let r = through + CGFloat(i) * 160
        ctx.addEllipse(in: CGRect(x: pole.x - r, y: pole.y - r, width: 2 * r, height: 2 * r))
    }
    for i in -5...5 {
        let angle = CGFloat.pi / 2 + CGFloat(i) * 8 * .pi / 180
        ctx.move(to: pole)
        ctx.addLine(to: CGPoint(x: pole.x + 3000 * cos(angle), y: pole.y + 3000 * sin(angle)))
    }
    ctx.strokePath()
    ctx.setBlendMode(.destinationIn)
    let fade = CGGradient(colorsSpace: nil, colors: [rgb(0, 1), rgb(0, 0.25)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(fade, startCenter: starCenter, startRadius: 140, endCenter: starCenter, endRadius: 640,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.endTransparencyLayer()
}

func icon(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / canvas, small = pixels <= 32
    // Drawn top-down in canvas points. Shadow offsets and blurs are in pixels, with y up.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)
    let squircle = RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: body).cgPath
    let vertical = [meridianTop, meridian, meridianDeep] as CFArray

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: rgb(0x000000, 0.3))
    ctx.addPath(squircle)
    ctx.setFillColor(meridian)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let field = CGGradient(colorsSpace: nil, colors: vertical, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(field, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    if !small { graticule(ctx, width: max(3, 1 / k)) }
    ctx.restoreGState()

    let glyph = small ? star(center: starCenter, height: 600, round: 34) : star(center: starCenter, height: 540, round: 14)
    ctx.saveGState()
    if !small { ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: rgb(0x063B3C, 0.45)) }
    ctx.addPath(glyph)
    ctx.setFillColor(chalk)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(glyph)
    ctx.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [chalk, chalk, chalkShade] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: starCenter.y - 300), end: CGPoint(x: 512, y: starCenter.y + 300), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/AppIcon.iconset").path)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(icon(pixels: points), folder.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(icon(pixels: points * 2), folder.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("Wrote \(folder.standardizedFileURL.path)")
