import AppKit
import MapKit

/// A compact marker for a destination country: a dot with the connection
/// count, red with a cross when every connection was blocked. The country name
/// appears while the pointer is over the marker or it is selected.
final class DestinationMarkerView: MKAnnotationView {
    static let reuseIdentifier = "destination"
    private static let diameter: CGFloat = 22

    private let label = MarkerLabel()
    private var connections = 0
    private var allBlocked = false
    private var someBlocked = false
    private var hovering = false {
        didSet { if hovering != oldValue { updateLabel() } }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .defaultHigh
        label.isHidden = true
        addSubview(label)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ destination: MapDestination, dimmed: Bool) {
        let activity = destination.activity
        connections = activity.connections
        allBlocked = activity.allBlocked
        someBlocked = activity.blocked > 0 && !activity.allBlocked
        alphaValue = dimmed ? 0.45 : 1
        label.text = destination.name
        setAccessibilityLabel("\(destination.name): \(destination.summary)")
        setAccessibilityRole(.button)
        needsDisplay = true
        updateLabel()
    }

    override var isSelected: Bool {
        didSet { updateLabel() }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    private func updateLabel() {
        label.isHidden = !(hovering || isSelected)
        label.sizeToFit()
        label.frame.origin = CGPoint(
            x: (bounds.width - label.frame.width) / 2,
            y: -label.frame.height - 4
        )
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let disc = bounds.insetBy(dx: 1.5, dy: 1.5)
        let fill: NSColor = allBlocked ? .systemRed : .controlAccentColor
        let circle = NSBezierPath(ovalIn: disc)
        fill.setFill()
        circle.fill()
        NSColor.white.setStroke()
        circle.lineWidth = 2
        circle.stroke()
        if allBlocked {
            drawSymbol("xmark", in: disc.insetBy(dx: 5.5, dy: 5.5))
        } else if connections > 1 {
            drawCount(connections > 99 ? "99+" : String(connections), in: disc)
        } else {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: disc.midX - 3, y: disc.midY - 3, width: 6, height: 6)).fill()
        }
        if someBlocked {
            let badge = CGRect(x: bounds.maxX - 8, y: bounds.minY, width: 8, height: 8)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }

    private func drawCount(_ text: String, in rect: CGRect) {
        let size: CGFloat = text.count > 2 ? 8.5 : 10.5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let measured = string.size(withAttributes: attributes)
        string.draw(
            at: CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
            withAttributes: attributes
        )
    }

    private func drawSymbol(_ name: String, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: rect)
    }
}

/// Where the user placed this Mac: a white disc in an accent ring, always
/// labeled.
final class OriginMarkerView: MKAnnotationView {
    static let reuseIdentifier = "origin"
    private let label = MarkerLabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        label.text = "This Mac"
        label.sizeToFit()
        label.frame.origin = CGPoint(x: (frame.width - label.frame.width) / 2, y: -label.frame.height - 4)
        addSubview(label)
        setAccessibilityLabel("This Mac")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.controlAccentColor.setFill()
        ring.fill()
        let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        NSColor.white.setFill()
        inner.fill()
    }
}

/// A small pill label under a marker.
private final class MarkerLabel: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
         .foregroundColor: NSColor.labelColor]
    }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 4)
    }

    func sizeToFit() { setFrameSize(intrinsicContentSize) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        pill.fill()
        NSColor.separatorColor.setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        (text as NSString).draw(at: CGPoint(x: 6, y: 2), withAttributes: attributes)
    }
}
