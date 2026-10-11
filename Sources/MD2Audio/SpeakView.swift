import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Markdown -> audio with the system voices. The text comes from a file or is typed/pasted, and can be edited.
struct SpeakView: View {
    @AppStorage("format") private var format: OutputFormat = .m4a
    @AppStorage("lang") private var lang = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    @AppStorage("voice") private var voiceID = ""
    @AppStorage("speed") private var speed = 1.0
    @AppStorage("pitch") private var pitch = 0.0
    @AppStorage("pause") private var pause = 1.0
    @AppStorage("sentencePause") private var sentencePause = 250.0
    @AppStorage("punctuationPause") private var punctuationPause = 150.0
    @AppStorage("variation") private var variation = 2.0
    @AppStorage("headingStyle") private var headingStyle = true
    @AppStorage("emphasis") private var emphasis = true
    @AppStorage("stripEmoji") private var stripEmoji = true
    @AppStorage("pronunciations") private var pronunciations = "# word = how to say it\n"

    @State private var text = ""
    @State private var sourceURL: URL?
    @State private var outputURL: URL?
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var showSyntax = false

    @StateObject private var converter = Converter()
    @StateObject private var preview = SpeechPreview()

    private static let markdownTypes: [UTType] =
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .plainText].compactMap { $0 }

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 320)
                .padding(.trailing, 10)
            settingsPane
                .frame(minWidth: 520)
                .padding(.leading, 10)
        }
        .padding(20)
        .task { loadVoices(); updateDefaultOutput() }
        .onReceive(NotificationCenter.default.publisher(
            for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in loadVoices() }
        // Voices downloaded in System Settings show up when coming back to the app
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in loadVoices() }
        .onChange(of: format) { updateDefaultOutput() }
        .alert("Conversion failed",
               isPresented: Binding(get: { converter.errorMessage != nil },
                                    set: { if !$0 { converter.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(converter.errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileDropZone(prompt: "Drop a Markdown file here or click to choose",
                         types: Self.markdownTypes, url: sourceURL, onSelect: setInput)
            HStack {
                Text("Text").font(.headline)
                Spacer()
                Button("Syntax", systemImage: "questionmark.circle") { showSyntax.toggle() }
                    .popover(isPresented: $showSyntax, arrowEdge: .bottom) {
                        SyntaxHelp(punctuationPauseMs: punctuationPause, blockPauseScale: pause)
                    }
                Button("Paste", systemImage: "doc.on.clipboard", action: paste)
                Button("Clear", systemImage: "xmark.circle", action: clear)
                    .disabled(text.isEmpty && sourceURL == nil)
            }
            .controlSize(.small)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("…or type or paste Markdown here (⌘V)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .disabled(converter.isRunning)
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                voiceSection
                naturalnessSection
                pronunciationSection
                outputSection
            }
            .formStyle(.grouped)
            .disabled(converter.isRunning)

            actionBar
            if let url = converter.resultURL, !converter.isRunning {
                PlayerView(url: url)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var voiceSection: some View {
        Section {
            Picker("Language", selection: $lang) {
                ForEach(languages, id: \.self) { lang in
                    Text(languageLabel(lang)).tag(lang)
                }
            }
            .onChange(of: lang) { selectDefaultVoice() }
            Picker("Voice", selection: $voiceID) {
                // Downloaded Enhanced/Premium voices are always listed, whatever the language
                let natural = voices.filter(\.isHighQuality)
                if !natural.isEmpty {
                    Section("Natural voices") {
                        ForEach(natural, id: \.identifier) { v in
                            Text("\(v.displayName) · \(languageName(v.language))").tag(v.identifier)
                        }
                    }
                }
                Section("\(languageName(lang)) compact voices") {
                    ForEach(voices.filter { $0.language == lang && !$0.isHighQuality }, id: \.identifier) {
                        Text($0.displayName).tag($0.identifier)
                    }
                }
            }
            .onChange(of: voiceID) { _, id in
                // Picking a natural voice of another language switches the language too
                if let v = voices.first(where: { $0.identifier == id }), v.language != lang { lang = v.language }
            }
            if let voice = voices.first(where: { $0.identifier == voiceID }), !voice.isHighQuality {
                Text("This is a compact voice. Enhanced/Premium voices sound much more natural.")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent {
                Button("Download Voices…", systemImage: "arrow.down.circle", action: openVoiceSettings)
            } label: {
                Text("In Spoken Content, open the System Voice menu and choose Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Voice")
                Spacer()
                Button(preview.isSpeaking ? "Stop" : "Preview", systemImage: preview.isSpeaking ? "stop.fill" : "play.fill",
                       action: togglePreview)
                    .controlSize(.small)
                    .disabled(voiceID.isEmpty)
            }
        }
    }

    private var naturalnessSection: some View {
        Section("Naturalness") {
            slider("Speed", value: $speed, range: 0.5...1.5, step: 0.05) { String(format: "%.2f×", $0) }
            slider("Pitch", value: $pitch, range: -20...20, step: 1) { String(format: "%+.0f%%", $0) }
            slider("Pause between sentences", value: $sentencePause, range: 0...1000, step: 50) { "\(Int($0)) ms" }
            slider("Pause at commas and dashes", value: $punctuationPause, range: 0...500, step: 25) { "\(Int($0)) ms" }
            slider("Pause between blocks", value: $pause, range: 0...3, step: 0.1) { String(format: "%.1f×", $0) }
            slider("Variation", value: $variation, range: 0...6, step: 0.5) { String(format: "±%.1f%%", $0) }
            Toggle("Read headings slower and lower", isOn: $headingStyle)
            Toggle("Stress bold and italic text", isOn: $emphasis)
            Toggle("Skip emoji", isOn: $stripEmoji)
        }
    }

    private var pronunciationSection: some View {
        Section {
            TextEditor(text: $pronunciations)
                .font(.system(.body, design: .monospaced))
                .frame(height: 70)
        } header: {
            Text("Pronunciations")
        } footer: {
            Text("One per line: word = how to say it (e.g. API = a pi i). Whole words, any case.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("Format", selection: $format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Save to") {
                HStack {
                    Text(outputURL?.path ?? "—")
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Change…", action: chooseOutput)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if converter.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: converter.progress)
                    Text(converter.status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel, action: converter.cancel)
            } else {
                Text(converter.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: convert) {
                    Label("Convert", systemImage: "waveform.badge.plus")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isTextEmpty || outputURL == nil || voiceID.isEmpty)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        label: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(label(value.wrappedValue))
                    .monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }

    // MARK: Actions

    private var languages: [String] {
        Array(Set(voices.map(\.language))).sorted()
    }

    private func languageName(_ lang: String) -> String {
        Locale.current.localizedString(forIdentifier: lang) ?? lang
    }

    /// "Italiano (it-IT) · 1 natural" so downloaded voices are easy to find.
    private func languageLabel(_ lang: String) -> String {
        let name = "\(languageName(lang)) (\(lang))"
        let natural = voices.filter { $0.language == lang && $0.isHighQuality }.count
        return natural > 0 ? "\(name) · \(natural) natural" : name
    }

    private var style: SpeechStyle {
        SpeechStyle(speed: speed, pitch: pitch, sentencePauseMs: sentencePause,
                    punctuationPauseMs: punctuationPause, variation: variation,
                    headingStyle: headingStyle, emphasis: emphasis, stripEmoji: stripEmoji,
                    pronunciations: SpeechStyle.parsePronunciations(pronunciations), language: lang)
    }

    private func loadVoices() {
        voices = AVSpeechSynthesisVoice.readingVoices()
        if !languages.contains(lang) {
            lang = languages.first { $0.hasPrefix(String(lang.prefix(2))) }
                ?? languages.first { $0.hasPrefix("en") } ?? languages.first ?? ""
        }
        selectDefaultVoice()
    }

    /// Keeps the chosen voice if it matches the language, otherwise picks the best-quality one.
    private func selectDefaultVoice() {
        let matching = voices.filter { $0.language == lang }
        if !matching.contains(where: { $0.identifier == voiceID }) {
            voiceID = matching.first?.identifier ?? ""
        }
    }

    /// Opens System Settings › Accessibility › Spoken Content, where voices are downloaded.
    private func openVoiceSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
        ]
        _ = urls.lazy.compactMap(URL.init(string:)).first { NSWorkspace.shared.open($0) }
    }

    private func togglePreview() {
        if preview.isSpeaking { return preview.stop() }
        // The first blocks of the text, or a sample sentence
        let markdown = isTextEmpty ? sampleText : text
        let items = (try? Converter.script(for: markdown, style: style, pauseScale: pause)) ?? []
        preview.speak(Array(items.prefix(3)), voiceID: voiceID)
    }

    private var sampleText: String {
        switch lang.prefix(2) {
        case "it": "# Anteprima\n\nQuesta è un'anteprima della voce. Regola le opzioni finché la lettura non ti sembra **naturale**."
        case "es": "# Vista previa\n\nEsta es una vista previa de la voz. Ajusta las opciones hasta que suene **natural**."
        case "fr": "# Aperçu\n\nCeci est un aperçu de la voix. Ajustez les options jusqu'à ce qu'elle sonne **naturelle**."
        case "de": "# Vorschau\n\nDies ist eine Vorschau der Stimme. Passe die Optionen an, bis sie **natürlich** klingt."
        default: "# Preview\n\nThis is a preview of the voice. Adjust the options until it sounds **natural**."
        }
    }

    private var isTextEmpty: Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// Loads the file into the editor; the audio is saved next to it by default.
    private func setInput(_ url: URL) {
        var encoding = String.Encoding.utf8
        guard let contents = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, usedEncoding: &encoding)) else {
            converter.errorMessage = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        text = contents
        sourceURL = url
        resetOutput()
    }

    private func paste() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        text = pasted
        sourceURL = nil
        resetOutput()
    }

    private func clear() {
        text = ""
        sourceURL = nil
        resetOutput()
    }

    private func resetOutput() {
        outputURL = nil
        converter.resultURL = nil
        converter.status = ""
        updateDefaultOutput()
    }

    /// Next to the loaded file, or Documents/Speech for typed or pasted text.
    private func updateDefaultOutput() {
        let base = outputURL ?? sourceURL ?? URL.documentsDirectory.appending(path: "Speech.md")
        outputURL = base.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "output"
        panel.directoryURL = outputURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { outputURL = url }
    }

    private func convert() {
        guard !isTextEmpty, let outputURL else { return }
        preview.stop()
        converter.run(markdown: text, output: outputURL, format: format, voiceID: voiceID,
                      style: style, pauseScale: pause)
    }
}
