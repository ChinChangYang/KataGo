//
//  OpeningBookTests.swift
//  KataGo iOSTests
//
//  Catalog + storage tests for the downloadable opening books.
//

import Foundation
import Compression
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Serialized because these tests mutate the process-global
/// `OpeningBook._booksDirectoryOverride` — and, since custom books arrived,
/// `CustomBookStore._directoryOverride`/`_defaultsOverride` too; running them
/// in parallel would race. One other suite touches the books override —
/// `DownloadCenterTests`, for the one test that installs a finished book — and
/// it is safe alongside this one because its body is `@MainActor` and
/// synchronous (so it cannot interleave with anything here) and it restores
/// the previous value rather than nil'ing it. Any new user of any of these
/// overrides must keep both of those properties, or live in THIS suite (the
/// async importer/resolver tests below do exactly that).
@Suite(.serialized)
@MainActor
struct OpeningBookTests {

    // MARK: - Test fixtures

    fileprivate typealias TestPosition = (
        nextPlayer: Int,
        moves: [(positions: [Int], winLoss: Double, sharpScore: Double, adjustedVisits: Int64, policyPrior: Double)],
        children: [(canonicalPos: Int, childId: Int, sym: Int)]
    )

    /// Size-agnostic book: root (black to play) with one move at canonical pos 0
    /// leading to a leaf child.
    fileprivate static func singleMoveBook() -> [TestPosition] {
        let root: TestPosition = (
            nextPlayer: 1,
            moves: [(positions: [0], winLoss: 0.6, sharpScore: 2.5, adjustedVisits: 100, policyPrior: 0.8)],
            children: [(canonicalPos: 0, childId: 1, sym: 0)]
        )
        let child: TestPosition = (nextPlayer: 2, moves: [], children: [])
        return [root, child]
    }

    /// Wrap raw bytes in a minimal gzip container that `BookLookup.decompressGzip`
    /// accepts: 10-byte header + raw DEFLATE body (COMPRESSION_ZLIB) + ignored
    /// CRC32 + ISIZE (used only as a capacity hint).
    fileprivate static func gzipForTesting(_ data: Data) -> Data {
        let srcSize = data.count
        var dst = Data(count: srcSize * 2 + 256)
        let written = dst.withUnsafeMutableBytes { d -> Int in
            data.withUnsafeBytes { s -> Int in
                compression_encode_buffer(
                    d.bindMemory(to: UInt8.self).baseAddress!, d.count,
                    s.bindMemory(to: UInt8.self).baseAddress!, srcSize,
                    nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0, "gzip test fixture encode failed")
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(dst.prefix(written))
        out.append(Data([0, 0, 0, 0]))  // CRC32 (ignored by the decompressor)
        var isize = UInt32(truncatingIfNeeded: srcSize).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    /// Point `CustomBookStore` at a scratch dir + throwaway defaults so the
    /// resolver path reached through `BookLookup.loadIfNeeded`/`isAvailable`
    /// (which constructs the default store itself) never touches real
    /// Documents or standard defaults. Caller nils both overrides in a defer.
    @discardableResult
    fileprivate static func isolateCustomBooks(into parent: URL,
                                               suiteName: String = #function) -> CustomBookStore {
        CustomBookStore._directoryOverride = parent.appendingPathComponent("CustomBooks", isDirectory: true)
        let defaults = UserDefaults(suiteName: "OpeningBookTests.\(suiteName)")!
        defaults.removePersistentDomain(forName: "OpeningBookTests.\(suiteName)")
        CustomBookStore._defaultsOverride = defaults
        return CustomBookStore()
    }

    fileprivate static func restoreCustomBooks() {
        CustomBookStore._directoryOverride = nil
        CustomBookStore._defaultsOverride = nil
    }

    /// Point the books directory at a temp dir and install a synthetic gzipped
    /// book at the size's downloadedURL. Caller resets the override + removes
    /// `parent` in a defer.
    @discardableResult
    fileprivate static func installFixtureBook(boardSize n: Int, into parent: URL) throws -> OpeningBook {
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        let book = OpeningBook.book(forBoardSize: n)!
        try OpeningBook.ensureBooksDirectory()
        let raw = BookLookup.serializeToBinary(positions: singleMoveBook(), boardSize: n)
        try gzipForTesting(raw).write(to: book.downloadedURL)
        return book
    }

    // MARK: - Catalog

    @Test func catalogCoversFourSquareSizes() {
        let sizes = Set(OpeningBook.allCases.map(\.boardSize))
        #expect(sizes == Set([6, 7, 8, 9]))
        #expect(OpeningBook.allCases.count == 4)
    }

    @Test func bookForBoardSizeResolves() {
        for n in 6...9 {
            #expect(OpeningBook.book(forBoardSize: n)?.boardSize == n)
        }
        #expect(OpeningBook.book(forBoardSize: 19) == nil)
        #expect(OpeningBook.book(forBoardSize: 5) == nil)
    }

    @Test func nineByNineCompressedSizeIsKnown() {
        // The 9x9 .kbook.gz size is already known from the previously bundled file.
        #expect(OpeningBook.book(forBoardSize: 9)?.fileSize == 240_027_267)
    }

    @Test func fileNamesAreKbookGz() {
        for book in OpeningBook.allCases {
            #expect(book.fileName.hasSuffix(".kbook.gz"), "\(book.fileName) should be a .kbook.gz")
            #expect(book.url.hasSuffix(book.fileName), "url should end with the fileName")
        }
    }

    // MARK: - Storage location

    @Test func downloadedURLLivesUnderOpeningBooksDirectory() {
        let book = OpeningBook.book(forBoardSize: 9)!
        #expect(book.downloadedURL.lastPathComponent == book.fileName)
        #expect(book.downloadedURL.deletingLastPathComponent().lastPathComponent == "OpeningBooks")
    }

    @Test func ensureBooksDirectoryCreatesDirExcludedFromBackup() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("obtest-\(UUID().uuidString)", isDirectory: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            try? FileManager.default.removeItem(at: parent)
        }

        let dir = try OpeningBook.ensureBooksDirectory()
        #expect(FileManager.default.fileExists(atPath: dir.path))
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Delete

    @Test func deleteRemovesArchiveAndDecompressedCache() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("obtest-\(UUID().uuidString)", isDirectory: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            try? FileManager.default.removeItem(at: parent)
        }

        let book = OpeningBook.book(forBoardSize: 6)!
        try OpeningBook.ensureBooksDirectory()
        try Data([1, 2, 3]).write(to: book.downloadedURL)
        try Data([4, 5, 6]).write(to: book.decompressedCacheURL)
        #expect(book.isDownloaded)
        #expect(FileManager.default.fileExists(atPath: book.decompressedCacheURL.path))

        book.deleteDownloaded()
        #expect(book.isDownloaded == false)
        #expect(FileManager.default.fileExists(atPath: book.decompressedCacheURL.path) == false)
    }

    @Test func decompressedCacheNameStripsGzExtension() {
        let book = OpeningBook.book(forBoardSize: 9)!
        // book9x9jp-20260226.kbook.gz -> cached decompressed file "...kbook"
        #expect(book.decompressedCacheURL.lastPathComponent.hasSuffix(".kbook"))
        #expect(book.decompressedCacheURL.lastPathComponent.hasSuffix(".gz") == false)
    }

    @Test func onDiskSizeReportsArchiveBytes() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("obtest-\(UUID().uuidString)", isDirectory: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            try? FileManager.default.removeItem(at: parent)
        }
        let book = OpeningBook.book(forBoardSize: 7)!
        #expect(book.onDiskSize == nil)
        try OpeningBook.ensureBooksDirectory()
        try Data(count: 1234).write(to: book.downloadedURL)
        #expect(book.onDiskSize == 1234)
    }

    // MARK: - BookLookup load-from-file integration

    @Test func loadIfNeededLoadsDownloadedBook() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("bltest-\(UUID().uuidString)", isDirectory: true)
        Self.isolateCustomBooks(into: parent)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }
        let book = try OpeningBookTests.installFixtureBook(boardSize: 7, into: parent)
        #expect(book.isDownloaded)

        let lookup = BookLookup()
        #expect(lookup.isAvailable(forBoardSize: 7))
        lookup.loadIfNeeded(boardSize: 7)

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !lookup.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.isLoaded)
        #expect(lookup.boardSize == 7)
        #expect(lookup.isReady(forBoardSize: 7))
        #expect(lookup.isReady(forBoardSize: 9) == false)
    }

    @Test func loadIfNeededNoOpWhenNotDownloaded() {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("bltest-\(UUID().uuidString)", isDirectory: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        Self.isolateCustomBooks(into: parent)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
        }

        let lookup = BookLookup()
        #expect(lookup.isAvailable(forBoardSize: 8) == false)
        lookup.loadIfNeeded(boardSize: 8)
        #expect(lookup.isLoaded == false)
    }

    @Test func loadIfNeededDifferentSizeUnloadsWhenNewSizeUnavailable() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("bltest-\(UUID().uuidString)", isDirectory: true)
        Self.isolateCustomBooks(into: parent)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }
        // Only the 7x7 book is present.
        try OpeningBookTests.installFixtureBook(boardSize: 7, into: parent)
        let lookup = BookLookup()
        lookup.loadIfNeeded(boardSize: 7)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !lookup.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.isReady(forBoardSize: 7))

        // Switching to an unavailable 8x8 unloads the 7x7.
        lookup.loadIfNeeded(boardSize: 8)
        #expect(lookup.isLoaded == false)
        #expect(lookup.isReady(forBoardSize: 7) == false)
    }

    // MARK: - Custom book import (CustomBookImporter)

    /// Scratch parent + isolated stores + a source file written from raw
    /// bytes. Returns (parent, sourceURL).
    fileprivate static func importScratch(suiteName: String = #function,
                                          sourceName: String,
                                          bytes: Data) throws -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        isolateCustomBooks(into: parent, suiteName: suiteName)
        let sourceURL = parent.appendingPathComponent(sourceName)
        try bytes.write(to: sourceURL)
        return (parent, sourceURL)
    }

    fileprivate static func cleanupScratch(_ parent: URL) {
        OpeningBook._booksDirectoryOverride = nil
        restoreCustomBooks()
        try? FileManager.default.removeItem(at: parent)
    }

    @Test func importPlainKbookStoresPlainExtension() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 12)
        let (parent, source) = try Self.importScratch(sourceName: "My 12 Book.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        let record = try await CustomBookImporter.importBook(from: source)
        #expect(record.fileName.hasSuffix(".kbook"))
        #expect(record.fileName.hasSuffix(".kbook.gz") == false)
        #expect(record.boardSize == 12)
        #expect(record.displayName == "My 12 Book")
        #expect(FileManager.default.fileExists(atPath: record.fileURL.path))
        #expect(CustomBookStore().records.map(\.id) == [record.id])
    }

    @Test func importGzippedKbookStoresGzExtension() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 6)
        let (parent, source) = try Self.importScratch(sourceName: "small.kbook.gz",
                                                      bytes: Self.gzipForTesting(raw))
        defer { Self.cleanupScratch(parent) }

        let record = try await CustomBookImporter.importBook(from: source)
        #expect(record.fileName.hasSuffix(".kbook.gz"))
        #expect(record.boardSize == 6)
        #expect(record.displayName == "small")
        #expect(FileManager.default.fileExists(atPath: record.fileURL.path))
    }

    @Test func importRejectsVersion2WithDistinctError() async throws {
        var raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 9)
        var version2 = UInt32(2).littleEndian
        withUnsafeBytes(of: &version2) { raw.replaceSubrange(4..<8, with: $0) }
        let (parent, source) = try Self.importScratch(sourceName: "future.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        await #expect(throws: CustomBookImportError.unsupportedBookVersion(2)) {
            try await CustomBookImporter.importBook(from: source)
        }
        #expect(CustomBookStore().records.isEmpty)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: CustomBookStore.directoryURL, includingPropertiesForKeys: nil)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func importRejectsUnsupportedBoardSize() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 16)
        let (parent, source) = try Self.importScratch(sourceName: "big.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        await #expect(throws: CustomBookImportError.unsupportedBoardSize(16)) {
            try await CustomBookImporter.importBook(from: source)
        }
        #expect(CustomBookStore().records.isEmpty)
    }

    @Test func importRejectsGarbageBeforeCopying() async throws {
        let (parent, source) = try Self.importScratch(sourceName: "notes.txt",
                                                      bytes: Data("just some text".utf8))
        defer { Self.cleanupScratch(parent) }

        await #expect(throws: CustomBookImportError.notABook) {
            try await CustomBookImporter.importBook(from: source)
        }
        #expect(CustomBookStore().records.isEmpty)
    }

    @Test func importRejectsTruncatedBookAndLeavesNothing() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 9)
        let (parent, source) = try Self.importScratch(sourceName: "cut.kbook",
                                                      bytes: raw.prefix(raw.count - 1))
        defer { Self.cleanupScratch(parent) }

        await #expect(throws: CustomBookImportError.notABook) {
            try await CustomBookImporter.importBook(from: source)
        }
        #expect(CustomBookStore().records.isEmpty)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: CustomBookStore.directoryURL, includingPropertiesForKeys: nil)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func deleteSweepsFileCacheRecordAndSelection() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 8)
        let (parent, source) = try Self.importScratch(sourceName: "book8.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        let store = CustomBookStore()
        let record = try await CustomBookImporter.importBook(from: source)
        store.setActiveBookIdentity(record.identity, forBoardSize: 8)
        try Data([1, 2, 3]).write(to: record.decompressedCacheURL)

        CustomBookImporter.delete(record)
        #expect(FileManager.default.fileExists(atPath: record.fileURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: record.decompressedCacheURL.path) == false)
        #expect(store.activeBookIdentity(forBoardSize: 8) == nil)
        #expect(store.records.isEmpty)
    }

    // MARK: - Resolver + selection-aware loading

    @Test func resolverPrefersSelectionThenCatalogThenNewestImport() async throws {
        let raw7 = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 7)
        let (parent, source) = try Self.importScratch(sourceName: "mine7.kbook", bytes: raw7)
        defer { Self.cleanupScratch(parent) }

        let store = CustomBookStore()

        // Imported only: the import resolves even with no selection.
        let record = try await CustomBookImporter.importBook(from: source)
        #expect(BookResolver.resolvedBook(forBoardSize: 7)?.identity == record.identity)

        // Catalog appears: automatic resolution prefers it.
        let catalog = try Self.installFixtureBook(boardSize: 7, into: parent)
        #expect(BookResolver.resolvedBook(forBoardSize: 7)?.identity == catalog.fileName)

        // An explicit selection wins over the catalog.
        store.setActiveBookIdentity(record.identity, forBoardSize: 7)
        #expect(BookResolver.resolvedBook(forBoardSize: 7)?.identity == record.identity)

        // A dangling selection falls back to the catalog.
        store.setActiveBookIdentity("no-such-book", forBoardSize: 7)
        #expect(BookResolver.resolvedBook(forBoardSize: 7)?.identity == catalog.fileName)

        // Deleting the selected import clears its selection and falls back.
        store.setActiveBookIdentity(record.identity, forBoardSize: 7)
        CustomBookImporter.delete(record)
        #expect(store.activeBookIdentity(forBoardSize: 7) == nil)
        #expect(BookResolver.resolvedBook(forBoardSize: 7)?.identity == catalog.fileName)
    }

    @Test func importedOnlySizeIsAvailable() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 12)
        let (parent, source) = try Self.importScratch(sourceName: "twelve.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        let lookup = BookLookup()
        #expect(lookup.isAvailable(forBoardSize: 12) == false)
        _ = try await CustomBookImporter.importBook(from: source)
        #expect(lookup.isAvailable(forBoardSize: 12))
    }

    @Test func loadIfNeededReloadsWhenSelectionChanges() async throws {
        let raw7 = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 7)
        let (parent, source) = try Self.importScratch(sourceName: "alt7.kbook", bytes: raw7)
        defer { Self.cleanupScratch(parent) }

        let store = CustomBookStore()
        let catalog = try Self.installFixtureBook(boardSize: 7, into: parent)
        let record = try await CustomBookImporter.importBook(from: source)

        // Loads the automatic pick: the catalog.
        let lookup = BookLookup()
        lookup.loadIfNeeded(boardSize: 7)
        var deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !lookup.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.loadedBookIdentity == catalog.fileName)

        // Same size + same identity: a further call is a no-op.
        lookup.loadIfNeeded(boardSize: 7)
        #expect(lookup.isLoaded)

        // Selection change for the loaded size: the next call reloads —
        // this plain-.kbook import also exercises the no-gzip load path.
        store.setActiveBookIdentity(record.identity, forBoardSize: 7)
        lookup.loadIfNeeded(boardSize: 7)
        deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while lookup.loadedBookIdentity != record.identity, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.loadedBookIdentity == record.identity)
        #expect(lookup.isReady(forBoardSize: 7))
    }

    /// Pin the mid-flight rule: a change that arrives while a load is in
    /// flight is re-resolved when the load lands — never dropped, and never
    /// left installing a stale book.
    @Test func loadIfNeededMidFlightChangeLandsOnLatest() async throws {
        let raw7 = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 7)
        let (parent, source) = try Self.importScratch(sourceName: "flight7.kbook", bytes: raw7)
        defer { Self.cleanupScratch(parent) }

        let store = CustomBookStore()
        try Self.installFixtureBook(boardSize: 7, into: parent)
        let record = try await CustomBookImporter.importBook(from: source)

        let lookup = BookLookup()
        // Start loading the automatic pick (the catalog), then immediately
        // flip the selection and re-request. Whether or not the first load is
        // still in flight, the lookup must settle on the newest resolution.
        lookup.loadIfNeeded(boardSize: 7)
        store.setActiveBookIdentity(record.identity, forBoardSize: 7)
        lookup.loadIfNeeded(boardSize: 7)

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while lookup.loadedBookIdentity != record.identity, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.loadedBookIdentity == record.identity)
        #expect(lookup.isReady(forBoardSize: 7))
    }

    /// Pin the one behavioral edge the identity-aware rewrite changed: same
    /// size, resolver nil (book gone from disk) now UNLOADS the stale book
    /// instead of keeping it.
    @Test func loadIfNeededUnloadsWhenLoadedBookVanishes() async throws {
        let raw = BookLookup.serializeToBinary(positions: Self.singleMoveBook(), boardSize: 9)
        let (parent, source) = try Self.importScratch(sourceName: "gone9.kbook", bytes: raw)
        defer { Self.cleanupScratch(parent) }

        let record = try await CustomBookImporter.importBook(from: source)
        let lookup = BookLookup()
        lookup.loadIfNeeded(boardSize: 9)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !lookup.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lookup.isReady(forBoardSize: 9))

        CustomBookImporter.delete(record)
        lookup.loadIfNeeded(boardSize: 9)
        #expect(lookup.isLoaded == false)
        #expect(lookup.loadedBookIdentity == nil)
    }

    // MARK: - reconcileActiveBook (the iOS picker's post-change reconcile)

    /// Scratch dirs + isolated stores, with NO book installed anywhere.
    /// Caller restores in a defer.
    fileprivate static func isolateWithNoBooks(suiteName: String = #function) -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rctest-\(UUID().uuidString)", isDirectory: true)
        OpeningBook._booksDirectoryOverride = parent.appendingPathComponent("OpeningBooks", isDirectory: true)
        isolateCustomBooks(into: parent, suiteName: suiteName)
        return parent
    }

    fileprivate static func board(_ width: Int, _ height: Int) -> BoardSize {
        let board = BoardSize()
        board.width = CGFloat(width)
        board.height = CGFloat(height)
        return board
    }

    /// The size to reconcile is the one that CHANGED, not the game's.
    ///
    /// Positive control for the `gameSize ?? size` bug: a 19x19 game with a
    /// 7x7 book live, reconciling 7. Targeting the game's size instead unloads
    /// a live book nothing asked about and loads nothing in its place.
    @Test func reconcileTargetsTheSizeThatChangedNotTheGames() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rctest-\(UUID().uuidString)", isDirectory: true)
        Self.isolateCustomBooks(into: parent)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }
        try Self.installFixtureBook(boardSize: 7, into: parent)

        let lookup = BookLookup()
        lookup.loadIfNeeded(boardSize: 7)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !lookup.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(lookup.isReady(forBoardSize: 7))
        let identity = lookup.loadedBookIdentity

        reconcileActiveBook(size: 7,
                            bookLookup: lookup,
                            gobanState: GobanState(),
                            board: Self.board(19, 19))

        #expect(lookup.isReady(forBoardSize: 7))
        #expect(lookup.loadedBookIdentity == identity)
    }

    /// The scoping rule: a change at some OTHER size never drags the displayed
    /// game out of book view.
    @Test func reconcileOfAnotherSizeLeavesTheGamesEyeAlone() {
        let parent = Self.isolateWithNoBooks()
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }

        let goban = GobanState()
        goban.eyeStatus = .book
        reconcileActiveBook(size: 7,
                            bookLookup: BookLookup(),
                            gobanState: goban,
                            board: Self.board(9, 9))

        #expect(goban.eyeStatus == .book)
    }

    /// The eye leaves book view when the DISPLAYED game's size lost its last
    /// book — the delete-the-active-book case.
    @Test func reconcileDropsBookViewWhenTheGamesSizeHasNoBookLeft() {
        let parent = Self.isolateWithNoBooks()
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }

        let goban = GobanState()
        goban.eyeStatus = .book
        reconcileActiveBook(size: 7,
                            bookLookup: BookLookup(),
                            gobanState: goban,
                            board: Self.board(7, 7))

        #expect(goban.eyeStatus == .opened)
    }

    /// ...and stays in book view while that size still has one — deleting the
    /// catalog book with an import behind it must not close the eye.
    @Test func reconcileKeepsBookViewWhileTheSizeStillHasABook() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rctest-\(UUID().uuidString)", isDirectory: true)
        Self.isolateCustomBooks(into: parent)
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }
        try Self.installFixtureBook(boardSize: 7, into: parent)

        let goban = GobanState()
        goban.eyeStatus = .book
        reconcileActiveBook(size: 7,
                            bookLookup: BookLookup(),
                            gobanState: goban,
                            board: Self.board(7, 7))

        #expect(goban.eyeStatus == .book)
    }

    /// A rectangular game has no book size of its own, so nothing about it
    /// matches a book change and its eye is left alone.
    @Test func reconcileIgnoresARectangularBoard() {
        let parent = Self.isolateWithNoBooks()
        defer {
            OpeningBook._booksDirectoryOverride = nil
            Self.restoreCustomBooks()
            try? FileManager.default.removeItem(at: parent)
        }

        let goban = GobanState()
        goban.eyeStatus = .book
        reconcileActiveBook(size: 7,
                            bookLookup: BookLookup(),
                            gobanState: goban,
                            board: Self.board(13, 9))

        #expect(goban.eyeStatus == .book)
    }
}
