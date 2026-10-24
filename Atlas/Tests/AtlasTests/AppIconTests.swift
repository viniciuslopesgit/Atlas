import Foundation
import ImageIO
import Testing

/// The app icon (Resources/AppIcon.iconset, drawn by scripts/make-icon.swift): a drawing for each size that fills
/// Apple's squircle grid, so macOS shows it as drawn instead of inside a grey frame.
struct AppIconTests {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources").standardizedFileURL
    static let sizes: [String: Int] = Dictionary(uniqueKeysWithValues: [16, 32, 128, 256, 512].flatMap { points in
        [("icon_\(points)x\(points).png", points), ("icon_\(points)x\(points)@2x.png", points * 2)]
    })

    static func image(_ name: String) throws -> CGImage {
        let url = resources.appendingPathComponent("AppIcon.iconset/\(name)")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(name) is missing")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Straight (not premultiplied) RGBA from 0 to 1 of each pixel, top row first.
    static func pixels(_ image: CGImage) -> (Int, Int) -> [Double] {
        let n = image.width
        var data = [UInt8](repeating: 0, count: n * n * 4)
        let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return { x, y in
            let i = (y * n + x) * 4, alpha = Double(data[i + 3]) / 255
            return (0..<3).map { alpha > 0 ? Double(data[i + $0]) / 255 / alpha : 0 } + [alpha]
        }
    }

    @Test func everySizeIsDrawnAtItsOwnPixelSize() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.resources.appendingPathComponent("AppIcon.iconset").path)
        #expect(Set(names.filter { !$0.hasPrefix(".") }) == Set(Self.sizes.keys))
        for (name, pixels) in Self.sizes {
            let image = try Self.image(name)
            #expect(image.width == pixels && image.height == pixels, "\(name) is \(image.width)×\(image.height)")
        }
    }

    /// The old icon was a white star on a transparent canvas: macOS 27 framed it in grey, and on a light Dock it vanished.
    @Test func everySizeIsAMeridianSquircleWithTheStar() throws {
        for (name, n) in Self.sizes {
            let at = Self.pixels(try Self.image(name))
            let k = Double(n) / 1024, margin = Int((100 * k).rounded(.up)), mid = n / 2
            func point(_ x: Double, _ y: Double) -> [Double] { at(Int(x * k), Int(y * k)) }
            for (x, y) in [(0, 0), (n - 1, 0), (0, n - 1), (n - 1, n - 1), (0, mid)] {
                #expect(at(x, y)[3] < 0.1, "\(name): (\(x), \(y)) is outside the squircle and stays transparent")
            }
            for (x, y) in [(margin, mid), (n - 1 - margin, mid), (mid, margin), (mid, n - 1 - margin)] {
                #expect(at(x, y)[3] > 0.95, "\(name): the squircle reaches Apple's 100-point margin at (\(x), \(y))")
            }
            let field = point(200, 640), star = point(512, 500)
            #expect(field[3] > 0.99 && field[0] < 0.2 && (0.3...0.6).contains(field[1]) && (0.3...0.6).contains(field[2]),
                    "\(name): the field is Meridian teal, not \(field)")
            #expect(star.prefix(3).allSatisfy { $0 > 0.85 }, "\(name): the star in the middle is chalk white, not \(star)")
        }
    }

    @Test func theBuildUsesTheDrawingsInsteadOfResamplingOneImage() throws {
        let build = try String(contentsOf: Self.resources.appendingPathComponent("../scripts/build-app.sh"), encoding: .utf8)
        #expect(build.contains("iconutil -c icns Resources/AppIcon.iconset"))
        #expect(!build.contains("sips"), "sips resampled a 256-pixel image up to 1024 pixels")
        let plist = try String(contentsOf: Self.resources.appendingPathComponent("Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
    }
}
