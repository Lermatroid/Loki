import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

public enum CommandError: LocalizedError {
    case timeout
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: "The command timed out."
        case .failed(let message): message
        }
    }
}

/// File-backed output avoids pipe deadlocks and keeps process ownership on one actor.
@MainActor
public final class Subprocess {
    public let process = Process()
    private let directory: URL
    private let outputURL: URL
    private let errorURL: URL
    private var handles: [FileHandle] = []
    private var launched = false
    private var closed = false

    public init(executable: String, arguments: [String], input: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("loki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        outputURL = directory.appendingPathComponent("stdout")
        errorURL = directory.appendingPathComponent("stderr")
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        for url in [outputURL, errorURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handles.append(try FileHandle(forWritingTo: url))
        }
        process.standardOutput = handles[0]
        process.standardError = handles[1]
        if let input {
            let url = directory.appendingPathComponent("stdin")
            try Data(input.utf8).write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            handles.append(handle)
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
    }

    public var isRunning: Bool { launched && process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    public func start() throws {
        try process.run()
        launched = true
    }

    public func result() -> CommandResult {
        CommandResult(status: launched && !process.isRunning ? process.terminationStatus : -1,
                      output: read(outputURL), error: read(errorURL))
    }

    private func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    public func terminate() {
        if isRunning { process.terminate() }
    }

    public func stop() async {
        terminate()
        for _ in 0..<20 {
            if !isRunning { break }
            // Cleanup must still wait when the owning task has been cancelled.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        if isRunning { Darwin.kill(pid, SIGKILL) }
        for _ in 0..<20 {
            if !isRunning { break }
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        close()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for handle in handles { try? handle.close() }
        handles.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    public static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                           timeout: TimeInterval = 12) async throws -> CommandResult {
        let command = try Subprocess(executable: executable, arguments: arguments, input: input)
        do {
            try Task.checkCancellation()
            try command.start()
            let deadline = Date().addingTimeInterval(timeout)
            while command.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CommandError.timeout }
                try await Task.sleep(for: .milliseconds(80))
            }
            let result = command.result()
            command.close()
            return result
        } catch {
            await command.stop()
            throw error
        }
    }
}
