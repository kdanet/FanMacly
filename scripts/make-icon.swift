import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels), inset = side * 0.09
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.19, yRadius: side * 0.19)
        NSGradient(colors: [NSColor(red: 0.16, green: 0.65, blue: 0.53, alpha: 1), NSColor(red: 0.06, green: 0.29, blue: 0.26, alpha: 1)])!.draw(in: path, angle: -65)
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.43, weight: .light)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let symbolSide = side * 0.54
            symbol.draw(in: NSRect(x: (side - symbolSide) / 2, y: (side - symbolSide) / 2, width: symbolSide, height: symbolSide))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
