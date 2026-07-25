//
//  SgfGameName.swift
//  KataGoAnalysisKit
//
//  Derives a human game name from an SGF's identity properties, for the import
//  paths that would otherwise stamp every row with the same literal (the
//  Safari extensions' "Open in KataGo Anytime", the Messages hand-off, Files
//  import). Lives here because KataGoAnalysisKit is @_exported by both
//  KataGoGameStore and KataGoUICore, so every app and extension already sees it
//  without a new link edge.
//
//  Name shape, in priority order:
//    "<GN> — <Black> vs <White>"   both present
//    "<GN>"                        no usable players
//    "<Black> vs <White>"          no GN
//    nil                           nothing usable (caller supplies a literal)
//
//  The Safari extensions write the page title into GN before spooling, so GN
//  also marks a spooled file as web-sourced — which is how the shared iOS
//  drain tells a Safari hand-off from an iMessage one.
//

import Foundation

public enum SgfGameName {
    /// Longest name we will produce. KataGo self-play players are ~60-character
    /// model strings and page titles can be arbitrary, so an uncapped name
    /// would overflow the game list, widget, and watch rows.
    public static let maxLength = 80

    /// Hard scalar ceiling behind `maxLength` (see `clamp`).
    static let maxScalars = 240

    /// How much of the file to scan. GN/PB/PW legally live only in the root
    /// node, which is at the very start — so a bounded prefix both keeps a
    /// large SGF from being walked character-by-character on the main thread
    /// during a cold-launch drain, and stops a `PB[` inside a later comment
    /// from being mistaken for a player.
    private static let scanPrefix = 4096

    /// Derive a display name from SGF text, or nil when nothing usable is present.
    public static func derive(fromSgf sgf: String) -> String? {
        let head = String(sgf.prefix(scanPrefix))
        let gameName = value(of: "GN", in: head)
        let black = value(of: "PB", in: head)
        let white = value(of: "PW", in: head)

        let players: String?
        switch (black, white) {
        case let (b?, w?):
            // Self-play games (katagotraining) carry the SAME model string in
            // both; "X vs X" is noise, so collapse it.
            players = (b == w) ? b : "\(b) vs \(w)"
        case let (b?, nil):
            players = b
        case let (nil, w?):
            players = w
        case (nil, nil):
            players = nil
        }

        switch (gameName, players) {
        case let (g?, p?): return clamp("\(g) — \(p)")
        case let (g?, nil): return clamp(g)
        case let (nil, p?): return clamp(p)
        case (nil, nil): return nil
        }
    }

    /// Whether the SGF carries a game name — the marker the Safari extensions
    /// write, used to distinguish a web hand-off from an iMessage one in the
    /// shared spool directory.
    public static func hasGameName(inSgf sgf: String) -> Bool {
        value(of: "GN", in: String(sgf.prefix(scanPrefix))) != nil
    }

    /// Read one root property value, sanitized. Returns nil when absent or
    /// empty (our own `printsgf` emits `PB[]PW[]`, which must not become a name).
    static func value(of property: String, in sgf: String) -> String? {
        guard let raw = rawValue(of: property, in: sgf) else { return nil }
        let cleaned = sanitize(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Scan for `<property>[value]`, honoring SGF backslash escapes inside the
    /// value. The preceding character must not be an uppercase letter, so `PB`
    /// does not match inside a longer identifier (the same boundary guard the
    /// macOS inspector uses).
    private static func rawValue(of property: String, in sgf: String) -> String? {
        let characters = Array(sgf)
        let key = Array(property)
        var index = 0
        while index + key.count < characters.count {
            guard Array(characters[index..<(index + key.count)]) == key,
                  characters[index + key.count] == "[" else {
                index += 1
                continue
            }
            if index > 0, characters[index - 1].isUppercase, characters[index - 1].isLetter {
                index += 1
                continue    // tail of a longer property identifier
            }
            var value = ""
            var cursor = index + key.count + 1
            var escaped = false
            while cursor < characters.count {
                let character = characters[cursor]
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "]" {
                    return value
                } else {
                    value.append(character)
                }
                cursor += 1
            }
            return value    // unterminated value: take what we have
        }
        return nil
    }

    /// Collapse whitespace and drop control characters. Page titles are
    /// attacker-controllable text that ends up in a CloudKit-synced record
    /// name rendered in the app, widgets, and on the watch.
    private static func sanitize(_ raw: String) -> String {
        // Control characters become SPACES rather than vanishing: a newline is
        // itself a control character, and deleting it would glue the words on
        // either side together ("game\n2037735" -> "game2037735"). Matches the
        // extensions' JS cleanup so both sides agree.
        let stripped = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func clamp(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var bounded = trimmed
        if bounded.count > maxLength {
            bounded = String(bounded.prefix(maxLength - 1)) + "…"
        }
        // A single grapheme cluster can carry unbounded combining marks, so cap
        // scalars as well as visible characters.
        if bounded.unicodeScalars.count > maxScalars {
            let scalars = bounded.unicodeScalars.prefix(maxScalars)
            bounded = String(String.UnicodeScalarView(scalars)) + "…"
        }
        return bounded
    }
}
