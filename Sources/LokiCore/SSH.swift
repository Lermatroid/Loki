import Foundation

public enum SSH {
    // Explicitly disable shared connections so an editor cannot own Loki's lifecycle.
    public static let baseArguments = [
        "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
        "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
        "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
        "-o", "RequestTTY=no", "-o", "RemoteCommand=none"
    ]

    public static func discoveryArguments(host: String) -> [String] {
        baseArguments + ["-o", "ClearAllForwardings=yes", host, "/bin/sh -s"]
    }

    /// Resolve authentication and routing with ssh itself, excluding inherited forwards.
    @MainActor
    public static func tunnelArguments(for forward: Forward) async throws -> [String] {
        try forward.validate()
        let resolved = try await Subprocess.run("/usr/bin/ssh", ["-G"] + baseArguments + [forward.host])
        guard resolved.status == 0 else { throw CommandError.failed(resolved.error) }
        return try tunnelArguments(for: forward, resolvedConfiguration: resolved.output)
    }

    public static func tunnelArguments(for forward: Forward, resolvedConfiguration: String) throws -> [String] {
        try forward.validate()
        // -F /dev/null prevents LocalForward/RemoteForward entries from binding other ports.
        // Preserve OpenSSH's resolved options rather than implementing its config parser.
        let excluded: Set<String> = [
            "host", "localforward", "remoteforward", "dynamicforward", "clearallforwardings",
            "controlmaster", "controlpath", "controlpersist", "exitonforwardfailure",
            "forkafterauthentication", "sessiontype", "stdinnull", "stdioforwardhost",
            "stdioforwardport", "loglevel", "localcommand", "permitlocalcommand", "remotecommand",
            "requesttty", "forwardagent", "forwardx11", "forwardx11trusted", "batchmode",
            "stricthostkeychecking", "serveraliveinterval", "serveralivecountmax", "connecttimeout",
            "connectionattempts", "canonicalizehostname", "canonicaldomains", "addressfamily"
        ]
        var arguments = ["-F", "/dev/null", "-o", "AddressFamily=any"] + baseArguments
        for line in resolvedConfiguration.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...])
            guard !excluded.contains(key), !value.isEmpty else { continue }
            arguments += ["-o", "\(key)=\(value)"]
        }
        arguments += ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ForkAfterAuthentication=no",
                      "-L", "127.0.0.1:\(forward.localPort):127.0.0.1:\(forward.remotePort)",
                      "-L", "[::1]:\(forward.localPort):127.0.0.1:\(forward.remotePort)", forward.host]
        return arguments
    }

    public static func failureMessage(_ stderr: String) -> (message: String, needsAttention: Bool) {
        if stderr.contains("Permission denied") || stderr.contains("Authentication failed") {
            return ("SSH authentication failed. Check your key or agent with ssh in Terminal.", true)
        }
        if stderr.contains("Host key verification failed") || stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return ("SSH host verification needs attention. Connect in Terminal to verify the host.", true)
        }
        if stderr.contains("Address already in use") {
            return ("The local port is already in use. Pause the other forward or choose a different port.", true)
        }
        if stderr.contains("Could not request local forwarding") {
            return ("SSH could not bind the local loopback addresses. See recent activity for details.", true)
        }
        let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? "SSH disconnected."
        return (lastLine, false)
    }
}
