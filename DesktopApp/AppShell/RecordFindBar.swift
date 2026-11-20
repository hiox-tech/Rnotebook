import AppKit

/// Compact native controls inside the same glass/material family as the
/// formatting toolbar. Expanding Replace changes only this floating surface.
@MainActor final class RecordFindBar: NSView, NSSearchFieldDelegate {
    let query = NSSearchField()
    let replacement = NSTextField()
    let counter = NSTextField(labelWithString: "")
    let replaceToggle = NSButton(title: "", target: nil, action: nil)
    private let content = RecordFindBarContent()
    private let chrome: NSView
    private let searchIcon = NSImageView()
    private let replaceIcon = NSImageView()
    private let previous = NSButton(), next = NSButton(), options = NSButton(), close = NSButton()
    private let replaceOne = NSButton(), replaceAll = NSButton()
    private(set) var showsReplacement = false
    var queryChanged: ((String) -> Void)?
    var navigate: ((Bool) -> Void)?
    var replace: ((Bool) -> Void)?
    var visibilityChanged: (() -> Void)?
    var dismiss: (() -> Void)?
    var optionsChanged: (() -> Void)?
    var caseSensitive = false
    var wholeWord = false
    var preferredHeight: CGFloat { showsReplacement ? 84 : 44 }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 22
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = content; chrome = glass
        } else {
            let material = NSVisualEffectView(); material.material = .popover
            material.blendingMode = .withinWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = 22
            material.layer?.borderWidth = 0.5; material.layer?.borderColor = NSColor.separatorColor.cgColor
            material.addSubview(content); chrome = material
        }
        super.init(frame: frameRect)
        setAccessibilityIdentifier("record-find-bar")
        addSubview(chrome)
        query.placeholderString = L10n.string("查找")
        query.isBezeled = false; query.drawsBackground = false; query.focusRingType = .none
        query.sendsSearchStringImmediately = true
        (query.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (query.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        query.font = .systemFont(ofSize: 12); query.delegate = self
        query.setAccessibilityIdentifier("record-find-query")
        replacement.placeholderString = L10n.string("替换为")
        replacement.isBezeled = false; replacement.drawsBackground = false; replacement.focusRingType = .none
        replacement.font = .systemFont(ofSize: 12); replacement.delegate = self
        replacement.setAccessibilityIdentifier("record-find-replacement")
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor; counter.alignment = .right
        counter.setAccessibilityIdentifier("record-find-count")
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        replaceIcon.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor; replaceIcon.contentTintColor = .secondaryLabelColor
        button(previous, symbol: "chevron.left", title: L10n.string("查找上一个"), action: #selector(goPrevious))
        button(next, symbol: "chevron.right", title: L10n.string("查找下一个"), action: #selector(goNext))
        button(options, symbol: "ellipsis", title: L10n.string("搜索选项"), action: #selector(showOptions))
        button(close, symbol: "xmark", title: L10n.string("关闭查找"), action: #selector(hide))
        for (control, title, action) in [(replaceToggle, L10n.string("替换"), #selector(toggleReplace)),
                                        (replaceOne, L10n.string("替换"), #selector(replaceCurrent)),
                                        (replaceAll, L10n.string("全部替换"), #selector(replaceEvery))] {
            control.title = title; control.font = .systemFont(ofSize: 11)
            control.isBordered = false; control.target = self; control.action = action
            control.setAccessibilityLabel(title)
        }
        replaceToggle.setButtonType(.toggle)
        replaceToggle.setAccessibilityIdentifier("record-find-toggle-replace")
        replaceOne.setAccessibilityIdentifier("record-find-replace-one")
        replaceAll.setAccessibilityIdentifier("record-find-replace-all")
        for view in [searchIcon, query, counter, previous, next, options, replaceToggle, close,
                     replaceIcon, replacement, replaceOne, replaceAll] { content.addSubview(view) }
        setReplacement(false)
    }
    required init?(coder: NSCoder) { nil }
    private func button(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.isBordered = false; button.target = self; button.action = action; button.toolTip = title
        button.setAccessibilityLabel(title)
    }
    override func layout() {
        super.layout()
        chrome.frame = bounds; content.frame = bounds
        var x = bounds.width - 12
        func trailing(_ view: NSView, width: CGFloat, gap: CGFloat = 4) {
            x -= width; view.frame = NSRect(x: x, y: 10, width: width, height: 24); x -= gap
        }
        trailing(close, width: 22); trailing(replaceToggle, width: 42)
        trailing(options, width: 22); trailing(next, width: 22, gap: 0); trailing(previous, width: 22)
        trailing(counter, width: 48, gap: 8)
        searchIcon.frame = NSRect(x: 14, y: 14, width: 16, height: 16)
        query.frame = NSRect(x: 38, y: 12, width: max(20, x - 38), height: 22)
        replaceIcon.frame = NSRect(x: 14, y: 54, width: 16, height: 16)
        replaceAll.frame = NSRect(x: bounds.width - 78, y: 50, width: 66, height: 24)
        replaceOne.frame = NSRect(x: replaceAll.frame.minX - 50, y: 50, width: 42, height: 24)
        replacement.frame = NSRect(x: 38, y: 52, width: max(20, replaceOne.frame.minX - 50), height: 22)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    func setReplacement(_ expanded: Bool) {
        showsReplacement = expanded; replaceToggle.state = expanded ? .on : .off
        for view in [replaceIcon, replacement, replaceOne, replaceAll] { view.isHidden = !expanded }
        needsLayout = true; visibilityChanged?()
    }
    func updateCount(current: Int?, total: Int, searching: Bool = false) {
        counter.stringValue = searching ? "…" : total == 0 ? "0" : "\(current.map { $0 + 1 } ?? 0)/\(total)"
        previous.isEnabled = total > 0; next.isEnabled = total > 0
        replaceOne.isEnabled = total > 0; replaceAll.isEnabled = total > 0
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === query { queryChanged?(query.stringValue) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === replacement { replace?(false) }
            else { navigate?(NSEvent.modifierFlags.contains(.shift) == false) }
            return true
        }
        return false
    }
    @objc private func goPrevious() { navigate?(false) }
    @objc private func goNext() { navigate?(true) }
    @objc private func hide() { dismiss?() }
    @objc private func toggleReplace() { setReplacement(!showsReplacement) }
    @objc private func replaceCurrent() { replace?(false) }
    @objc private func replaceEvery() { replace?(true) }
    @objc private func showOptions() {
        let menu = NSMenu()
        for (title, action, checked) in [(L10n.string("区分大小写"), #selector(toggleCase), caseSensitive),
                                         (L10n.string("完整词语"), #selector(toggleWord), wholeWord)] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.state = checked ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.maxY), in: options)
    }
    @objc private func toggleCase() { caseSensitive.toggle(); optionsChanged?() }
    @objc private func toggleWord() { wholeWord.toggle(); optionsChanged?() }
}

@MainActor private final class RecordFindBarContent: NSView { override var isFlipped: Bool { true } }
