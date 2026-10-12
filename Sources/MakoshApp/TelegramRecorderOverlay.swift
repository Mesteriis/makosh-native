import AppKit
import QuartzCore

/// Own AppKit implementation of the reference's floating recorder geometry.
/// Panels stay attached to the composer window and never become key windows.
@MainActor final class TelegramRecorderOverlay {
    private weak var anchor: NSView?
    private weak var parent: NSWindow?
    private let control: NSPanel
    private let lock: NSPanel
    private let surface = RecorderControlSurface(frame: .init(x: 0, y: 0, width: 120, height: 120))
    private let lockSurface = RecorderLockSurface(frame: .init(x: 0, y: 0, width: 36, height: 50))
    private var upward: CGFloat = 0
    private var locked = false
    private var latestPointer: NSPoint?
    var toggleOneTime: () -> Void = {}
    var primaryAction: (() -> Void)? {
        didSet { surface.primaryAction = primaryAction }
    }

    init?(anchor: NSView) {
        guard let parent = anchor.window else { return nil }
        self.anchor = anchor; self.parent = parent
        control = Self.panel(size: .init(width: 120, height: 120))
        lock = Self.panel(size: .init(width: 36, height: 50))
        control.contentView = surface
        lock.contentView = lockSurface
        lockSurface.once.target = self
        lockSurface.once.action = #selector(selectOneTime)
        updatePosition()
        parent.addChildWindow(control, ordered: .above)
        parent.addChildWindow(lock, ordered: .above)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.1; scale.toValue = 1; scale.duration = 0.4
            scale.damping = 18; scale.initialVelocity = 0
            surface.layer?.add(scale, forKey: "recorder.appear.scale")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
            surface.layer?.add(fade, forKey: "recorder.appear.fade")
        }
    }
    private static func panel(size: NSSize) -> NSPanel {
        let result = NSPanel(contentRect: .init(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        result.isOpaque = false; result.backgroundColor = .clear
        result.hasShadow = false; result.hidesOnDeactivate = false
        result.collectionBehavior = [.fullScreenAuxiliary, .transient]
        result.setAccessibilitySubrole(.floatingWindow)
        return result
    }
    func update(roundVideo: Bool, locked: Bool, level: Float, canUseOneTime: Bool, isOneTime: Bool) {
        let wasLocked = self.locked
        self.locked = locked
        if locked { upward = 0 }
        surface.update(roundVideo: roundVideo, locked: locked, level: level)
        lockSurface.update(locked: locked, percent: 1 - min(1, upward / 100),
            canUseOneTime: canUseOneTime, isOneTime: isOneTime)
        updatePosition(animated: locked && !wasLocked)
        if let latestPointer { surface.setInside(contains(latestPointer)) }
    }
    func move(upward: Double, pointer: NSPoint) {
        latestPointer = pointer
        if !locked { self.upward = max(0, CGFloat(upward)); updatePosition() }
        surface.setInside(contains(pointer))
        lockSurface.updateProgress(1 - min(1, self.upward / 100))
    }
    func updatePointer(_ point: NSPoint) { latestPointer = point; surface.setInside(contains(point)) }
    func contains(_ point: NSPoint) -> Bool { control.frame.contains(point) }
    func isOneTimeControl(_ point: NSPoint) -> Bool {
        !lockSurface.once.isHidden && lock.frame.contains(point)
    }
    func owns(_ window: NSWindow?) -> Bool { window === parent || window === control || window === lock }
    func hide(animated: Bool = true) {
        parent?.removeChildWindow(control); parent?.removeChildWindow(lock)
        surface.layer?.removeAllAnimations()
        control.ignoresMouseEvents = true; lock.ignoresMouseEvents = true
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                control.animator().alphaValue = 0; lock.animator().alphaValue = 0
            } completionHandler: { [control, lock] in
                Task { @MainActor in control.orderOut(nil); lock.orderOut(nil) }
            }
        } else { control.orderOut(nil); lock.orderOut(nil) }
    }
    private func updatePosition(animated: Bool = false) {
        guard let anchor, let parent else { return }
        let center = parent.convertPoint(toScreen: anchor.convert(.init(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil))
        let rect = NSRect(x: center.x - 60, y: center.y - 60 + upward, width: 120, height: 120)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            control.animator().setFrame(rect, display: true)
        } else { control.setFrame(rect, display: true) }
        lock.setFrameOrigin(.init(x: center.x - 18, y: center.y + (locked ? 95 : 135)))
    }
    @objc private func selectOneTime() { toggleOneTime() }
}

@MainActor private final class RecorderControlSurface: NSView {
    private let inner = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let image = NSImageView()
    private var inside = true
    private var tracking: NSTrackingArea?
    var primaryAction: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        halo.frame = bounds
        halo.path = CGPath(ellipseIn: bounds.insetBy(dx: 7, dy: 7), transform: nil)
        inner.path = CGPath(ellipseIn: bounds.insetBy(dx: 20, dy: 20), transform: nil)
        layer?.addSublayer(halo); layer?.addSublayer(inner)
        image.frame = .init(x: 40, y: 40, width: 40, height: 40)
        image.contentTintColor = .white
        addSubview(image)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityIdentifier("telegram.voice.floating")
        update(roundVideo: false, locked: false, level: 0)
    }
    required init?(coder: NSCoder) { nil }
    func update(roundVideo: Bool, locked: Bool, level: Float) {
        image.image = NSImage(systemSymbolName: locked ? "paperplane.fill" : roundVideo ? "video.fill" : "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
        setAccessibilityLabel(locked ? "Отправить запись" : roundVideo ? "Запись круглого видео" : "Запись голосового сообщения")
        let scale = 0.8 + CGFloat(max(0, min(1, level))) * 0.2
        halo.transform = CATransform3DMakeScale(scale, scale, 1)
        applyColor()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }
    override func accessibilityPerformPress() -> Bool {
        guard let primaryAction else { return false }
        primaryAction(); return true
    }
    func setInside(_ inside: Bool) { self.inside = inside; applyColor() }
    private func applyColor() {
        let color = inside ? NSColor.controlAccentColor : NSColor.systemRed
        CATransaction.begin(); CATransaction.setAnimationDuration(0.1)
        inner.fillColor = color.cgColor; halo.fillColor = color.withAlphaComponent(0.3).cgColor
        CATransaction.commit()
    }
}

@MainActor private final class RecorderLockSurface: NSView {
    private let outline = NSView(frame: .init(x: 5, y: 0, width: 26, height: 50))
    private let icon = NSImageView(frame: .init(x: 8, y: 24, width: 20, height: 20))
    private let arrow = NSImageView(frame: .init(x: 11, y: 5, width: 14, height: 14))
    let once = NSButton(frame: .init(x: 0, y: 7, width: 36, height: 36))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        outline.wantsLayer = true; outline.layer?.cornerRadius = 13
        outline.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        outline.layer?.borderWidth = 1; outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(outline); addSubview(icon); addSubview(arrow); addSubview(once)
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        arrow.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor; arrow.contentTintColor = .controlAccentColor
        once.isBordered = false; once.title = ""; once.imagePosition = .imageOnly
        once.contentTintColor = .controlAccentColor
        once.setAccessibilityIdentifier("telegram.voice.overlay.oneTime")
        once.setAccessibilityLabel("Одноразовая запись")
        once.isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func update(locked: Bool, percent: CGFloat, canUseOneTime: Bool, isOneTime: Bool) {
        outline.isHidden = locked; icon.isHidden = locked; arrow.isHidden = locked
        once.isHidden = !locked || !canUseOneTime
        once.image = NSImage(systemSymbolName: isOneTime ? "1.circle.fill" : "1.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        once.setAccessibilityValue(isOneTime ? "Включено" : "Выключено")
        updateProgress(percent)
    }
    func updateProgress(_ percent: CGFloat) { arrow.alphaValue = max(0, min(1, percent)) }
}
