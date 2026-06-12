import Foundation
import Darwin

final class PtySession {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private static let reaperQueue = DispatchQueue(label: "com.automicvault.vaultty.pty-reaper", qos: .utility)

    private var childPid: pid_t = -1
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.automicvault.vaultty.pty")

    deinit {
        stop()
    }

    func start(shellPath: String, environment: [String: String], workingDirectory: URL) throws {
        var masterFd: Int32 = -1
        var windowSize = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&masterFd, nil, nil, &windowSize)
        guard pid >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "forkpty failed: \(String(cString: strerror(errno)))"]
            )
        }

        if pid == 0 {
            workingDirectory.path.withCString { path in
                _ = chdir(path)
            }
            for (key, value) in environment {
                key.withCString { keyPointer in
                    value.withCString { valuePointer in
                        _ = setenv(keyPointer, valuePointer, 1)
                    }
                }
            }
            let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
            let loginShell = "-" + shellName
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(loginShell),
                nil
            ]
            shellPath.withCString { shellPointer in
                argv.withUnsafeMutableBufferPointer { argvBuffer in
                    _ = execv(shellPointer, argvBuffer.baseAddress)
                }
            }
            perror("exec")
            _exit(127)
        }

        self.master = masterFd
        self.childPid = pid
        disableEcho(fd: masterFd)
        startReading(fd: masterFd)
        startWaiting(pid: pid)
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

    func sendInterrupt() {
        guard master >= 0 else { return }
        if isSignalInputModeEnabled() == true {
            var foregroundProcessGroup: Int32 = 0
            if ioctl(master, TIOCGPGRP, &foregroundProcessGroup) == 0,
               foregroundProcessGroup > 0,
               kill(-foregroundProcessGroup, SIGINT) == 0 {
                return
            }
            if childPid > 0, kill(-childPid, SIGINT) == 0 {
                return
            }
        }
        write("\u{3}")
    }

    func write(_ string: String) {
        guard master >= 0, let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(master, base, data.count)
        }
    }

    func stop() {
        let pid = childPid
        let fd = master
        let processGroups = processGroupsToTerminate(masterFd: fd, childPid: pid)

        if !processGroups.isEmpty {
            send(signal: SIGTERM, toProcessGroups: processGroups)
        }
        if pid > 0 {
            _ = kill(pid, SIGTERM)
        }

        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        if fd >= 0 {
            close(fd)
            master = -1
        }
        if pid > 0 {
            Self.reapChild(pid: pid)
        }
        childPid = -1
    }

    private func disableEcho(fd: Int32) {
        var term = termios()
        if tcgetattr(fd, &term) == 0 {
            term.c_lflag &= ~UInt(ECHO)
            _ = tcsetattr(fd, TCSANOW, &term)
        }
    }

    private func isSignalInputModeEnabled() -> Bool? {
        guard master >= 0 else { return nil }
        var term = termios()
        guard tcgetattr(master, &term) == 0 else { return nil }
        return (term.c_lflag & UInt(ISIG)) != 0
    }

    private func processGroupsToTerminate(masterFd: Int32, childPid: pid_t) -> [pid_t] {
        var groups: [pid_t] = []

        if masterFd >= 0 {
            var foregroundProcessGroup: pid_t = 0
            if ioctl(masterFd, TIOCGPGRP, &foregroundProcessGroup) == 0,
               foregroundProcessGroup > 0 {
                groups.append(foregroundProcessGroup)
            }
        }

        if childPid > 0 {
            groups.append(childPid)
        }

        var seen = Set<pid_t>()
        return groups.filter { seen.insert($0).inserted }
    }

    private func send(signal: Int32, toProcessGroups processGroups: [pid_t]) {
        for processGroup in processGroups {
            _ = kill(-processGroup, signal)
        }
    }

    private static func reapChild(pid: pid_t) {
        reaperQueue.async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {
            }
        }
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

    private func startWaiting(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            let exitStatus = Self.exitStatus(fromWaitStatus: status)
            if self?.childPid == pid {
                self?.childPid = -1
                self?.exitSource = nil
            }
            DispatchQueue.main.async {
                self?.onExit?(exitStatus)
            }
        }
        source.resume()
        self.exitSource = source
    }

    private static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }
}
