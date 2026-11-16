import AppKit
import XCTest
@testable import FanMacly

final class FanIconGlyphTests: XCTestCase {
    static func centroid(_ image: CGImage) throws -> CGPoint {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        return try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = storage.bindMemory(to: UInt8.self)
            var mass = 0.0, xSum = 0.0, ySum = 0.0
            for y in 0..<h { for x in 0..<w {
                let alpha = Double(pixels[(y * w + x) * 4 + 3])
                mass += alpha; xSum += (Double(x) + 0.5) * alpha; ySum += (Double(y) + 0.5) * alpha
            } }
            XCTAssertGreaterThan(mass, 0)
            return CGPoint(x: xSum / mass, y: ySum / mass)
        }
    }
    @MainActor func testActualProductionMaskStaysCenteredAtEveryAngle() async throws {
        let view = RotatingFanView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let rotor = try XCTUnwrap(view.layer?.sublayers?.first)
        let image = try XCTUnwrap(rotor.mask?.contents) as! CGImage
        XCTAssertEqual(image.width, image.height)
        let center = try Self.centroid(image)
        XCTAssertEqual(center.x, Double(image.width) / 2, accuracy: 0.06)
        XCTAssertEqual(center.y, Double(image.height) / 2, accuracy: 0.06)
        // Independently rasterize the actual mask under rotation, not just the
        // layer's anchor point. This fails with the unbalanced SF Symbol.
        for step in 0..<16 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 192, bitsPerComponent: 8,
                bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 96, y: 96)
            context.rotate(by: Double(step) * .pi / 8)
            context.draw(image, in: CGRect(x: -72, y: -72, width: 144, height: 144))
            let rotated = try Self.centroid(XCTUnwrap(context.makeImage()))
            XCTAssertEqual(rotated.x, 96, accuracy: 0.15, "angle \(step)")
            XCTAssertEqual(rotated.y, 96, accuracy: 0.15, "angle \(step)")
        }
    }
    @MainActor func testSpeedChangesDoNotMoveThePivot() async throws {
        let view = RotatingFanView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let rotor = try XCTUnwrap(view.layer?.sublayers?.first)
        for speed in [0.0, 0.5, 4.8, 6, 1, 0] {
            view.setSpeed(speed)
            XCTAssertEqual(rotor.position, CGPoint(x: 12, y: 12))
            XCTAssertEqual(rotor.anchorPoint, CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(rotor.mask?.frame, CGRect(x: 1, y: 1, width: 18, height: 18))
        }
    }
}

final class FanIconGlyphScaleTests: XCTestCase {
    /// CI Macs have no Retina display, so the symbol is rasterized at 1x there.
    /// The centered mask must stay balanced at every scale.
    func testCenteredMaskIsBalancedAtEveryScale() throws {
        let symbol = try XCTUnwrap(NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium)))
        for scale in [1.0, 2.0, 3.0] {
            let raw = try XCTUnwrap(FanIconGlyph.rasterize(symbol, scale: scale))
            let image = FanIconGlyph.centered(raw)
            XCTAssertEqual(image.width, image.height)
            let center = try FanIconGlyphTests.centroid(image)
            // A quarter of a 1x pixel: invisible, and well below the half-pixel wobble of an unbalanced mask.
            XCTAssertEqual(center.x / Double(image.width), 0.5, accuracy: 0.25 / 24, "scale \(scale)")
            XCTAssertEqual(center.y / Double(image.height), 0.5, accuracy: 0.25 / 24, "scale \(scale)")
        }
    }
}
