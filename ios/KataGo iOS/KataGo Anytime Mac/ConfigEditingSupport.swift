//
//  ConfigEditingSupport.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 5: reusable infrastructure for the native AppKit config editors.
//  Two pieces:
//
//    1. `ConfigEngineSync` — moved to `KataGoUICore/Session/ConfigEngineSync.swift`
//       so iOS and macOS share identical GTP orchestration. The macOS controllers
//       still call `ConfigEngineSync.*`; they now resolve from `KataGoUICore`
//       (imported below).
//
//    2. `ConfigFormBuilder` — native form-row builders (`NSTextField`+`NSStepper`
//       numeric rows, `NSPopUpButton` enum rows, `NSButton` checkbox rows) that
//       return ready-to-stack labeled rows. The Info tab and T6's sheet both
//       build their forms from these.
//
//  No SwiftData @Model schema change: every accessor used here already exists on
//  `Config` (stored props + computed accessors). Board size is intentionally NOT
//  handled by `ConfigEngineSync` — changing it mid-game replays a destructive
//  command sequence (`rectangular_boardsize` + showboard + printsgf) that the
//  Info tab defers to T6; the Info tab shows board size read-only.
//

import AppKit
import KataGoUICore

// MARK: - ConfigFormBuilder

/// Builds native AppKit form rows (a leading label + a trailing editable
/// control) for the config editors. Each builder returns an `NSView` row whose
/// control already has its target/action wired to the supplied closure; the
/// closure performs the `Config` write + `ConfigEngineSync` call.
///
/// Rows are plain `NSStackView`s laid out leading-label / trailing-control; a
/// caller stacks them vertically (the Info tab uses a vertical `NSStackView`).
/// The builders retain their action closures via small `NSObject` "target"
/// boxes stored on the control through associated handlers — implemented here
/// with a dedicated `ActionTarget` so Swift 6 strict concurrency stays clean
/// (no escaping `@Sendable` requirements; everything is `@MainActor`).
@MainActor
enum ConfigFormBuilder {

    /// Standard leading label width so every row's controls align.
    static let labelWidth: CGFloat = 150

    // MARK: Numeric row (NSTextField + NSStepper)

    /// A labeled numeric row: an editable `NSTextField` mirrored by an
    /// `NSStepper`. Both commit through `onChange(newValue)`. `format` renders
    /// the field text; `decimals` controls the stepper's increment precision.
    ///
    /// Returns the row view; the live value is owned by the caller's `Config`,
    /// so the builder seeds the controls from `value` and reports edits via
    /// `onChange`. The returned `NumericRow` exposes `reload(value:)` so the
    /// owner can repopulate it when the selected game changes.
    static func numericRow(title: String,
                           value: Double,
                           minValue: Double,
                           maxValue: Double,
                           step: Double,
                           format: @escaping (Double) -> String,
                           onChange: @escaping (Double) -> Void) -> NumericRow {
        NumericRow(title: title,
                   value: value,
                   minValue: minValue,
                   maxValue: maxValue,
                   step: step,
                   format: format,
                   onChange: onChange)
    }

    // MARK: Popup row (NSPopUpButton)

    /// A labeled enumeration row backed by an `NSPopUpButton`. `options` are the
    /// human-readable titles; `selectedIndex` is the initially-selected item;
    /// `onChange(index)` fires with the newly-selected index.
    static func popupRow(title: String,
                         options: [String],
                         selectedIndex: Int,
                         onChange: @escaping (Int) -> Void) -> PopupRow {
        PopupRow(title: title,
                 options: options,
                 selectedIndex: selectedIndex,
                 onChange: onChange)
    }

    // MARK: Checkbox row (NSButton .switch)

    /// A labeled boolean row backed by a checkbox `NSButton`. `onChange(isOn)`
    /// fires with the new state. (Not used by the Info tab's common settings,
    /// which have no booleans, but provided for T6's full editor — multi-stone
    /// suicide, has-button, use-LLM, etc.)
    static func checkboxRow(title: String,
                            isOn: Bool,
                            onChange: @escaping (Bool) -> Void) -> CheckboxRow {
        CheckboxRow(title: title, isOn: isOn, onChange: onChange)
    }

    // MARK: Read-only row

    /// A labeled read-only row: a leading label and a trailing static value
    /// label. Used for the summary fields and for board size (read-only here).
    static func readOnlyRow(title: String, value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// A section header label (small, secondary, uppercased) for grouping rows.
    static func sectionHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        return label
    }
}

// MARK: - Row types
//
// Each row is an `NSStackView` subclass that OWNS its controls + action closure
// (so the closure outlives the builder call) and exposes `reload(...)` so the
// Info tab can repopulate the row when the selected game changes WITHOUT
// rebuilding the whole form. All are `@MainActor` (they only touch AppKit).

/// Labeled numeric row: `NSTextField` ⟷ `NSStepper`, both committing the same
/// value through `onChange`.
@MainActor
final class NumericRow: NSStackView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void
    private let step: Double

    init(title: String,
         value: Double,
         minValue: Double,
         maxValue: Double,
         step: Double,
         format: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        self.step = step
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.target = self
        field.action = #selector(fieldChanged)

        stepper.minValue = minValue
        stepper.maxValue = maxValue
        stepper.increment = step
        stepper.valueWraps = false
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(field)
        addArrangedSubview(stepper)

        reload(value: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates both controls from `value` without firing `onChange`.
    func reload(value: Double) {
        stepper.doubleValue = value
        field.stringValue = format(value)
    }

    private func commit(_ value: Double) {
        let clamped = min(stepper.maxValue, max(stepper.minValue, value))
        stepper.doubleValue = clamped
        field.stringValue = format(clamped)
        onChange(clamped)
    }

    @objc private func stepperChanged() {
        commit(stepper.doubleValue)
    }

    @objc private func fieldChanged() {
        // Parse the typed text; fall back to the stepper's current value if the
        // text isn't a number (mirrors iOS's `Float(newValue) ?? default` guard,
        // here keeping the prior value rather than a compiled default).
        let parsed = Double(field.stringValue) ?? stepper.doubleValue
        commit(parsed)
    }
}

/// Labeled enumeration row backed by an `NSPopUpButton`.
@MainActor
final class PopupRow: NSStackView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onChange: (Int) -> Void

    init(title: String,
         options: [String],
         selectedIndex: Int,
         onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        popup.addItems(withTitles: options)
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(popup)

        reload(options: options, selectedIndex: selectedIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates the menu + selection without firing `onChange`. Re-adding the
    /// items keeps the popup correct even if the option list ever changes.
    func reload(options: [String], selectedIndex: Int) {
        popup.removeAllItems()
        popup.addItems(withTitles: options)
        if options.indices.contains(selectedIndex) {
            popup.selectItem(at: selectedIndex)
        }
    }

    /// Convenience reload when only the selection changed.
    func reload(selectedIndex: Int) {
        if popup.itemArray.indices.contains(selectedIndex) {
            popup.selectItem(at: selectedIndex)
        }
    }

    @objc private func popupChanged() {
        onChange(popup.indexOfSelectedItem)
    }
}

/// Labeled boolean row backed by a checkbox `NSButton`.
@MainActor
final class CheckboxRow: NSStackView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        checkbox.title = ""
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged)
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(checkbox)

        reload(isOn: isOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates the checkbox state without firing `onChange`.
    func reload(isOn: Bool) {
        checkbox.state = isOn ? .on : .off
    }

    @objc private func checkboxChanged() {
        onChange(checkbox.state == .on)
    }
}
