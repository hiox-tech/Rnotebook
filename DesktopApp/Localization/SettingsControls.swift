import AppKit
import SwiftUI

struct SettingsFontSize: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identifier: String
    let label: String

    func makeNSView(context: Context) -> FontSizeControl {
        FontSizeControl(value: $value, range: range, identifier: identifier, label: label)
    }
    func updateNSView(_ view: FontSizeControl, context: Context) {
        view.value = $value
        view.refresh()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FontSizeControl, context: Context) -> CGSize? {
        CGSize(width: 132, height: 24)
    }
}

/// Commit valid values only; incomplete or invalid text never reaches persisted preferences.
@MainActor final class FontSizeControl: NSStackView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let stepper = NSStepper()
    var value: Binding<Double>
    private let range: ClosedRange<Double>
    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    init(value: Binding<Double>, range: ClosedRange<Double>, identifier: String, label: String) {
        self.value = value; self.range = range
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 5
        field.alignment = .right
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = self; field.target = self; field.action = #selector(commit(_:))
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(label)
        stepper.minValue = range.lowerBound; stepper.maxValue = range.upperBound
        stepper.increment = 1; stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(step(_:))
        stepper.setAccessibilityIdentifier(identifier + "-stepper")
        stepper.setAccessibilityLabel(label + L10n.string("微调"))
        addArrangedSubview(field); addArrangedSubview(stepper)
        let unit = NSTextField(labelWithString: "pt")
        unit.textColor = .secondaryLabelColor
        addArrangedSubview(unit)
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        // SwiftUI may refresh another setting while this field has uncommitted input.
        guard window?.firstResponder !== field.currentEditor() || field.currentEditor() == nil else { return }
        stepper.doubleValue = value.wrappedValue
        field.stringValue = formatter.string(from: NSNumber(value: value.wrappedValue)) ?? ""
    }
    private var enteredValue: Double? {
        let decimal = formatter.decimalSeparator ?? "."
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: decimal, with: ".")
        guard let number = Double(text), number.isFinite, range.contains(number) else { return nil }
        return number
    }
    @objc func commit(_ sender: Any?) {
        if let number = enteredValue, number != value.wrappedValue {
            value.wrappedValue = number
        }
        field.stringValue = formatter.string(from: NSNumber(value: value.wrappedValue)) ?? ""
        stepper.doubleValue = value.wrappedValue
    }
    @objc func step(_ sender: NSStepper) {
        value.wrappedValue = min(range.upperBound, max(range.lowerBound, sender.doubleValue))
        field.stringValue = formatter.string(from: NSNumber(value: value.wrappedValue)) ?? ""
    }
    func controlTextDidChange(_ notification: Notification) {
        // Stepping after typing starts from the visible value, without persisting partial input.
        if let number = enteredValue { stepper.doubleValue = number }
    }
    func controlTextDidEndEditing(_ notification: Notification) { commit(field) }
}

enum SettingsEnvironment {
    static func selectionError(_ url: URL, directory: Bool) -> String? {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return L10n.string("所选位置已不存在，请重新选择。")
        }
        if directory {
            guard isDirectory.boolValue else { return L10n.string("请选择文件夹。") }
            return FileManager.default.isWritableFile(atPath: url.path) ? nil : L10n.string("所选目录不可写，请选择其他目录。")
        }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            return L10n.string("请选择可执行文件。")
        }
        return nil
    }
}

/// A single selectable path with middle truncation; full path and source stay in the tooltip.
struct SettingsPath: NSViewRepresentable {
    let url: URL?
    let identifier: String
    let source: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isEditable = false; field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.placeholderString = L10n.string("未找到可执行文件")
        field.setAccessibilityIdentifier(identifier)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = url?.path ?? ""
        field.toolTip = source + (url.map { "\n" + $0.path } ?? L10n.string(" · 未找到可执行文件"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 218, height: 24)
    }
}

struct SettingsFileButton: NSViewRepresentable {
    let title: String
    let directory: Bool
    let current: URL?
    let fallback: URL
    let identifier: String
    let selected: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: L10n.string("选择…"), target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = L10n.string("选择…")
        button.setAccessibilityLabel(title)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsFileButton
        private var panel: NSOpenPanel?
        init(_ parent: SettingsFileButton) { self.parent = parent }
        @objc func choose(_ sender: NSButton) {
            guard panel == nil, let window = sender.window, window.attachedSheet == nil else { return }
            let request = parent
            let panel = NSOpenPanel(); self.panel = panel
            panel.title = request.title
            panel.canChooseDirectories = request.directory; panel.canChooseFiles = !request.directory
            panel.canCreateDirectories = request.directory; panel.allowsMultipleSelection = false
            panel.directoryURL = request.current.map { request.directory ? $0 : $0.deletingLastPathComponent() } ?? request.fallback
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.panel = nil
                guard response == .OK, let url = panel.url else { return }
                request.selected(url)
            }
        }
    }
}
