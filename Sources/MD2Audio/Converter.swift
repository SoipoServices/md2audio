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

    /// Markdown -> utterances with their pauses, ready for the synthesizer.
    /// Silent blocks (dividers) lengthen the pause before the next spoken block,
    /// and a heading always gets at least its own pause before it too.
    /// The items of the first `count` blocks, for a preview.
    static func firstBlocks(_ count: Int, of items: [SpeechItem]) -> [SpeechItem] {
        var blocks = 0
        return Array(items.prefix { item in
            defer { if !item.joined { blocks += 1 } }
            return blocks < count
        })
    }

    static func script(for markdown: String, style: SpeechStyle, pauseScale: Double) throws
        -> [SpeechItem] {
        var items: [SpeechItem] = []
        for block in try MarkdownBlocks.parse(markdown) {
            var spoken = SSMLBuilder.items(for: block, style: style)
            guard !spoken.isEmpty else {
                if case .divider = block.kind, !items.isEmpty {
                    items[items.count - 1].pause = max(items[items.count - 1].pause, block.pause * pauseScale)
                }
                continue
            }
            if block.isHeading, !items.isEmpty {
                items[items.count - 1].pause = max(items[items.count - 1].pause, block.pause * pauseScale)
            }
            spoken[spoken.count - 1].pause = block.pause * pauseScale
            items += spoken
        }
        return items
    }

    func run(markdown: String, output: URL, format: OutputFormat, voiceID: String,
             style: SpeechStyle, pauseScale: Double) {
        guard start() else { return }
        Task {
            do {
                try await convert(markdown, to: output, format: format, voiceID: voiceID,
                                  style: style, pauseScale: pauseScale) { i, n in
                    progress = Double(i - 1) / Double(n)
                    status = "Speaking part \(i) of \(n)"
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
        }
    }

    // MARK: Batch

    /// Files queued for a batch conversion, with their status.
    @Published var queue: [BatchItem] = []

    /// Converts every queued file, each saved in `folder` (or next to its source).
    /// A failing file is marked and the batch goes on with the next one.
    func runBatch(folder: URL?, format: OutputFormat, voiceID: String, style: SpeechStyle, pauseScale: Double) {
        guard !queue.isEmpty, start() else { return }
        for i in queue.indices { queue[i].reset() }
        Task {
            var used = Set<String>()
            let count = queue.count
            for i in queue.indices {
                if cancelled {
                    queue[i].state = .cancelled
                    continue
                }
                let source = queue[i].source
                let output = Batch.outputURL(for: source, folder: folder, ext: format.fileExtension, used: &used)
                queue[i].state = .running
                queue[i].activity = "Reading the text…"
                status = "File \(i + 1) of \(count) · \(source.lastPathComponent)"
                progress = Double(i) / Double(count)
                do {
                    let markdown = try TextFile.read(source)
                    try await convert(markdown, to: output, format: format, voiceID: voiceID,
                                      style: style, pauseScale: pauseScale) { b, n in
                        queue[i].progress = Double(b - 1) / Double(n)
                        queue[i].activity = "Speaking part \(b) of \(n) → \(output.lastPathComponent)"
                        progress = (Double(i) + queue[i].progress) / Double(count)
                    }
                    queue[i].state = .done(output)
                } catch is CancellationError {
                    queue[i].state = .cancelled
                } catch {
                    queue[i].state = .failed(error.localizedDescription)
                }
            }
            progress = 1
            status = cancelled ? "Cancelled" : Batch.summary(queue)
            isRunning = false
        }
    }

    // MARK: Shared

    private var cancelled = false

    private func start() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        cancelled = false
        progress = 0
        resultURL = nil
        errorMessage = nil
        status = "Preparing the text…"
        return true
    }

    private func convert(_ markdown: String, to output: URL, format: OutputFormat, voiceID: String,
                         style: SpeechStyle, pauseScale: Double,
                         onBlock: (_ index: Int, _ count: Int) -> Void) async throws {
        let items = try Self.script(for: markdown, style: style, pauseScale: pauseScale)
        guard !items.isEmpty else { throw SpeechError.noText }
        let writer = SpeechFileWriter()
        self.writer = writer
        defer { self.writer = nil }
        if cancelled { throw CancellationError() }
        try await writer.write(items, voiceID: voiceID, format: format, to: output) { onBlock($0, items.count) }
    }

    func cancel() {
        cancelled = true
        writer?.cancel()
    }
}

enum TextFile {
    /// Reads a text file as UTF-8, or in the encoding it declares or that can be detected.
    static func read(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, usedEncoding: &encoding)) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't read \(url.lastPathComponent) as text.",
        ])
    }
}
