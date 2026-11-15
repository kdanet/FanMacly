import CoreGraphics

/// SF Symbols include typographic side bearings, not a rotation-safe canvas.
/// Balance the visible ink once, preserving the old aspect-fit scale. Simply
/// cropping and stretching the ink would also enlarge the menu-bar symbol.
enum FanIconGlyph {
    static func centered(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ink: CGRect? = pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = storage.bindMemory(to: UInt8.self)
            var left = width, top = height, right = -1, bottom = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] >= 16 {
                    // Ignore almost-transparent antialiasing fringes, whose
                    // asymmetric one-pixel tails do not describe the hub.
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= left, bottom >= top else { return nil }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
        guard let ink else { return image }
        let side = max(width, height)
        guard let centered = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format) else { return image }
        centered.interpolationQuality = .none
        // Bitmap rows start at the top; Core Graphics draws from the bottom.
        let sourceCenterY = CGFloat(height) - ink.midY
        centered.draw(image, in: CGRect(x: CGFloat(side) / 2 - ink.midX, y: CGFloat(side) / 2 - sourceCenterY,
                                       width: CGFloat(width), height: CGFloat(height)))
        return centered.makeImage() ?? image
    }
}
