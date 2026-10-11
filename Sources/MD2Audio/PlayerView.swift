import AVFoundation
import SwiftUI

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            timer?.invalidate()
        } else {
            player.play()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        isPlaying = player.isPlaying
    }

    func seek(to t: TimeInterval) {
        player?.currentTime = t
        currentTime = t
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
            self.currentTime = 0
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}

struct PlayerView: View {
    let url: URL
    @StateObject private var player = AudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Save As…", action: saveAs)
            }
            HStack {
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
                Slider(value: Binding(get: { player.currentTime }, set: player.seek),
                       in: 0...max(player.duration, 0.1))
                Text("\(format(player.currentTime)) / \(format(player.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { player.load(url) }
        .onChange(of: url) { _, new in player.load(new) }
        .onDisappear { player.stop() }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
