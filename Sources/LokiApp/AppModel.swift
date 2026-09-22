import AppKit
import Combine
import LokiCore
import Network
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: Configuration
    @Published private(set) var sessions: [TunnelSession] = []
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let store = ConfigurationStore()
    private var discoveryTasks: [String: Task<Void, Never>] = [:]
    private var subscriptions: [AnyCancellable] = []
    private let networkMonitor = NWPathMonitor()
    private var wasOffline = false
    private var sleeping = false
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init() {
        do { configuration = try store.load() }
        catch {
            configuration = Configuration(forwards: [])
            self.error = "Could not load configuration. \(error.localizedDescription)"
        }
        reconcile()
        if error == nil {
            do { try store.save(configuration) }
            catch { self.error = "Could not save configuration. \(error.localizedDescription)" }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.wake() } }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.sleep() } }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.wasOffline && !offline && !self.sleeping { self.reconnect() }
                self.wasOffline = offline
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "dev.liam.loki.network"))
    }

    var hosts: [String] { Set(configuration.forwards.map(\.host)).sorted() }
    var enabledCount: Int { configuration.forwards.filter(\.enabled).count }
    var connectedCount: Int { sessions.filter { $0.status.connection == .connected }.count }
    var needsAttention: Bool { sessions.contains { $0.status.needsAttention } }
    var symbol: String { needsAttention ? "network.badge.shield.half.filled" : "point.3.connected.trianglepath.dotted" }

    func save(_ forwards: [Forward]) {
        var updated = configuration
        updated.forwards = forwards
        commit(updated)
    }

    func upsert(_ forwards: [Forward], replacing id: UUID? = nil) throws {
        var updated = configuration
        updated.forwards.removeAll { $0.id == id }
        updated.forwards.append(contentsOf: forwards)
        try store.save(updated)
        configuration = updated
        reconcile()
    }

    func remove(_ id: UUID) { save(configuration.forwards.filter { $0.id != id }) }

    func toggle(_ session: TunnelSession) {
        let updated = configuration.forwards.map { item in
            var item = item
            if item.id == session.id { item.enabled.toggle() }
            return item
        }
        save(updated)
    }

    func setAllEnabled(_ enabled: Bool, host: String? = nil) {
        save(configuration.forwards.map { item in
            var item = item
            if host == nil || item.host == host { item.enabled = enabled }
            return item
        })
    }

    func reconnect(host: String? = nil) {
        for session in sessions where session.forward.enabled && (host == nil || session.forward.host == host) {
            session.restart()
        }
        refreshDiscovery()
    }

    func refreshDiscovery() {
        for task in discoveryTasks.values { task.cancel() }
        discoveryTasks.removeAll()
        startDiscovery()
    }

    func stopRemoteProcess(_ session: TunnelSession, force: Bool) {
        Task {
            await session.stopRemoteProcess(force: force)
            refreshDiscovery()
        }
    }

    func setNotifications(_ enabled: Bool) {
        Task {
            do {
                if enabled {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    guard granted else { error = "Enable Loki notifications in System Settings first."; return }
                }
                var updated = configuration
                updated.notifyOnOutage = enabled
                commit(updated)
            } catch { self.error = error.localizedDescription }
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = "Could not change launch at login. \(error.localizedDescription)" }
    }

    func shutdown() {
        for session in sessions { session.shutdown() }
        for task in discoveryTasks.values { task.cancel() }
        networkMonitor.cancel()
    }

    func stop() async {
        shutdown()
        for session in sessions { await session.stop() }
        for task in discoveryTasks.values { await task.value }
    }

    private func commit(_ updated: Configuration) {
        do {
            try store.save(updated)
            configuration = updated
            reconcile()
        } catch { self.error = error.localizedDescription }
    }

    private func reconcile() {
        let ids = Set(configuration.forwards.map(\.id))
        for session in sessions where !ids.contains(session.id) { session.shutdown() }
        sessions = configuration.forwards.map { forward in
            if let existing = sessions.first(where: { $0.id == forward.id }) {
                existing.update(forward)
                return existing
            }
            let session = TunnelSession(forward: forward)
            session.onOutage = { [weak self] forward, message in self?.notify(forward, message) }
            session.restart()
            return session
        }
        subscriptions = sessions.map { session in
            session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
        refreshDiscovery()
    }

    private func startDiscovery() {
        let activeHosts = Set(configuration.forwards.filter(\.enabled).map(\.host))
        for host in activeHosts {
            let ports = configuration.forwards.filter { $0.host == host && $0.enabled }.map(\.remotePort)
            discoveryTasks[host] = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let snapshot = try await Discovery.inspect(host: host, ports: ports)
                        try Task.checkCancellation()
                        guard let self else { return }
                        for session in self.sessions where session.forward.host == host && session.forward.enabled {
                            session.receiveMetadata(snapshot.ports[session.forward.remotePort] ?? [], at: Date())
                        }
                    } catch {
                        if Task.isCancelled { return }
                        guard let self else { return }
                        for session in self.sessions where session.forward.host == host && session.forward.enabled {
                            session.metadataFailed(error.localizedDescription)
                        }
                    }
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
        }
    }

    private func sleep() {
        sleeping = true
        for session in sessions { session.shutdown() }
        for task in discoveryTasks.values { task.cancel() }
    }

    private func wake() {
        sleeping = false
        reconnect()
    }

    private func notify(_ forward: Forward, _ message: String) {
        guard configuration.notifyOnOutage else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(forward.host) · port \(forward.localPort)"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: forward.id.uuidString, content: content, trigger: nil))
    }
}
