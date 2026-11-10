import AppKit
import SwiftUI

/// One file in a batch conversion, with its progress.
struct BatchItem: Identifiable, Equatable {
    enum State: Equatable {
        case pending, running, done(URL), failed(String), cancelled
    }

    let id = UUID()
    let source: URL
    var state: State = .pending
}

enum Batch {
    /// Adds the URLs not already in the queue, keeping the order.
    static func append(_ urls: [URL], to queue: inout [BatchItem]) {
        var seen = Set(queue.map(\.source.standardizedFileURL))
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            queue.append(BatchItem(source: url))
        }
    }

    /// The output file for `source`: same name with `ext`, in `folder` or next to the source.
    /// Names already used in this batch (e.g. two `README.md` from different folders) get " 2", " 3"…
    static func outputURL(for source: URL, folder: URL?, ext: String, used: inout Set<String>) -> URL {
        let dir = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var name = base, n = 2
        while !used.insert(dir.appending(path: "\(name).\(ext)").standardizedFileURL.path).inserted {
            name = "\(base) \(n)"
            n += 1
        }
        return dir.appending(path: "\(name).\(ext)")
    }

    static func chooseFolder(startingAt dir: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = dir
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func summary(_ queue: [BatchItem]) -> String {
        let done = queue.filter { if case .done = $0.state { true } else { false } }.count
        let failed = queue.filter { if case .failed = $0.state { true } else { false } }.count
        return failed == 0 ? "Done: \(done) of \(queue.count) files" : "Done: \(done) of \(queue.count) files, \(failed) failed"
    }
}

/// The list of queued files, with per-file status.
struct BatchListView: View {
    @Binding var queue: [BatchItem]
    let isRunning: Bool

    var body: some View {
        List {
            ForEach(queue) { item in
                HStack(spacing: 8) {
                    icon(for: item.state).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.source.lastPathComponent).lineLimit(1)
                        Text(detail(for: item))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if case .done(let url) = item.state {
                        Button("Show in Finder", systemImage: "magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    if !isRunning {
                        Button("Remove", systemImage: "minus.circle") {
                            queue.removeAll { $0.id == item.id }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    @ViewBuilder private func icon(for state: BatchItem.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func detail(for item: BatchItem) -> String {
        switch item.state {
        case .done(let url): "→ \(url.lastPathComponent)"
        case .failed(let message): message
        case .cancelled: "Cancelled"
        default: item.source.deletingLastPathComponent().path
        }
    }
}
