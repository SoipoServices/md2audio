import AppKit
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

/// How English words are read in a text of another language.
enum EnglishWords {
    /// By the main voice, as it reads them. `{en: …}` adds the pronunciation guide.
    case mainVoice
    /// Found automatically and read by the main voice with the pronunciation guide.
    case guide
    /// Found automatically and read by an English voice.
    case voice
}

/// English words written with the sounds every voice has, the way a speaker of Italian says them
/// ("deployment" -> diˈplɔiment). The system voices only have the sounds of their own language (English
/// ones are dropped from a <phoneme>), so this is how a voice is told to read an English word.
/// Built by Tools/make_english_dict.py from the CMU Pronouncing Dictionary.
enum EnglishPronunciation {
    static func ipa(for word: String) -> String? {
        table[word.lowercased()]
    }

    private static let table: [String: String] = {
        // In the app bundle, or SwiftPM's resource bundle with `swift run`
        guard let url = Bundle.main.url(forResource: "english", withExtension: "dict")
                ?? Bundle.module.url(forResource: "english", withExtension: "dict"),
              let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data,
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var table: [String: String] = [:]
        table.reserveCapacity(120_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            table[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return table
    }()
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
    /// Asides in parentheses read lower and quicker, the pitch drifts down along a paragraph,
    /// and longer sentences are followed by a longer breath.
    var naturalIntonation = true
    var english = EnglishWords.mainVoice
    /// The voice for a language code ("en", "fr-FR"…) used by {fr: …} spans and, with `.voice`, English
    /// words; nil = no voice for that language, the main voice reads it.
    var voiceForLanguage: (String) -> String? = { _ in nil }

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

/// One utterance for the synthesizer.
struct SpeechItem {
    var ssml: String
    /// Seconds of silence after it.
    var pause = 0.0
    /// Voice identifier; nil = the main voice.
    var voiceID: String?
    /// The next item continues the same sentence (another voice): no gap in between.
    var joined = false
}

/// Builds SSML for a block. Apple voices honor <break> and absolute <prosody rate/pitch/volume>
/// (nested prosody does not combine; <emphasis>, <sub> and <voice> are ignored and <lang> cuts the
/// utterance short), so every segment gets its own values and a span in another language becomes
/// an utterance of its own, spoken by a voice of that language.
@MainActor
enum SSMLBuilder {
    private static let emphasisOpen: Character = "\u{E000}"
    private static let emphasisClose: Character = "\u{E001}"
    /// One unit of pause inside a sentence; repeated for longer pauses.
    private static let pauseMark: Character = "\u{E002}"
    /// A trailing-thought pause after an ellipsis, always 500 ms.
    private static let ellipsisMark: Character = "\u{E003}"
    /// End of a language span. A span starts with U+E100 + the index of its language.
    private static let languageClose: Character = "\u{E006}"
    private static let sentenceEnd: Set<Character> = [".", "!", "?", ":", ";", "…"]

    private static func languageOpen(_ index: Int) -> Character {
        Character(Unicode.Scalar(UInt32(0xE100 + index))!)
    }

    private static func languageIndex(_ ch: Character) -> Int? {
        guard let v = ch.unicodeScalars.first?.value, (0xE100..<0xE200).contains(v) else { return nil }
        return Int(v - 0xE100)
    }

    private static func isMarker(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0xE000..<0xE200).contains(v)
    }

    /// The utterances for a block: one, or several when it has spans in other languages.
    /// Empty when there is nothing to read.
    static func items(for block: Block, style: SpeechStyle) -> [SpeechItem] {
        var text = block.segments.map { seg in
            style.emphasis && seg.emphasized
                ? "\(emphasisOpen)\(seg.text)\(emphasisClose)" : seg.text
        }.joined()
        // Index 0 = the main language, kept as it is (no detection)
        var languages = [""]
        text = shortenURLs(text)
        text = markLanguageSpans(text, &languages)
        text = text.replacingOccurrences(of: #"(\.\.\.|…)(?!\.)"#, with: "…" + String(ellipsisMark),
                                         options: .regularExpression)
        if style.punctuationPauseMs > 0 { text = markPauses(text) }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if style.stripEmoji { text = stripEmoji(text) }
        text = outsideLanguageSpans(text) { applyPronunciations($0, style.pronunciations) }
        if !style.language.hasPrefix("en"),
           style.english == .guide || (style.english == .voice && style.voiceForLanguage("en") != nil) {
            let english = languages.firstIndex(of: "en") ?? languages.count
            if english == languages.count { languages.append("en") }
            let detector = EnglishDetector(mainLanguage: style.language)
            text = outsideLanguageSpans(text) {
                detector.mark($0, open: languageOpen(english), close: languageClose)
            }
        }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        // A closing punctuation mark gives a proper falling intonation
        if let last = text.last(where: { !isMarker($0) && !$0.isWhitespace }), !sentenceEnd.contains(last) {
            text += "."
        }
        // Punctuation right after a span belongs to it, so that voice gets the intonation
        text = text.replacingOccurrences(of: "\(languageClose)([.,;:!?…]+)(?![\\p{L}\\p{N}])",
                                         with: "$1\(languageClose)", options: .regularExpression)

        var items: [SpeechItem] = []
        var body = ""
        var hasSpeech = false
        var voice: String?  // nil = main voice
        var inEmphasis = false
        var inAside = false
        /// In an English span read by the main voice with the pronunciation guide
        var inGuide = false

        /// A change of voice ends the utterance; the next one follows without a gap.
        func setVoice(_ new: String?) {
            guard new != voice else { return }
            if hasSpeech {
                items.append(SpeechItem(ssml: "<speak>\(body)</speak>", voiceID: voice, joined: true))
                body = ""
                hasSpeech = false
            }
            voice = new
        }

        let sentences = sentences(text, language: style.language)
        for (i, sentence) in sentences.enumerated() {
            if i > 0 && style.sentencePauseMs > 0 {
                // A longer sentence is followed by a longer breath
                let words = Double(sentences[i - 1].split(separator: " ").count)
                let breath = style.naturalIntonation ? min(max(0.8 + words / 40, 0.8), 1.4) : 1
                body += "<break time=\"\(Int(style.sentencePauseMs * breath))ms\"/>"
            }
            var rate = style.speed * (1 + jitter(style.variation))
            var pitch = style.pitch + jitter(style.variation) * 100
            if block.isHeading && style.headingStyle {
                rate *= 0.92
                pitch -= 4
            }
            if style.naturalIntonation, sentences.count > 1 {
                // The pitch drifts down along the paragraph and the last sentence slows down a little
                pitch += 2 - 4 * Double(i) / Double(sentences.count - 1)
                if i == sentences.count - 1 { rate *= 0.98 }
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
                var r = rate, p = pitch
                if inEmphasis { r *= 0.93; p += 6 }
                if inAside { r *= 1.05; p -= 4 }
                body += prosody(inGuide ? guided(segment) : escape(segment), rate: r, pitch: p, louder: inEmphasis)
                hasSpeech = true
            }
            for ch in sentence {
                if ch == pauseMark || ch == ellipsisMark {
                    flush()
                    pauseMs += ch == pauseMark ? style.punctuationPauseMs : 500
                } else if ch == emphasisOpen || ch == emphasisClose {
                    flush()
                    inEmphasis = ch == emphasisOpen
                } else if let index = languageIndex(ch) {
                    flush()
                    flushPause()
                    let language = languages[safe: index] ?? ""
                    let isMain = language.isEmpty || language.prefix(2) == style.language.prefix(2)
                    inGuide = !isMain && language.lowercased().hasPrefix("en") && style.english != .voice
                    setVoice(isMain || inGuide ? nil : style.voiceForLanguage(language))
                } else if ch == languageClose {
                    flush()
                    flushPause()
                    inGuide = false
                    setVoice(nil)
                } else if style.naturalIntonation, ch == "(" {
                    flush()
                    pauseMs += style.punctuationPauseMs
                    inAside = true
                    segment.append(ch)
                } else if inAside, ch == ")" {
                    segment.append(ch)
                    flush()
                    inAside = false
                    pauseMs += style.punctuationPauseMs
                } else {
                    if !ch.isWhitespace { flushPause() }  // adjacent pauses add up
                    segment.append(ch)
                }
            }
            flush()
            flushPause()
        }
        if hasSpeech {
            items.append(SpeechItem(ssml: "<speak>\(body)</speak>", voiceID: voice))
        } else if !items.isEmpty {
            items[items.count - 1].joined = false
        }
        return items
    }

    /// `{en: machine learning}` -> a span read by a voice of that language.
    /// `{it: …}` with the main language keeps the words in the main voice.
    private static func markLanguageSpans(_ text: String, _ languages: inout [String]) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{([A-Za-z]{2,3}(?:-[A-Za-z]{2})?):\s*([^{}]+)\}"#) else {
            return text
        }
        var result = text
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let code = Range(match.range(at: 1), in: result),
                  let content = Range(match.range(at: 2), in: result) else { continue }
            let language = String(result[code])
            let index = languages.firstIndex(of: language) ?? languages.count
            if index == languages.count { languages.append(language) }
            result.replaceSubrange(whole, with: "\(languageOpen(index))\(result[content])\(languageClose)")
        }
        return result
    }

    /// Applies `transform` to the text that is not inside a language span.
    private static func outsideLanguageSpans(_ text: String, _ transform: (String) -> String) -> String {
        var result = "", outside = "", inSpan = false
        for ch in text {
            if !inSpan, languageIndex(ch) != nil {
                result += transform(outside)
                outside = ""
                inSpan = true
            }
            if inSpan { result.append(ch) } else { outside.append(ch) }
            if ch == languageClose { inSpan = false }
        }
        return result + transform(outside)
    }

    /// A bare web address is read as its site name only, by the main voice:
    /// https://www.example.com/a?b=c -> example.com
    private static func shortenURLs(_ text: String) -> String {
        text.replacingOccurrences(of: #"https?://(?:www\.)?([^\s/?#]+[^\s/?#.,;:!)])\S*?(?=[.,;:!?)]*(?:\s|$))"#,
                                  with: "\(languageOpen(0))$1\(languageClose)", options: .regularExpression)
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

    /// English text for the main voice: every word in the dictionary gets its pronunciation.
    private static func guided(_ text: String) -> String {
        var result = "", word = ""
        func flushWord() {
            defer { word = "" }
            guard !word.isEmpty else { return }
            if let ipa = EnglishPronunciation.ipa(for: word) {
                result += "<phoneme alphabet=\"ipa\" ph=\"\(ipa)\">\(escape(word))</phoneme>"
            } else {
                result += escape(word)
            }
        }
        for ch in text {
            if ch.isLetter {
                word.append(ch)
            } else {
                flushWord()
                result += escape(String(ch))
            }
        }
        flushWord()
        return result
    }

    /// `xml` is the escaped text of the segment.
    private static func prosody(_ xml: String, rate: Double, pitch: Double, louder: Bool) -> String {
        let p = pitch.rounded()
        let pitchStr = String(format: "%+.0f%%", p == 0 ? 0 : p)  // avoid "-0%"
        let volume = louder ? " volume=\"+3dB\"" : ""
        return "<prosody rate=\"\(Int((rate * 100).rounded()))%\" pitch=\"\(pitchStr)\"\(volume)>"
            + xml + "</prosody>"
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

    /// The replacement is marked as main language, so it is not taken for an English word.
    private static func applyPronunciations(_ text: String, _ rules: [(find: String, replace: String)]) -> String {
        rules.reduce(text) { text, rule in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.find)
                + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
            return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: NSRegularExpression.escapedTemplate(
                                                   for: "\(languageOpen(0))\(rule.replace)\(languageClose)"))
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

/// Finds English words and phrases in a text of another language.
/// A word starts a span when it is clearly English: an English dictionary word that either is not in the
/// main language's dictionary or looks very English. Neighbours that look English enough join the span,
/// so "machine learning" or "state of the art" are read in one go. Words the main language shares with
/// English ("come", "more", "computer") stay in the main voice unless they are next to English words.
@MainActor
struct EnglishDetector {
    private struct Word { var isSeed = false, canJoin = false, canBridge = false }

    private static var cache: [String: Word] = [:]
    private static let recognizer = NLLanguageRecognizer()
    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}+"#)

    private let main: NLLanguage
    /// The main language's spelling dictionary, if installed.
    private let mainDictionary: String?
    /// Italian, Spanish and Portuguese words end in a vowel, most English loanwords do not.
    private let nativeWordsEndInVowel: Bool

    init(mainLanguage: String) {
        let code = String(mainLanguage.prefix(2))
        main = NLLanguage(code)
        nativeWordsEndInVowel = ["it", "es", "pt"].contains(code)
        let available = NSSpellChecker.shared.availableLanguages
        mainDictionary = available.first { $0 == code } ?? available.first { $0.hasPrefix(code) }
    }

    func mark(_ text: String, open: Character, close: Character) -> String {
        let ns = text as NSString
        let tokens = Self.wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !tokens.isEmpty else { return text }
        let words = tokens.map { classify(ns.substring(with: $0)) }
        /// Only spaces, hyphens or emphasis marks between two tokens
        func adjacent(_ i: Int, _ j: Int) -> Bool {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(tokens[i]),
                                                 length: tokens[j].location - NSMaxRange(tokens[i])))
            return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "-" || $0 == "\u{E000}" || $0 == "\u{E001}" }
        }

        var english = words.map(\.isSeed)
        guard english.contains(true) else { return text }
        var changed = true
        while changed {
            changed = false
            for i in words.indices where !english[i] {
                let before = i > 0 && english[i - 1] && adjacent(i - 1, i)
                let after = i + 1 < words.count && english[i + 1] && adjacent(i, i + 1)
                if (words[i].canJoin && (before || after)) || (words[i].canBridge && before && after) {
                    english[i] = true
                    changed = true
                }
            }
        }

        let result = NSMutableString(string: text)
        for i in words.indices.reversed() where english[i] {
            let endsSpan = !(i + 1 < words.count && english[i + 1] && adjacent(i, i + 1))
            let startsSpan = !(i > 0 && english[i - 1] && adjacent(i - 1, i))
            if endsSpan { result.insert(String(close), at: NSMaxRange(tokens[i])) }
            guard startsSpan else { continue }
            // An elided article goes with its word: "l'update", "dell'app"
            let elided = i > 0 && NSMaxRange(tokens[i - 1]) + 1 == tokens[i].location
                && "'’".contains(ns.substring(with: NSRange(location: tokens[i].location - 1, length: 1)))
            result.insert(String(open), at: tokens[elided ? i - 1 : i].location)
        }
        return result as String
    }

    private func classify(_ word: String) -> Word {
        let key = "\(main.rawValue) \(word)"
        if let cached = Self.cache[key] { return cached }
        var result = Word()
        defer { Self.cache[key] = result }
        // Acronyms (API, USA) are left to the main voice
        guard word.count >= 2, !(word.count <= 5 && word == word.uppercased()) else { return result }

        let recognizer = Self.recognizer
        recognizer.reset()
        recognizer.languageConstraints = [main, .english]
        recognizer.processString(word)
        let score = recognizer.languageHypotheses(withMaximum: 2)[.english] ?? 0
        guard score >= 0.3, isSpelled(word, in: "en") else { return result }

        // With no dictionary for the main language, every word may belong to it
        let inMain = mainDictionary.map { isSpelled(word, in: $0) } ?? true
        let looksNative = inMain && nativeWordsEndInVowel && "aeiouàèéìòù".contains(word.lowercased().last ?? " ")
        result.canBridge = score >= 0.4                                    // "work in progress"
        result.canJoin = word.count >= 3 && score >= (looksNative ? 0.6 : 0.35)  // "smart" next to "working"
        if word.count >= 3 {
            result.isSeed = !inMain ? score >= 0.5 : score >= 0.9 && !looksNative
        } else {
            result.isSeed = score >= 0.95 && !looksNative                  // "of"
        }
        return result
    }

    private func isSpelled(_ word: String, in language: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
