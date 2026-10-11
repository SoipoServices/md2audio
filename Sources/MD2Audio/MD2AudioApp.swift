import AppKit
import SwiftUI

@main
struct MD2AudioApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("MD2Audio") {
            ContentView()
                .frame(minWidth: 900, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) { HelpMenuItem() }
        }

        Window("MD2Audio Help", id: HelpView.windowID) {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SPM executable (`swift run`) to get a proper window/Dock icon
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
