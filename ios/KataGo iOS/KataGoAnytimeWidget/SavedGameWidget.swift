// SavedGameWidget.swift
import WidgetKit
import SwiftUI

struct SavedGameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SavedGameWidget", provider: PlaceholderProvider()) { _ in
            Text("KataGo")
        }
    }
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry { let date: Date }
