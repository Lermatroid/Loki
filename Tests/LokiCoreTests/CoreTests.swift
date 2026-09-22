import Foundation
import Testing
@testable import LokiCore

@Test func defaultOnlyUsesTestPort() throws {
    let config = Configuration()
    try config.validate()
    #expect(config.forwards.map(\.localPort) == [3010])
    #expect(config.forwards.map(\.remotePort) == [3010])
}

@Test func portConflictsAcrossMachinesAreRejected() {
    let config = Configuration(forwards: [
        Forward(host: "first", localPort: 3010, remotePort: 3000),
        Forward(host: "second", localPort: 3010, remotePort: 3001)
    ])
    #expect(throws: ConfigurationError.self) { try config.validate() }
}

@Test func invalidHostAndPortsAreRejected() {
    for host in ["-oProxyCommand=bad", "host;command", "host name", ""] {
        #expect(throws: ConfigurationError.self) {
            try Forward(host: host, localPort: 3010, remotePort: 3010).validate()
        }
    }
    #expect(throws: ConfigurationError.self) {
        try Forward(host: "tinytroid", localPort: 65536, remotePort: 3010).validate()
    }
}

@Test func inheritedForwardsAndEditorMultiplexingAreExcluded() throws {
    let args = try SSH.tunnelArguments(for: Forward(host: "tinytroid", localPort: 3010, remotePort: 3010), resolvedConfiguration: """
    host tinytroid
    hostname tinytroid.example
    user tinytroid
    localforward 3000 127.0.0.1:3000
    remoteforward 3001 127.0.0.1:3001
    dynamicforward 3002
    controlmaster auto
    controlpath /tmp/editor-ssh
    identityfile ~/.ssh/my_key
    proxyjump bastion
    """)
    #expect(!args.contains { $0.contains("3000") || $0.contains("3001") || $0.contains("3002") || $0.contains("editor-ssh") })
    #expect(args.contains("identityfile=~/.ssh/my_key"))
    #expect(args.contains("proxyjump=bastion"))
    #expect(args.contains("ControlPath=none"))
    #expect(args.contains("127.0.0.1:3010:127.0.0.1:3010"))
    #expect(args.contains("[::1]:3010:127.0.0.1:3010"))
    #expect(args.prefix(2) == ["-F", "/dev/null"])
}

@Test func metadataPreservesPathsAndWorktreeIdentity() throws {
    let output = ["shell banner\nLOKI1", "PORT", "3010", "PROCESS", "42", "/usr/bin/node", "/work/feature tree/apps/web",
                  "/work/feature tree", "feature/xyz", "/work/noodler/.git", "PORT", "3011", "END", ""].joined(separator: "\0")
    let snapshot = try DiscoverySnapshot.parse(output)
    #expect(snapshot.ports[3011] == [])
    let process = try #require(snapshot.ports[3010]?.first)
    #expect(process.projectName == "noodler")
    #expect(process.branch == "feature/xyz")
    #expect(process.directory == "/work/feature tree/apps/web")
}

@Test func incompleteDiscoveryDoesNotLookLikeAnEmptyMachine() {
    #expect(throws: CommandError.self) { try DiscoverySnapshot.parse("LOKI1\0PORT\03010\0PROCESS\042\0") }
    #expect(throws: CommandError.self) { try DiscoverySnapshot.parse("LOKI1\0PORT\03010\0") }
}

@Test func listenerParsingTracksProcessOwnership() {
    let listeners = LocalListener.parse("p42\ncnode\nf20\nn127.0.0.1:3010\np43\ncssh\nf4\nn[::1]:3010\n")
    #expect(listeners.count == 2)
    #expect(listeners[0].pid == 42)
    #expect(listeners[1].command == "ssh")
}

@Test func authenticationFailureStopsRetrying() {
    #expect(SSH.failureMessage("Permission denied (publickey).").needsAttention)
    #expect(SSH.failureMessage("Host key verification failed.").needsAttention)
    #expect(!SSH.failureMessage("Connection timed out").needsAttention)
}

@Test @MainActor func commandOutputAndTimeout() async throws {
    let result = try await Subprocess.run("/usr/bin/printf", ["hello\nworld"])
    #expect(result.status == 0)
    #expect(result.output == "hello\nworld")
    await #expect(throws: CommandError.self) {
        try await Subprocess.run("/bin/sleep", ["5"], timeout: 0.1)
    }
}

@Test @MainActor func cancellationReleasesOwnedProcess() async throws {
    let task = Task { try await Subprocess.run("/bin/sleep", ["20"]) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
