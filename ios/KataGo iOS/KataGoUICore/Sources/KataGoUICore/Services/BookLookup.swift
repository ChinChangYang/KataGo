//
//  BookLookup.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/3/2.
//

import Foundation
import Compression
import SwiftUI

public struct BookMoveInfo {
    public let winLoss: Double
    public let sharpScore: Double
    public let adjustedVisits: Int64
    public let policyPrior: Double
    public let rank: Int
}

// MARK: - Binary format constants

/// Binary book format (.kbook) layout — all little-endian, 4-byte aligned.
///
/// The book is built with --av-threshold 10000 (minimum adjusted visits).
private let kbookMagic: UInt32 = 0x4B424F4B  // "KBOK"
private let kbookVersion: UInt32 = 1
private let headerSize = 32
private let positionEntrySize = 16
private let moveEntrySize = 28
private let childEntrySize = 8

@MainActor
@Observable
public class BookLookup {
    public private(set) var isLoaded = false

    /// Identity of the loaded book (catalog fileName or import UUID), so a
    /// selection change for the loaded size is detected as "needs reload"
    /// even though the size is unchanged. Nil when nothing is loaded.
    public private(set) var loadedBookIdentity: String?
    public private(set) var isInBook = false
    public private(set) var currentPositionId: Int = 0
    private(set) var accumulatedSymmetry: Int = 0
    public private(set) var justAdvanced = false

    private var isLoading = false

    /// Bumped on every unload and every load start. An in-flight load whose
    /// generation no longer matches was superseded (unloaded, or a newer load
    /// started) and must not install its result.
    private var loadGeneration = 0

    /// A size whose resolution changed while a load was in flight. Re-resolved
    /// as soon as the in-flight load lands, so a selection change (or delete)
    /// during a slow decompress is never silently dropped.
    private var pendingResolveSize: Int?

    private var bookData: Data?
    private var positionCount: UInt32 = 0
    private var moveCount: UInt32 = 0
    private var childCount: UInt32 = 0
    private var movePositionCount: UInt32 = 0

    // Precomputed table offsets
    private var positionTableOffset: Int = 0
    private var movesTableOffset: Int = 0
    private var childrenTableOffset: Int = 0
    private var movePositionsTableOffset: Int = 0

    /// Board size (2...15) read from the loaded book's binary header. Zero until
    /// a book is loaded. All coordinate/symmetry math derives from this, so the
    /// same code path serves every supported board size.
    private(set) var boardSize = 0

    public init() {}

    /// Load the active opening book for `newSize` (2...15), if any — the
    /// resolver's pick among the catalog download and the user's imports.
    /// Loading the already-active book is a no-op (same size AND same
    /// identity); a size switch or a selection change unloads the current book
    /// first. If no book resolves for `newSize`, the lookup is left unloaded
    /// (callers gate the `.book` eye mode on `isReady(forBoardSize:)`).
    public func loadIfNeeded(boardSize newSize: Int) {
        let resolved = BookResolver.resolvedBook(forBoardSize: newSize)
        if isLoaded && boardSize == newSize && loadedBookIdentity == resolved?.identity { return }
        if isLoading {
            // Something changed mid-flight (selection, delete, size). Note it
            // and re-resolve when the in-flight load lands, instead of
            // silently dropping the change and installing a stale book.
            pendingResolveSize = newSize
            return
        }
        if isLoaded { unload() }
        guard let resolved else { return }
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        Task { await load(from: resolved.sourceURL, identity: resolved.identity, generation: generation) }
    }

    /// Unload when the loaded book no longer resolves as its size's active
    /// book (deleted, or superseded by a selection change). No-op otherwise.
    /// For callers that only know "something changed somewhere" — the size
    /// that changed may not be the displayed game's.
    public func unloadIfStale() {
        guard isLoaded else { return }
        if BookResolver.resolvedBook(forBoardSize: boardSize)?.identity != loadedBookIdentity {
            unload()
        }
    }

    /// Clear all loaded state (used on board-size change and after a book is
    /// deleted from the management UI).
    public func unload() {
        loadGeneration += 1
        bookData = nil
        isLoaded = false
        loadedBookIdentity = nil
        isInBook = false
        currentPositionId = 0
        accumulatedSymmetry = 0
        justAdvanced = false
        boardSize = 0
        positionCount = 0
        moveCount = 0
        childCount = 0
        movePositionCount = 0
    }

    /// Whether any book for `size` exists on this device — catalog download or
    /// user import (so the `.book` eye mode can be offered). Independent of
    /// whether it is currently loaded.
    public func isAvailable(forBoardSize size: Int) -> Bool {
        BookResolver.resolvedBook(forBoardSize: size) != nil
    }

    /// Whether a book is loaded AND matches `size` (so the book overlay can
    /// render right now).
    public func isReady(forBoardSize size: Int) -> Bool {
        isLoaded && boardSize == size
    }

    /// Test-only initializer that serializes hand-crafted positions into
    /// in-memory binary Data, then loads from that.
    init(positions: [(nextPlayer: Int, moves: [(positions: [Int], winLoss: Double, sharpScore: Double, adjustedVisits: Int64, policyPrior: Double)], children: [(canonicalPos: Int, childId: Int, sym: Int)])], boardSize: Int = 9) {
        guard !positions.isEmpty else { return }
        let data = Self.serializeToBinary(positions: positions, boardSize: boardSize)
        if loadFromData(data) {
            self.isLoaded = true
            self.isInBook = self.positionCount > 0
        }
    }

    // MARK: - Binary serialization (for tests)

    /// Serialize hand-crafted positions into binary format Data.
    nonisolated static func serializeToBinary(positions: [(nextPlayer: Int, moves: [(positions: [Int], winLoss: Double, sharpScore: Double, adjustedVisits: Int64, policyPrior: Double)], children: [(canonicalPos: Int, childId: Int, sym: Int)])], boardSize: Int = 9) -> Data {
        // Count totals
        var totalMoves = 0
        var totalChildren = 0
        var totalMovePositions = 0
        for pos in positions {
            totalMoves += pos.moves.count
            totalChildren += pos.children.count
            for move in pos.moves {
                totalMovePositions += move.positions.count
            }
        }

        let posCount = UInt32(positions.count)
        var data = Data(capacity: headerSize
                        + positions.count * positionEntrySize
                        + totalMoves * moveEntrySize
                        + totalChildren * childEntrySize
                        + totalMovePositions)

        // Header
        appendUInt32(&data, kbookMagic)
        appendUInt32(&data, kbookVersion)
        appendUInt32(&data, UInt32(boardSize))  // boardSize
        appendUInt32(&data, posCount)
        appendUInt32(&data, UInt32(totalMoves))
        appendUInt32(&data, UInt32(totalChildren))
        appendUInt32(&data, UInt32(totalMovePositions))
        appendUInt32(&data, 0)  // reserved

        // Position table
        var moveIdx: UInt32 = 0
        var childIdx: UInt32 = 0
        for pos in positions {
            data.append(UInt8(pos.nextPlayer))  // nextPlayer
            data.append(0)                       // _pad
            appendUInt16(&data, UInt16(pos.moves.count))   // movesCount
            appendUInt32(&data, moveIdx)         // movesStart
            appendUInt16(&data, UInt16(pos.children.count)) // childrenCount
            appendUInt16(&data, 0)               // _pad2
            appendUInt32(&data, childIdx)        // childrenStart
            moveIdx += UInt32(pos.moves.count)
            childIdx += UInt32(pos.children.count)
        }

        // Moves table
        var movePosIdx: UInt32 = 0
        for pos in positions {
            for move in pos.moves {
                appendUInt32(&data, movePosIdx)          // positionsStart
                data.append(UInt8(move.positions.count))  // positionsCount
                data.append(0)                            // _pad
                data.append(0)                            // _pad
                data.append(0)                            // _pad
                appendFloat32(&data, Float(move.winLoss))     // winLoss
                appendFloat32(&data, Float(move.sharpScore))  // sharpScore
                appendInt64(&data, move.adjustedVisits)       // adjustedVisits
                appendFloat32(&data, Float(move.policyPrior)) // policyPrior
                movePosIdx += UInt32(move.positions.count)
            }
        }

        // Children table
        for pos in positions {
            for child in pos.children {
                data.append(UInt8(child.canonicalPos))  // canonicalPos
                data.append(UInt8(child.sym))           // sym
                appendUInt16(&data, 0)                  // _pad
                appendUInt32(&data, UInt32(child.childId)) // childId
            }
        }

        // Move positions table
        for pos in positions {
            for move in pos.moves {
                for p in move.positions {
                    data.append(UInt8(p))
                }
            }
        }

        return data
    }

    private nonisolated static func appendLittleEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private nonisolated static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        appendLittleEndian(&data, value)
    }

    private nonisolated static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        appendLittleEndian(&data, value)
    }

    private nonisolated static func appendInt64(_ data: inout Data, _ value: Int64) {
        appendLittleEndian(&data, value)
    }

    private nonisolated static func appendFloat32(_ data: inout Data, _ value: Float) {
        appendLittleEndian(&data, value.bitPattern)
    }

    // MARK: - Loading

    /// Parse the book at `sourceURL` (a `.kbook` or `.kbook.gz`) off the main
    /// actor, then install it under `identity` — unless `generation` shows the
    /// load was superseded while the parse ran. Either way, any change that
    /// arrived mid-flight (`pendingResolveSize`) is re-resolved on the way out.
    private func load(from sourceURL: URL, identity: String, generation: Int) async {
        defer {
            isLoading = false
            if let size = pendingResolveSize {
                pendingResolveSize = nil
                loadIfNeeded(boardSize: size)
            }
        }
        let parseTask = Task.detached(priority: .userInitiated) {
            Self.loadBinaryBook(sourceURL: sourceURL)
        }
        guard let data = await parseTask.value else {
            return
        }
        guard generation == loadGeneration else { return }

        if loadFromData(data) {
            self.isLoaded = true
            self.loadedBookIdentity = identity
            self.isInBook = self.positionCount > 0
            self.currentPositionId = 0
            self.accumulatedSymmetry = 0
        }
    }

    /// Read a book source. A plain `.kbook` is mapped directly; a `.kbook.gz`
    /// is decompressed to the caches dir on first use, then mmapped.
    private nonisolated static func loadBinaryBook(sourceURL: URL) -> Data? {
        // A plain (non-gzipped) .kbook needs no cache: map it directly.
        if let raw = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
           raw.count >= 4, raw.readUInt32(at: 0) == kbookMagic {
            return raw
        }

        let filename = sourceURL.deletingPathExtension().lastPathComponent
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cachedURL = cacheDir.appendingPathComponent(filename)

        // Try to use cached decompressed file via mmap (skip fileExists to avoid TOCTOU)
        let fm = FileManager.default
        let bundleMod = (try? fm.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? .distantPast
        let cacheMod = (try? fm.attributesOfItem(atPath: cachedURL.path)[.modificationDate] as? Date) ?? .distantPast
        if cacheMod >= bundleMod, let data = try? Data(contentsOf: cachedURL, options: .mappedIfSafe) {
            #if !DEBUG
            // Validate cache isn't corrupted
            if data.count >= 4, data.readUInt32(at: 0) == kbookMagic {
                return data
            }
            #endif
            // Corrupted cache — fall through to re-decompress
            printError("Corrupted cache file detected, re-decompressing")
            try? FileManager.default.removeItem(at: cachedURL)
        }

        // Decompress from the source archive
        guard let compressedData = try? Data(contentsOf: sourceURL) else {
            printError("Failed to read compressed data from \(sourceURL.lastPathComponent)")
            return nil
        }
        guard let decompressedData = decompressGzip(compressedData) else {
            printError("Decompression failed for book data")
            return nil
        }

        // Write to cache for future launches, use in-memory data now
        try? decompressedData.write(to: cachedURL)
        return decompressedData
    }

    // MARK: - Header validation

    /// Everything the fixed-size KBOK header declares about a book, after validation.
    struct BookHeaderSummary: Equatable {
        let boardSize: Int
        let positionCount: UInt32
        let moveCount: UInt32
        let childCount: UInt32
        let movePositionCount: UInt32
    }

    enum BookValidationError: Error, Equatable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt32)
        case unsupportedBoardSize(UInt32)
    }

    /// Validate the KBOK header and table bounds of `data` (decompressed bytes).
    /// The board-size gate is the app-wide book range: square 2...15. KBOK v1
    /// stores each move position in one byte with pass sentinel N*N, so 15x15
    /// (225) is the largest board the format can represent (see ADR 0009).
    nonisolated static func parseHeader(_ data: Data) throws -> BookHeaderSummary {
        guard data.count >= headerSize else { throw BookValidationError.truncated }

        let magic = data.readUInt32(at: 0)
        guard magic == kbookMagic else { throw BookValidationError.badMagic }

        let version = data.readUInt32(at: 4)
        guard version == kbookVersion else { throw BookValidationError.unsupportedVersion(version) }

        let boardSizeVal = data.readUInt32(at: 8)
        guard (2...15).contains(boardSizeVal) else { throw BookValidationError.unsupportedBoardSize(boardSizeVal) }

        let positionCount = data.readUInt32(at: 12)
        let moveCount = data.readUInt32(at: 16)
        let childCount = data.readUInt32(at: 20)
        let movePositionCount = data.readUInt32(at: 24)

        let movesTableOffset = headerSize + Int(positionCount) * positionEntrySize
        let childrenTableOffset = movesTableOffset + Int(moveCount) * moveEntrySize
        let movePositionsTableOffset = childrenTableOffset + Int(childCount) * childEntrySize
        let expectedMinSize = movePositionsTableOffset + Int(movePositionCount)
        guard data.count >= expectedMinSize else { throw BookValidationError.truncated }

        return BookHeaderSummary(boardSize: Int(boardSizeVal),
                                 positionCount: positionCount,
                                 moveCount: moveCount,
                                 childCount: childCount,
                                 movePositionCount: movePositionCount)
    }

    /// Full structural validation for an import: sniffs gzip vs plain KBOK,
    /// decompresses if needed, then validates the header and table bounds.
    nonisolated static func validateImportedBook(_ raw: Data) throws -> (summary: BookHeaderSummary, isGzipped: Bool) {
        if raw.count >= 2, raw[raw.startIndex] == 0x1f, raw[raw.startIndex + 1] == 0x8b {
            guard let decompressed = decompressGzip(raw) else { throw BookValidationError.truncated }
            return (try parseHeader(decompressed), true)
        }
        return (try parseHeader(raw), false)
    }

    /// Load binary book data and validate header. Returns true on success.
    private func loadFromData(_ data: Data) -> Bool {
        let summary: BookHeaderSummary
        do {
            summary = try Self.parseHeader(data)
        } catch {
            printError("Book validation failed: \(error)")
            return false
        }

        self.boardSize = summary.boardSize
        self.positionCount = summary.positionCount
        self.moveCount = summary.moveCount
        self.childCount = summary.childCount
        self.movePositionCount = summary.movePositionCount

        // Compute table offsets (already bounds-checked by parseHeader)
        self.positionTableOffset = headerSize
        self.movesTableOffset = positionTableOffset + Int(positionCount) * positionEntrySize
        self.childrenTableOffset = movesTableOffset + Int(moveCount) * moveEntrySize
        self.movePositionsTableOffset = childrenTableOffset + Int(childCount) * childEntrySize

        self.bookData = data
        return true
    }

    // MARK: - Binary accessors

    /// Read position entry fields at the given position index.
    private struct PositionEntry {
        let nextPlayer: UInt8
        let movesCount: UInt16
        let movesStart: UInt32
        let childrenCount: UInt16
        let childrenStart: UInt32
    }

    private func readPosition(at index: Int) -> PositionEntry? {
        guard let data = bookData, index >= 0, index < Int(positionCount) else { return nil }
        let offset = positionTableOffset + index * positionEntrySize
        guard offset + positionEntrySize <= data.count else { return nil }
        return data.withUnsafeBytes { buf in
            PositionEntry(
                nextPlayer: buf.load(fromByteOffset: offset, as: UInt8.self),
                movesCount: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)),
                movesStart: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)),
                childrenCount: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)),
                childrenStart: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
            )
        }
    }

    /// Read move entry fields at the given move index.
    private struct MoveEntry {
        let positionsStart: UInt32
        let positionsCount: UInt8
        let winLoss: Float
        let sharpScore: Float
        let adjustedVisits: Int64
        let policyPrior: Float
    }

    private func readMove(at index: Int) -> MoveEntry? {
        guard let data = bookData, index >= 0, index < Int(moveCount) else { return nil }
        let offset = movesTableOffset + index * moveEntrySize
        guard offset + moveEntrySize <= data.count else { return nil }
        return data.withUnsafeBytes { buf in
            MoveEntry(
                positionsStart: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self)),
                positionsCount: buf.load(fromByteOffset: offset + 4, as: UInt8.self),
                winLoss: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))),
                sharpScore: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))),
                adjustedVisits: Int64(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 16, as: Int64.self)),
                policyPrior: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)))
            )
        }
    }

    /// Read move position at the given index in the move positions table.
    private func readMovePosition(at index: Int) -> UInt8? {
        guard let data = bookData, index >= 0, index < Int(movePositionCount) else { return nil }
        let offset = movePositionsTableOffset + index
        guard offset < data.count else { return nil }
        return data[offset]
    }

    /// Read child entry fields at the given child index.
    private struct ChildEntry {
        let canonicalPos: UInt8
        let sym: UInt8
        let childId: UInt32
    }

    private func readChild(at index: Int) -> ChildEntry? {
        guard let data = bookData, index >= 0, index < Int(childCount) else { return nil }
        let offset = childrenTableOffset + index * childEntrySize
        guard offset + childEntrySize <= data.count else { return nil }
        return ChildEntry(
            canonicalPos: data[offset],
            sym: data[offset + 1],
            childId: data.readUInt32(at: offset + 4)
        )
    }

    /// Find child by canonical position using linear scan (avg ~2 children per position).
    private func findChild(forPosition posEntry: PositionEntry, canonicalPos: Int) -> ChildEntry? {
        let start = Int(posEntry.childrenStart)
        let count = Int(posEntry.childrenCount)
        for i in start..<(start + count) {
            guard let child = readChild(at: i) else { continue }
            if Int(child.canonicalPos) == canonicalPos {
                return child
            }
        }
        return nil
    }

    // MARK: - Gzip decompression

    private nonisolated static func decompressGzip(_ data: Data) -> Data? {
        guard data.count > 18,
              data[0] == 0x1f,
              data[1] == 0x8b,
              data[2] == 0x08 else {
            printError("Invalid gzip header")
            return nil
        }

        let flags = data[3]
        var offset = 10

        // Skip optional gzip header fields
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= data.count else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {  // FNAME
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }

        guard offset < data.count - 8 else {
            printError("Truncated gzip header fields at offset \(offset)")
            return nil
        }

        // Read uncompressed size from ISIZE (last 4 bytes, little-endian, mod 2^32)
        let isize = Int(data.readUInt32(at: data.count - 4))

        let deflateData = data[offset..<(data.count - 8)]
        // Use isize as hint, but allow larger (isize is mod 2^32)
        var capacity = max(isize, deflateData.count * 4)
        let maxCapacity = 1024 * 1024 * 1024  // 1 GB safety limit

        guard capacity > 0 else { return nil }

        while capacity <= maxCapacity {
            var result = Data(count: capacity)
            let decodedSize = result.withUnsafeMutableBytes { destBuffer in
                deflateData.withUnsafeBytes { srcBuffer in
                    compression_decode_buffer(
                        destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        srcBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        deflateData.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decodedSize > 0 else {
                printError("Decompression failed (size=0)")
                return nil
            }
            if decodedSize < capacity {
                result.count = decodedSize
                return result
            }
            // decodedSize == capacity: might be truncated, retry with larger buffer
            capacity *= 2
        }
        printError("Decompression exceeded max capacity (\(maxCapacity) bytes)")
        return nil
    }

    // MARK: - Symmetry functions (ported from book.js)

    func compose(_ sym1: Int, _ sym2: Int) -> Int {
        var s2 = sym2
        if sym1 & 0x4 != 0 {
            s2 = (s2 & 0x4) | ((s2 & 0x2) >> 1) | ((s2 & 0x1) << 1)
        }
        return sym1 ^ s2
    }

    func applySymmetry(_ pos: Int, sym: Int) -> Int {
        guard pos < boardSize * boardSize else { return pos }
        var y = pos / boardSize
        var x = pos % boardSize

        if sym & 1 != 0 { y = boardSize - 1 - y }
        if sym & 2 != 0 { x = boardSize - 1 - x }
        if sym >= 4 { swap(&x, &y) }

        return x + y * boardSize
    }

    func applyInverseSymmetry(_ pos: Int, sym: Int) -> Int {
        guard pos < boardSize * boardSize else { return pos }
        var y = pos / boardSize
        var x = pos % boardSize

        if sym >= 4 { swap(&x, &y) }
        if sym & 1 != 0 { y = boardSize - 1 - y }
        if sym & 2 != 0 { x = boardSize - 1 - x }

        return x + y * boardSize
    }

    // MARK: - Coordinate mapping

    /// Convert book coordinates (y=0 top) to app BoardPoint (y=0 bottom).
    func bookToAppPoint(bookX: Int, bookY: Int, boardHeight: Int) -> BoardPoint {
        return BoardPoint(x: bookX, y: boardHeight - 1 - bookY)
    }

    /// Convert app BoardPoint to book position index.
    func appPointToBookPos(_ point: BoardPoint, boardWidth: Int, boardHeight: Int) -> Int {
        if point.isPass(width: boardWidth, height: boardHeight) {
            return boardSize * boardSize  // 81 for pass
        }
        let bookX = point.x
        let bookY = boardHeight - 1 - point.y
        return bookY * boardSize + bookX
    }

    // MARK: - Navigation

    public func advanceMove(appPoint: BoardPoint, boardWidth: Int, boardHeight: Int) {
        guard isInBook, boardWidth == boardSize, boardHeight == boardSize else { return }

        let displayPos = appPointToBookPos(appPoint, boardWidth: boardWidth, boardHeight: boardHeight)

        // Apply inverse symmetry to get canonical position
        let canonicalPos: Int
        if displayPos >= boardSize * boardSize {
            canonicalPos = displayPos  // pass is symmetry-invariant
        } else {
            canonicalPos = applyInverseSymmetry(displayPos, sym: accumulatedSymmetry)
        }

        guard let posEntry = readPosition(at: currentPositionId) else {
            isInBook = false
            return
        }

        guard let child = findChild(forPosition: posEntry, canonicalPos: canonicalPos) else {
            isInBook = false
            justAdvanced = true
            return
        }

        let newSym = compose(Int(child.sym), accumulatedSymmetry)
        currentPositionId = Int(child.childId)
        accumulatedSymmetry = newSym

        if child.childId >= positionCount {
            isInBook = false
        }

        justAdvanced = true
    }

    public func clearJustAdvanced() {
        justAdvanced = false
    }

    public func resetToRoot() {
        guard isLoaded else { return }
        currentPositionId = 0
        accumulatedSymmetry = 0
        isInBook = positionCount > 0
    }

    /// Replay book state from a list of app BoardPoints (called after undo/forward/game switch).
    public func syncFromMoves(_ moves: [BoardPoint], boardWidth: Int, boardHeight: Int) {
        guard isLoaded, boardWidth == boardSize, boardHeight == boardSize else {
            isInBook = false
            return
        }

        resetToRoot()
        for point in moves {
            advanceMove(appPoint: point, boardWidth: boardWidth, boardHeight: boardHeight)
            if !isInBook { break }
        }
        justAdvanced = false
    }

    // MARK: - Display

    /// Read the current position entry, or nil if not in book.
    private var currentPositionEntry: PositionEntry? {
        guard isInBook else { return nil }
        return readPosition(at: currentPositionId)
    }

    /// Black winrate (0..1) for the best book move, or nil if not in book.
    public var bestBlackWinrate: Float? {
        guard let posEntry = currentPositionEntry, posEntry.movesCount > 0,
              let bestMove = readMove(at: Int(posEntry.movesStart)) else { return nil }
        return Float((1.0 - Double(bestMove.winLoss)) / 2.0)
    }

    /// Black score lead for the best book move, or nil if not in book.
    public var bestBlackScore: Float? {
        guard let posEntry = currentPositionEntry, posEntry.movesCount > 0,
              let bestMove = readMove(at: Int(posEntry.movesStart)) else { return nil }
        return Float(-bestMove.sharpScore)
    }

    /// The next player at the current position (1=black, 2=white), or nil if not in book.
    public var currentNextPlayer: Int? {
        guard let posEntry = currentPositionEntry else { return nil }
        return Int(posEntry.nextPlayer)
    }

    /// The number of moves at the current position, or nil if not in book.
    var currentMovesCount: Int? {
        guard let posEntry = currentPositionEntry else { return nil }
        return Int(posEntry.movesCount)
    }

    public func getBookAnalysis(boardWidth: Int, boardHeight: Int) -> [BoardPoint: BookMoveInfo] {
        guard boardWidth == boardSize,
              boardHeight == boardSize,
              let posEntry = currentPositionEntry else {
            return [:]
        }

        var result: [BoardPoint: BookMoveInfo] = [:]

        let movesStart = Int(posEntry.movesStart)
        let movesCount = Int(posEntry.movesCount)

        for rank in 0..<movesCount {
            guard let move = readMove(at: movesStart + rank) else { continue }

            let posStart = Int(move.positionsStart)
            let posCount = Int(move.positionsCount)

            for j in 0..<posCount {
                guard let posByte = readMovePosition(at: posStart + j) else { continue }
                let canonicalPos = Int(posByte)
                let isPass = canonicalPos >= boardSize * boardSize

                let displayPos: Int
                if isPass {
                    displayPos = canonicalPos
                } else {
                    displayPos = applySymmetry(canonicalPos, sym: accumulatedSymmetry)
                }

                let appPoint: BoardPoint

                if isPass {
                    appPoint = BoardPoint.pass(width: boardWidth, height: boardHeight)
                } else {
                    let bookX = displayPos % boardSize
                    let bookY = displayPos / boardSize
                    appPoint = bookToAppPoint(bookX: bookX, bookY: bookY, boardHeight: boardHeight)
                }

                result[appPoint] = BookMoveInfo(
                    winLoss: Double(move.winLoss),
                    sharpScore: Double(move.sharpScore),
                    adjustedVisits: move.adjustedVisits,
                    policyPrior: Double(move.policyPrior),
                    rank: rank
                )
            }
        }

        return result
    }
}

// MARK: - Data extension for reading little-endian values

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        withUnsafeBytes { buffer in
            value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        }
        return UInt16(littleEndian: value)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeBytes { buffer in
            value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return UInt32(littleEndian: value)
    }

    func readInt64(at offset: Int) -> Int64 {
        var value: Int64 = 0
        withUnsafeBytes { buffer in
            value = buffer.loadUnaligned(fromByteOffset: offset, as: Int64.self)
        }
        return Int64(littleEndian: value)
    }

    func readFloat32(at offset: Int) -> Float {
        var bits: UInt32 = 0
        withUnsafeBytes { buffer in
            bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: bits))
    }
}
