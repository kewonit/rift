import AppKit

/// Rift's mark from the app icon as a menu bar template image: two rings split
/// along a fault and slipped by one ring's spacing, so the outer band runs into
/// the inner band across the gap.
enum RiftMark {
    /// Exactly 2:1, so the fault's edge steps evenly.
    private static let fault = atan(2.0) * 180 / .pi
    // Heavier than the app icon, because the menu bar draws it at 18 points.
    private static let outerRadius = 270.0
    private static let innerRadius = 98.0
    private static let band = 112.0
    private static let gap = 84.0
    /// The drawing's height in the units above.
    private static let extent = 860.0

    static let menuBarImage: NSImage = {
        let size = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size * scale, pixelsHigh: size * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.black.setFill()
            path(in: NSRect(x: 0, y: 0, width: size, height: size)).fill()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }()

    static func path(in rect: NSRect) -> NSBezierPath {
        let unit = rect.height / extent
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let half = gap / 2
        // Where each band's centre line meets the fault, so bands line up across it.
        let slip = ((outerRadius * outerRadius - half * half).squareRoot()
            - (innerRadius * innerRadius - half * half).squareRoot()) / 2
        let path = NSBezierPath()
        for axis in [fault, fault + 180] {
            let radians = axis * .pi / 180
            let origin = NSPoint(
                x: centre.x + cos(radians) * slip * unit,
                y: centre.y + sin(radians) * slip * unit
            )
            for radius in [outerRadius, innerRadius] {
                append(
                    outer: radius + band / 2, inner: radius - band / 2,
                    facing: axis - 90, unit: unit, origin: origin, to: path
                )
            }
        }
        return path
    }

    /// One half of a ring, on the side of the fault that `facing` points to.
    private static func append(
        outer: Double, inner: Double, facing: Double, unit: Double, origin: NSPoint, to path: NSBezierPath
    ) {
        let half = gap / 2
        let outerSweep = acos(half / outer) * 180 / .pi
        let innerSweep = acos(half / inner) * 180 / .pi
        // Each half starts afresh, or the arc would draw a line from the last one.
        let start = (facing - outerSweep) * .pi / 180
        path.move(to: NSPoint(
            x: origin.x + cos(start) * outer * unit,
            y: origin.y + sin(start) * outer * unit
        ))
        path.appendArc(
            withCenter: origin, radius: outer * unit,
            startAngle: facing - outerSweep, endAngle: facing + outerSweep, clockwise: false
        )
        path.appendArc(
            withCenter: origin, radius: inner * unit,
            startAngle: facing + innerSweep, endAngle: facing - innerSweep, clockwise: true
        )
        path.close()
    }
}
