import AppKit

// macOS 风格 squircle + 粉紫渐变 + 中央"ク"字 + 右下红色三角条
func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225

    // squircle 路径
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // 主渐变：粉 → 紫 → 深紫蓝
    let gradient = NSGradient(colors: [
        NSColor(red: 0.96, green: 0.32, blue: 0.62, alpha: 1.0),
        NSColor(red: 0.55, green: 0.18, blue: 0.85, alpha: 1.0),
        NSColor(red: 0.20, green: 0.12, blue: 0.55, alpha: 1.0),
    ])!
    gradient.draw(in: rect, angle: -100)

    // 左上柔光
    let glow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    glow.draw(in: rect, angle: -45)

    // 中央"ク"字（白色，HiraMin 重体）
    let charSize = size * 0.66
    let font = NSFont(name: "HiraMinProN-W6", size: charSize) ?? NSFont.boldSystemFont(ofSize: charSize)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.96),
    ]
    let str = "ク" as NSString
    let strSize = str.size(withAttributes: attrs)
    str.draw(at: NSPoint(
        x: (size - strSize.width) / 2,
        y: (size - strSize.height) / 2 - size * 0.04
    ), withAttributes: attrs)

    // 右下红色三角条（hazard corner，与悬浮窗呼应）
    let cs = size * 0.16
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: size, y: cs))
    tri.line(to: NSPoint(x: size, y: 0))
    tri.line(to: NSPoint(x: size - cs, y: 0))
    tri.close()
    NSGraphicsContext.current!.saveGraphicsState()
    tri.addClip()
    let stripe = size * 0.022
    let gap = stripe * 0.7
    var x: CGFloat = -cs
    while x < size + cs {
        let stripePath = NSBezierPath()
        stripePath.move(to: NSPoint(x: x, y: 0))
        stripePath.line(to: NSPoint(x: x + stripe, y: 0))
        stripePath.line(to: NSPoint(x: x + stripe + cs, y: cs))
        stripePath.line(to: NSPoint(x: x + cs, y: cs))
        stripePath.close()
        NSColor(red: 1.0, green: 0.22, blue: 0.30, alpha: 0.92).setFill()
        stripePath.fill()
        x += stripe + gap
    }
    NSGraphicsContext.current!.restoreGraphicsState()

    return img
}

func savePNG(_ img: NSImage, to path: String) throws {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PNG", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outDir = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, sz) in sizes {
    try savePNG(renderIcon(size: sz), to: "\(outDir)/\(name)")
}
print("Wrote iconset to \(outDir)")
