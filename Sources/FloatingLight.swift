import AppKit
import QuartzCore

enum LightSkin: String, CaseIterable, Identifiable, Sendable {
    case classic
    case halloween

    static let defaultsKey = "lightSkin"
    var id: String { rawValue }
    var title: String { self == .classic ? "经典红绿灯" : "万圣节 🎃" }
    var legend: String {
        self == .classic
            ? "黄：执行中  ·  绿：完成  ·  红：异常或中断\n红灯也表示等待确认或审批；处理后恢复黄灯。"
            : "幽灵：等待或异常  ·  南瓜：执行中  ·  蝙蝠：完成\n灯位仍为上红、中橙、下绿；未知状态显示灰色。"
    }

    static func restore(_ value: String?) -> LightSkin { value.flatMap(Self.init(rawValue:)) ?? .classic }
}

// The three fixed vector symbols share the classic light positions. No timer,
// bitmap assets or implicit animations are needed for the seasonal appearance.
@MainActor
final class HalloweenGlyph {
    let layer = CALayer()
    private let body = CAShapeLayer()
    private let face = CAShapeLayer()
    private let ridges = CAShapeLayer()
    private let stem = CAShapeLayer()

    init(index: Int) {
        layer.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        for shape in [body, ridges, stem, face] {
            shape.frame = layer.bounds
            layer.addSublayer(shape)
        }
        face.fillColor = NSColor(srgbRed: 0.07, green: 0.04, blue: 0.10, alpha: 1).cgColor
        ridges.fillColor = nil
        ridges.strokeColor = NSColor(srgbRed: 0.20, green: 0.07, blue: 0.05, alpha: 0.35).cgColor
        ridges.lineWidth = 0.75
        stem.fillColor = NSColor(srgbRed: 0.50, green: 0.66, blue: 0.27, alpha: 1).cgColor
        switch index {
        case 0: configureGhost()
        case 1: configurePumpkin()
        default: configureBat()
        }
        body.shadowPath = body.path
        body.shadowRadius = 3
        body.shadowOffset = .zero
    }

    private func configureGhost() {
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 3, y: 3))
        outline.addLine(to: CGPoint(x: 3, y: 13))
        outline.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 3, y: 19), control2: CGPoint(x: 6, y: 22))
        outline.addCurve(to: CGPoint(x: 21, y: 13), control1: CGPoint(x: 18, y: 22), control2: CGPoint(x: 21, y: 19))
        for point in [
            CGPoint(x: 21, y: 3), CGPoint(x: 18, y: 5), CGPoint(x: 15, y: 2), CGPoint(x: 12, y: 5), CGPoint(x: 9, y: 2),
            CGPoint(x: 6, y: 5),
        ] {
            outline.addLine(to: point)
        }
        outline.closeSubpath()
        body.path = outline
        let features = CGMutablePath()
        features.addEllipse(in: CGRect(x: 7, y: 12, width: 3, height: 4))
        features.addEllipse(in: CGRect(x: 14, y: 12, width: 3, height: 4))
        features.addEllipse(in: CGRect(x: 10.5, y: 6, width: 3, height: 4))
        face.path = features
    }

    private func configurePumpkin() {
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 12, y: 19))
        outline.addCurve(to: CGPoint(x: 2, y: 13), control1: CGPoint(x: 8, y: 22), control2: CGPoint(x: 2, y: 20))
        outline.addCurve(to: CGPoint(x: 9, y: 3), control1: CGPoint(x: 0, y: 6), control2: CGPoint(x: 4, y: 2))
        outline.addQuadCurve(to: CGPoint(x: 15, y: 3), control: CGPoint(x: 12, y: 1))
        outline.addCurve(to: CGPoint(x: 22, y: 13), control1: CGPoint(x: 20, y: 2), control2: CGPoint(x: 24, y: 6))
        outline.addCurve(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 22, y: 20), control2: CGPoint(x: 16, y: 22))
        outline.closeSubpath()
        body.path = outline
        let grooves = CGMutablePath()
        grooves.move(to: CGPoint(x: 9, y: 19))
        grooves.addCurve(to: CGPoint(x: 9, y: 3), control1: CGPoint(x: 6, y: 15), control2: CGPoint(x: 6, y: 7))
        grooves.move(to: CGPoint(x: 15, y: 19))
        grooves.addCurve(to: CGPoint(x: 15, y: 3), control1: CGPoint(x: 18, y: 15), control2: CGPoint(x: 18, y: 7))
        ridges.path = grooves
        stem.path = Self.polygon([
            CGPoint(x: 11, y: 19), CGPoint(x: 11, y: 23), CGPoint(x: 15, y: 23), CGPoint(x: 13, y: 19),
        ])
        let features = CGMutablePath()
        features.addPath(Self.polygon([CGPoint(x: 5, y: 13), CGPoint(x: 9, y: 16), CGPoint(x: 10, y: 12)]))
        features.addPath(Self.polygon([CGPoint(x: 14, y: 12), CGPoint(x: 15, y: 16), CGPoint(x: 19, y: 13)]))
        features.addPath(Self.polygon([CGPoint(x: 11, y: 10), CGPoint(x: 12, y: 12), CGPoint(x: 13, y: 10)]))
        features.addPath(
            Self.polygon([
                CGPoint(x: 6, y: 8), CGPoint(x: 9, y: 7), CGPoint(x: 10, y: 8), CGPoint(x: 11, y: 6),
                CGPoint(x: 13, y: 6), CGPoint(x: 14, y: 8), CGPoint(x: 15, y: 7), CGPoint(x: 18, y: 8),
                CGPoint(x: 15, y: 4), CGPoint(x: 9, y: 4),
            ]))
        face.path = features
    }

    private func configureBat() {
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 1, y: 18))
        outline.addCurve(to: CGPoint(x: 8, y: 13), control1: CGPoint(x: 5, y: 18), control2: CGPoint(x: 5, y: 14))
        for point in [CGPoint(x: 9, y: 19), CGPoint(x: 12, y: 16), CGPoint(x: 15, y: 19), CGPoint(x: 16, y: 13)] {
            outline.addLine(to: point)
        }
        outline.addCurve(to: CGPoint(x: 23, y: 18), control1: CGPoint(x: 19, y: 14), control2: CGPoint(x: 19, y: 18))
        for point in [
            CGPoint(x: 22, y: 9), CGPoint(x: 19, y: 11), CGPoint(x: 17, y: 7), CGPoint(x: 15, y: 9),
            CGPoint(x: 12, y: 4), CGPoint(x: 9, y: 9), CGPoint(x: 7, y: 7), CGPoint(x: 5, y: 11), CGPoint(x: 2, y: 9),
        ] {
            outline.addLine(to: point)
        }
        outline.closeSubpath()
        body.path = outline
        let features = CGMutablePath()
        features.addEllipse(in: CGRect(x: 9, y: 11, width: 2, height: 2))
        features.addEllipse(in: CGRect(x: 13, y: 11, width: 2, height: 2))
        face.path = features
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    func update(index: Int, state: TaskState) {
        let active = [TaskState.failed, .running, .completed][index] == state || (index == 0 && state == .waiting)
        let unknown = state == .unknown
        let colors = [
            NSColor(srgbRed: 1, green: 0.32, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 1, green: 0.59, blue: 0.15, alpha: 1),
            NSColor(srgbRed: 0.48, green: 0.89, blue: 0.44, alpha: 1),
        ]
        let color = unknown ? NSColor.systemGray : colors[index]
        stem.fillColor =
            unknown
            ? NSColor.systemGray.cgColor
            : NSColor(srgbRed: 0.50, green: 0.66, blue: 0.27, alpha: 1).cgColor
        body.fillColor = color.cgColor
        body.shadowColor = color.cgColor
        body.shadowOpacity = active ? 0.6 : 0
        layer.opacity = active ? 1 : (unknown && index == 1 ? 0.85 : 0.23)
    }
}

@MainActor
final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingLightView: NSView {
    var state: TaskState = .unknown { didSet { if oldValue != state { updateLampColors() } } }
    var skin: LightSkin = .classic { didSet { if oldValue != skin { updateLampColors() } } }
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onReset: (() -> Void)?
    var onSkinSelected: ((LightSkin) -> Void)?
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var dragged = false
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private let housing = CALayer()
    private var lamps: [CALayer] = []
    private var highlights: [CALayer] = []
    private var halloweenGlyphs: [HalloweenGlyph] = []
    private let cobweb = CAShapeLayer()
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
            let glyph = HalloweenGlyph(index: lamps.count - 1)
            layer?.addSublayer(glyph.layer)
            halloweenGlyphs.append(glyph)
        }
        cobweb.fillColor = nil
        cobweb.strokeColor = NSColor(srgbRed: 0.94, green: 0.63, blue: 0.31, alpha: 0.35).cgColor
        cobweb.lineWidth = 0.55
        layer?.addSublayer(cobweb)
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
            halloweenGlyphs[index].layer.frame = CGRect(
                x: (bounds.width - 24) / 2, y: bounds.height - 33 - CGFloat(index) * 26, width: 24, height: 24)
        }
        cobweb.frame = bounds
        let web = CGMutablePath()
        let corner = CGPoint(x: bounds.width - 7, y: bounds.height - 9)
        for end in [
            CGPoint(x: bounds.width - 15, y: bounds.height - 6), CGPoint(x: bounds.width - 13, y: bounds.height - 15),
            CGPoint(x: bounds.width - 4, y: bounds.height - 19),
        ] {
            web.move(to: corner)
            web.addLine(to: end)
        }
        web.move(to: CGPoint(x: bounds.width - 10, y: bounds.height - 6.5))
        web.addQuadCurve(
            to: CGPoint(x: bounds.width - 4, y: bounds.height - 13),
            control: CGPoint(x: bounds.width - 10, y: bounds.height - 13))
        cobweb.path = web
        CATransaction.commit()
    }
    private func updateLampColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let halloween = skin == .halloween
        housing.backgroundColor =
            halloween
            ? NSColor(srgbRed: 0.105, green: 0.06, blue: 0.14, alpha: 0.98).cgColor
            : NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        housing.borderColor =
            halloween
            ? NSColor(srgbRed: 0.74, green: 0.38, blue: 0.15, alpha: 0.85).cgColor
            : NSColor(calibratedWhite: 0.65, alpha: 0.65).cgColor
        cobweb.isHidden = !halloween
        for (index, lampState) in [TaskState.failed, .running, .completed].enumerated() {
            guard index < lamps.count else { continue }
            let active = state == lampState || (state == .waiting && lampState == .failed)
            let color =
                state == .unknown && index == 1
                ? NSColor.systemGray : (active ? lampState.color : lampState.color.withAlphaComponent(0.20))
            lamps[index].backgroundColor = color.cgColor
            highlights[index].opacity = active ? 1 : 0
            lamps[index].isHidden = halloween
            halloweenGlyphs[index].layer.isHidden = !halloween
            halloweenGlyphs[index].update(index: index, state: state)
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
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let skins = NSMenu()
        for option in LightSkin.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == skin ? .on : .off
            skins.addItem(item)
        }
        appearance.submenu = skins
        menu.addItem(appearance)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CodexTaskLight", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func showDetails() { onClick?() }
    @objc private func resetPosition() { onReset?() }
    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let skin = LightSkin(rawValue: raw) else { return }
        onSkinSelected?(skin)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

@MainActor
final class FloatingLightController: NSObject {
    let panel: LightPanel
    let light = FloatingLightView(frame: NSRect(x: 0, y: 0, width: 40, height: 96))
    var enabled: Bool
    var screenObserver: NSObjectProtocol?
    init(skin: LightSkin = .classic, onClick: @escaping () -> Void) {
        enabled = true
        light.skin = skin
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
    func update(state: TaskState, title: String, skin: LightSkin) {
        light.skin = skin
        light.state = state
        light.toolTip = state.title + " · " + title + "\n" + skin.title + " · 拖动调整位置，点击查看详情"
        light.setAccessibilityElement(true)
        light.setAccessibilityRole(.button)
        light.setAccessibilityLabel("任务状态：" + state.title)
    }
}
