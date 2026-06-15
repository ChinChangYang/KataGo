import AppKit

/// A small reusable view controller that displays a single centered label.
/// Used for the sidebar (Library) and inspector (Inspector) panes until their
/// real content arrives in later phases.
final class PlaceholderViewController: NSViewController {
    private let labelText: String

    init(labelText: String) {
        self.labelText = labelText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let label = NSTextField(labelWithString: labelText)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }
}
