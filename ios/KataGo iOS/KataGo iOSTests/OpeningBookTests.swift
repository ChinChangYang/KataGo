//
//  OpeningBookTests.swift
//  KataGo iOSTests
//
//  Catalog + storage tests for the downloadable opening books.
//

import Foundation
import Compression
import Testing
@testable import KataGoUICore

/// Serialized because these tests mutate the process-global
/// `OpeningBook._booksDirectoryOverride`; running them in parallel would race.
/// No other suite touches that override, so serializing this suite is sufficient.
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
        defer {
            OpeningBook._booksDirectoryOverride = nil
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
        defer { OpeningBook._booksDirectoryOverride = nil }

        let lookup = BookLookup()
        #expect(lookup.isAvailable(forBoardSize: 8) == false)
        lookup.loadIfNeeded(boardSize: 8)
        #expect(lookup.isLoaded == false)
    }

    @Test func loadIfNeededDifferentSizeUnloadsWhenNewSizeUnavailable() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("bltest-\(UUID().uuidString)", isDirectory: true)
        defer {
            OpeningBook._booksDirectoryOverride = nil
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
}
