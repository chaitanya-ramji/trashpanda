import AppKit

/// Helpers for the tests that draw a view into a bitmap.
enum RenderSupport {
    /// Writes the picture as a PNG, when the environment variable HEADER_PNG_DIR names a folder.
    /// The picture has a clear background, so it is put on the color of a menu first. Then a human can look at it.
    static func writePNG(_ rep: NSBitmapImageRep, name: String?, dark: Bool) {
        guard let dir = ProcessInfo.processInfo.environment["HEADER_PNG_DIR"], let name, let image = rep.cgImage else { return }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let gray: CGFloat = dark ? 0.18 : 0.96
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = context.makeImage() else { return }
        let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        try? png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
