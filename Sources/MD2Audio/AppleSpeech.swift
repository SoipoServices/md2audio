import AVFoundation
import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case wav = "WAV", m4a = "M4A"
    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

/// Speaks SSML utterances with AVSpeechSynthesizer and writes them, with pauses, to a WAV or M4A file.
@MainActor
final class SpeechFileWriter {
    private let synthesizer = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func write(_ items: [(ssml: String, pause: Double)], voiceID: String, format: OutputFormat,
               to url: URL, onItem: (Int) -> Void) async throws {
        defer { file = nil }
        // Without this check an unknown id silently falls back to the system voice
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw SpeechError.voiceUnavailable }
        for (i, item) in items.enumerated() {
            if cancelled { throw CancellationError() }
            onItem(i + 1)
            guard let utterance = AVSpeechUtterance(ssmlRepresentation: item.ssml) else { continue }
            utterance.voice = voice
            try await speak(utterance, format: format, to: url)
            try writeSilence(seconds: item.pause)
        }
        if file == nil { throw SpeechError.noAudio }
    }

    func cancel() {
        cancelled = true
        synthesizer.stopSpeaking(at: .immediate)
        finish(CancellationError())
    }

    private func speak(_ utterance: AVSpeechUtterance, format: OutputFormat, to url: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            synthesizer.write(utterance) { [weak self] buffer in
                MainActor.assumeIsolated {
                    guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 { return self.finish(nil) }  // empty buffer = end of utterance
                    do {
                        try self.audioFile(for: pcm.format, output: format, url: url).write(from: pcm)
                    } catch {
                        self.synthesizer.stopSpeaking(at: .immediate)
                        self.finish(error)
                    }
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func audioFile(for pcm: AVAudioFormat, output: OutputFormat, url: URL) throws -> AVAudioFile {
        if let file { return file }
        var settings: [String: Any] = [
            AVSampleRateKey: pcm.sampleRate,
            AVNumberOfChannelsKey: pcm.channelCount,
        ]
        switch output {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 64_000
        }
        try? FileManager.default.removeItem(at: url)
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: pcm.commonFormat, interleaved: pcm.isInterleaved)
        file = f
        return f
    }

    private func writeSilence(seconds: Double) throws {
        guard let file, seconds > 0 else { return }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames  // new buffers are zero-filled
        try file.write(from: silence)
    }
}

/// Plays SSML utterances through the speakers to try out settings.
@MainActor
final class SpeechPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    /// Utterances still queued; `synthesizer.isSpeaking` is unreliable inside the delegate callbacks.
    private var pending: [AVSpeechUtterance] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ items: [(ssml: String, pause: Double)], voiceID: String) {
        stop()
        let voice = AVSpeechSynthesisVoice(identifier: voiceID)
        for item in items {
            guard let u = AVSpeechUtterance(ssmlRepresentation: item.ssml) else { continue }
            u.voice = voice
            u.postUtteranceDelay = item.pause
            pending.append(u)
            synthesizer.speak(u)
        }
        isSpeaking = !pending.isEmpty
    }

    func stop() {
        pending.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let ended = Ended(utterance: u)
        Task { @MainActor in self.done(ended.utterance) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let ended = Ended(utterance: u)
        Task { @MainActor in self.done(ended.utterance) }
    }

    private func done(_ utterance: AVSpeechUtterance) {
        pending.removeAll { $0 === utterance }
        if pending.isEmpty { isSpeaking = false }
    }

    /// Carries the utterance from the synthesizer's queue to the main actor.
    private struct Ended: @unchecked Sendable { let utterance: AVSpeechUtterance }
}

enum SpeechError: LocalizedError {
    case noAudio, noText, voiceUnavailable
    var errorDescription: String? {
        switch self {
        case .noAudio: "The voice produced no audio. Try another voice."
        case .noText: "No readable text found in the Markdown file."
        case .voiceUnavailable: "The selected voice is not available. Pick another voice."
        }
    }
}

extension AVSpeechSynthesisVoice {
    /// Installed system voices, best quality first. Novelty and Personal voices are left out.
    static func readingVoices() -> [AVSpeechSynthesisVoice] {
        speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.language, rank($0), $0.name) < ($1.language, rank($1), $1.name) }
    }

    /// Premium first, then Enhanced, then compact.
    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        -v.quality.rawValue
    }

    var isHighQuality: Bool { quality != .default }

    /// Some names already carry "(Enhanced)".
    var displayName: String {
        if name.contains("(") { return name }
        switch quality {
        case .premium: return "\(name) (Premium)"
        case .enhanced: return "\(name) (Enhanced)"
        default: return name
        }
    }
}
