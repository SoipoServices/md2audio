import SwiftUI
import UniformTypeIdentifiers

/// Audio -> text with on-device speech recognition.
@available(macOS 26, *)
struct TranscribeView: View {
    @AppStorage("sttLocale") private var localeID = Locale.current.identifier
    @AppStorage("sttFormat") private var format: TranscriptFormat = .markdown
    @AppStorage("sttTimestamps") private var timestamps = false

    @State private var audioURL: URL?
    @State private var text = ""
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []

    @StateObject private var transcriber = Transcriber()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FileDropZone(prompt: "Drop an audio file here or click to choose",
                         types: [.audio], url: audioURL) { url in
                audioURL = url
                text = ""
                transcriber.segments = []
                transcriber.status = ""
            }
            .disabled(transcriber.isRunning)

            Form {
                Section("Recognition") {
                    Picker("Language", selection: $localeID) {
                        ForEach(locales, id: \.identifier) { locale in
                            Text(label(for: locale)).tag(locale.identifier)
                        }
                    }
                    Text("Runs entirely on this Mac. The speech model for a language is downloaded the first time you use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Output") {
                    Picker("Format", selection: $format) {
                        ForEach(TranscriptFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Timestamps", isOn: $timestamps)
                        .disabled(format == .srt)
                }
            }
            .formStyle(.grouped)
            .frame(height: 230)
            .disabled(transcriber.isRunning)

            actionBar

            TextEditor(text: $text)
                .font(.system(.body, design: format == .srt ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if text.isEmpty {
                        Text(transcriber.isRunning ? "Listening…" : "The transcript will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)

            HStack {
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save As…", systemImage: "square.and.arrow.down", action: save)
            }
            .disabled(text.isEmpty || transcriber.isRunning)
        }
        .padding(20)
        .task { await loadLocales() }
        .onChange(of: transcriber.segments.count) { render() }
        .onChange(of: format) { render() }
        .onChange(of: timestamps) { render() }
        .alert("Transcription failed",
               isPresented: Binding(get: { transcriber.errorMessage != nil },
                                    set: { if !$0 { transcriber.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(transcriber.errorMessage ?? "")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if transcriber.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: transcriber.progress)
                    Text(transcriber.status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel, action: transcriber.cancel)
            } else {
                Text(transcriber.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: transcribe) {
                    Label("Transcribe", systemImage: "text.bubble")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(audioURL == nil || locales.isEmpty)
            }
        }
    }

    private func label(for locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return installed.contains(locale.identifier) ? "\(name) · downloaded" : name
    }

    private func loadLocales() async {
        locales = await Transcriber.supportedLocales()
        installed = await Transcriber.installedLocales()
        if !locales.contains(where: { $0.identifier == localeID }) {
            // Prefer the language chosen for speech (e.g. it-IT), then the system language
            let speechLang = UserDefaults.standard.string(forKey: "lang") ?? ""
            let wanted = [speechLang, Locale.current.identifier].map { $0.replacingOccurrences(of: "-", with: "_") }
            localeID = wanted.first { id in locales.contains { $0.identifier == id } }
                ?? locales.first { $0.identifier.hasPrefix(String(wanted[0].prefix(2))) }?.identifier
                ?? locales.first?.identifier ?? ""
        }
    }

    private func transcribe() {
        guard let audioURL else { return }
        text = ""
        transcriber.run(url: audioURL, locale: Locale(identifier: localeID))
        Task {
            // Refresh the "downloaded" markers once a new model is installed
            while transcriber.isRunning { try? await Task.sleep(for: .seconds(1)) }
            installed = await Transcriber.installedLocales()
        }
    }

    private func render() {
        text = TranscriptFormatter.render(
            transcriber.segments, format: format, timestamps: timestamps,
            title: audioURL?.deletingPathExtension().lastPathComponent ?? "Transcript")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = (audioURL?.deletingPathExtension().lastPathComponent ?? "transcript")
            + "." + format.fileExtension
        panel.directoryURL = audioURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            transcriber.errorMessage = error.localizedDescription
        }
    }
}
