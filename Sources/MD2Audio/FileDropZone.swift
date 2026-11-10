import SwiftUI
import UniformTypeIdentifiers

/// Dashed area that accepts dropped files or folders, or opens a file picker on click.
/// Folders are searched (recursively) for files of the accepted types.
struct FileDropZone: View {
    let prompt: String
    let types: [UTType]
    let url: URL?
    /// Number of files queued for a batch; when above 0 it is shown instead of `url`.
    var batchCount = 0
    let onSelect: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                Image(systemName: batchCount > 0 ? "doc.on.doc" : url == nil ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 32))
                if batchCount > 0 {
                    Text("\(batchCount) file\(batchCount == 1 ? "" : "s") queued").font(.headline)
                    Text("Drop or click to add more").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(url?.lastPathComponent ?? prompt)
                        .font(.headline)
                    if let url {
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Select or drop several files (or a folder) to convert them all at once")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await provider.loadFileURL() { urls.append(url) }
                }
                deliver(urls)
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { deliver(panel.urls) }
    }

    private func deliver(_ urls: [URL]) {
        let files = urls.flatMap(expand)
        if !files.isEmpty { onSelect(files) }
    }

    /// A file of an accepted type, or the accepted files inside a folder (sorted by path).
    private func expand(_ url: URL) -> [URL] {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { return accepts(url) ? [url] : [] }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (items?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && accepts($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        // Plain text only by exact match: source code etc. also conforms to it, and a folder may hold plenty
        return types.contains { type == $0 || ($0 != .plainText && type.conforms(to: $0)) }
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}
