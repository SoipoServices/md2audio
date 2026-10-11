import Foundation
import NaturalLanguage

/// A readable block of the Markdown document.
struct Block {
    enum Kind { case heading(Int), paragraph, listItem, quote, divider }
    struct Segment { var text: String; var emphasized: Bool }

    var kind: Kind
    var segments: [Segment]

    /// Seconds of silence after the block (scaled by the pause setting).
    var pause: Double {
        switch kind {
        case .heading(let level): [1.0, 0.9, 0.8][safe: level - 1] ?? 0.7
        case .listItem: 0.3
        case .paragraph, .quote: 0.5
        case .divider: 2.0  // *** or --- marks a section break
        }
    }

    var isHeading: Bool { if case .heading = kind { true } else { false } }
}

/// Markdown -> blocks: code, images and tables are dropped, links are read as text,
/// dividers become silent blocks.
enum MarkdownBlocks {
    static func parse(_ markdown: String) throws -> [Block] {
        let attributed = try AttributedString(
            markdown: markdown,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible))

        var blocks: [Block] = []
        var currentID: Int?
        for run in attributed.runs {
            guard let intent = run.presentationIntent,
                  let innermost = intent.components.first else { continue }
            let kinds = intent.components.map(\.kind)
            let inline = run.inlinePresentationIntent ?? []
            if kinds.contains(where: isSkipped) || inline.contains(.code) || run.imageURL != nil {
                continue
            }
            if innermost.identity != currentID {
                currentID = innermost.identity
                blocks.append(Block(kind: kind(for: kinds), segments: []))
            }
            let emphasized = inline.contains(.stronglyEmphasized) || inline.contains(.emphasized)
            blocks[blocks.count - 1].segments.append(
                .init(text: String(attributed[run.range].characters), emphasized: emphasized))
        }
        return blocks
    }

    private static func isSkipped(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .codeBlock, .table: true
        default: false
        }
    }

    private static func kind(for kinds: [PresentationIntent.Kind]) -> Block.Kind {
        for kind in kinds {
            switch kind {
            case .header(let level): return .heading(level)
            case .thematicBreak: return .divider
            case .listItem: return .listItem
            case .blockQuote: return .quote
            default: continue
            }
        }
        return .paragraph
    }
}

/// Voice settings that shape how the text is spoken.
struct SpeechStyle {
    var speed = 1.0             // 1.0 = voice default
    var pitch = 0.0             // percent, -30...+30
    var sentencePauseMs = 250.0 // extra silence between sentences
    var punctuationPauseMs = 150.0 // extra silence at commas; dashes, ; and : get twice as much
    var variation = 2.0         // max random rate/pitch change per sentence, percent
    var headingStyle = true     // headings slightly slower and lower
    var emphasis = true         // bold/italic slightly slower, higher and louder
    var stripEmoji = true
    var pronunciations: [(find: String, replace: String)] = []
    var language = "it-IT"

    /// "find = replace" lines; blank lines and lines starting with # are ignored.
    static func parsePronunciations(_ text: String) -> [(find: String, replace: String)] {
        text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let find = line[..<eq].trimmingCharacters(in: .whitespaces)
            let replace = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return find.isEmpty ? nil : (find, replace)
        }
    }
}

/// Builds SSML for a block. Apple voices honor <break> and absolute <prosody rate/pitch/volume>
/// (nested prosody does not combine and <emphasis> is ignored), so every segment gets its own values.
enum SSMLBuilder {
    private static let emphasisOpen: Character = "\u{E000}"
    private static let emphasisClose: Character = "\u{E001}"
    /// One unit of pause inside a sentence; repeated for longer pauses.
    private static let pauseMark: Character = "\u{E002}"
    /// A trailing-thought pause after an ellipsis, always 500 ms.
    private static let ellipsisMark: Character = "\u{E003}"
    private static let markers: Set<Character> = [emphasisOpen, emphasisClose, pauseMark, ellipsisMark]
    private static let sentenceEnd: Set<Character> = [".", "!", "?", ":", ";", "…"]

    static func ssml(for block: Block, style: SpeechStyle) -> String? {
        var text = block.segments.map { seg in
            style.emphasis && seg.emphasized
                ? "\(emphasisOpen)\(seg.text)\(emphasisClose)" : seg.text
        }.joined()
        text = text.replacingOccurrences(of: #"(\.\.\.|…)(?!\.)"#, with: "…" + String(ellipsisMark),
                                         options: .regularExpression)
        if style.punctuationPauseMs > 0 { text = markPauses(text) }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if style.stripEmoji { text = stripEmoji(text) }
        text = applyPronunciations(text, style.pronunciations)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // A closing punctuation mark gives a proper falling intonation
        if let last = text.last(where: { !markers.contains($0) && !$0.isWhitespace }),
           !sentenceEnd.contains(last) {
            text += "."
        }

        var body = ""
        var inEmphasis = false
        for (i, sentence) in sentences(text, language: style.language).enumerated() {
            if i > 0 && style.sentencePauseMs > 0 {
                body += "<break time=\"\(Int(style.sentencePauseMs))ms\"/>"
            }
            var rate = style.speed * (1 + jitter(style.variation))
            var pitch = style.pitch + jitter(style.variation) * 100
            if block.isHeading && style.headingStyle {
                rate *= 0.92
                pitch -= 4
            }
            var segment = ""
            var pauseMs = 0.0
            func flushPause() {
                defer { pauseMs = 0 }
                guard pauseMs > 0 else { return }
                body += "<break time=\"\(Int(pauseMs))ms\"/>"
            }
            func flush() {
                defer { segment = "" }
                guard segment.contains(where: { !$0.isWhitespace }) else { return }
                // Punctuation alone needs no prosody of its own
                guard segment.contains(where: { $0.isLetter || $0.isNumber }) else { return body += escape(segment) }
                body += prosody(segment, rate: inEmphasis ? rate * 0.93 : rate,
                                pitch: inEmphasis ? pitch + 6 : pitch, louder: inEmphasis)
            }
            for ch in sentence {
                if ch == pauseMark || ch == ellipsisMark {
                    flush()
                    pauseMs += ch == pauseMark ? style.punctuationPauseMs : 500
                } else if ch == emphasisOpen || ch == emphasisClose {
                    flush()
                    inEmphasis = ch == emphasisOpen
                } else {
                    if !ch.isWhitespace { flushPause() }  // adjacent pauses add up
                    segment.append(ch)
                }
            }
            flush()
            flushPause()
        }
        return "<speak>\(body)</speak>"
    }

    /// Pauses inside a sentence: commas (1 unit), ; and : (2), spaced or em dashes (2, read as a comma
    /// instead of "minus"), and runs of extra spaces (1 per extra space, up to 6).
    /// Numbers like 3,5 or 10:30 and hyphenated words like e-mail are left alone.
    private static func markPauses(_ text: String) -> String {
        let unit = String(pauseMark)
        let rules: [(pattern: String, template: String)] = [
            (#"\s*(?:—|–|--|(?<=\s)-(?=\s))\s*"#, "," + unit + unit + " "),
            (#"([;:])(?=\s)"#, "$1" + unit + unit),
            (#",(?=\s)"#, "," + unit),
        ]
        var text = rules.reduce(text) { text, rule in
            text.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
        // Extra spaces: the first one is a normal space, every other adds a unit
        while let r = text.range(of: #"[ \t]{2,}"#, options: .regularExpression) {
            let extra = min(text.distance(from: r.lowerBound, to: r.upperBound) - 1, 6)
            text.replaceSubrange(r, with: " " + String(repeating: pauseMark, count: extra))
        }
        return text
    }

    private static func prosody(_ text: String, rate: Double, pitch: Double, louder: Bool) -> String {
        let p = pitch.rounded()
        let pitchStr = String(format: "%+.0f%%", p == 0 ? 0 : p)  // avoid "-0%"
        let volume = louder ? " volume=\"+3dB\"" : ""
        return "<prosody rate=\"\(Int((rate * 100).rounded()))%\" pitch=\"\(pitchStr)\"\(volume)>"
            + escape(text) + "</prosody>"
    }

    private static func jitter(_ percent: Double) -> Double {
        percent > 0 ? Double.random(in: -percent...percent) / 100 : 0
    }

    private static func sentences(_ text: String, language: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(String(language.prefix(2))))
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]))
            return true
        }
        return result.isEmpty ? [text] : result
    }

    private static func stripEmoji(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { s in
            let p = s.properties
            // Digits, # and * count as emoji too; only drop real pictographs and their joiners
            let pictograph = p.isEmojiPresentation || (p.isEmoji && s.value > 0x238C)
            return !pictograph && s.value != 0x200D && s.value != 0xFE0F && s.value != 0x20E3
        }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .replacingOccurrences(of: #" ([.,;:!?…])"#, with: "$1", options: .regularExpression)
    }

    private static func applyPronunciations(_ text: String, _ rules: [(find: String, replace: String)]) -> String {
        rules.reduce(text) { text, rule in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.find)
                + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
            return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: rule.replace))
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
