//
//  PhotoImportSheet.swift
//  GobanRecogKit
//
//  Shared preview-and-confirm sheet for importing a game from a board photo.
//  Used by iOS and macOS — the two targets that link GobanRecogKit; there is
//  no photo import on visionOS, tvOS, or watchOS. Four states:
//    - recognizing:  a spinner while the C++ pipeline runs;
//    - preview:      the recognized position on an engine-free board, stone
//                    counts, confidence, and a next-to-play picker, with Import
//                    and Cancel. Tapping an intersection cycles it
//                    empty → black → white → empty so the user can correct
//                    mis-recognized stones (e.g. shadows) before importing;
//                    Reset restores the recognized position.
//    - adjustingGrid: shown after a recognition failure (or "Adjust Grid" from
//                    preview) so the user can drag the board's four corner
//                    intersections and pick the board size, then retry; Back
//                    (from preview) restores the exact preview, including stone
//                    edits, without re-recognizing.
//    - failure:      terminal coaching copy, reached only for undecodable
//                    image data (nothing to adjust).
//
//  The grid phase replaced an axis-aligned crop rect. A crop could only narrow
//  where the automatic detector looked, which does nothing for photos whose
//  board face no proposer can find at all; the quad's corners ARE the answer,
//  handed to the lattice fit directly. It remains a superset — a rectangle is a
//  quad — so the old "frame just the board" gesture still works, and if the
//  quad cannot be fitted the sheet falls back to automatic detection within its
//  bounding box, which is exactly what cropping used to do.
//
//  The board is rendered engine-free with the shared `ReportBoardView` from the
//  pure `RecognizedBoard.stoneVertices` mapping, which the
//  `stoneVerticesMatchEngineFinalStones` test pins to the importer's
//  SGF → final-position path — so the preview (edited or not) matches the
//  imported game exactly.
//

import KataGoUICore
import SwiftUI

public struct PhotoImportSheet: View {
    private let imageData: Data
    private let suggestedName: String
    private let onImport: (_ sgf: String, _ name: String) -> Void
    private let onCancel: () -> Void
    private let onRetry: (() -> Void)?
    private let retryButtonTitle: String

    @State private var phase: Phase = .recognizing
    @State private var nextToPlay: PlayerColor = .black
    /// The user-corrected position, nil while untouched. Kept separate from the
    /// recognized board in `phase` so Reset can always restore the original and
    /// the Reset button can hide itself when edits cycle back to it (Equatable).
    @State private var editedBoard: RecognizedBoard?
    /// The quad last submitted to the recognizer (normalized, top-left origin);
    /// nil = automatic detection over the whole frame.
    @State private var submittedQuad: BoardQuad?
    /// The quad being edited in the grid phase.
    @State private var editingQuad = BoardQuad.inset(
        in: CGRect(x: 0, y: 0, width: 1, height: 1), fraction: 0.1)
    /// The board size the grid phase draws and submits. Seeded from whatever
    /// the automatic pass detected, else 19.
    @State private var editingBoardSize = 19
    /// Orientation-baked screen-resolution decode shown by the grid phase;
    /// loaded once on first need.
    @State private var displayImage: CGImage?
    /// Bumped by Recognize so the attempt-keyed `.task` restarts recognition.
    @State private var recognitionAttempt = 0

    /// The sizes the pipeline scores (`SUPPORTED_SIZES`). There is no "Auto"
    /// here: the overlay has to draw a concrete lattice, and an overlay drawn
    /// at the wrong size would be a lie in exactly the situation the user
    /// opened this control to diagnose. It is also self-teaching — a wrong
    /// size is instantly visible, because the lines miss the board.
    private static let supportedSizes = [9, 13, 19]

    /// The sheet's own margin. The grid phase drops it horizontally so the
    /// photo can reach the sheet's edges, and re-adds it to that phase's text,
    /// picker, and buttons.
    private static let contentPadding: CGFloat = 24
    /// The lane the non-grid phases use, applied INSIDE `contentPadding` (so
    /// the card itself is `contentMaxWidth + 2 * contentPadding` wide). Before
    /// the grid phase this cap sat OUTSIDE the padding instead, making 480 the
    /// card's own width and the content lane a narrower 432; that made the
    /// non-grid phases ~48 pt narrower on iPad than they are now. Cosmetic and
    /// iPad-only — iPhone is device-width-bound and macOS floors on
    /// `minWidth` regardless — and accepted as harmless rather than undone.
    private static let contentMaxWidth: CGFloat = 480
    /// The sheet's lane. Wider than `contentMaxWidth` because the photo is the
    /// entire point of the grid phase. Applied for EVERY phase, not just that
    /// one: an NSHostingController sheet sizes its window to the SwiftUI
    /// root's ideal (fitting) width, which is phase-dependent regardless of
    /// this cap — the constant alone would not stop the window jumping on
    /// "Adjust Grid". What actually pins it is `LibraryActions.swift`'s
    /// `minWidth` floor, set to this same 560: floor and cap coincide, so
    /// every phase is pinned to 560 on macOS and there is no jump.
    private static let sheetMaxWidth: CGFloat = 560

    /// Whether the grid editor is showing. Drives the phase-aware chrome: this
    /// is the only phase whose content wants more room than words need.
    private var isGridPhase: Bool {
        if case .adjustingGrid = phase { return true }
        return false
    }

    private enum Phase: Equatable {
        case recognizing
        case preview(RecognizedBoard)
        case adjustingGrid(GridContext)
        case failure(BoardRecognitionError)
    }

    /// Why the grid phase is showing — drives the headline and the Back
    /// button. `fromPreview` carries the recognition (and any stone edits) so
    /// Back can restore the exact preview without re-running the pipeline.
    private enum GridContext: Equatable {
        case firstFailure
        case retryFailure
        case fromPreview(RecognizedBoard, edited: RecognizedBoard?)
    }

    /// - Parameters:
    ///   - imageData: the encoded picked image (JPEG/PNG/HEIC).
    ///   - suggestedName: default game name the host supplies (Files basename or
    ///     "Board Photo <date>"), passed back to `onImport`.
    ///   - onImport: called with the synthesized SGF (for the chosen next-to-play)
    ///     and the suggested name when the user confirms.
    ///   - onCancel: called when the user dismisses without importing.
    ///   - onRetry: optional; when provided, the failure state offers a retry
    ///     button so the host can re-present its picker (or re-open the camera).
    ///   - retryButtonTitle: the retry button's label; defaults to "Try Another
    ///     Image" (the file/library entry point). Camera hosts pass "Retake
    ///     Photo". Ignored when `onRetry` is nil (no button shown).
    public init(imageData: Data,
                suggestedName: String,
                onImport: @escaping (_ sgf: String, _ name: String) -> Void,
                onCancel: @escaping () -> Void,
                onRetry: (() -> Void)? = nil,
                retryButtonTitle: String = "Try Another Image") {
        self.imageData = imageData
        self.suggestedName = suggestedName
        self.onImport = onImport
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.retryButtonTitle = retryButtonTitle
    }

    public var body: some View {
        VStack(spacing: isGridPhase ? 0 : 20) {
            // The grid phase supplies its own headline and needs every point
            // it can get; on macOS the sheet window's title says this anyway.
            if !isGridPhase {
                Text("Import from Photo")
                    .font(.headline)
            }

            switch phase {
            case .recognizing:
                recognizing
            case .preview(let board):
                preview(board)
            case .adjustingGrid(let context):
                adjustingGrid(context)
            case .failure(let error):
                failure(error)
            }
        }
        .padding(.vertical, Self.contentPadding)
        .padding(.horizontal, isGridPhase ? 0 : Self.contentPadding)
        .frame(maxWidth: Self.sheetMaxWidth)
        .task(id: recognitionAttempt) { await recognize() }
    }

    // MARK: - States

    private var recognizing: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.large)
            Text("Reading the board…")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel, action: onCancel)
                .accessibilityIdentifier("PhotoImportSheet.cancel")
        }
        .frame(maxWidth: Self.contentMaxWidth, minHeight: 240)
    }

    @ViewBuilder
    private func preview(_ board: RecognizedBoard) -> some View {
        let current = editedBoard ?? board
        let hasEdits = current != board
        let vertices = current.stoneVertices
        VStack(spacing: 16) {
            ReportBoardView(
                width: board.size,
                height: board.size,
                blackVertices: vertices.black,
                whiteVertices: vertices.white,
                overlay: .none,
                isClassicStoneStyle: false,
                showCoordinate: true,
                verticalFlip: false,
                onTapCoordinate: { coordinate in
                    // Coordinate.y is 1-based from the bottom; rows are
                    // top-origin, so grid row = size − y.
                    editedBoard = current.cyclingStone(atCol: coordinate.x,
                                                       row: board.size - coordinate.y)
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Board preview")
            .accessibilityHint("Tap an intersection to cycle empty, black, white")
            .accessibilityIdentifier("PhotoImportSheet.board")
            .frame(maxWidth: 320, maxHeight: 320)

            HStack(spacing: 16) {
                Label("\(board.size) × \(board.size)", systemImage: "squareshape.split.3x3")
                stoneCount(current.blackCount, fill: .black, colorName: "black")
                stoneCount(current.whiteCount, fill: .white, colorName: "white")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("Tap a point to correct: empty → black → white")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLowConfidence(board) {
                // Only reachable on the manual-grid path, which lifts the
                // recognizer's confidence floor: the user placed the grid, so
                // "low confidence, try again" would tell them nothing they can
                // act on. Showing the position with a warning keeps them in
                // control — every intersection is tappable.
                Label("Low confidence — check the stones before importing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("PhotoImportSheet.lowConfidenceWarning")
            }

            HStack(spacing: 12) {
                Text("Confidence \(Int((board.confidence * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Adjust Grid") {
                    guard prepareGridPhase(seedFrom: board) else { return }
                    phase = .adjustingGrid(.fromPreview(board, edited: editedBoard))
                }
                .font(.caption)
                .accessibilityIdentifier("PhotoImportSheet.adjustGrid")
                if hasEdits {
                    Button("Reset") { editedBoard = nil }
                        .font(.caption)
                        .accessibilityIdentifier("PhotoImportSheet.reset")
                }
            }

            // Segmented style drops the Picker's label on iOS, so render the
            // caption explicitly — without it the control is two bare
            // Black/White buttons whose purpose the user can't guess. macOS
            // keeps the label instead of dropping it, so `.labelsHidden()`
            // below is what stops it rendering a second, redundant caption
            // there (VoiceOver still sees the label; only the visible text
            // is hidden).
            VStack(spacing: 8) {
                Text("Next to play")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Next to play", selection: $nextToPlay) {
                    Text("Black").tag(PlayerColor.black)
                    Text("White").tag(PlayerColor.white)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                Spacer()
                Button("Import") {
                    onImport(current.synthesizedSGF(nextToPlay: nextToPlay), suggestedName)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: Self.contentMaxWidth)
    }

    /// A stone-count item: a real stone glyph (explicit black/white fill with a
    /// stroke so it reads correctly on any background — the SF-Symbol circles
    /// both rendered gray under the row's `.secondary` style in dark mode)
    /// followed by the count.
    private func stoneCount(_ count: Int, fill: Color, colorName: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(.gray, lineWidth: 1))
                .frame(width: 14, height: 14)
            Text("\(count)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(colorName) stones")
    }

    private func failure(_ error: BoardRecognitionError) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(error.userFacingMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                if let onRetry {
                    Spacer()
                    Button(retryButtonTitle, action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("PhotoImportSheet.retry")
                }
            }
        }
        .frame(maxWidth: Self.contentMaxWidth, minHeight: 240)
    }

    @ViewBuilder
    private func adjustingGrid(_ context: GridContext) -> some View {
        VStack(spacing: 16) {
            Text(gridHeadline(for: context))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.contentPadding)

            if let displayImage {
                BoardQuadView(image: displayImage,
                              quad: $editingQuad,
                              boardSize: editingBoardSize)
                    // The photo takes the space the chrome does not need,
                    // and bleeds past the sheet's margins — width is what
                    // binds the aspect fit on every device this ships to, so
                    // those 48 points are the biggest single win available.
                    //
                    // Do NOT add `.layoutPriority(-1)` here. It was tried and
                    // measured actively harmful: it forces the photo to
                    // yield first and completely, and at Accessibility XXXL
                    // on an iPhone 17 that shrank the photo to 54.67x41 pt
                    // (~14% of normal) and made the corner-drag editor
                    // unusable, vs. 288x216 pt without it. At default text
                    // size it made no difference (402x301 either way), and
                    // the chrome was never clipped in any measured case — so
                    // the priority bought nothing and nearly broke the
                    // accessibility case.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 6) {
                Picker("Board size", selection: $editingBoardSize) {
                    ForEach(Self.supportedSizes, id: \.self) { size in
                        Text("\(size)×\(size)").tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("PhotoImportSheet.boardSizePicker")
                Text("The grid should land on the board's lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.contentPadding)

            HStack {
                if case .fromPreview(let board, let edited) = context {
                    Button("Back") {
                        editedBoard = edited
                        phase = .preview(board)
                    }
                    .accessibilityIdentifier("PhotoImportSheet.gridBack")
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                if let onRetry {
                    Button(retryButtonTitle, action: onRetry)
                        .accessibilityIdentifier("PhotoImportSheet.retry")
                }
                Spacer()
                Button("Recognize") {
                    submittedQuad = editingQuad
                    recognitionAttempt += 1
                    phase = .recognizing
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("PhotoImportSheet.recognize")
            }
            .padding(.horizontal, Self.contentPadding)
        }
    }

    private func gridHeadline(for context: GridContext) -> String {
        switch context {
        // "Line crossings", not "the board's corners": the fit wants the outer
        // GRID intersections, which on most boards sit well inside the wooden
        // edge. Placing them on the wood is the single easiest way to get a
        // grid that is subtly wrong everywhere.
        //
        // Two lines each at the sheet's width (three for the retry, where the
        // extra coaching earns its space). Every line here is a line the photo
        // does not get, and "then tap Recognize" says nothing the prominent
        // default-action button two rows below does not.
        case .firstFailure:
            return "Couldn't find the board. Drag each corner onto the outermost line crossing."
        case .retryFailure:
            return "Still no luck. Corners go on the outermost line crossing, not the wooden edge — and check the size."
        case .fromPreview:
            return "Drag each corner onto the outermost line crossing."
        }
    }

    // MARK: - Recognition

    private func recognize() async {
        // Only a fresh `.recognizing` transition runs the pipeline; the sheet
        // body re-appearing after a result must not re-run it.
        guard phase == .recognizing else { return }
        do {
            let board = try await recognizeOnce()
            // Each successful recognition replaces the position wholesale:
            // stone edits belong to the old board, and the picker default
            // re-derives (the user can still override it afterwards).
            editedBoard = nil
            nextToPlay = board.defaultNextToPlay
            phase = .preview(board)
        } catch let error as BoardRecognitionError {
            phase = phaseAfterFailure(error)
        } catch {
            phase = phaseAfterFailure(.recognitionFailed(reason: "\(error)"))
        }
    }

    /// One recognition attempt: automatic over the whole frame, or the user's
    /// quad when they have placed one.
    ///
    /// A user quad that cannot be fitted falls back to automatic detection
    /// inside its bounding box. That preserves exactly what the old crop phase
    /// did — "look only here, and work it out yourself" — for a user who drew a
    /// rough box around the board rather than placing corners precisely.
    private func recognizeOnce() async throws -> RecognizedBoard {
        guard let quad = submittedQuad else {
            return try await BoardRecognizer.recognize(imageData: imageData)
        }
        do {
            return try await BoardRecognizer.recognize(imageData: imageData,
                                                       quadNormalized: quad,
                                                       boardSize: editingBoardSize)
        } catch let error as BoardRecognitionError {
            guard case .recognitionFailed = error else { throw error }
            return try await BoardRecognizer.recognize(
                imageData: imageData,
                cropNormalized: QuadGeometry.boundingRect(of: quad))
        }
    }

    /// A failed recognition opens the grid phase — the user can point at the
    /// board — unless the data is undecodable (nothing to adjust) or, in a
    /// belt-and-suspenders corner, the display decode fails after ingestion
    /// succeeded; both fall back to the terminal failure state.
    private func phaseAfterFailure(_ error: BoardRecognitionError) -> Phase {
        guard case .recognitionFailed = error else { return .failure(error) }
        guard prepareGridPhase(seedFrom: nil) else { return .failure(error) }
        return .adjustingGrid(submittedQuad == nil ? .firstFailure : .retryFailure)
    }

    /// Readies the grid phase: decodes the photo if needed and seeds the quad
    /// and board size.
    ///
    /// Seeding from a successful detection is what makes this "correct what the
    /// app found" rather than "start from nothing" — usually only one or two
    /// corners are actually wrong. With no detection to seed from, the quad
    /// keeps whatever the user last submitted, else an inset rectangle.
    ///
    /// Returns false when the photo cannot be decoded for display, in which
    /// case there is nothing to drag corners on.
    private func prepareGridPhase(seedFrom board: RecognizedBoard?) -> Bool {
        if displayImage == nil {
            displayImage = BoardImageIngestion.displayImage(from: imageData)
        }
        guard displayImage != nil else { return false }

        if let detected = board?.detectedQuad {
            editingQuad = detected
        } else if let submittedQuad {
            editingQuad = submittedQuad
        } else {
            editingQuad = BoardQuad.inset(in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                          fraction: 0.1)
        }
        if let size = board?.size, Self.supportedSizes.contains(size) {
            editingBoardSize = size
        }
        return true
    }

    /// Whether to warn about this position: only for a board the manual-grid
    /// path produced, and only below the tier the automatic path would have
    /// demanded of it.
    ///
    /// Keyed on `quadSource`, not on "did the user submit a quad". A user quad
    /// that fails to fit falls back to automatic detection in its bounding box,
    /// and a board from THAT path already cleared the recognizer's own floor —
    /// warning about it would be inconsistent with the identical board reached
    /// without ever opening the grid editor. `hasPrefix` because the
    /// stone-anchored refit appends a suffix ("user+a").
    private func isLowConfidence(_ board: RecognizedBoard) -> Bool {
        board.quadSource.hasPrefix("user") && board.confidence < 0.45
    }
}
