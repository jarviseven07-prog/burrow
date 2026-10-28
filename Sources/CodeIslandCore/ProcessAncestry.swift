import Foundation

/// One process in an agent's ancestry, nearest first.
///
/// Everything the Codex process matchers need, captured once so the matching
/// itself stays a pure function over plain values (and is testable without
/// spawning anything).
public struct ProcessAncestor: Sendable, Equatable {
    public let pid: Int32
    /// Resolved executable (`proc_pidpath`) — symlinks already followed.
    public let executablePath: String?
    /// argv, including argv[0].
    public let arguments: [String]
    /// Only the variables a matcher asks for; empty when unreadable.
    public let environment: [String: String]
    /// CFBundleIdentifier of the outermost `.app` containing `executablePath`.
    public let bundleIdentifier: String?

    public init(
        pid: Int32,
        executablePath: String?,
        arguments: [String] = [],
        environment: [String: String] = [:],
        bundleIdentifier: String? = nil
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum ProcessAncestry {
    /// Outermost `.app` bundle in an executable path — the app itself, not a
    /// nested helper (`…/Codex.app/Contents/Resources/codex`, not a nested helper `.app`).
    public static func outermostAppBundlePath(forExecutable path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...index]))
    }
}

/// Parser for the `KERN_PROCARGS2` sysctl buffer: `argc` (Int32), the exec
/// path, NUL padding, `argc` NUL-terminated argv strings, then the environment
/// as NUL-terminated `KEY=VALUE` strings up to an empty string.
public enum ProcArgsParser {
    public static func parse(
        _ buffer: [UInt8],
        environmentKeys: Set<String> = []
    ) -> (arguments: [String], environment: [String: String])? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = intSize
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }  // exec path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }  // padding

        func nextString() -> String? {
            guard offset < buffer.count else { return nil }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            let value = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return value
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }

        var environment: [String: String] = [:]
        if !environmentKeys.isEmpty {
            while let entry = nextString(), !entry.isEmpty {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<separator])
                if environmentKeys.contains(key) {
                    environment[key] = String(entry[entry.index(after: separator)...])
                }
            }
        }
        return (arguments, environment)
    }

    /// The `keys` variables of a process — or nil when its environment block
    /// cannot be trusted to be whole: argv ends before `argc` strings, the
    /// block holds no entry at all (the kernel withheld it; a real CLI process
    /// always has PATH, HOME…), or its last entry runs off the end of the
    /// buffer. `parse` returns whatever it got in those cases, which a caller
    /// that must tell "variable unset" from "environment unknown" cannot use:
    /// a missing `CODEX_HOME` would read as "uses the default root".
}
