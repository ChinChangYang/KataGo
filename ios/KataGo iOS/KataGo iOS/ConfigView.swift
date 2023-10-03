//
//  ConfigView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/19.
//

import SwiftUI

struct EditButtonBar: View {
    var body: some View {
        HStack {
            Spacer()
            EditButton()
        }
    }
}

struct ConfigItem: View {
    @Environment(\.editMode) private var editMode
    let title: String
    @Binding var content: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if editMode?.wrappedValue.isEditing == true {
                TextField("", text: $content)
                    .multilineTextAlignment(.trailing)
                    .background(Color(white: 0.9))
            } else {
                Text(content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigItems: View {
    @EnvironmentObject var config: Config
    @State var maxMessageCharacters: String = "200"
    @State var maxAnalysisMoves: String = "8"

    var body: some View {
        VStack {
            ConfigItem(title: "Max message characters:", content: $maxMessageCharacters)
                .onChange(of: maxMessageCharacters) { newText in
                    config.maxMessageCharacters = Int(newText) ??
                    Config.defaultMaxMessageCharacters
                }
                .padding(.bottom)

            ConfigItem(title: "Max analysis moves:", content: $maxAnalysisMoves)
                .onChange(of: maxAnalysisMoves) { newText in
                    config.maxAnalysisMoves = Int(newText) ??
                    Config.defaultMaxAnalysisMoves
                }
        }
    }
}

struct ConfigView: View {
    @State var isEditing = EditMode.inactive

    var body: some View {
        VStack {
            EditButtonBar()
                .padding()
            ConfigItems()
                .padding()
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .environment(\.editMode, $isEditing)
    }
}

struct ConfigView_Previews: PreviewProvider {
    static let config = Config()
    static var previews: some View {
        ConfigView()
            .environmentObject(config)
    }
}
