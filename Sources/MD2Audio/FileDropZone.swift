import SwiftUI
import UniformTypeIdentifiers

/// Dashed area that accepts a dropped file or opens a file picker on click.
struct FileDropZone: View {
    let prompt: String
    let types: [UTType]
    let url: URL?
    let onSelect: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                Image(systemName: url == nil ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 32))
                Text(url?.lastPathComponent ?? prompt)
                    .font(.headline)
                if let url {
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in onSelect(url) } }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { onSelect(url) }
    }
}
