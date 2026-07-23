/// One-shot latch that defers the widget-timeline reload for a game switch
/// until the switched game's state has actually landed (the stones-ready edge
/// that follows `GobanState.loadGame`'s trailing `showboard`). Reloading at
/// switch time raced ahead of the engine reply: the widget re-read the App
/// Group store before `sgf`/stones/`lastModificationDate` were written and
/// then showed stale content until the next hourly tick.
///
/// Usage (iOS `GameSplitView` and macOS `MainWindowController` identically):
/// arm on the selection change; on `.fireNow` (deselection — nothing will
/// land) save + reload immediately; consume at the end of the stones-ready
/// handler, after the stones writes, and save + reload only when it fires.
/// Per-move stones-ready edges find the latch unarmed and never burn
/// WidgetKit reload budget.
public struct WidgetReloadLatch {
    public private(set) var isArmed = false

    public init() {}

    public enum SwitchAction: Equatable, Sendable {
        case fireNow
        case armed
    }

    /// The selected game changed. A real game arms the latch; deselection has
    /// no data to await, so it fires now — and drops any stale arm so an
    /// abandoned switch can't fire on a later unrelated stones-ready edge.
    public mutating func gameSwitched(hasNewGame: Bool) -> SwitchAction {
        isArmed = hasNewGame
        return hasNewGame ? .armed : .fireNow
    }

    /// The switched game's stones landed. One-shot: true exactly once per arm.
    public mutating func consumeDataLanded() -> Bool {
        defer { isArmed = false }
        return isArmed
    }
}
