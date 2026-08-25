//
//  OpeningBookPickerView.swift
//  KataGo Anytime
//
//  Download / inspect / delete the catalog opening books, import the user's
//  own .kbook/.kbook.gz files, and choose the active book per board size.
//  Mirrors ModelPickerView's trio. Reached from ModelPickerView, whose sheet
//  hands BookLookup/GobanState/BoardSize across from the session — so this
//  screen reads all three NON-optionally and a dropped injection traps on
//  arrival instead of quietly reconciling nothing.
//

import SwiftUI
import KataGoUICore

/// Reconcile a live `BookLookup` after anything changed what the resolver
/// would answer for `size` — an import, a delete, or an active-book selection.
///
/// Scoped so it can never touch a live book of a DIFFERENT size: deleting a
/// 7x7 book while a 9x9 game is in book view must leave the 9x9 book alone.
/// `loadIfNeeded` itself does the rest — it reloads when the resolved identity
/// changed and unloads when nothing resolves any more — and the eye falls back
/// out of book view only when the CURRENT game's size lost its last book.
///
/// Every parameter is non-optional on purpose. This function shipped dead
/// because the model-picker sheet did not hand the live book and the eye
/// across, `@Environment` answered nil, and it returned at a guard nothing was
/// watching. The sheet is still the only way here, so the callers now read all
/// three non-optionally: dropping the injection again is a trap on arrival at
/// the screen, not a log line.
@MainActor
func reconcileActiveBook(size: Int,
                         bookLookup: BookLookup,
                         gobanState: GobanState,
                         board: BoardSize) {
    let gameSize: Int? = board.width == board.height ? Int(board.width) : nil
    guard gameSize == size || bookLookup.isReady(forBoardSize: size) else { return }
    // Reconcile the size that CHANGED. Usually that is the game's size; when it
    // is not, the guard leaves only one other case — `size` is the size
    // currently LOADED — and reloading the game's size there would unload a
    // live book nothing asked about and load nothing in its place.
    bookLookup.loadIfNeeded(boardSize: size)
    // The eye speaks only for the displayed game, so it leaves book view only
    // when THAT size lost its last book.
    guard gameSize == size, !bookLookup.isAvailable(forBoardSize: size) else { return }
    guard gobanState.eyeStatus == .book else { return }
    gobanState.eyeStatus = .opened
}

struct OpeningBookTrashButton: View {
    let book: OpeningBook
    @Binding var isDownloaded: Bool
    var onDeleted: (() -> Void)? = nil
    @State private var isConfirming = false
    @Environment(BookLookup.self) private var bookLookup
    @Environment(GobanState.self) private var gobanState
    @Environment(BoardSize.self) private var board

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Label("Remove Opening Book", systemImage: "trash")
                .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("OpeningBookDetailView.trashButton")
        .confirmationDialog(
            "Remove this opening book? You can download it again later.",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                book.deleteDownloaded()
                // The resolver may now answer with an imported book of the
                // same size — or with nothing, in which case the live lookup
                // unloads and the eye leaves book view.
                reconcileActiveBook(size: book.boardSize,
                                    bookLookup: bookLookup,
                                    gobanState: gobanState,
                                    board: board)
                isDownloaded = book.isDownloaded
                onDeleted?()
            }
            Button("Cancel", role: .cancel) {
                isConfirming = false
            }
        }
    }
}

/// Detail screen for one imported book: name, board size, size on disk,
/// import date, and removal.
struct ImportedBookDetailView: View {
    let record: CustomBookRecord
    /// Invoked after the record is deleted, so the list refreshes.
    let onStoreChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(BookLookup.self) private var bookLookup
    @Environment(GobanState.self) private var gobanState
    @Environment(BoardSize.self) private var board
    @State private var isConfirmingDelete = false

    var body: some View {
        List {
            Section {
                LabeledContent("Board Size", value: "\(record.boardSize)x\(record.boardSize)")
                if let size = record.onDiskSize {
                    LabeledContent("Size", value: size.humanFileSize)
                }
                LabeledContent("Imported", value: record.importedAt.formatted(date: .abbreviated, time: .shortened))
            } footer: {
                Text("An imported book stays on this device only. The app read its board size from the file itself.")
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Remove Imported Book", systemImage: "trash")
                }
                .accessibilityIdentifier("ImportedBookDetailView.trashButton")
            }
        }
        .navigationTitle(record.displayName)
        .confirmationDialog(
            "Remove this imported book? The app keeps no copy of the original file.",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                CustomBookImporter.delete(record)
                reconcileActiveBook(size: record.boardSize,
                                    bookLookup: bookLookup,
                                    gobanState: gobanState,
                                    board: board)
                onStoreChanged()
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                isConfirmingDelete = false
            }
        }
    }
}

struct OpeningBookDetailView: View {
    let book: OpeningBook
    /// Memoized by the center against the book's destination, so re-entering
    /// this screen shows the transfer that is already running rather than
    /// starting a second one.
    let download: Download
    /// Forwarded to the trash button, so a delete refreshes the picker's
    /// Imported/Active Books sections (they are plain @State, not observable).
    var onDeleted: (() -> Void)? = nil
    @State private var isDownloaded = false

    /// `isOnDisk: false` on purpose. A book has nothing to activate, so the
    /// `.play` role is unreachable here — the Downloaded label and the trash
    /// button take the button's place once the file has landed.
    private var role: DownloadButtonRole {
        DownloadButtonRole.role(isOnDisk: false,
                                state: download.state,
                                hasPartial: download.hasPartial)
    }

    private var downloadButton: some View {
        Button {
            switch role {
            case .download, .resume:
                if let url = URL(string: book.url) {
                    DownloadCenter.shared.start(download, from: url)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            case .play:
                break // unreachable; see `role`
            }
        } label: {
            Label {
                Text(role.actionTitle)
            } icon: {
                if role == .pause {
                    Image(systemName: role.systemImageName, variableValue: download.progress)
                        .symbolVariableValueMode(.draw)
                } else {
                    Image(systemName: role.systemImageName)
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("OpeningBookDetailView.downloadButton")
    }

    var body: some View {
        VStack {
            // The tester asked for the network picker's spinning icon here.
            // Same view, same modifiers — not a second copy of them.
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)

            VStack(alignment: .leading) {
                Text(book.title)
                    .bold()

                HStack {
                    if isDownloaded {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let onDisk = book.onDiskSize {
                            Text(onDisk.humanFileSize)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(book.fileSize.humanFileSize)
                            .foregroundStyle(.secondary)
                        downloadButton
                    }

                    Spacer()

                    if isDownloaded {
                        OpeningBookTrashButton(book: book,
                                               isDownloaded: $isDownloaded,
                                               onDeleted: onDeleted)
                    }
                }
                .padding(.vertical)

                ScrollView {
                    Text(book.description)
                }
            }
        }
        .padding()
        .navigationTitle(book.title)
        .onAppear { isDownloaded = book.isDownloaded }
        // Explicit state, not the `isDownloading` true->false edge a pause and
        // a completion used to share. Activation is NOT done here any more —
        // see ContentView — because this view is often gone by the time a
        // 240 MB book finishes.
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = book.isDownloaded }
        }
    }
}

struct OpeningBookPickerView: View {
    @Environment(BookLookup.self) private var bookLookup
    @Environment(GobanState.self) private var gobanState
    @Environment(BoardSize.self) private var board

    @State private var customRecords: [CustomBookRecord] = []
    /// Sizes where more than one book claims the board, so an explicit choice
    /// exists to make. Recomputed by `reload()` — none of its inputs
    /// (UserDefaults, the file system, catalog downloads) are observable.
    @State private var contestedSizes: [(size: Int, candidates: [ResolvedBook])] = []

    @State private var isPresentingImporter = false
    @State private var isCopying = false
    @State private var copyProgress: Double = 0
    @State private var importTask: Task<Void, Never>?
    @State private var importErrorMessage: String?

    var body: some View {
        List {
            if !contestedSizes.isEmpty {
                Section {
                    ForEach(contestedSizes, id: \.size) { entry in
                        Picker("\(entry.size)x\(entry.size)", selection: activeBookBinding(forSize: entry.size)) {
                            ForEach(entry.candidates, id: \.identity) { candidate in
                                Text(candidate.displayName).tag(candidate.identity)
                            }
                        }
                    }
                } header: {
                    Text("Active Books")
                } footer: {
                    Text("These board sizes have more than one book. The chosen one is what book view shows.")
                }
            }

            Section {
                ForEach(OpeningBook.allCases.sorted { $0.boardSize < $1.boardSize }) { book in
                    NavigationLink {
                        OpeningBookDetailView(
                            book: book,
                            download: DownloadCenter.shared.download(for: book.downloadedURL),
                            onDeleted: reload
                        )
                    } label: {
                        HStack {
                            Text(book.title)
                            Spacer()
                            if book.isDownloaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Downloaded")
                            } else {
                                Text(book.fileSize.humanFileSize)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Opening books show KataGo's strongest opening moves and their evaluations directly on the board. Once a book is downloaded or imported for a board size, tap the eye button to switch the board into book view.")
            }

            Section {
                ForEach(customRecords) { record in
                    NavigationLink {
                        ImportedBookDetailView(record: record, onStoreChanged: reload)
                    } label: {
                        HStack {
                            Text(record.displayName)
                            Spacer()
                            Text("\(record.boardSize)x\(record.boardSize)")
                                .foregroundStyle(.secondary)
                            if let size = record.onDiskSize {
                                Text(size.humanFileSize)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteCustomRecords)

                Button {
                    isPresentingImporter = true
                } label: {
                    Label("Import Book…", systemImage: "plus")
                }
                .accessibilityIdentifier("OpeningBookPickerView.importButton")
            } header: {
                Text("Imported Books")
            } footer: {
                Text("Import a .kbook or .kbook.gz file built with the KataGo book pipeline. Square boards from 2x2 to 15x15.")
            }
        }
        .navigationTitle("Opening Books")
        .task { reload() }
        // A catalog download finishing while this screen is up changes the
        // candidate lists, which nothing observable carries — re-scan.
        .onChange(of: DownloadCenter.shared.finishedGeneration) { _, _ in
            reload()
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            // Permissive on purpose, like the network importer: providers
            // type files inconsistently, and the KBOK sniff in the importer
            // is what actually decides, with a specific reason when it says no.
            allowedContentTypes: [.gzip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                startImport(from: url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isCopying) {
            CustomModelImportProgressView(title: "Importing Book",
                                          progress: copyProgress,
                                          onCancel: cancelImport)
                .interactiveDismissDisabled()
        }
        .alert("Couldn't Import Book",
               isPresented: Binding(get: { importErrorMessage != nil },
                                    set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    // MARK: - State

    private func reload() {
        let store = CustomBookStore()
        customRecords = store.records.sorted { $0.importedAt < $1.importedAt }
        contestedSizes = (2...15).compactMap { size in
            let candidates = BookResolver.candidates(forBoardSize: size, store: store)
            return candidates.count >= 2 ? (size, candidates) : nil
        }
    }

    /// Shows the RESOLVED identity (so an automatic choice reads as what it
    /// is); a user change writes an explicit per-size key.
    private func activeBookBinding(forSize size: Int) -> Binding<String> {
        Binding(
            get: { BookResolver.resolvedBook(forBoardSize: size)?.identity ?? "" },
            set: { newIdentity in
                CustomBookStore().setActiveBookIdentity(newIdentity, forBoardSize: size)
                reconcileActiveBook(size: size,
                                    bookLookup: bookLookup,
                                    gobanState: gobanState,
                                    board: board)
                reload()
            }
        )
    }

    // MARK: - Import

    /// Copies the picked file in on a background task, then refreshes the list
    /// and reconciles the live book (an import is the current game's only
    /// activation hook — there is no download completion to observe).
    private func startImport(from url: URL) {
        copyProgress = 0
        isCopying = true
        importTask = Task {
            do {
                // `importBook` is a nonisolated async function, so the copy
                // runs off the main actor even though this Task inherits it.
                let record = try await CustomBookImporter.importBook(from: url) { fraction in
                    Task { @MainActor in copyProgress = fraction }
                }
                isCopying = false
                reconcileActiveBook(size: record.boardSize,
                                    bookLookup: bookLookup,
                                    gobanState: gobanState,
                                    board: board)
                reload()
            } catch is CancellationError {
                // The partial file is already gone; nothing was recorded.
                isCopying = false
            } catch {
                // Dismiss the progress sheet and let that land BEFORE raising
                // the alert. Both are presentations from this view, and a
                // `defer` would have written them in one transaction — an
                // alert raised in the same update that dismisses a sheet can be
                // dropped, leaving a failed import with no explanation at all.
                // Any file is pickable here (`.data` is in the allowed types),
                // so the failure path is easy to reach.
                isCopying = false
                await Task.yield()
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isCopying = false
    }

    /// Swipe-to-delete for imported books. The rows go immediately; the file,
    /// cache and selection sweep follow, and the list is re-read afterwards.
    private func deleteCustomRecords(at offsets: IndexSet) {
        let doomed = offsets.map { customRecords[$0] }
        customRecords.remove(atOffsets: offsets)
        for record in doomed {
            CustomBookImporter.delete(record)
            reconcileActiveBook(size: record.boardSize,
                                bookLookup: bookLookup,
                                gobanState: gobanState,
                                board: board)
        }
        reload()
    }
}

/// Hosts the trio the picker's sheet hands across in the app, so the previews
/// satisfy the non-optional reads the way `ModelRunnerView` does.
private struct BookPreviewHost<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var bookLookup = BookLookup()
    @State private var gobanState = GobanState()
    @State private var board = BoardSize()

    var body: some View {
        NavigationStack {
            content
        }
        .environment(bookLookup)
        .environment(gobanState)
        .environment(board)
    }
}

#Preview("Opening Book Picker") {
    BookPreviewHost {
        OpeningBookPickerView()
    }
}

#Preview("Opening Book Detail") {
    BookPreviewHost {
        OpeningBookDetailView(
            book: OpeningBook.allCases[3],
            download: DownloadCenter.shared.download(for: OpeningBook.allCases[3].downloadedURL)
        )
    }
}
