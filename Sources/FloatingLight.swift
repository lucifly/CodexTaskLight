import AppKit
import QuartzCore

@MainActor
final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingLightView: NSView {
    var state: TaskState = .unknown { didSet { if oldValue != state { updateLampColors() } } }
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onReset: (() -> Void)?
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var dragged = false
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private let housing = CALayer()
    private var lamps: [CALayer] = []
    private var highlights: [CALayer] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }
    private func configureLayers() {
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        housing.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        housing.borderColor = NSColor(calibratedWhite: 0.65, alpha: 0.65).cgColor
        housing.borderWidth = 0.8
        layer?.addSublayer(housing)
        for _ in 0..<3 {
            let lamp = CALayer()
            lamp.cornerRadius = 7
            layer?.addSublayer(lamp)
            lamps.append(lamp)
            let highlight = CALayer()
            highlight.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            highlight.cornerRadius = 1
            lamp.addSublayer(highlight)
            highlights.append(highlight)
        }
        CATransaction.commit()
        positionLayers()
        updateLampColors()
    }
    override func layout() {
        super.layout()
        positionLayers()
    }
    private func positionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let body = bounds.insetBy(dx: 1, dy: 1)
        housing.frame = body
        housing.cornerRadius = body.width / 2
        for (index, lamp) in lamps.enumerated() {
            lamp.frame = CGRect(
                x: (bounds.width - 14) / 2, y: bounds.height - 29 - CGFloat(index) * 26, width: 14, height: 14)
            highlights[index].frame = CGRect(x: 3, y: 9, width: 3, height: 2)
        }
        CATransaction.commit()
    }
    private func updateLampColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, lampState) in [TaskState.failed, .running, .completed].enumerated() {
            guard index < lamps.count else { continue }
            let active = state == lampState || (state == .waiting && lampState == .failed)
            let color =
                state == .unknown && index == 1
                ? NSColor.systemGray : (active ? lampState.color : lampState.color.withAlphaComponent(0.20))
            lamps[index].backgroundColor = color.cgColor
            highlights[index].opacity = active ? 1 : 0
        }
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLampColors()
    }
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let dx = point.x - mouseStart.x
        let dy = point.y - mouseStart.y
        if hypot(dx, dy) > 3 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let details = NSMenuItem(title: "查看任务详情", action: #selector(showDetails), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
        let reset = NSMenuItem(title: "重置位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CodexTaskLight", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func showDetails() { onClick?() }
    @objc private func resetPosition() { onReset?() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

@MainActor
final class FloatingLightController: NSObject {
    let panel: LightPanel
    let light = FloatingLightView(frame: NSRect(x: 0, y: 0, width: 40, height: 96))
    var enabled: Bool
    var screenObserver: NSObjectProtocol?
    init(onClick: @escaping () -> Void) {
        enabled = true
        panel = LightPanel(
            contentRect: light.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = light
        light.onClick = onClick
        light.onReset = { [weak self] in self?.resetPosition() }
        light.onMoved = { [weak self] in
            self?.keepOnScreen()
            self?.savePosition()
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "floatingPositionSaved") {
            panel.setFrameOrigin(
                NSPoint(x: defaults.double(forKey: "floatingX"), y: defaults.double(forKey: "floatingY")))
            keepOnScreen()
        } else {
            resetPosition()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keepOnScreen()
                self?.savePosition()
            }
        }
        if enabled { panel.orderFrontRegardless() }
    }
    func setVisible(_ visible: Bool) {
        enabled = visible
        UserDefaults.standard.set(visible, forKey: "floatingWindowEnabled")
        if visible {
            keepOnScreen()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
    func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 24, y: area.maxY - panel.frame.height - 64))
        savePosition()
    }
    func keepOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let x = min(max(panel.frame.minX, area.minX + 4), area.maxX - panel.frame.width - 4)
        let y = min(max(panel.frame.minY, area.minY + 4), area.maxY - panel.frame.height - 4)
        let origin = NSPoint(x: x, y: y)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
    func savePosition() {
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.minX, forKey: "floatingX")
        defaults.set(panel.frame.minY, forKey: "floatingY")
        defaults.set(true, forKey: "floatingPositionSaved")
    }
    func update(state: TaskState, title: String) {
        light.state = state
        light.toolTip = state.title + " · " + title + "\n拖动调整位置，点击查看详情"
        light.setAccessibilityElement(true)
        light.setAccessibilityRole(.button)
        light.setAccessibilityLabel("任务状态：" + state.title)
    }
}
