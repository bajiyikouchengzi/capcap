import AppKit

final class ColorPickerRunner {
    static let shared = ColorPickerRunner()

    private var activeColorSampler: NSColorSampler?
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var consumedKeys: Set<Int64> = []
    private var isConfirmingPick = false
    private var hintPanel: NSPanel?

    var isActive: Bool { activeColorSampler != nil }

    private init() {}

    func cancel() {
        guard activeColorSampler != nil else { return }
        activeColorSampler = nil
        stopKeyboardMonitoring()
        Self.postEscapeKeyEvent()
    }

    @discardableResult
    func run(
        on screen: NSScreen? = nil,
        onPicked: ((NSColor, String) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) -> Bool {
        guard activeColorSampler == nil else { return false }

        let sampler = NSColorSampler()
        activeColorSampler = sampler
        startKeyboardMonitoring()
        showKeyboardHint(on: screen ?? Self.currentScreen())
        sampler.show { [weak self, weak sampler] picked in
            guard let self, self.activeColorSampler === sampler else { return }
            self.activeColorSampler = nil
            self.stopKeyboardMonitoring()
            guard let picked else {
                onFinished?()
                return
            }

            let result = Self.pickResult(from: picked)
            let copied = ClipboardManager.copyColorToClipboard(hex: result.hex)

            if Defaults.historyCacheEnabled {
                HistoryManager.shared.addColor(hex: result.hex)
                Defaults.lastPickedColorHex = result.hex
            }

            NotificationCenter.default.post(name: .colorPaletteDidChange, object: nil)
            onPicked?(result.color, result.hex)
            ToastWindow.show(message: L10n.colorCopied(copied), on: screen ?? Self.currentScreen())
            onFinished?()
        }
        return true
    }

    private func showKeyboardHint(on screen: NSScreen?) {
        guard let screen else { return }
        let width = min(620, screen.visibleFrame.width - 40)
        let label = NSTextField(wrappingLabelWithString: "\(Defaults.colorValueFormat.title)  ·  \(L10n.colorPickerControls)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let surface = NSVisualEffectView()
        surface.material = .hudWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.masksToBounds = true
        surface.addSubview(label)
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - width / 2,
                                                y: screen.visibleFrame.minY + 24,
                                                width: width, height: 54),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = surface
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver + 4
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        panel.orderFrontRegardless()
        hintPanel = panel
    }

    private func startKeyboardMonitoring() {
        stopKeyboardMonitoring()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        // A session tap also reaches the system sampler when it owns keyboard
        // focus. Consume handled keys so native navigation cannot move it twice.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let runner = Unmanaged<ColorPickerRunner>.fromOpaque(context).takeUnretainedValue()
                return runner.handleKeyEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        keyboardTap = tap
        keyboardSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopKeyboardMonitoring() {
        hintPanel?.orderOut(nil)
        hintPanel = nil
        if let keyboardTap {
            CGEvent.tapEnable(tap: keyboardTap, enable: false)
            CFMachPortInvalidate(keyboardTap)
        }
        if let keyboardSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes)
        }
        keyboardTap = nil
        keyboardSource = nil
        consumedKeys.removeAll()
        isConfirmingPick = false
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard isActive else { return passthrough }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyboardTap { CGEvent.tapEnable(tap: keyboardTap, enable: true) }
            return passthrough
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            guard consumedKeys.remove(key) != nil else { return passthrough }
            // Confirm on release so the matching Return key-up is consumed
            // before the sampler closes and focus returns to the editor.
            if key == 36 || key == 76 { confirmCurrentColor() }
            return nil
        }
        guard type == .keyDown,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        else { return passthrough }
        if key == 36 || key == 76 { // Return and numeric keypad Enter
            consumedKeys.insert(key)
            return nil
        }
        guard !isConfirmingPick else { return passthrough }
        let direction: CGPoint
        switch key {
        case 123: direction = CGPoint(x: -1, y: 0)
        case 124: direction = CGPoint(x: 1, y: 0)
        case 125: direction = CGPoint(x: 0, y: 1)
        case 126: direction = CGPoint(x: 0, y: -1)
        default: return passthrough
        }
        consumedKeys.insert(key)
        moveSamplerCursor(direction: direction)
        return nil
    }

    private func confirmCurrentColor() {
        guard !isConfirmingPick,
              let position = CGEvent(source: nil)?.location,
              let mouseDown = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: position, mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: position, mouseButton: .left
              )
        else { return }
        isConfirmingPick = true
        // Use the sampler's existing selection path so keyboard confirmation
        // shares color conversion, clipboard, history and completion callbacks.
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    private func moveSamplerCursor(direction: CGPoint) {
        guard let position = CGEvent(source: nil)?.location else { return }
        let displays = NSScreen.screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (screen, CGDisplayBounds(id))
        }
        guard let display = displays.first(where: { $0.bounds.contains(position) }) else { return }
        // Quartz cursor coordinates are points, not backing pixels.
        let step = 1 / max(display.screen.backingScaleFactor, 1)
        var target = CGPoint(x: position.x + direction.x * step, y: position.y + direction.y * step)
        if !displays.contains(where: { $0.bounds.contains(target) }) {
            // Stay on the display at an outer edge or a gap between monitors.
            target.x = min(max(target.x, display.bounds.minX), display.bounds.maxX - step)
            target.y = min(max(target.y, display.bounds.minY), display.bounds.maxY - step)
        }
        guard CGWarpMouseCursorPosition(target) == .success else { return }
        // Warping alone emits no event, so notify the sampler to refresh its
        // loupe and the color beneath the new cursor location as well.
        let movement = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: target, mouseButton: .left
        )
        movement?.post(tap: .cghidEventTap)
    }

    private static func pickResult(from color: NSColor) -> (color: NSColor, hex: String) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        let swatchColor = NSColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        return (swatchColor, String(format: "#%02X%02X%02X", r, g, b))
    }

    private static func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private static func postEscapeKeyEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let escapeKeyCode = CGKeyCode(53)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
