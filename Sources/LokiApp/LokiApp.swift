import AppKit
import Combine
import LokiCore
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--diagnose") {
            await Diagnostics.run()
        } else {
            LokiApp.main()
        }
    }
}

struct LokiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private var dashboardWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(showDashboard)
        updateStatusItem()
        statusSubscription = Self.model?.objectWillChange.sink { [weak self] in
            // Read published values after the model has applied the change.
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }
        showDashboard()
    }

    private func updateStatusItem() {
        guard let model = Self.model, let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: model.needsAttention ? "exclamationmark.circle" : "arrow.left.arrow.right",
            accessibilityDescription: "Loki, \(model.connectedCount) forwards connected"
        )
        button.image?.isTemplate = true
        button.setAccessibilityLabel("Loki, \(model.connectedCount) forwards connected")
    }

    @objc func showDashboard() {
        if dashboardWindow == nil, let model = Self.model {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 370),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Loki"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: DashboardView(model: model))
            window.center()
            window.setFrameAutosaveName("LokiDashboard")
            window.isReleasedWhenClosed = false
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Forwarding continues when the dashboard is closed.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task {
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
private enum Diagnostics {
    static func run() async {
        func argument(_ name: String, default fallback: String) -> String {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return fallback }
            return CommandLine.arguments[index + 1]
        }
        let forward = Forward(host: argument("--host", default: "tinytroid"),
                              localPort: Int(argument("--local-port", default: "3010")) ?? 3010,
                              remotePort: Int(argument("--remote-port", default: "3010")) ?? 3010)
        let duration = Double(argument("--duration", default: "25")) ?? 25
        let session = TunnelSession(forward: forward)
        session.restart()
        let discovery = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await Discovery.inspect(host: forward.host, ports: [forward.remotePort])
                    try Task.checkCancellation()
                    session.receiveMetadata(snapshot.ports[forward.remotePort] ?? [], at: Date())
                } catch {
                    if Task.isCancelled { return }
                    session.metadataFailed(error.localizedDescription)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        let deadline = Date().addingTimeInterval(duration)
        var lastLine = ""
        while Date() < deadline {
            let status = session.status
            let line = "\(status.title) | sshPID=\(status.sshPID.map(String.init) ?? "none") | project=\(status.processes.first?.projectName ?? "unknown") | branch=\(status.processes.first?.branch ?? "unknown") | error=\(status.lastError ?? "none") | metadataError=\(status.metadataError ?? "none")"
            if line != lastLine { FileHandle.standardOutput.write(Data((line + "\n").utf8)); lastLine = line }
            try? await Task.sleep(for: .milliseconds(250))
        }
        discovery.cancel()
        await discovery.value
        await session.stop()
        for event in session.status.events { print("Event: \(event.message)") }
        print("Stopped. Loki's test forward has been released.")
    }
}
