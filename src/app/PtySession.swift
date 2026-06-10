import Foundation
import Darwin

final class PtySession {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.automicvault.vaultty.pty")

    deinit {
        stop()
    }

    func start(shellPath: String, environment: [String: String], workingDirectory: URL) throws {
        var masterFd: Int32 = -1
        var slaveFd: Int32 = -1
        var windowSize = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFd, &slaveFd, nil, nil, &windowSize) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "openpty failed: \(String(cString: strerror(errno)))"]
            )
        }

        var term = termios()
        if tcgetattr(slaveFd, &term) == 0 {
            term.c_lflag &= ~UInt(ECHO)
            _ = tcsetattr(slaveFd, TCSANOW, &term)
        }

        let slaveInput = FileHandle(fileDescriptor: dup(slaveFd), closeOnDealloc: true)
        let slaveOutput = FileHandle(fileDescriptor: dup(slaveFd), closeOnDealloc: true)
        let slaveError = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = slaveInput
        process.standardOutput = slaveOutput
        process.standardError = slaveError
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.onExit?(process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            close(masterFd)
            throw error
        }

        self.master = masterFd
        self.process = process
        startReading(fd: masterFd)
    }

    func resize(rows: UInt16, cols: UInt16) {
        guard master >= 0 else { return }
        var windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &windowSize)
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        guard master >= 0 else { return nil }
        var term = termios()
        guard tcgetattr(master, &term) == 0 else { return nil }
        return (term.c_lflag & UInt(ICANON)) != 0
    }

    func write(_ string: String) {
        guard master >= 0, let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(master, base, data.count)
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if master >= 0 {
            close(master)
            master = -1
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                source.cancel()
                return
            }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            DispatchQueue.main.async {
                self?.onOutput?(text)
            }
        }
        source.setCancelHandler {
        }
        source.resume()
        self.readSource = source
    }
}
