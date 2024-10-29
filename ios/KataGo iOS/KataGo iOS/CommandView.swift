//
//  CommandView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/2.
//

import SwiftUI
import KataGoInterface

struct CommandView: View {
    @Environment(MessageList.self) var messageList
    @State private var command = ""
    var config: Config
    @Environment(Turn.self) var player

    var body: some View {
        VStack {
            ScrollViewReader { scrollView in
                ScrollView(.vertical) {
                    // Vertically show each KataGo message
                    LazyVStack {
                        ForEach(messageList.messages) { message in
                            Text(message.text)
                                .font(.body.monospaced())
                                .id(message.id)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .onAppear {
                        scrollView.scrollTo(messageList.messages.last?.id)
                    }
                }
            }

            HStack {
                TextField("Enter your GTP command (list_commands)", text: $command)
                    .disableAutocorrection(true)
#if !os(macOS)
                    .textInputAutocapitalization(.never)
#endif
                    .onSubmit {
                        messageList.appendAndSend(command: command)
                        command = ""
                    }
                Button(action: {
                    messageList.appendAndSend(command: command)
                    command = ""
                }) {
                    Image(systemName: "paperplane")
                }
            }
            .padding()
        }
        .padding()
    }
}
