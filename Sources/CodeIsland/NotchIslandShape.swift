import AppKit
import QuartzCore

/// The island's silhouette as NotchPanelView lays it out: top-anchored,
/// centred on the panel window plus `centerOffset`.
struct NotchIslandGeometry: Equatable {
    var centerOffset: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// The inverse-radius shoulders reaching out along the top edge.
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    var expanded: Bool
}

/// SwiftUI's `.spring(response:dampingFraction:)` for CASpringAnimation
/// (unit mass), so the island moves exactly as NotchAnimation describes it.
struct NotchSpring: Equatable {
    var response: TimeInterval
    var dampingFraction: CGFloat

    var stiffness: CGFloat { pow(2 * .pi / CGFloat(response), 2) }
    var damping: CGFloat { 4 * .pi * dampingFraction / CGFloat(response) }

    static var open: NotchSpring {
        NotchSpring(response: NotchAnimationMetrics.openResponse, dampingFraction: NotchAnimationMetrics.openDamping)
    }
    static var close: NotchSpring {
        NotchSpring(response: NotchAnimationMetrics.closeResponse, dampingFraction: NotchAnimationMetrics.closeDamping)
    }
    /// Collapsed-bar changes: the prehover widen, the idle indicator's ear.
    static var settle: NotchSpring {
        NotchSpring(response: NotchHoverInteraction.prehoverAnimationDuration, dampingFraction: 1)
    }

    func animation(keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = stiffness
        a.damping = damping
        a.duration = a.settlingDuration
        return a
    }
}

/// Moves the island's black silhouette with Core Animation, so the open and
/// close springs run in the render server at the display's own rate instead
/// of being stepped by SwiftUI on the main thread (uneven 8 ms steps, and a
/// first frame that waited for the expanded content's layout).
///
/// `maskLayer` masks the panel's whole content — a black fill and the SwiftUI
/// view above it — so the same silhouette is both the island and its clip.
/// Every scalar animates additively: a new target mid-spring (the measured
/// expanded height, a close before the open settled) adds its own spring on
/// top of the one running, keeping position and speed continuous.
@MainActor
final class NotchIslandShapeDriver {
    let maskLayer = CALayer()
    private let body = CALayer()
    private let leftShoulder = CAShapeLayer()
    private let rightShoulder = CAShapeLayer()

    private(set) var target: NotchIslandGeometry?
    private var bounds: CGRect = .zero
    private var lastFlip: CFTimeInterval = 0
    private var serial = 0

    init() {
        maskLayer.anchorPoint = .zero
        body.backgroundColor = NSColor.black.cgColor
        // Anchored at the top edge: height grows downward, width from the centre.
        body.anchorPoint = CGPoint(x: 0.5, y: 1)
        body.cornerCurve = .continuous
        // The layer is unflipped, so the bottom corners are the min-Y ones.
        body.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        for shoulder in [leftShoulder, rightShoulder] {
            shoulder.fillColor = NSColor.black.cgColor
            shoulder.bounds = .zero
            shoulder.anchorPoint = .zero
        }
        maskLayer.addSublayer(body)
        maskLayer.addSublayer(leftShoulder)
        maskLayer.addSublayer(rightShoulder)
    }

    /// The panel's content bounds (unflipped). The island hangs from the top.
    func setBounds(_ newBounds: CGRect) {
        guard newBounds != bounds else { return }
        bounds = newBounds
        withoutActions {
            maskLayer.frame = newBounds
            if let target { place(target) }
        }
    }

    /// Animate to `geometry` with the spring its change calls for: open or
    /// close when the island flips, otherwise the one already under way.
    func update(_ geometry: NotchIslandGeometry) {
        guard geometry != target else { return }
        let now = CACurrentMediaTime()
        let spring: NotchSpring?
        if let target {
            if geometry.expanded != target.expanded {
                lastFlip = now
                spring = geometry.expanded ? .open : .close
            } else if geometry.expanded {
                // A height measured just after the open joins the open spring;
                // later content changes settle without a bounce.
                spring = now - lastFlip < NotchAnimationMetrics.openResponse ? .open : .close
            } else {
                spring = .settle
            }
        } else {
            spring = nil
        }
        apply(geometry, spring: spring)
    }

    func apply(_ geometry: NotchIslandGeometry, spring: NotchSpring?) {
        let old = target
        target = geometry
        withoutActions { place(geometry) }
        guard let spring, let old else { return }

        serial += 1
        let w = Self.edges(old), n = Self.edges(geometry)
        additive(body, "position.x", from: w.center - n.center, spring)
        additive(body, "bounds.size.width", from: old.width - geometry.width, spring)
        additive(body, "bounds.size.height", from: old.height - geometry.height, spring)
        additive(body, "cornerRadius", from: old.bottomRadius - geometry.bottomRadius, spring)
        additive(leftShoulder, "position.x", from: w.left - n.left, spring)
        additive(rightShoulder, "position.x", from: w.right - n.right, spring)

        if old.topExtension != geometry.topExtension {
            for (layer, side) in [(leftShoulder, CGFloat(-1)), (rightShoulder, CGFloat(1))] {
                let a = spring.animation(keyPath: "path")
                a.fromValue = layer.presentation()?.path ?? Self.shoulder(old.topExtension, side: side)
                a.toValue = layer.path
                layer.add(a, forKey: "path")
            }
        }
    }

    private func place(_ g: NotchIslandGeometry) {
        let e = Self.edges(g)
        let top = bounds.maxY
        body.bounds = CGRect(x: 0, y: 0, width: g.width, height: g.height)
        body.position = CGPoint(x: bounds.midX + e.center, y: top)
        body.cornerRadius = g.bottomRadius
        leftShoulder.position = CGPoint(x: bounds.midX + e.left, y: top)
        rightShoulder.position = CGPoint(x: bounds.midX + e.right, y: top)
        leftShoulder.path = Self.shoulder(g.topExtension, side: -1)
        rightShoulder.path = Self.shoulder(g.topExtension, side: 1)
    }

    private func additive(_ layer: CALayer, _ keyPath: String, from delta: CGFloat, _ spring: NotchSpring) {
        guard abs(delta) > 0.001 else { return }
        let a = spring.animation(keyPath: keyPath)
        a.isAdditive = true
        a.fromValue = delta
        a.toValue = 0
        layer.add(a, forKey: "\(keyPath)#\(serial)")
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Centre and both top corners, relative to the panel's centre.
    static func edges(_ g: NotchIslandGeometry) -> (center: CGFloat, left: CGFloat, right: CGFloat) {
        (g.centerOffset, g.centerOffset - g.width / 2, g.centerOffset + g.width / 2)
    }

    /// The concave fillet between the top edge and one side, drawn from that
    /// side's top corner (`side` -1 left, 1 right; y up) — NotchPanelShape's
    /// shoulder curve.
    static func shoulder(_ ext: CGFloat, side: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: side * ext, y: 0))
        p.addCurve(
            to: CGPoint(x: 0, y: -ext),
            control1: CGPoint(x: side * ext * 0.35, y: 0),
            control2: CGPoint(x: 0, y: -ext * 0.35)
        )
        p.closeSubpath()
        return p
    }
}

/// The panel window's content: a black fill and the SwiftUI view, both
/// masked by the island silhouette the driver animates.
final class NotchIslandContainerView: NSView {
    let driver: NotchIslandShapeDriver
    private let fill = NotchIslandFillView()

    init(content: NSView, driver: NotchIslandShapeDriver) {
        self.driver = driver
        super.init(frame: content.frame)
        wantsLayer = true
        autoresizesSubviews = true
        fill.frame = bounds
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        attachMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        attachMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachMask()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachMask()
    }

    private func attachMask() {
        guard let layer else { return }
        if layer.mask !== driver.maskLayer { layer.mask = driver.maskLayer }
        driver.setBounds(bounds)
    }
}

/// Black under the SwiftUI content; the mask makes it the island.
private final class NotchIslandFillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.black.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
