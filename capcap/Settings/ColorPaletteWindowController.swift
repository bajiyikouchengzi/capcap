import AppKit

/// A persistent favorite palette with recent colors supplied by screenshot history.
final class ColorPaletteWindowController: NSWindowController {
    static let shared = ColorPaletteWindowController()
    private let stack = NSStackView()
    private var recentColors: [String] = []
    private var loadGeneration = UUID()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 300)
        super.init(window: panel)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        panel.contentView = scroll
        let document = ColorPaletteDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        for name in [Notification.Name.languageDidChange, .colorPaletteDidChange, .historyDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func showPalette() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func refresh() {
        rebuild()
        let includeHistory = Defaults.historyCacheEnabled
        let generation = UUID()
        loadGeneration = generation
        // Reading history may touch disk and extended attributes.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var seen = Set<String>()
            let colors = (includeHistory ? HistoryManager.shared.entries() : []).compactMap { entry -> String? in
                guard case .color(let value) = entry.kind,
                      let hex = ClipboardColorParser.normalizedHex(from: value),
                      seen.insert(hex).inserted else { return nil }
                return hex
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.recentColors = Array(colors.prefix(30))
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        window?.title = L10n.colorPaletteTitle
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let format = NSPopUpButton()
        format.addItems(withTitles: ColorValueFormat.allCases.map(\.title))
        format.selectItem(at: ColorValueFormat.allCases.firstIndex(of: Defaults.colorValueFormat) ?? 0)
        format.target = self
        format.action = #selector(formatChanged(_:))
        let formatRow = NSStackView(views: [NSTextField(labelWithString: L10n.colorCopyFormat), NSView(), format])
        formatRow.orientation = .horizontal
        formatRow.alignment = .centerY
        add(formatRow)
        let hint = NSTextField(wrappingLabelWithString: L10n.colorPaletteHint)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        add(hint)
        addHeading(L10n.colorFavoritesTitle)
        let favorites = Defaults.favoriteColorHexes
        if favorites.isEmpty { addEmpty(L10n.colorFavoritesEmpty) }
        favorites.forEach(addColor)
        addHeading(L10n.colorRecentTitle)
        var recent = recentColors
        if let last = Defaults.lastPickedColorHex, !recent.contains(last) { recent.insert(last, at: 0) }
        if recent.isEmpty { addEmpty(L10n.colorRecentEmpty) }
        recent.forEach(addColor)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addHeading(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        add(label)
    }

    private func addEmpty(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        add(label)
    }

    private func addColor(_ hex: String) {
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = ColorValueFormat.color(from: hex)?.cgColor
        swatch.layer?.cornerRadius = 5
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let copy = NSButton(title: Defaults.colorValueFormat.string(from: hex), target: self, action: #selector(copyColor(_:)))
        copy.identifier = NSUserInterfaceItemIdentifier(hex)
        copy.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        copy.bezelStyle = .rounded
        copy.toolTip = L10n.colorCopyAction
        let favorite = NSButton()
        let selected = Defaults.favoriteColorHexes.contains(hex)
        favorite.image = NSImage(systemSymbolName: selected ? "star.fill" : "star", accessibilityDescription: nil)
        favorite.contentTintColor = selected ? .systemYellow : .secondaryLabelColor
        favorite.isBordered = false
        favorite.identifier = NSUserInterfaceItemIdentifier(hex)
        favorite.target = self
        favorite.action = #selector(toggleFavorite(_:))
        favorite.toolTip = selected ? L10n.colorRemoveFavorite : L10n.colorAddFavorite
        favorite.setAccessibilityLabel(favorite.toolTip)
        let row = NSStackView(views: [swatch, copy, NSView(), favorite])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        add(row)
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard ColorValueFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        Defaults.colorValueFormat = ColorValueFormat.allCases[sender.indexOfSelectedItem]
    }

    @objc private func copyColor(_ sender: NSButton) {
        guard let hex = sender.identifier?.rawValue else { return }
        let copied = ClipboardManager.copyColorToClipboard(hex: hex)
        ToastWindow.show(message: L10n.colorCopied(copied))
    }

    @objc private func toggleFavorite(_ sender: NSButton) {
        guard let hex = sender.identifier?.rawValue else { return }
        var colors = Defaults.favoriteColorHexes
        if colors.contains(hex) { colors.removeAll { $0 == hex } } else { colors.append(hex) }
        Defaults.favoriteColorHexes = colors
    }
}

private final class ColorPaletteDocumentView: NSView {
    override var isFlipped: Bool { true }
}
