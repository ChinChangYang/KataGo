//
//  PhotoImportSheet.swift
//  GobanRecogKit
//
//  Shared preview-and-confirm sheet for importing a game from a board photo.
//  Used by iOS/visionOS and macOS; the platform entry points (PhotosPicker,
//  fileImporter, NSOpenPanel) supply the picked image `Data` and wire the
//  completion in later tasks. Four states:
//    - recognizing:  a spinner while the C++ pipeline runs;
//    - preview:      the recognized position on an engine-free board, stone
//                    counts, confidence, and a next-to-play picker, with Import
//                    and Cancel. Tapping an intersection cycles it
//                    empty → black → white → empty so the user can correct
//                    mis-recognized stones (e.g. shadows) before importing;
//                    Reset restores the recognized position.
//    - cropping:     shown after a recognition failure (or "Adjust Crop" from
//                    preview) so the user can drag the crop rect onto just the
//                    board and retry; Back (from preview) restores the exact
//                    preview, including stone edits, without re-recognizing.
//    - failure:      terminal coaching copy, reached only for undecodable
//                    image data (nothing to crop).
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
    /// The last crop submitted to the recognizer (normalized, top-left
    /// origin); nil = full frame. Prefills the crop phase and is reused by
    /// the next Recognize.
    @State private var cropRect: CGRect?
    /// The rect being edited in the crop phase.
    @State private var editingCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Orientation-baked screen-resolution decode shown by the crop phase;
    /// loaded once on first need.
    @State private var displayImage: CGImage?
    /// Bumped by Recognize so the attempt-keyed `.task` restarts recognition.
    @State private var recognitionAttempt = 0

    private enum Phase: Equatable {
        case recognizing
        case preview(RecognizedBoard)
        case cropping(CropContext)
        case failure(BoardRecognitionError)
    }

    /// Why the crop phase is showing — drives the headline and the Back
    /// button. `fromPreview` carries the recognition (and any stone edits) so
    /// Back can restore the exact preview without re-running the pipeline.
    private enum CropContext: Equatable {
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
        VStack(spacing: 20) {
            Text("Import from Photo")
                .font(.headline)

            switch phase {
            case .recognizing:
                recognizing
            case .preview(let board):
                preview(board)
            case .cropping(let context):
                cropping(context)
            case .failure(let error):
                failure(error)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
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
        .frame(minHeight: 240)
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

            HStack(spacing: 12) {
                Text("Confidence \(Int((board.confidence * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Adjust Crop") {
                    if displayImage == nil {
                        displayImage = BoardImageIngestion.displayImage(from: imageData)
                    }
                    guard displayImage != nil else { return }
                    editingCropRect = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    phase = .cropping(.fromPreview(board, edited: editedBoard))
                }
                .font(.caption)
                .accessibilityIdentifier("PhotoImportSheet.adjustCrop")
                if hasEdits {
                    Button("Reset") { editedBoard = nil }
                        .font(.caption)
                        .accessibilityIdentifier("PhotoImportSheet.reset")
                }
            }

            // Segmented style drops the Picker's label, so render the caption
            // explicitly — without it the control is two bare Black/White
            // buttons whose purpose the user can't guess.
            VStack(spacing: 8) {
                Text("Next to play")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Next to play", selection: $nextToPlay) {
                    Text("Black").tag(PlayerColor.black)
                    Text("White").tag(PlayerColor.white)
                }
                .pickerStyle(.segmented)
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
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private func cropping(_ context: CropContext) -> some View {
        VStack(spacing: 16) {
            Text(cropHeadline(for: context))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let displayImage {
                BoardCropView(image: displayImage, cropRect: $editingCropRect)
                    .frame(maxWidth: 400, maxHeight: 400)
            }

            HStack {
                if case .fromPreview(let board, let edited) = context {
                    Button("Back") {
                        editedBoard = edited
                        phase = .preview(board)
                    }
                    .accessibilityIdentifier("PhotoImportSheet.cropBack")
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                if let onRetry {
                    Button(retryButtonTitle, action: onRetry)
                        .accessibilityIdentifier("PhotoImportSheet.retry")
                }
                Spacer()
                Button("Recognize") {
                    cropRect = editingCropRect
                    recognitionAttempt += 1
                    phase = .recognizing
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("PhotoImportSheet.recognize")
            }
        }
    }

    private func cropHeadline(for context: CropContext) -> String {
        switch context {
        case .firstFailure:
            return "Couldn't find the board. Drag the corners to frame just the board, then tap Recognize."
        case .retryFailure:
            return "Still couldn't read the board. Tighten the crop to just the board, or retake the photo with more even lighting."
        case .fromPreview:
            return "Adjust the crop, then tap Recognize."
        }
    }

    // MARK: - Recognition

    private func recognize() async {
        // Only a fresh `.recognizing` transition runs the pipeline; the sheet
        // body re-appearing after a result must not re-run it.
        guard phase == .recognizing else { return }
        do {
            let board = try await BoardRecognizer.recognize(imageData: imageData,
                                                            cropNormalized: cropRect)
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

    /// A failed recognition opens the crop phase — the user can point at the
    /// board — unless the data is undecodable (nothing to crop) or, in a
    /// belt-and-suspenders corner, the display decode fails after ingestion
    /// succeeded; both fall back to the terminal failure state.
    private func phaseAfterFailure(_ error: BoardRecognitionError) -> Phase {
        guard case .recognitionFailed = error else { return .failure(error) }
        if displayImage == nil {
            displayImage = BoardImageIngestion.displayImage(from: imageData)
        }
        guard displayImage != nil else { return .failure(error) }
        editingCropRect = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return .cropping(cropRect == nil ? .firstFailure : .retryFailure)
    }
}
