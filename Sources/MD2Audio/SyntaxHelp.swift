import SwiftUI

/// Popover listing the Markdown syntax that changes how the text is read.
struct SyntaxHelp: View {
    let punctuationPauseMs: Double
    let blockPauseScale: Double

    @State private var copied = false

    private var rows: [(syntax: String, effect: String)] {
        let unit = Int(punctuationPauseMs)
        func block(_ s: Double) -> String { String(format: "%.1f s", s * blockPauseScale) }
        return [
            ("# Heading", "Read slower and lower, with a pause before and after (\(block(1.0)))"),
            ("**bold**  *italic*", "Stressed: a bit slower, higher and louder"),
            ("*** or --- on its own line", "Section break: \(block(2.0)) pause"),
            ("blank line", "New paragraph: \(block(0.5)) pause"),
            ("- item  1. item", "List item: \(block(0.3)) pause"),
            ("...  or  …", "Trailing thought: 500 ms pause"),
            (",", unit > 0 ? "\(unit) ms pause" : "Normal comma (punctuation pauses are off)"),
            ("; and :", unit > 0 ? "\(unit * 2) ms pause" : "Normal punctuation"),
            ("word - word  –  —", unit > 0 ? "\(unit * 2) ms pause, never read as \"minus\"" : "Read as a comma"),
            ("extra   spaces", unit > 0 ? "\(unit) ms per extra space (up to 6)" : "Ignored"),
            ("[text](link)", "Only the text is read"),
            ("`code`, code blocks, images, tables", "Skipped"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Markdown syntax").font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy Table", systemImage: copied ? "checkmark" : "doc.on.doc",
                       action: copyTable)
                    .controlSize(.small)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.syntax) { row in
                    GridRow {
                        Text(row.syntax).font(.system(.body, design: .monospaced))
                        Text(row.effect).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Durations follow the current settings: Pause at commas and dashes, and Pause between blocks. 3,5 · 10:30 · e-mail · -5 are read normally.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
        .padding(16)
        .frame(width: 520)
    }

    /// The table as tab-separated lines: pastes as text or into a spreadsheet.
    private func copyTable() {
        let text = rows.map { "\($0.syntax)\t\($0.effect)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Help window opened from the Help menu, using the current pause settings.
struct HelpView: View {
    static let windowID = "help"

    @AppStorage("punctuationPause") private var punctuationPause = 150.0
    @AppStorage("pause") private var pause = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Text → Audio").font(.headline)
                Text("Drop a Markdown file, or type or paste text in the editor. Choose a language and voice, adjust the reading, then click Convert (⌘↩). Preview reads the first blocks with the current settings.")
                Text("Audio → Text").font(.headline).padding(.top, 6)
                Text("Drop an audio file, choose the language and format, and transcribe it on device (macOS 26 or later).")
            }
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .top], 16)
            SyntaxHelp(punctuationPauseMs: punctuationPause, blockPauseScale: pause)
        }
        .frame(width: 520)
    }
}

/// Help › MD2Audio Help (⌘?) opens the help window instead of the "Help isn't available" alert.
struct HelpMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MD2Audio Help") { openWindow(id: HelpView.windowID) }
            .keyboardShortcut("?", modifiers: .command)
    }
}
