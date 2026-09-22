import Foundation

public struct RemoteProcess: Equatable, Sendable {
    public let pid: Int
    public let command: String
    public let directory: String
    public let repository: String
    public let branch: String
    public let commonGitDirectory: String

    public var projectName: String {
        if !commonGitDirectory.isEmpty {
            let common = URL(fileURLWithPath: commonGitDirectory)
            if common.lastPathComponent == ".git" { return common.deletingLastPathComponent().lastPathComponent }
        }
        if !repository.isEmpty { return URL(fileURLWithPath: repository).lastPathComponent }
        if !directory.isEmpty, directory != "/" { return URL(fileURLWithPath: directory).lastPathComponent }
        return URL(fileURLWithPath: command).lastPathComponent
    }
}

public struct DiscoverySnapshot: Equatable, Sendable {
    public let ports: [Int: [RemoteProcess]]

    public static func parse(_ output: String) throws -> DiscoverySnapshot {
        guard let marker = output.range(of: "LOKI1\0") else {
            throw CommandError.failed("The remote machine did not return process details.")
        }
        let fields = output[marker.upperBound...].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var currentPort: Int?
        var ports: [Int: [RemoteProcess]] = [:]
        while index < fields.count {
            switch fields[index] {
            case "PORT":
                guard index + 1 < fields.count, let port = Int(fields[index + 1]) else { throw malformed() }
                currentPort = port
                ports[port] = []
                index += 2
            case "PROCESS":
                guard let port = currentPort, index + 7 < fields.count, let pid = Int(fields[index + 1]) else { throw malformed() }
                ports[port, default: []].append(RemoteProcess(
                    pid: pid, command: fields[index + 2], directory: fields[index + 3],
                    repository: fields[index + 4], branch: fields[index + 5], commonGitDirectory: fields[index + 6]))
                index += 7
            case "END": return DiscoverySnapshot(ports: ports)
            default: throw malformed()
            }
        }
        throw malformed()
    }

    private static func malformed() -> CommandError { .failed("Remote process details were incomplete. Retrying discovery.") }
}

public enum Discovery {
    public static func script(ports: [Int]) -> String {
        let portList = Set(ports).filter { (1...65535).contains($0) }.sorted().map(String.init).joined(separator: " ")
        // NUL-separated fields preserve whitespace in project paths and process names.
        return #"""
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        command -v lsof >/dev/null 2>&1 || { echo 'lsof is unavailable on this machine.' >&2; exit 2; }
        printf 'LOKI1\000'
        for port in \#(portList); do
            printf 'PORT\000%s\000' "$port"
            pids=$(lsof -nP -a -i4TCP:"$port" -sTCP:LISTEN -Fpn 2>/dev/null | awk '/^p/ {pid=substr($0,2)} /^n(127\.0\.0\.1|\*):/ {print pid}' | sort -u)
            for pid in $pids; do
                case "$pid" in *[!0-9]*|'') continue;; esac
                cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
                cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
                repo=''; branch=''; common=''
                if [ -n "$cwd" ] && [ -d "$cwd" ]; then
                    repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo=''
                    if [ -n "$repo" ]; then
                        branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
                        common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=''
                    fi
                fi
                printf 'PROCESS\000%s\000%s\000%s\000%s\000%s\000%s\000' "$pid" "$cmd" "$cwd" "$repo" "$branch" "$common"
            done
        done
        printf 'END\000'
        """#
    }

    @MainActor
    public static func inspect(host: String, ports: [Int]) async throws -> DiscoverySnapshot {
        let result = try await Subprocess.run("/usr/bin/ssh", SSH.discoveryArguments(host: host),
                                              input: script(ports: ports), timeout: 15)
        guard result.status == 0 else {
            throw CommandError.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try DiscoverySnapshot.parse(result.output)
    }

    @MainActor
    public static func localListeners(port: Int, pid: Int32? = nil) async throws -> [LocalListener] {
        var arguments = ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]
        if let pid { arguments += ["-p", String(pid)] }
        let result = try await Subprocess.run("/usr/sbin/lsof", arguments, timeout: 4)
        if result.status != 0 && result.status != 1 { throw CommandError.failed(result.error) }
        return LocalListener.parse(result.output)
    }
}

public struct LocalListener: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let address: String

    public static func parse(_ output: String) -> [LocalListener] {
        var pid: Int32?
        var command = ""
        var result: [LocalListener] = []
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "c": command = String(line.dropFirst())
            case "n":
                if let pid { result.append(LocalListener(pid: pid, command: command, address: String(line.dropFirst()))) }
            default: break
            }
        }
        return result
    }
}
