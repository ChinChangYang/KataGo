//
//  OpeningBookPickerView.swift
//  KataGo Anytime
//
//  Download / inspect / delete the KataGo opening books (6x6...9x9). Mirrors
//  ModelPickerView's trio. Reached from ModelPickerView, which may be shown
//  before a game session exists, so BookLookup/GobanState are looked up
//  optionally from the environment.
//

import SwiftUI
import KataGoUICore

struct OpeningBookTrashButton: View {
    let book: OpeningBook
    @Binding var isDownloaded: Bool
    @State private var isConfirming = false
    @Environment(BookLookup.self) private var bookLookup: BookLookup?
    @Environment(GobanState.self) private var gobanState: GobanState?

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
                // If the deleted book is the one currently loaded, unload it and
                // leave book view (the overlay would otherwise show nothing).
                if bookLookup?.isReady(forBoardSize: book.boardSize) == true {
                    bookLookup?.unload()
                    if gobanState?.eyeStatus == .book {
                        gobanState?.eyeStatus = .opened
                    }
                }
                isDownloaded = book.isDownloaded
            }
            Button("Cancel", role: .cancel) {
                isConfirming = false
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
    @State private var isDownloaded = false
    @Environment(BookLookup.self) private var bookLookup: BookLookup?

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
                        OpeningBookTrashButton(book: book, isDownloaded: $isDownloaded)
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
    var body: some View {
        List {
            Section {
                ForEach(OpeningBook.allCases.sorted { $0.boardSize < $1.boardSize }) { book in
                    NavigationLink {
                        OpeningBookDetailView(
                            book: book,
                            download: DownloadCenter.shared.download(for: book.downloadedURL)
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
                Text("Opening books show KataGo's strongest opening moves and their evaluations directly on the board. Once a board's book is downloaded, tap the eye button to switch the board into book view.")
            }
        }
        .navigationTitle("Opening Books")
    }
}

#Preview("Opening Book Picker") {
    NavigationStack {
        OpeningBookPickerView()
    }
}

#Preview("Opening Book Detail") {
    NavigationStack {
        OpeningBookDetailView(
            book: OpeningBook.allCases[3],
            download: DownloadCenter.shared.download(for: OpeningBook.allCases[3].downloadedURL)
        )
    }
}
