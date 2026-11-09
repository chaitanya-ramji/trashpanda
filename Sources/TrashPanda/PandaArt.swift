import AppKit

/// All artwork is drawn in code. One drawing feeds the menu bar icon, the app icon, and the spinner.
enum PandaArt {

    // MARK: Panda shapes (unit square, origin at bottom left)

    private static let center = CGPoint(x: 0.5, y: 0.495)

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        var t = AffineTransform(translationByX: cx, byY: cy)
        t.rotate(byDegrees: rotation)
        path.transform(using: t)
        return path
    }

    private static var headShape: NSBezierPath { ellipse(0.5, 0.46, 0.275, 0.24) }

    private static var earShapes: [NSBezierPath] {
        [ellipse(0.285, 0.665, 0.098, 0.098), ellipse(0.715, 0.665, 0.098, 0.098)]
    }

    private static var patchShapes: [NSBezierPath] {
        [ellipse(0.385, 0.465, 0.06, 0.088, rotation: -24), // left eye patch
         ellipse(0.615, 0.465, 0.06, 0.088, rotation: 24)]  // right eye patch
    }

    private static var noseShape: NSBezierPath { ellipse(0.5, 0.385, 0.036, 0.026) }

    private static var eyeDots: [NSBezierPath] {
        [ellipse(0.396, 0.478, 0.016, 0.016), ellipse(0.604, 0.478, 0.016, 0.016)]
    }

    /// Scales the panda about its visual center so it fills a square of side `size`.
    private static func place(_ path: NSBezierPath, in rect: NSRect, zoom: CGFloat) {
        var t = AffineTransform(translationByX: -center.x, byY: -center.y)
        t.append(AffineTransform(scaleByX: zoom, byY: zoom))
        t.append(AffineTransform(translationByX: 0.5, byY: 0.5))
        t.append(AffineTransform(scaleByX: rect.width, byY: rect.height))
        t.append(AffineTransform(translationByX: rect.minX, byY: rect.minY))
        path.transform(using: t)
    }

    private static func placed(_ paths: [NSBezierPath], in rect: NSRect, zoom: CGFloat) -> [NSBezierPath] {
        paths.map { p in
            let copy = p.copy() as! NSBezierPath
            place(copy, in: rect, zoom: zoom)
            return copy
        }
    }

    // MARK: Menu bar icon

    /// A minimal panda face. It is a template image, so macOS colors it for light and dark bars.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let square = NSRect(x: (rect.width - rect.height) / 2, y: 0, width: rect.height, height: rect.height)
            let zoom: CGFloat = 1.32
            let cg = NSGraphicsContext.current?.cgContext
            let head = placed([headShape], in: square, zoom: zoom)[0]
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Solid ears, then clear the part of each ear that sits inside the head.
            for p in placed(earShapes, in: square, zoom: zoom) { p.fill() }
            cg?.setBlendMode(.clear)
            head.fill()
            cg?.setBlendMode(.normal)

            // Outlined head, solid eye patches, solid nose.
            head.lineWidth = 1.5
            head.stroke()
            for p in placed(patchShapes, in: square, zoom: zoom) { p.fill() }
            placed([noseShape], in: square, zoom: zoom).first?.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Trash Panda"
        return image
    }

    /// One frame of the busy spinner. Eight dots fade around a circle.
    static func spinnerFrame(_ step: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let dots = 8
            let radius: CGFloat = 6.2
            for i in 0..<dots {
                let age = (i - step % dots + dots) % dots
                let alpha = 0.2 + 0.8 * CGFloat(dots - 1 - age) / CGFloat(dots - 1)
                let angle = CGFloat(i) / CGFloat(dots) * 2 * .pi
                let c = CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: App icon

    /// The app icon: a dark tile with a gradient edge, faint sweep marks, and a white panda.
    static func drawAppIcon(in canvas: NSRect) {
        let side = canvas.width
        let tile = canvas.insetBy(dx: side * 0.0977, dy: side * 0.0977)  // Apple icon grid: 824 of 1024
        let radius = tile.width * 0.2237
        let outer = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

        // Soft shadow under the tile.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = side * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
        shadow.set()
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1).setFill()
        outer.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Gradient edge, then the flat face of the tile.
        NSGradient(colors: [NSColor(srgbRed: 0.169, green: 0.176, blue: 0.184, alpha: 1),
                            NSColor(srgbRed: 0.075, green: 0.082, blue: 0.09, alpha: 1)])?
            .draw(in: outer, angle: -90)
        let edge = tile.width * 0.04
        let inner = NSBezierPath(roundedRect: tile.insetBy(dx: edge, dy: edge),
                                 xRadius: radius - edge, yRadius: radius - edge)
        NSColor(srgbRed: 0.122, green: 0.129, blue: 0.137, alpha: 1).setFill()
        inner.fill()

        // Sweep marks, clipped to the tile.
        NSGraphicsContext.saveGraphicsState()
        inner.addClip()
        let marks: [(CGFloat, CGFloat)] = [(0.16, 0.36), (0.30, 0.20), (0.74, 0.16)]
        for (x, alpha) in marks {
            let line = NSBezierPath()
            line.lineWidth = tile.width * 0.052
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: tile.minX + tile.width * (x - 0.18), y: tile.minY + tile.height * 0.06))
            line.line(to: NSPoint(x: tile.minX + tile.width * (x + 0.34), y: tile.minY + tile.height * 0.94))
            NSColor.white.withAlphaComponent(alpha * 0.42).setStroke()
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The panda.
        let zoom: CGFloat = 1.34
        // Dark ears with a thin light rim, so they stay visible on the dark tile.
        for ear in placed(earShapes, in: tile, zoom: zoom) {
            NSColor(srgbRed: 0.18, green: 0.19, blue: 0.2, alpha: 1).setFill()
            ear.fill()
            ear.lineWidth = tile.width * 0.014
            NSColor.white.withAlphaComponent(0.92).setStroke()
            ear.stroke()
        }
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        placed([headShape], in: tile, zoom: zoom)[0].fill()
        NSColor(srgbRed: 0.122, green: 0.129, blue: 0.137, alpha: 1).setFill()
        for p in placed(patchShapes, in: tile, zoom: zoom) { p.fill() }
        placed([noseShape], in: tile, zoom: zoom).first?.fill()
        NSColor.white.setFill()
        for p in placed(eyeDots, in: tile, zoom: zoom) { p.fill() }
    }

    /// Writes the PNG sizes that `iconutil` needs.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        try writeMenuBarPreview(to: directory.deletingLastPathComponent().appendingPathComponent("menubar-preview.png"))
    }

    /// A large picture of the menu bar glyph on light and dark bars. It is for review only.
    private static func writeMenuBarPreview(to url: URL) throws {
        let scale: CGFloat = 10
        let width = 20 * scale * 2 + 60, height = 18 * scale + 40
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let frames: [(NSColor, NSColor)] = [(.white, .black), (NSColor(white: 0.15, alpha: 1), .white)]
        for (i, (bg, fg)) in frames.enumerated() {
            let box = NSRect(x: 20 + CGFloat(i) * (20 * scale + 20), y: 20, width: 20 * scale, height: 18 * scale)
            bg.setFill(); NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
            let tinted = NSImage(size: box.size, flipped: false) { r in
                menuBarIcon().draw(in: r)
                fg.setFill(); r.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: box)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: url) }
    }
}
