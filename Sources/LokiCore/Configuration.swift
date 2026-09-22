import Foundation

public enum ProbeMode: String, Codable, CaseIterable, Sendable {
    case http, https, tcp
    public var title: String { rawValue.uppercased() }
}

public struct Forward: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var host: String
    public var localPort: Int
    public var remotePort: Int
    public var probe: ProbeMode
    public var enabled: Bool

    public init(id: UUID = UUID(), host: String, localPort: Int, remotePort: Int,
                probe: ProbeMode = .http, enabled: Bool = true) {
        self.id = id
        self.host = host
        self.localPort = localPort
        self.remotePort = remotePort
        self.probe = probe
        self.enabled = enabled
    }

    public var url: URL? {
        guard probe != .tcp else { return nil }
        return URL(string: "\(probe.rawValue)://127.0.0.1:\(localPort)")
    }

    public func validate() throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._@-]*$"#
        guard host.range(of: pattern, options: .regularExpression) != nil else {
            throw ConfigurationError.invalid("Use an SSH alias or hostname, optionally user@hostname.")
        }
        guard (1024...65535).contains(localPort), (1...65535).contains(remotePort) else {
            throw ConfigurationError.invalid("Local ports must be 1024–65535; remote ports must be 1–65535.")
        }
    }
}

public struct Configuration: Codable, Sendable {
    public var forwards: [Forward]
    public var notifyOnOutage: Bool

    public init(forwards: [Forward] = [Forward(host: "tinytroid", localPort: 3010, remotePort: 3010)],
                notifyOnOutage: Bool = false) {
        self.forwards = forwards
        self.notifyOnOutage = notifyOnOutage
    }

    public func validate() throws {
        var ports = Set<Int>()
        var ids = Set<UUID>()
        for forward in forwards {
            try forward.validate()
            guard ports.insert(forward.localPort).inserted else {
                throw ConfigurationError.invalid("Local port \(forward.localPort) is already configured. Choose a different local port.")
            }
            guard ids.insert(forward.id).inserted else {
                throw ConfigurationError.invalid("Duplicate forward identifier.")
            }
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Loki/configuration.json")
    }

    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    public func save(_ configuration: Configuration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}
