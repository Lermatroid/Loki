import Foundation

enum RemoteProcessControl {
    struct Target: Equatable, Sendable {
        let pid: Int
        let started: String
    }

    struct Result: Equatable, Sendable {
        let signalledCount: Int
        let remaining: [Target]

        static func parse(_ output: String) throws -> Result {
            guard let marker = output.range(of: "LOKISTOP1\0") else { throw malformed() }
            let fields = output[marker.upperBound...].split(separator: "\0", omittingEmptySubsequences: false)
            guard let first = fields.first, let count = Int(first), count >= 0 else { throw malformed() }
            var targets: [Target] = []
            var index = 1
            while index < fields.count {
                if fields[index] == "END" { return Result(signalledCount: count, remaining: targets) }
                guard fields[index] == "TARGET", index + 2 < fields.count,
                      let pid = Int(fields[index + 1]), pid > 1, !fields[index + 2].isEmpty else { throw malformed() }
                targets.append(Target(pid: pid, started: String(fields[index + 2])))
                index += 3
            }
            throw malformed()
        }

        private static func malformed() -> CommandError {
            .failed("The remote machine did not confirm whether the process stopped. Refresh its details before trying again.")
        }
    }

    @MainActor
    static func stop(_ forward: Forward, forceTargets: [Target]? = nil) async throws -> Result {
        try forward.validate()
        let result = try await Subprocess.run("/usr/bin/ssh", SSH.discoveryArguments(host: forward.host),
                                              input: script(port: forward.remotePort, forceTargets: forceTargets), timeout: 20)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError.failed(message.isEmpty ? "Could not stop the remote process." : message)
        }
        return try Result.parse(result.output)
    }

    static func script(port: Int, forceTargets: [Target]? = nil) throws -> String {
        guard (1...65535).contains(port) else { throw ConfigurationError.invalid("Invalid remote port.") }
        let allowed: String
        if let forceTargets {
            guard !forceTargets.isEmpty, forceTargets.allSatisfy({ $0.pid > 1 && !$0.started.isEmpty }) else {
                throw ConfigurationError.invalid("No remote process is available to force stop.")
            }
            let patterns = forceTargets.map { target in
                "'\(target.pid)|\(target.started.replacingOccurrences(of: "'", with: "'\\''"))'"
            }.joined(separator: "|")
            allowed = "case \"$1|$2\" in \(patterns)) return 0;; *) return 1;; esac"
        } else {
            allowed = "return 0"
        }
        // Match the IPv4 loopback destination used by the tunnel. Force stop retains process identity.
        return #"""
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        LC_ALL=C
        export LC_ALL
        command -v lsof >/dev/null 2>&1 || { echo 'lsof is unavailable on this machine.' >&2; exit 2; }
        listeners() {
            lsof -nP -a -i4TCP:\#(port) -sTCP:LISTEN -Fpn 2>/dev/null |
                awk '/^p/ {pid=substr($0,2)} /^n(127\.0\.0\.1|\*):/ {print pid}' | sort -u
        }
        identity() { ps -p "$1" -o lstart= 2>/dev/null; }
        allowed() { \#(allowed); }
        targets=''
        count=0
        for pid in $(listeners); do
            case "$pid" in *[!0-9]*|'') continue;; esac
            [ "$pid" -gt 1 ] || continue
            started=$(identity "$pid")
            [ -n "$started" ] || continue
            allowed "$pid" "$started" || continue
            if kill -\#(forceTargets == nil ? "TERM" : "KILL") "$pid"; then
                count=$((count + 1))
                targets="${targets}${pid}|${started}
        "
            elif [ "$(identity "$pid")" = "$started" ]; then
                echo "Could not stop PID $pid. Check the remote user's process permissions." >&2
                exit 3
            fi
        done
        remaining_targets() {
            current=" $(listeners | tr '\n' ' ') "
            printf '%s' "$targets" | while IFS='|' read -r pid started; do
                [ -n "$pid" ] || continue
                case "$current" in *" $pid "*) ;; *) continue;; esac
                [ "$(identity "$pid")" = "$started" ] || continue
                printf '%s|%s\n' "$pid" "$started"
            done
        }
        remaining=$(remaining_targets)
        attempts=0
        while [ -n "$remaining" ] && [ "$attempts" -lt 3 ]; do
            sleep 1
            attempts=$((attempts + 1))
            remaining=$(remaining_targets)
        done
        printf 'LOKISTOP1\000%s\000' "$count"
        printf '%s\n' "$remaining" | while IFS='|' read -r pid started; do
            [ -n "$pid" ] || continue
            printf 'TARGET\000%s\000%s\000' "$pid" "$started"
        done
        printf 'END\000'
        """#
    }
}
