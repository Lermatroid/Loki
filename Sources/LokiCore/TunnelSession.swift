import Combine
import Foundation

@MainActor
public final class TunnelSession: ObservableObject, Identifiable {
    @Published public private(set) var forward: Forward
    @Published public private(set) var status = ForwardStatus()
    @Published public private(set) var isStoppingRemoteProcess = false
    @Published public private(set) var canForceStopRemoteProcess = false
    public nonisolated let id: UUID
    private var task: Task<Void, Never>?
    private var command: Subprocess?
    private var hasConnected = false
    private var outageStarted: Date?
    private var notified = false
    private var forceStopTargets: [RemoteProcessControl.Target] = []
    public var onOutage: ((Forward, String) -> Void)?

    public init(forward: Forward) { self.forward = forward; self.id = forward.id }

    public func update(_ forward: Forward) {
        guard self.forward != forward else { return }
        if self.forward.host != forward.host || self.forward.remotePort != forward.remotePort {
            status.processes = []
            status.metadataCheckedAt = nil
            status.metadataError = nil
            forceStopTargets = []
            canForceStopRemoteProcess = false
        }
        self.forward = forward
        restart()
    }

    public func restart() {
        let previous = task
        previous?.cancel()
        command?.terminate()
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            self.status.connection = self.forward.enabled ? .connecting : .paused
            self.status.service = .unchecked
            self.status.lastError = nil
            self.outageStarted = nil
            self.notified = false
            if self.forward.enabled { await self.run() }
        }
    }

    public func shutdown() {
        task?.cancel()
        command?.terminate()
    }

    public func stop() async {
        shutdown()
        await task?.value
        status.connection = .paused
    }

    public func receiveMetadata(_ processes: [RemoteProcess], at date: Date) {
        status.processes = processes
        status.metadataCheckedAt = date
        status.metadataError = nil
    }

    public func metadataFailed(_ message: String) { status.metadataError = message }

    public func stopRemoteProcess(force: Bool = false) async {
        guard !isStoppingRemoteProcess, !force || canForceStopRemoteProcess else { return }
        let targetForward = forward
        let targets = force ? forceStopTargets : nil
        isStoppingRemoteProcess = true
        if !force {
            forceStopTargets = []
            canForceStopRemoteProcess = false
        }
        defer { isStoppingRemoteProcess = false }
        do {
            let result = try await RemoteProcessControl.stop(targetForward, forceTargets: targets)
            guard forward.host == targetForward.host, forward.remotePort == targetForward.remotePort else { return }
            forceStopTargets = result.remaining
            canForceStopRemoteProcess = !result.remaining.isEmpty
            var refreshedProcesses: [RemoteProcess]?
            do {
                let snapshot = try await Discovery.inspect(host: targetForward.host, ports: [targetForward.remotePort])
                guard forward.host == targetForward.host, forward.remotePort == targetForward.remotePort else { return }
                let processes = snapshot.ports[targetForward.remotePort] ?? []
                receiveMetadata(processes, at: Date())
                refreshedProcesses = processes
                forceStopTargets.removeAll { target in !processes.contains { $0.pid == target.pid } }
                canForceStopRemoteProcess = !forceStopTargets.isEmpty
                if processes.isEmpty && status.connection == .connected {
                    status.service = .waiting
                    status.lastError = nil
                }
            } catch {
                guard forward.host == targetForward.host, forward.remotePort == targetForward.remotePort else { return }
                metadataFailed(error.localizedDescription)
            }
            let message: String
            if canForceStopRemoteProcess {
                message = force
                    ? "The remote process is still listening on port \(forward.remotePort) after force stop."
                    : "The remote process is still listening on port \(forward.remotePort). You can force stop it."
            } else if result.signalledCount == 0 {
                message = force
                    ? "The original process is no longer listening on port \(forward.remotePort)."
                    : "No remote process is listening on port \(forward.remotePort)."
            } else {
                let outcome = "\(force ? "Force stopped" : "Stopped") the remote \(result.signalledCount == 1 ? "process" : "processes") on port \(forward.remotePort)."
                if let processes = refreshedProcesses, !processes.isEmpty {
                    message = "\(outcome) A process is already listening on this port again. The server may have restarted automatically."
                } else {
                    message = "\(outcome) The forward \(forward.enabled ? "is ready" : "is still paused") when you restart the server."
                }
            }
            record(message)
        } catch {
            guard forward.host == targetForward.host, forward.remotePort == targetForward.remotePort else { return }
            let message = "Could not \(force ? "force stop" : "stop") the remote process. \(error.localizedDescription)"
            record(message)
        }
    }

    private func record(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if status.events.last?.message != message {
            status.events.append(StatusEvent(message: message))
            if status.events.count > 30 { status.events.removeFirst() }
        }
    }

    private func checkOutage(_ message: String) {
        guard hasConnected else { return }
        if outageStarted == nil { outageStarted = Date() }
        if !notified, let start = outageStarted, Date().timeIntervalSince(start) >= 30 {
            notified = true
            onOutage?(forward, message)
        }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                status.connection = .connecting
                status.service = .unchecked
                let listeners = try await Discovery.localListeners(port: forward.localPort)
                try Task.checkCancellation()
                if let owner = listeners.first {
                    let message = "Local port \(forward.localPort) is used by \(owner.command) (PID \(owner.pid)). Choose another local port or pause its existing forward."
                    status.connection = .attention(message)
                    status.lastError = message
                    record(message)
                    return
                }
                let arguments = try await SSH.tunnelArguments(for: forward)
                try Task.checkCancellation()
                let process = try Subprocess(executable: "/usr/bin/ssh", arguments: arguments)
                command = process
                try process.start()
                status.sshPID = process.pid
                record("Connecting to \(forward.host):\(forward.remotePort)")

                let deadline = Date().addingTimeInterval(12)
                var bound = false
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                    let owned = try await Discovery.localListeners(port: forward.localPort, pid: process.pid)
                    try Task.checkCancellation()
                    if owned.count >= 2 { bound = true; break }
                }
                guard bound, process.isRunning else {
                    let error = process.result().error
                    throw CommandError.failed(error.isEmpty ? "SSH did not establish both local loopback listeners." : error)
                }
                status.connection = .connected
                status.lastError = nil
                record("Forward established on localhost:\(forward.localPort)")
                hasConnected = true
                let connectedAt = Date()

                while process.isRunning {
                    try Task.checkCancellation()
                    let freshMetadata = status.metadataError == nil && status.metadataCheckedAt.map { Date().timeIntervalSince($0) < 25 } == true
                    var service = await Health.check(forward)
                    if case .unreachable = service, freshMetadata && status.processes.isEmpty {
                        service = .waiting
                    }
                    if service == .unverified, freshMetadata && status.processes.isEmpty { service = .waiting }
                    try Task.checkCancellation()
                    guard process.isRunning else { break }
                    if status.service != service { record(service.title) }
                    status.service = service
                    switch service {
                    case .responding:
                        status.lastResponseAt = Date()
                        status.lastError = nil
                        outageStarted = nil
                        notified = false
                    case .unreachable(let message):
                        status.lastError = message
                        checkOutage("Service on port \(forward.localPort) is not responding.")
                    case .waiting, .unverified:
                        status.lastError = nil
                        outageStarted = nil
                        notified = false
                    case .unchecked: break
                    }
                    if Date().timeIntervalSince(connectedAt) > 20 { attempt = 0 }
                    try await Task.sleep(for: .seconds(3))
                }
                throw CommandError.failed(process.result().error)
            } catch {
                if let command { await command.stop() }
                command = nil
                status.sshPID = nil
                if Task.isCancelled { return }
                record(error.localizedDescription)
                let failure = SSH.failureMessage(error.localizedDescription)
                status.lastError = failure.message
                record(failure.message)
                if failure.needsAttention {
                    status.connection = .attention(failure.message)
                    return
                }
                attempt += 1
                let delay = min(pow(2, Double(min(attempt - 1, 5))), 30)
                status.connection = .retrying(Date().addingTimeInterval(delay))
                checkOutage(failure.message)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
}
