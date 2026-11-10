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
    /// Audio of the utterance being spoken.
    private var chunks: [AVAudioPCMBuffer] = []
    /// Loudness of the main voice, to bring the other voices to the same level.
    private var mainLevel: Float?

    func write(_ items: [SpeechItem], voiceID: String, format: OutputFormat,
               to url: URL, onItem: (Int) -> Void) async throws {
        defer { file = nil }
        // Without this check an unknown id silently falls back to the system voice
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw SpeechError.voiceUnavailable }
        for (i, item) in items.enumerated() {
            if cancelled { throw CancellationError() }
            onItem(i + 1)
            guard let utterance = AVSpeechUtterance(ssmlRepresentation: item.ssml) else { continue }
            utterance.voice = item.voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? voice
            try await speak(utterance)
            defer { chunks = [] }
            guard let audio = PCM.merge(chunks) else { continue }
            // Voices end with ~0.2 s of silence: cut it where the sentence goes on in another voice
            if item.joined { PCM.trimTrailingSilence(audio, keeping: 0.03) }
            if item.voiceID == nil || item.voiceID == voiceID {
                mainLevel = PCM.level(audio) ?? mainLevel
            } else if let mainLevel, let level = PCM.level(audio) {
                PCM.scale(audio, by: mainLevel / level)
            }
            let file = try audioFile(for: audio.format, output: format, url: url)
            // Voices differ in sample rate; the file keeps the first one's
            try file.write(from: audio.format == file.processingFormat
                ? audio : PCM.convert(audio, to: file.processingFormat))
            try writeSilence(seconds: item.pause)
        }
        if file == nil { throw SpeechError.noAudio }
    }

    func cancel() {
        cancelled = true
        synthesizer.stopSpeaking(at: .immediate)
        finish(CancellationError())
    }

    private func speak(_ utterance: AVSpeechUtterance) async throws {
        chunks = []
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            synthesizer.write(utterance) { [weak self] buffer in
                MainActor.assumeIsolated {
                    guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 { return self.finish(nil) }  // empty buffer = end of utterance
                    // Copied: the synthesizer may reuse its buffers
                    if let copy = PCM.merge([pcm]) { self.chunks.append(copy) }
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

/// Helpers for PCM buffers.
enum PCM {
    /// One buffer with the frames of all the buffers that share the first one's format.
    static func merge(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let same = buffers.filter { $0.format == format }
        let total = same.reduce(0) { $0 + $1.frameLength }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for buffer in same {
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for ch in 0..<min(src.count, dst.count) {
                guard let from = src[ch].mData, let to = dst[ch].mData else { continue }
                memcpy(to + Int(out.frameLength) * bytesPerFrame, from, Int(buffer.frameLength) * bytesPerFrame)
            }
            out.frameLength += buffer.frameLength
        }
        return out
    }

    /// Drops the silent end of a buffer, keeping `seconds` of it.
    static func trimTrailingSilence(_ buffer: AVAudioPCMBuffer, keeping seconds: Double) {
        guard let data = buffer.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        guard let last = samples.lastIndex(where: { abs($0) > 0.003 }) else { return }
        let keep = last + 1 + Int(seconds * buffer.format.sampleRate)
        buffer.frameLength = AVAudioFrameCount(min(keep, Int(buffer.frameLength)))
    }

    /// RMS of the samples that are not silence.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData else { return nil }
        var sum: Float = 0, count = 0
        for sample in UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)) where abs(sample) > 0.003 {
            sum += sample * sample
            count += 1
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : nil
    }

    /// Changes the volume, by at most a factor of 2 and without clipping.
    static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard let data = buffer.floatChannelData else { return }
        for ch in 0..<Int(buffer.format.channelCount) {
            let samples = UnsafeMutableBufferPointer(start: data[ch], count: Int(buffer.frameLength))
            let peak = samples.reduce(0) { max($0, abs($1)) }
            let gain = min(max(gain, 0.5), 2, peak > 0 ? 0.98 / peak : 2)
            for i in samples.indices { samples[i] *= gain }
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 4096
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SpeechError.noAudio }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
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

    func speak(_ items: [SpeechItem], voiceID: String) {
        stop()
        let voice = AVSpeechSynthesisVoice(identifier: voiceID)
        for item in items {
            guard let u = AVSpeechUtterance(ssmlRepresentation: item.ssml) else { continue }
            u.voice = item.voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? voice
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

    /// The name without "(Enhanced)" and the like: the same speaker can exist in several languages.
    private var speaker: String {
        name.components(separatedBy: " (")[0]
    }

    /// The best voice for a language code ("en", "fr-FR"): the main voice's own speaker when it also
    /// speaks that language, otherwise the best quality, preferring the given region (US, then GB, for "en").
    static func best(for code: String, like main: AVSpeechSynthesisVoice?,
                     in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let code = code.replacingOccurrences(of: "_", with: "-")
        let prefix = code.prefix(2).lowercased()
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 10
            if let main, v.speaker == main.speaker { s += 100 }
            if v.language.lowercased() == code.lowercased() { s += 5 }
            if v.language == "en-US" { s += 2 } else if v.language == "en-GB" { s += 1 }
            return s
        }
        // `max` keeps the last of equals: reversed, so the first in the list wins
        return voices.filter { $0.language.lowercased().hasPrefix(prefix) }.reversed().max { score($0) < score($1) }
    }

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
