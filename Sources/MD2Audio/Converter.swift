import Foundation

/// Converts Markdown text to audio with the system voices and reports progress.
@MainActor
final class Converter: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var resultURL: URL?
    @Published var errorMessage: String?

    private var writer: SpeechFileWriter?

    /// Markdown -> (SSML, pause) per block, ready for the synthesizer.
    /// Silent blocks (dividers) lengthen the pause before the next spoken block,
    /// and a heading always gets at least its own pause before it too.
    static func script(for markdown: String, style: SpeechStyle, pauseScale: Double) throws
        -> [(ssml: String, pause: Double)] {
        var items: [(ssml: String, pause: Double)] = []
        for block in try MarkdownBlocks.parse(markdown) {
            guard let ssml = SSMLBuilder.ssml(for: block, style: style) else {
                if case .divider = block.kind, !items.isEmpty {
                    items[items.count - 1].pause = max(items[items.count - 1].pause, block.pause * pauseScale)
                }
                continue
            }
            if block.isHeading, !items.isEmpty {
                items[items.count - 1].pause = max(items[items.count - 1].pause, block.pause * pauseScale)
            }
            items.append((ssml, block.pause * pauseScale))
        }
        return items
    }

    func run(markdown: String, output: URL, format: OutputFormat, voiceID: String,
             style: SpeechStyle, pauseScale: Double) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        resultURL = nil
        errorMessage = nil
        status = "Preparing…"

        Task {
            let writer = SpeechFileWriter()
            self.writer = writer
            do {
                let items = try Self.script(for: markdown, style: style, pauseScale: pauseScale)
                guard !items.isEmpty else { throw SpeechError.noText }
                try await writer.write(items, voiceID: voiceID, format: format, to: output) { i in
                    progress = Double(i - 1) / Double(items.count)
                    status = "Block \(i) of \(items.count)"
                }
                progress = 1
                status = "Done"
                resultURL = output
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                status = "Failed"
                errorMessage = error.localizedDescription
            }
            isRunning = false
            self.writer = nil
        }
    }

    func cancel() {
        writer?.cancel()
    }
}
