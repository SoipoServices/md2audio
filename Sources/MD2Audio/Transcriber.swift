import AVFoundation
import Foundation
import Speech

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case text = "Text", markdown = "Markdown", srt = "Subtitles (SRT)"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .srt: "srt"
        }
    }
}

/// One recognized stretch of speech, with word timings when available.
struct TranscriptSegment {
    struct Word { var text: String; var start: Double; var end: Double }
    var start: Double
    var end: Double
    var text: String
    var words: [Word]
}

/// Transcribes audio files on-device with SpeechAnalyzer (macOS 26+).
@available(macOS 26, *)
@MainActor
final class Transcriber: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var segments: [TranscriptSegment] = []
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    static func installedLocales() async -> Set<String> {
        Set(await SpeechTranscriber.installedLocales.map(\.identifier))
    }

    func run(url: URL, locale: Locale) {
        guard start() else { return }
        task = Task {
            do {
                let duration = try await transcribe(url, locale: locale) { self.status = $0 }
                progress = 1
                status = segments.isEmpty ? "No speech found" : "Done: \(Self.clock(duration)) of audio"
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

    /// Audio files queued for a batch transcription, with their status.
    @Published var queue: [BatchItem] = []

    /// Transcribes every queued file and saves each transcript in `folder` (or next to its audio).
    /// A failing file is marked and the batch goes on with the next one.
    func runBatch(locale: Locale, format: TranscriptFormat, timestamps: Bool, folder: URL?) {
        guard !queue.isEmpty, start() else { return }
        for i in queue.indices { queue[i].reset() }
        task = Task {
            var used = Set<String>()
            let count = queue.count
            for i in queue.indices {
                if Task.isCancelled {
                    queue[i].state = .cancelled
                    continue
                }
                let source = queue[i].source
                queue[i].state = .running
                status = "File \(i + 1) of \(count) · \(source.lastPathComponent)"
                progress = Double(i) / Double(count)
                do {
                    try await transcribe(source, locale: locale) { fileStatus in
                        self.queue[i].activity = fileStatus
                    } progress: { fileProgress in
                        self.queue[i].progress = fileProgress
                        self.progress = (Double(i) + fileProgress) / Double(count)
                    }
                    guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
                    let output = Batch.outputURL(for: source, folder: folder, ext: format.fileExtension, used: &used)
                    queue[i].activity = "Saving \(output.lastPathComponent)…"
                    let text = TranscriptFormatter.render(segments, format: format, timestamps: timestamps,
                                                          title: source.deletingPathExtension().lastPathComponent)
                    try text.write(to: output, atomically: true, encoding: .utf8)
                    queue[i].state = .done(output)
                } catch is CancellationError {
                    queue[i].state = .cancelled
                } catch {
                    queue[i].state = .failed(error.localizedDescription)
                }
            }
            progress = 1
            status = Task.isCancelled ? "Cancelled" : Batch.summary(queue)
            segments = []
            isRunning = false
        }
    }

    // MARK: Shared

    private func start() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        progress = 0
        segments = []
        errorMessage = nil
        return true
    }

    /// Transcribes one file into `segments`; returns the audio duration in seconds.
    @discardableResult
    private func transcribe(_ url: URL, locale: Locale, status report: @escaping (String) -> Void,
                            progress onProgress: ((Double) -> Void)? = nil) async throws -> Double {
        segments = []
        report("Opening the audio…")
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])

        // The language model is downloaded once, on first use
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            report("Downloading the \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) speech model…")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        defer { self.analyzer = nil }
        report("Starting the transcription…")
        let collector = Task {
            for try await result in transcriber.results {
                let segment = Self.segment(from: result)
                segments.append(segment)
                let fraction = duration > 0 ? min(segment.end / duration, 1) : 0
                if let onProgress { onProgress(fraction) } else { progress = fraction }
                report("Transcribing \(Self.clock(segment.end)) of \(Self.clock(duration))")
            }
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await collector.value
        try Task.checkCancellation()
        return duration
    }

    func cancel() {
        task?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private static func segment(from result: SpeechTranscriber.Result) -> TranscriptSegment {
        let text = result.text
        let words: [TranscriptSegment.Word] = text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            return .init(text: String(text[run.range].characters), start: range.start.seconds, end: range.end.seconds)
        }
        return TranscriptSegment(
            start: result.range.start.seconds, end: result.range.end.seconds,
            text: String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum TranscriptionError: LocalizedError {
    case noSpeech
    var errorDescription: String? { "No speech found" }
}

/// Turns transcript segments into text, Markdown or SRT subtitles.
enum TranscriptFormatter {
    static func render(_ segments: [TranscriptSegment], format: TranscriptFormat,
                       timestamps: Bool, title: String) -> String {
        switch format {
        case .text:
            return segments.map { stamp($0, timestamps, bold: false) + $0.text }.joined(separator: "\n\n")
        case .markdown:
            let body = segments.map { stamp($0, timestamps, bold: true) + $0.text }.joined(separator: "\n\n")
            return "# \(title)\n\n\(body)\n"
        case .srt:
            return cues(segments).enumerated().map { i, cue in
                "\(i + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(cue.text)\n"
            }.joined(separator: "\n")
        }
    }

    private static func stamp(_ s: TranscriptSegment, _ on: Bool, bold: Bool) -> String {
        guard on else { return "" }
        let t = "[\(clockWithHours(s.start))]"
        return bold ? "**\(t)** " : "\(t) "
    }

    /// Subtitle cues of at most ~84 characters / 6 seconds, ending early at sentence punctuation.
    private static func cues(_ segments: [TranscriptSegment]) -> [(start: Double, end: Double, text: String)] {
        var cues: [(start: Double, end: Double, text: String)] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                cues.append((segment.start, segment.end, segment.text))
                continue
            }
            var text = "", start = 0.0, end = 0.0
            func flush() {
                let line = text.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { cues.append((start, end, line)) }
                text = ""
            }
            for word in segment.words {
                if text.isEmpty {
                    start = word.start
                } else if (text + word.text).count > 84 || word.end - start > 6 {
                    flush()
                    start = word.start
                }
                text += word.text
                end = word.end
                if let last = text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last), text.count > 30 {
                    flush()
                }
            }
            flush()
        }
        return cues
    }

    private static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func clockWithHours(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
