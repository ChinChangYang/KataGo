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

    // MARK: Rank menu row (pull-down NSPopUpButton with submenus)

    /// A labeled rank chooser: the 259 profiles grouped by `RankCatalog`
    /// (Full Strength, Dan, Kyu, Pro by decade) behind a pull-down whose title
    /// is the current profile. `onChange(profile)` fires with the picked
    /// profile; the owner rebuilds the form to refresh the title, as it
    /// already does after a profile change.
    static func rankMenuRow(title: String,
                            current: String,
                            onChange: @escaping (String) -> Void) -> RankMenuRow {
        RankMenuRow(title: title, current: current, onChange: onChange)
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

    // MARK: Separator

    /// Adds a horizontal separator spanning the width of `stack`. Unlike the row
    /// builders (which RETURN a view for the caller to add), this both adds the
    /// `NSBox` to the stack AND pins its leading/trailing to `stack` — the pins
    /// reference `stack`, so the separator must already be in the view hierarchy
    /// before the constraints activate (otherwise AppKit throws "no common
    /// ancestor"). Shared by the Info tab, the config editor, and the New Game
    /// sheet so the separator style stays in one place.
    static func addSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        separator.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
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
final class NumericRow: NSStackView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void
    private let step: Double
    /// The last clamped value that fired `onChange`, so a repeated commit of the
    /// same value is suppressed. On Return an `NSTextField` fires BOTH its cell
    /// action (`fieldChanged`) and `controlTextDidEndEditing`, which would
    /// otherwise call `onChange` twice and double-reconfigure the engine. This is
    /// the RAW clamped value (before any sync-layer rounding); storing the raw
    /// value can only cause a harmless extra fire, never suppress a real edit.
    private var lastCommittedValue: Double?

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
        // Also commit when editing ends by Tab or click-away, not only on Return.
        // Without this the field's action fires only on Return, so a typed value
        // the user tabs/clicks away from would be silently dropped.
        field.delegate = self

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
        lastCommittedValue = value
    }

    private func commit(_ value: Double) {
        let clamped = min(stepper.maxValue, max(stepper.minValue, value))
        // Update the displayed controls UNCONDITIONALLY so an out-of-range typed
        // value still snaps to the clamped display even when `onChange` is skipped.
        stepper.doubleValue = clamped
        field.stringValue = format(clamped)
        // Suppress a no-op commit (notably the Return double-fire, where the cell
        // action and the end-editing delegate both call commit with the same value).
        guard clamped != lastCommittedValue else { return }
        lastCommittedValue = clamped
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

    // Commit on Tab / click-away (and any programmatic end of editing, e.g.
    // `makeFirstResponder(nil)`), so a value the user types but doesn't confirm
    // with Return still takes effect. Idempotent with `fieldChanged`.
    func controlTextDidEndEditing(_ obj: Notification) {
        commit(Double(field.stringValue) ?? stepper.doubleValue)
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

/// Labeled rank chooser backed by a PULL-DOWN `NSPopUpButton` with submenus.
///
/// Pull-down, not pop-up: a pop-up-mode `NSPopUpButton` cannot select from a
/// submenu — choosing a leaf fires its action but never updates the selection
/// or the title — so the flat 259-item popup it replaces could never have
/// been grouped. A pull-down shows its item 0 as the title and leaves the
/// rest to us: leaves carry the profile in `representedObject`, the current
/// one wears a checkmark (the Board/Book View submenu idiom in AppDelegate).
@MainActor
final class RankMenuRow: NSStackView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let onChange: (String) -> Void

    init(title: String, current: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.menu = makeMenu(current: current)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(popup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeMenu(current: String) -> NSMenu {
        let menu = NSMenu(title: "Rank")
        // Item 0 is the pull-down's title, never shown in the list.
        menu.addItem(NSMenuItem(title: RankCatalog.title(for: current), action: nil, keyEquivalent: ""))
        menu.addItem(leaf(RankCatalog.aiProfile, title: RankCatalog.aiTitle, current: current))
        menu.addItem(submenu("Dan", RankCatalog.dan.map { ($0, $0) }, current: current))
        menu.addItem(submenu("Kyu", RankCatalog.kyu.map { ($0, $0) }, current: current))
        let pro = NSMenuItem(title: "Pro", action: nil, keyEquivalent: "")
        let proMenu = NSMenu(title: "Pro")
        for decade in RankCatalog.decades {
            proMenu.addItem(submenu(RankCatalog.decadeLabel(decade),
                                    RankCatalog.entries(inDecade: decade).map { ($0.profile, $0.label) },
                                    current: current))
        }
        pro.submenu = proMenu
        menu.addItem(pro)
        return menu
    }

    private func submenu(_ title: String,
                         _ entries: [(profile: String, label: String)],
                         current: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in entries {
            menu.addItem(leaf(entry.profile, title: entry.label, current: current))
        }
        item.submenu = menu
        // A checkmark on the group that holds the current pick, so the
        // closed menu already says where to look.
        item.state = entries.contains { $0.profile == current } ? .on : .off
        return item
    }

    private func leaf(_ profile: String, title: String, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(leafPicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = profile
        item.state = profile == current ? .on : .off
        return item
    }

    @objc private func leafPicked(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        onChange(profile)
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
