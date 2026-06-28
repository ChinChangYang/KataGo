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
            Image(systemName: "trash")
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
    @State var downloader: Downloader
    @State private var isDownloaded = false
    @Environment(BookLookup.self) private var bookLookup: BookLookup?

    private var downloadButton: some View {
        Button {
            if downloader.isDownloading {
                downloader.cancel()
            } else {
                Task {
                    // Downloader does not create directories.
                    try? OpeningBook.ensureBooksDirectory()
                    if let url = URL(string: book.url) {
                        try? await downloader.download(from: url)
                    }
                }
            }
        } label: {
            if downloader.isDownloading {
                Image(systemName: "stop.circle", variableValue: downloader.progress)
                    .symbolVariableValueMode(.draw)
            } else {
                Image(systemName: "arrow.down")
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("OpeningBookDetailView.downloadButton")
    }

    var body: some View {
        VStack(alignment: .leading) {
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
        .padding()
        .navigationTitle(book.title)
        .onAppear { isDownloaded = book.isDownloaded }
        .onChange(of: downloader.isDownloading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                isDownloaded = book.isDownloaded
                // Make the just-downloaded book available immediately if it
                // matches the active board size (no-op otherwise).
                if isDownloaded {
                    bookLookup?.loadIfNeeded(boardSize: book.boardSize)
                }
            }
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
                            downloader: Downloader(destinationURL: book.downloadedURL)
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
            downloader: Downloader(destinationURL: OpeningBook.allCases[3].downloadedURL)
        )
    }
}
