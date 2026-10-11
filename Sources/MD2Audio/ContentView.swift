import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case speak = "Text → Audio"
    case transcribe = "Audio → Text"
    var id: String { rawValue }
}

/// Main window: switches between Markdown -> audio and audio -> text.
struct ContentView: View {
    @AppStorage("mode") private var mode: Mode = .speak

    var body: some View {
        // Both views stay alive so switching mode keeps files, progress and results
        ZStack {
            SpeakView()
                .opacity(mode == .speak ? 1 : 0)
                .allowsHitTesting(mode == .speak)
            transcribeView
                .opacity(mode == .transcribe ? 1 : 0)
                .allowsHitTesting(mode == .transcribe)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var transcribeView: some View {
        if #available(macOS 26, *) {
            TranscribeView()
        } else {
            ContentUnavailableView("Requires macOS 26", systemImage: "text.bubble",
                                   description: Text("Audio transcription uses the on-device speech recognition introduced in macOS 26."))
        }
    }
}
