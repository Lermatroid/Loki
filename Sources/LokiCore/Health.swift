import Foundation

public enum ConnectionState: Equatable, Sendable {
    case paused
    case connecting
    case connected
    case retrying(Date)
    case attention(String)
}

public enum ServiceState: Equatable, Sendable {
    case unchecked
    case waiting
    case responding(Int)
    case unreachable(String)
    case unverified

    public var title: String {
        switch self {
        case .unchecked: "Checking service"
        case .waiting: "Waiting for remote service"
        case .responding(let code): (200..<400).contains(code) ? "Responding · HTTP \(code)" : "HTTP \(code)"
        case .unreachable: "Service not responding"
        case .unverified: "Forward established"
        }
    }
}

public struct ForwardStatus: Sendable {
    public var connection: ConnectionState = .paused
    public var service: ServiceState = .unchecked
    public var processes: [RemoteProcess] = []
    public var metadataCheckedAt: Date?
    public var metadataError: String?
    public var lastResponseAt: Date?
    public var lastError: String?
    public var sshPID: Int32?
    public var events: [StatusEvent] = []

    public init() {}
    public var title: String {
        switch connection {
        case .paused: "Paused"
        case .connecting: "Connecting"
        case .connected: service.title
        case .retrying: "Reconnecting"
        case .attention: "Needs attention"
        }
    }

    public var needsAttention: Bool {
        switch connection {
        case .attention, .retrying: true
        case .connected:
            switch service {
            case .unreachable: true
            case .responding(let status): status >= 400
            default: false
            }
        default: false
        }
    }
}

public struct StatusEvent: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let message: String
}

public enum Health {
    @MainActor
    public static func check(_ forward: Forward) async -> ServiceState {
        guard let url = forward.url else { return .unverified }
        // curl only reads headers and never follows redirects outside the forwarded service.
        do {
            let result = try await Subprocess.run("/usr/bin/curl", [
                "--silent", "--show-error", "--head", "--noproxy", "*", "--max-time", "4",
                "--output", "/dev/null", "--write-out", "%{http_code}", url.absoluteString
            ], timeout: 5)
            guard result.status == 0, let status = Int(result.output), status >= 100 else {
                return .unreachable(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .responding(status)
        } catch { return .unreachable(error.localizedDescription) }
    }
}
