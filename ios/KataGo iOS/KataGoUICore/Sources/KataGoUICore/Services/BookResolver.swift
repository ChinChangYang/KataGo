//
//  BookResolver.swift
//  KataGoUICore
//
//  The one rule for which opening book a board size uses — the "active book":
//
//    1. an explicit per-size selection whose identity resolves to a file on
//       disk (catalog `fileName` or import UUID);
//    2. otherwise the catalog book for the size, if downloaded;
//    3. otherwise the newest imported book of the size whose file exists.
//
//  Every branch verifies the file, so a dangling selection or a deleted file
//  falls through instead of resolving to nothing loadable. `BookLookup`
//  consults this for both availability and loading, which is what makes an
//  imported-only size (say 12×12, no catalog entry) work with no selection at
//  all, and what makes deleting the active book fall back automatically.
//

import Foundation

/// One loadable book for a size: where its bytes live and how to name it.
public struct ResolvedBook: Equatable, Sendable {
    public let identity: String
    public let sourceURL: URL
    public let displayName: String
    public let isImported: Bool
}

public enum BookResolver {
    /// The active book for `size`, or nil if no book of that size exists on
    /// this device.
    public static func resolvedBook(forBoardSize size: Int,
                                    store: CustomBookStore = CustomBookStore()) -> ResolvedBook? {
        let candidates = candidates(forBoardSize: size, store: store)
        guard !candidates.isEmpty else { return nil }

        if let chosen = store.activeBookIdentity(forBoardSize: size),
           let match = candidates.first(where: { $0.identity == chosen }) {
            return match
        }
        // Automatic resolution: catalog first, else the newest import.
        if let catalog = candidates.first(where: { !$0.isImported }) {
            return catalog
        }
        return candidates.last  // imports are ordered oldest-to-newest
    }

    /// Every loadable book for `size`: the catalog book (if downloaded) first,
    /// then imports ordered by import date (oldest first, so the list is
    /// stable as new imports append).
    public static func candidates(forBoardSize size: Int,
                                  store: CustomBookStore = CustomBookStore()) -> [ResolvedBook] {
        var result: [ResolvedBook] = []
        if let book = OpeningBook.book(forBoardSize: size), book.isDownloaded {
            result.append(ResolvedBook(identity: book.fileName,
                                       sourceURL: book.downloadedURL,
                                       displayName: book.title,
                                       isImported: false))
        }
        let imports = store.records(forBoardSize: size)
            .filter(\.isOnDisk)
            .sorted { $0.importedAt < $1.importedAt }
        result.append(contentsOf: imports.map { record in
            ResolvedBook(identity: record.identity,
                         sourceURL: record.fileURL,
                         displayName: record.displayName,
                         isImported: true)
        })
        return result
    }
}
