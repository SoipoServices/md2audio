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
        .fileDrop(types: types, isTargeted: $isTargeted, onSelect: onSelect)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { deliver(panel.urls) }
    }

    private func deliver(_ urls: [URL]) {
        let files = FileDrop.expand(urls, types: types)
        if !files.isEmpty { onSelect(files) }
    }
}

extension View {
    /// Accepts dropped files and folders of the given types, anywhere on the view.
    func fileDrop(types: [UTType], isTargeted: Binding<Bool>? = nil,
                  onSelect: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            FileDrop.load(providers) { urls in
                let files = FileDrop.expand(urls, types: types)
                if !files.isEmpty { onSelect(files) }
            }
            return true
        }
    }
}

enum FileDrop {
    /// The URLs of the dropped items, in the order they were dropped.
    /// Every load must start before the drop handler returns: afterwards the dragged items are gone.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL?]
            init(count: Int) { urls = Array(repeating: nil, count: count) }
        }
        let box = Box(count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.lock.withLock { box.urls[i] = url }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(box.urls.compactMap { $0 }) }
        }
    }

    /// Files chosen one by one are taken when they are of an accepted kind (any text file for plain text);
    /// a folder gives the files inside it, subfolders included, sorted by path.
    static func expand(_ urls: [URL], types: [UTType]) -> [URL] {
        urls.flatMap { url -> [URL] in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return accepts(url, types, strict: false) ? [url] : [] }
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return (items?.allObjects as? [URL] ?? [])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                        && accepts($0, types, strict: true)
                }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// Strict (inside folders): plain text only by exact match, because source code and the like
    /// conform to it too and a folder may hold plenty.
    private static func accepts(_ url: URL, _ types: [UTType], strict: Bool) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            // No or unknown extension: fine for a file picked on purpose where text is accepted
            return !strict && types.contains(.plainText)
        }
        return types.contains { type == $0 || ((!strict || $0 != .plainText) && type.conforms(to: $0)) }
    }
}
