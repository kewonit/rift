import AppKit
import MapKit

/// A destination country, drawn like a station on a transit map. Busier
/// countries get a slightly larger dot, and a country where every connection
/// was blocked is red with a cross. The name and count appear while the pointer
/// is over the marker or it is selected.
final class DestinationMarkerView: MKAnnotationView {
    static let reuseIdentifier = "destination"
    /// The view stays this big so the small dot is still easy to click.
    private static let hitSize: CGFloat = 22

    private let label = MarkerLabel()
    private var connections = 0
    private var allBlocked = false
    private var someBlocked = false
    private var style = NetworkMapStyle.standard
    private var hovering = false {
        didSet { if hovering != oldValue { updateLabel() } }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize)
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

    func configure(_ destination: MapDestination, dimmed: Bool, style: NetworkMapStyle) {
        let activity = destination.activity
        self.style = style
        connections = activity.connections
        allBlocked = activity.allBlocked
        someBlocked = activity.blocked > 0 && !activity.allBlocked
        alphaValue = dimmed ? 0.45 : 1
        label.text = "\(destination.name) · \(destination.summary)"
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

    private var dotDiameter: CGFloat {
        switch connections {
        case ...1: 8
        case 2...9: 10
        default: 12
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if allBlocked {
            let disc = bounds.insetBy(dx: 4, dy: 4)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: disc).fill()
            drawSymbol("xmark", in: disc.insetBy(dx: 4, dy: 4))
            return
        }
        let inset = (bounds.width - dotDiameter) / 2
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        NSColor.white.setFill()
        dot.fill()
        NetworkMapPalette.mark(style: style, appearance: effectiveAppearance).setStroke()
        dot.lineWidth = 1.5
        dot.stroke()
        if someBlocked {
            let badge = CGRect(x: bounds.midX + dotDiameter / 2 - 3, y: bounds.midY - dotDiameter / 2 - 2, width: 5, height: 5)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }

    private func drawSymbol(_ name: String, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: rect)
    }
}

/// Where the user placed this Mac: a solid dot in a white ring, always labeled.
final class OriginMarkerView: MKAnnotationView {
    static let reuseIdentifier = "origin"
    private let label = MarkerLabel()
    var style = NetworkMapStyle.standard {
        didSet { needsDisplay = true }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 16, height: 16)
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
        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        NetworkMapPalette.mark(style: style, appearance: effectiveAppearance).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
    }
}

/// A small pill label under a marker.
private final class MarkerLabel: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
         .foregroundColor: NSColor.labelColor]
    }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 10, height: ceil(size.height) + 3)
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
        (text as NSString).draw(at: CGPoint(x: 5, y: 1.5), withAttributes: attributes)
    }
}
