//
//  PhotoImportSheet.swift
//  GobanRecogKit
//
//  Shared preview-and-confirm sheet for importing a game from a board photo.
//  Used by iOS/visionOS and macOS; the platform entry points (PhotosPicker,
//  fileImporter, NSOpenPanel) supply the picked image `Data` and wire the
//  completion in later tasks. Three states:
//    - recognizing:  a spinner while the C++ pipeline runs;
//    - preview:      the recognized position on an engine-free board, stone
//                    counts, confidence, and a next-to-play picker, with Import
//                    and Cancel;
//    - failure:      friendly coaching copy with Try Another Image / Cancel.
//
//  The board is rendered engine-free by synthesizing the SGF and reading its
//  final position with `SgfOperations` (the same path the importer uses, so the
//  preview matches the imported game exactly), then drawing it with the shared
//  `ReportBoardView`.
//

import KataGoUICore
import SwiftUI

public struct PhotoImportSheet: View {
    private let imageData: Data
    private let suggestedName: String
    private let onImport: (_ sgf: String, _ name: String) -> Void
    private let onCancel: () -> Void
    private let onRetry: (() -> Void)?

    @State private var phase: Phase = .recognizing
    @State private var nextToPlay: PlayerColor = .black
    /// GTP vertices of the recognized stones (computed once on success), used
    /// to render the preview. Independent of `nextToPlay`.
    @State private var blackVertices: [String] = []
    @State private var whiteVertices: [String] = []

    private enum Phase: Equatable {
        case recognizing
        case preview(RecognizedBoard)
        case failure(BoardRecognitionError)
    }

    /// - Parameters:
    ///   - imageData: the encoded picked image (JPEG/PNG/HEIC).
    ///   - suggestedName: default game name the host supplies (Files basename or
    ///     "Board Photo <date>"), passed back to `onImport`.
    ///   - onImport: called with the synthesized SGF (for the chosen next-to-play)
    ///     and the suggested name when the user confirms.
    ///   - onCancel: called when the user dismisses without importing.
    ///   - onRetry: optional; when provided, the failure state offers "Try
    ///     Another Image" so the host can re-present its picker.
    public init(imageData: Data,
                suggestedName: String,
                onImport: @escaping (_ sgf: String, _ name: String) -> Void,
                onCancel: @escaping () -> Void,
                onRetry: (() -> Void)? = nil) {
        self.imageData = imageData
        self.suggestedName = suggestedName
        self.onImport = onImport
        self.onCancel = onCancel
        self.onRetry = onRetry
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
            case .failure(let error):
                failure(error)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .task { await recognize() }
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
        }
        .frame(minHeight: 240)
    }

    private func preview(_ board: RecognizedBoard) -> some View {
        VStack(spacing: 16) {
            ReportBoardView(
                width: board.size,
                height: board.size,
                blackVertices: blackVertices,
                whiteVertices: whiteVertices,
                overlay: .none,
                isClassicStoneStyle: false,
                showCoordinate: true,
                verticalFlip: false
            )
            .frame(maxWidth: 320, maxHeight: 320)

            HStack(spacing: 16) {
                Label("\(board.size) × \(board.size)", systemImage: "squareshape.split.3x3")
                stoneCount(board.blackCount, fill: .black, colorName: "black")
                stoneCount(board.whiteCount, fill: .white, colorName: "white")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("Confidence \(Int((board.confidence * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.tertiary)

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
                Spacer()
                Button("Import") {
                    onImport(board.synthesizedSGF(nextToPlay: nextToPlay), suggestedName)
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
                if let onRetry {
                    Spacer()
                    Button("Try Another Image", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minHeight: 240)
    }

    // MARK: - Recognition

    private func recognize() async {
        // Guard against re-running if the sheet body re-appears after a result.
        guard phase == .recognizing else { return }
        do {
            let board = try await BoardRecognizer.recognize(imageData: imageData)
            // Compute the preview vertices via the same SGF → final-position path
            // the importer uses, so the preview matches the imported game.
            let sgf = board.synthesizedSGF(nextToPlay: board.defaultNextToPlay)
            let stones = SgfOperations(sgf: sgf).finalStones()
            blackVertices = stones.black
            whiteVertices = stones.white
            nextToPlay = board.defaultNextToPlay
            phase = .preview(board)
        } catch let error as BoardRecognitionError {
            phase = .failure(error)
        } catch {
            phase = .failure(.recognitionFailed(reason: "\(error)"))
        }
    }
}
