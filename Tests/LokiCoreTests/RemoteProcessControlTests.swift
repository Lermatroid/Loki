import Foundation
import Testing
@testable import LokiCore

@Test func remoteStopRejectsInvalidTargetsAndIncompleteResponses() throws {
    #expect(throws: ConfigurationError.self) { try RemoteProcessControl.script(port: 0) }
    #expect(throws: ConfigurationError.self) { try RemoteProcessControl.script(port: 3000, forceTargets: []) }
    #expect(throws: ConfigurationError.self) {
        try RemoteProcessControl.script(port: 3000, forceTargets: [.init(pid: 1, started: "today")])
    }
    #expect(throws: CommandError.self) { try RemoteProcessControl.Result.parse("LOKISTOP1\0" + "1\0") }
    #expect(throws: CommandError.self) { try RemoteProcessControl.Result.parse("ssh disconnected") }
}

@Test @MainActor func remoteStopTerminatesOnlyTheRequestedListener() async throws {
    try await withListener { server, port in
        try await withListener { other, _ in
            let stopped = try await runStopScript(port: port)
            #expect(stopped.signalledCount == 1)
            #expect(stopped.remaining.isEmpty)
            #expect(!server.isRunning)
            #expect(other.isRunning)

            let empty = try await runStopScript(port: port)
            #expect(empty.signalledCount == 0)
            #expect(empty.remaining.isEmpty)
        }
    }
}

@Test @MainActor func forceStopChecksIdentityAndLeavesReplacementServersRunning() async throws {
    try await withListener(ignoringTermination: true) { server, port in
        let stopped = try await runStopScript(port: port)
        let target = try #require(stopped.remaining.first)
        #expect(stopped.signalledCount == 1)
        #expect(target.pid == Int(server.pid))
        #expect(server.isRunning)

        let stale = try await runStopScript(port: port, forceTargets: [.init(pid: target.pid, started: "stale identity")])
        #expect(stale.signalledCount == 0)
        #expect(server.isRunning)

        let forced = try await runStopScript(port: port, forceTargets: stopped.remaining)
        #expect(forced.signalledCount == 1)
        #expect(forced.remaining.isEmpty)
        #expect(!server.isRunning)

        try await withListener(port: port) { replacement, _ in
            let retried = try await runStopScript(port: port, forceTargets: stopped.remaining)
            #expect(retried.signalledCount == 0)
            #expect(replacement.isRunning)
        }
    }
}

@MainActor
private func runStopScript(port: Int, forceTargets: [RemoteProcessControl.Target]? = nil) async throws -> RemoteProcessControl.Result {
    let result = try await Subprocess.run("/bin/sh", ["-s"],
                                          input: RemoteProcessControl.script(port: port, forceTargets: forceTargets))
    #expect(result.status == 0, "\(result.error)")
    return try RemoteProcessControl.Result.parse(result.output)
}

@MainActor
private func withListener(port: Int = 0, ignoringTermination: Bool = false,
                          body: (Subprocess, Int) async throws -> Void) async throws {
    let server = try Subprocess(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
    import signal, socket, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN if \(ignoringTermination ? "True" : "False") else signal.SIG_DFL)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', \(port)))
    listener.listen()
    print(listener.getsockname()[1], flush=True)
    while True:
        time.sleep(1)
    """])
    do {
        try server.start()
        let deadline = Date().addingTimeInterval(5)
        while server.isRunning && server.result().output.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let actualPort = try #require(Int(server.result().output.trimmingCharacters(in: .whitespacesAndNewlines)),
                                      "Listener failed to start: \(server.result().error)")
        try await body(server, actualPort)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}
