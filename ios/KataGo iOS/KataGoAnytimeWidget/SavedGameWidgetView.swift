import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SavedGameEntry

    private var thumbnail: some View {
        Group {
            if let data = entry.snapshot.thumbnail, let image = decode(data) {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                WidgetBoardView(width: entry.snapshot.boardWidth,
                                height: entry.snapshot.boardHeight,
                                blackVertices: entry.snapshot.lastBlackStones,
                                whiteVertices: entry.snapshot.lastWhiteStones)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        let snap = entry.snapshot
        Group {
            switch family {
            case .systemSmall:
                VStack(spacing: 4) {
                    thumbnail
                    Text(snap.name).font(.caption).bold().lineLimit(1)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 6) {
                    Text(snap.name).font(.headline).lineLimit(1)
                    thumbnail.frame(maxHeight: .infinity)
                    Text(snap.firstComment).font(.callout).lineLimit(6)
                }
            default: // .systemMedium
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.name).font(.headline).lineLimit(1)
                        Text(snap.firstComment).font(.caption).lineLimit(3)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .widgetURL(snap.gameID.map(GameDeepLink.url(for:)))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func decode(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
