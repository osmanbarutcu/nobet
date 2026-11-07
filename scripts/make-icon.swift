// Uygulama simgesini çizer. Kullanım:
//   swift scripts/make-icon.swift Resources/AppIcon.iconset
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let u = CGFloat(pixels) / 1024

    // Gövde: macOS simge ızgarası (824 piksel, köşe 185).
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 24 * u,
                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(path)
    cg.setFillColor(NSColor(red: 0.07, green: 0.10, blue: 0.18, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let colors = [
        NSColor(red: 0.20, green: 0.16, blue: 0.43, alpha: 1).cgColor,
        NSColor(red: 0.05, green: 0.04, blue: 0.14, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924 * u), end: CGPoint(x: 0, y: 100 * u), options: [])
    }

    // Göz: nöbet tutan gözcü. Badem biçimli kapak, kehribar iris, koyu göz bebeği, küçük ışık.
    let cx = 512 * u
    let cy = 512 * u
    let lens = CGMutablePath()
    lens.move(to: CGPoint(x: 202 * u, y: cy))
    lens.addQuadCurve(to: CGPoint(x: 822 * u, y: cy), control: CGPoint(x: cx, y: cy + 420 * u))
    lens.addQuadCurve(to: CGPoint(x: 202 * u, y: cy), control: CGPoint(x: cx, y: cy - 420 * u))
    lens.closeSubpath()

    cg.saveGState()
    cg.addPath(lens)
    cg.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
    cg.fillPath()
    cg.addPath(lens)
    cg.clip()
    cg.setFillColor(NSColor(red: 0.98, green: 0.69, blue: 0.18, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: cx - 165 * u, y: cy - 165 * u, width: 330 * u, height: 330 * u))
    cg.setFillColor(NSColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: cx - 80 * u, y: cy - 80 * u, width: 160 * u, height: 160 * u))
    cg.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    cg.fillEllipse(in: CGRect(x: cx + 28 * u, y: cy + 36 * u, width: 52 * u, height: 52 * u))
    cg.restoreGState()

    cg.addPath(lens)
    cg.setLineWidth(26 * u)
    cg.setLineJoin(.round)
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    cg.strokePath()
    cg.restoreGState()

    return rep.representation(using: .png, properties: [:])
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for entry in sizes {
    guard let data = render(pixels: entry.pixels) else { fatalError("Çizim başarısız: \(entry.name)") }
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(entry.name + ".png"))
}
print("Yazıldı: \(output)")
