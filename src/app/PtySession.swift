import Foundation
import Darwin

final class PtySession {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?

    private let sessionID: String
    private let queue = DispatchQueue(label: "com.automicvault.vaultty.session-client")
    private var socketFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var parserBuffer = ""

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    deinit {
        stop()
    }

    func start(shellPath: String, environment: [String: String], workingDirectory: URL) throws {
        try Self.ensureDaemonIsRunning()
        let fd = try Self.connectToDaemon()
        socketFd = fd
        startReading(fd: fd)

        let envBlob = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\0")
        sendLine([
            "ATTACH",
            Self.base64(sessionID),
            Self.base64(workingDirectory.path),
            Self.base64(shellPath),
            Self.base64(envBlob)
        ].joined(separator: " "))
    }

    func resize(rows: UInt16, cols: UInt16) {
        sendLine("RESIZE \(rows) \(cols)")
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        nil
    }

    func sendInterrupt() {
        sendLine("INTERRUPT")
    }

    func write(_ string: String, suppressEcho: Bool = false) {
        guard let data = string.data(using: .utf8) else { return }
        sendLine("INPUT \(data.base64EncodedString())")
    }

    func stop() {
        sendLine("DETACH")
        readSource?.cancel()
        readSource = nil
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        parserBuffer.removeAll(keepingCapacity: false)
    }

    static func killDetachedSession(sessionID: String) throws {
        try ensureDaemonIsRunning()
        let fd = try connectToDaemon()
        defer { close(fd) }
        let line = "KILL \(base64(sessionID))\n"
        try writeAll(line, to: fd)
    }

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                source.cancel()
                DispatchQueue.main.async { [weak self] in
                    self?.onExit?(0)
                }
                return
            }

            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            self.consumeProtocolText(text)
        }
        source.setCancelHandler {
        }
        source.resume()
        readSource = source
    }

    private func consumeProtocolText(_ text: String) {
        parserBuffer += text
        while let newline = parserBuffer.firstIndex(of: "\n") {
            let line = String(parserBuffer[..<newline])
            parserBuffer.removeSubrange(...newline)
            handleProtocolLine(line.trimmingCharacters(in: .newlines))
        }
    }

    private func handleProtocolLine(_ line: String) {
        if let payload = line.removingPrefix("OUTPUT "),
           let data = Data(base64Encoded: payload),
           let text = String(data: data, encoding: .utf8) {
            onOutput?(text)
            return
        }

        if let payload = line.removingPrefix("READY ") {
            let created = payload.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            DispatchQueue.main.async { [weak self] in
                self?.onReady?(created)
            }
            return
        }

        if let payload = line.removingPrefix("EXIT ") {
            let status = Int32(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            DispatchQueue.main.async { [weak self] in
                self?.onExit?(status)
            }
        }
    }

    private func sendLine(_ line: String) {
        guard socketFd >= 0 else { return }
        try? Self.writeAll(line + "\n", to: socketFd)
    }

    private static func writeAll(_ string: String, to fd: Int32) throws {
        guard let data = string.data(using: .utf8) else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                } else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "socket write failed: \(String(cString: strerror(errno)))"]
                    )
                }
            }
        }
    }

    private static func connectToDaemon() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket")
        }

        do {
            try connect(fd: fd, path: socketPath())
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "daemon socket path is too long"]
            )
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in pathBytes.indices {
                buffer[index] = UInt8(bitPattern: pathBytes[index])
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard result == 0 else {
            throw posixError("connect")
        }
    }

    private static func ensureDaemonIsRunning() throws {
        if (try? connectToDaemon()).map({ fd in close(fd); return true }) == true {
            return
        }

        let helper = try sessiondHelperPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["VAULTTY_SESSIOND_SOCKET"] = socketPath()
        if helper.contains("/target/debug/") || helper.contains("/target/release/") {
            env["VAULTTY_SESSIOND_ALLOW_DEBUG_CLIENT"] = "1"
        }
        process.environment = env
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        var lastError: Error?
        while Date() < deadline {
            do {
                let fd = try connectToDaemon()
                close(fd)
                return
            } catch {
                lastError = error
                usleep(50_000)
            }
        }
        throw lastError ?? posixError("connect")
    }

    private static func sessiondHelperPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["VAULTTY_SESSIOND"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("vaultty-sessiond", isDirectory: false)
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for candidate in [
            "target/debug/vaultty-sessiond",
            "target/release/vaultty-sessiond"
        ] {
            let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(candidate)
                .path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: "vaultty-sessiond helper was not found"]
        )
    }

    private static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["VAULTTY_SESSIOND_SOCKET"],
           !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vaultty", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("sessiond.sock", isDirectory: false)
            .path
    }

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
