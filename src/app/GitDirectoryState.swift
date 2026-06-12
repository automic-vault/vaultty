import Foundation

final class GitDirectoryStateProvider {
    private struct CacheEntry {
        let expiresAt: Date
        let summary: String?
    }

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let cacheTTL: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var didResolveGit = false
    private var gitURL: URL?

    init(cacheTTL: TimeInterval = 2) {
        self.cacheTTL = cacheTTL
    }

    func summary(forDirectory url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let rootPath = gitWorktreeRoot(containing: path) else { return nil }
        return summary(forGitDirectory: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    private func summary(forGitDirectory url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard containsGitMetadata(at: path) else { return nil }

        let now = Date()
        lock.lock()
        if let entry = cache[path], entry.expiresAt > now {
            lock.unlock()
            return entry.summary
        }
        lock.unlock()

        let summary = loadSummary(for: path)
        lock.lock()
        cache[path] = CacheEntry(expiresAt: now.addingTimeInterval(cacheTTL), summary: summary)
        lock.unlock()
        return summary
    }

    private func containsGitMetadata(at path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return fileManager.fileExists(atPath: gitPath)
    }

    private func gitWorktreeRoot(containing path: String) -> String? {
        var cursor = (path as NSString).standardizingPath
        while true {
            if containsGitMetadata(at: cursor) {
                return cursor
            }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent.isEmpty {
                return nil
            }
            cursor = parent
        }
    }

    private func loadSummary(for path: String) -> String? {
        guard let gitURL = resolvedGitURL(),
              let output = runStatus(gitURL: gitURL, repositoryPath: path)
        else {
            return nil
        }
        return parseStatus(output)
    }

    private func resolvedGitURL() -> URL? {
        lock.lock()
        if didResolveGit {
            let url = gitURL
            lock.unlock()
            return url
        }
        lock.unlock()

        let url = executableURL(named: "git")

        lock.lock()
        if !didResolveGit {
            gitURL = url
            didResolveGit = true
        }
        let resolved = gitURL
        lock.unlock()
        return resolved
    }

    private func executableURL(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func runStatus(gitURL: URL, repositoryPath: String) -> String? {
        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", repositoryPath, "status", "--short", "--branch"]
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + 0.45) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.1)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func parseStatus(_ output: String) -> String? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return nil }

        var branch = "HEAD"
        var ahead = 0
        var behind = 0
        var changed = 0
        var untracked = 0

        for line in lines {
            if line.hasPrefix("## ") {
                let branchLine = String(line.dropFirst(3))
                branch = parseBranchName(branchLine)
                ahead = parseCount(named: "ahead", in: branchLine)
                behind = parseCount(named: "behind", in: branchLine)
                continue
            }

            if line.hasPrefix("??") {
                untracked += 1
            } else if !line.hasPrefix("!!") {
                changed += 1
            }
        }

        var parts = ["git", branch]
        if changed == 0 && untracked == 0 {
            parts.append("clean")
        } else {
            if changed > 0 {
                parts.append("\(changed) changed")
            }
            if untracked > 0 {
                parts.append("\(untracked) untracked")
            }
        }
        if ahead > 0 {
            parts.append("ahead \(ahead)")
        }
        if behind > 0 {
            parts.append("behind \(behind)")
        }
        return parts.joined(separator: " ")
    }

    private func parseBranchName(_ branchLine: String) -> String {
        if branchLine.hasPrefix("No commits yet on ") {
            return String(branchLine.dropFirst("No commits yet on ".count))
        }
        let beforeTracking = branchLine.components(separatedBy: "...").first ?? branchLine
        let beforeDetails = beforeTracking.components(separatedBy: " [").first ?? beforeTracking
        return beforeDetails.isEmpty ? "HEAD" : beforeDetails
    }

    private func parseCount(named name: String, in text: String) -> Int {
        let pattern = "\(name) [0-9]+"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return 0
        }
        return Int(text[range].split(separator: " ").last ?? "") ?? 0
    }
}
