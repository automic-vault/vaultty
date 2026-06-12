import Darwin
import Foundation

final class GitDirectoryStateProvider {
    private struct CacheEntry {
        let expiresAt: Date
        let summary: String?
    }

    private struct RepositoryLocation {
        let worktreePath: String
        let gitDirectoryPath: String
    }

    private struct IndexEntry {
        let path: String
        let mtimeSeconds: Int
        let size: UInt32
    }

    private struct ChangeCounts {
        var additions = 0
        var deletions = 0

        var isClean: Bool {
            additions == 0 && deletions == 0
        }
    }

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let cacheTTL: TimeInterval
    private var cache: [String: CacheEntry] = [:]

    init(cacheTTL: TimeInterval = 2) {
        self.cacheTTL = cacheTTL
    }

    func summary(forDirectory url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let location = repositoryLocation(containing: path) else { return nil }

        let now = Date()
        lock.lock()
        if let entry = cache[location.worktreePath], entry.expiresAt > now {
            lock.unlock()
            return entry.summary
        }
        lock.unlock()

        let summary = loadSummary(for: location)
        lock.lock()
        cache[location.worktreePath] = CacheEntry(
            expiresAt: now.addingTimeInterval(cacheTTL),
            summary: summary
        )
        lock.unlock()
        return summary
    }

    private func repositoryLocation(containing path: String) -> RepositoryLocation? {
        var cursor = (path as NSString).standardizingPath
        while true {
            let gitPath = (cursor as NSString).appendingPathComponent(".git")
            if directoryExists(at: gitPath) {
                return RepositoryLocation(worktreePath: cursor, gitDirectoryPath: gitPath)
            }
            if fileManager.fileExists(atPath: gitPath),
               let redirectedGitPath = redirectedGitDirectory(from: gitPath, relativeTo: cursor) {
                return RepositoryLocation(worktreePath: cursor, gitDirectoryPath: redirectedGitPath)
            }

            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent.isEmpty {
                return nil
            }
            cursor = parent
        }
    }

    private func redirectedGitDirectory(from gitFilePath: String, relativeTo worktreePath: String) -> String? {
        guard let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }

        let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPath.hasPrefix("/") {
            return (rawPath as NSString).standardizingPath
        }
        return ((worktreePath as NSString).appendingPathComponent(rawPath) as NSString).standardizingPath
    }

    private func loadSummary(for location: RepositoryLocation) -> String? {
        guard let branch = branchName(in: location.gitDirectoryPath) else {
            return nil
        }

        guard let indexEntries = readIndexEntries(in: location.gitDirectoryPath) else {
            return "git \(branch)"
        }

        let counts = changeCounts(
            worktreePath: location.worktreePath,
            entries: indexEntries
        )

        if counts.isClean {
            return "git \(branch) clean"
        }

        var parts = ["git", branch, "dirty"]
        if counts.additions > 0 {
            parts.append("+\(counts.additions)")
        }
        if counts.deletions > 0 {
            parts.append("-\(counts.deletions)")
        }
        return parts.joined(separator: " ")
    }

    private func branchName(in gitDirectoryPath: String) -> String? {
        let headPath = (gitDirectoryPath as NSString).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let refName = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if refName.hasPrefix("refs/heads/") {
                return String(refName.dropFirst("refs/heads/".count))
            }
            return String(refName)
        }
        return String(trimmed.prefix(7))
    }

    private func readIndexEntries(in gitDirectoryPath: String) -> [IndexEntry]? {
        let indexPath = (gitDirectoryPath as NSString).appendingPathComponent("index")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              data.count >= 12,
              data[0] == 0x44,
              data[1] == 0x49,
              data[2] == 0x52,
              data[3] == 0x43
        else {
            return nil
        }

        let version = readUInt32(data, at: 4)
        guard version == 2 || version == 3 else {
            return nil
        }

        let entryCount = Int(readUInt32(data, at: 8))
        var offset = 12
        var entries: [IndexEntry] = []
        entries.reserveCapacity(min(entryCount, 4096))

        for _ in 0..<entryCount {
            guard offset + 62 <= data.count else { return nil }
            let entryStart = offset
            let mtimeSeconds = Int(readUInt32(data, at: offset + 8))
            let size = readUInt32(data, at: offset + 36)
            let flags = readUInt16(data, at: offset + 60)
            offset += 62
            if version == 3 && (flags & 0x4000) != 0 {
                guard offset + 2 <= data.count else { return nil }
                offset += 2
            }

            let declaredPathLength = Int(flags & 0x0FFF)
            let pathEnd: Int
            if declaredPathLength < 0x0FFF {
                pathEnd = min(offset + declaredPathLength, data.count)
            } else if let nul = data[offset...].firstIndex(of: 0) {
                pathEnd = nul
            } else {
                return nil
            }

            guard pathEnd <= data.count,
                  let path = String(data: data[offset..<pathEnd], encoding: .utf8)
            else {
                return nil
            }
            entries.append(IndexEntry(path: path, mtimeSeconds: mtimeSeconds, size: size))

            offset = pathEnd
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            guard offset < data.count else { return nil }
            offset += 1

            let entryLength = offset - entryStart
            let padding = (8 - (entryLength % 8)) % 8
            offset += padding
        }

        return entries
    }

    private func changeCounts(worktreePath: String, entries: [IndexEntry]) -> ChangeCounts {
        var counts = ChangeCounts()
        var trackedPaths = Set<String>()
        var trackedDirectories = Set<String>()

        for entry in entries {
            trackedPaths.insert(entry.path)
            var directory = (entry.path as NSString).deletingLastPathComponent
            while !directory.isEmpty && directory != "." {
                trackedDirectories.insert(directory)
                directory = (directory as NSString).deletingLastPathComponent
            }

            switch trackedFileState(worktreePath: worktreePath, entry: entry) {
            case .unchanged:
                break
            case .changed:
                counts.additions += 1
            case .deleted:
                counts.deletions += 1
            }
        }

        counts.additions += untrackedCount(
            worktreePath: worktreePath,
            trackedPaths: trackedPaths,
            trackedDirectories: trackedDirectories
        )
        return counts
    }

    private enum TrackedFileState {
        case unchanged
        case changed
        case deleted
    }

    private func trackedFileState(worktreePath: String, entry: IndexEntry) -> TrackedFileState {
        let path = (worktreePath as NSString).appendingPathComponent(entry.path)
        var fileStat = stat()
        let result = URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { representation in
            lstat(representation, &fileStat)
        }
        guard result == 0 else {
            return errno == ENOENT ? .deleted : .changed
        }

        let size = UInt32(clamping: fileStat.st_size)
        let mtimeSeconds = Int(fileStat.st_mtimespec.tv_sec)
        if size != entry.size || mtimeSeconds != entry.mtimeSeconds {
            return .changed
        }
        return .unchanged
    }

    private func untrackedCount(
        worktreePath: String,
        trackedPaths: Set<String>,
        trackedDirectories: Set<String>
    ) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: worktreePath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }

        var count = 0
        var visited = 0
        let maxVisited = 5_000
        let maxUntracked = 99

        for case let url as URL in enumerator {
            visited += 1
            if visited > maxVisited || count >= maxUntracked {
                break
            }

            let relativePath = relativePath(for: url.path, basePath: worktreePath)
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if name == ".git" || isIgnoredDirectoryName(name) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if trackedPaths.contains(relativePath) {
                continue
            }

            if isDirectory {
                if trackedDirectories.contains(relativePath) {
                    continue
                }
                count += 1
                enumerator.skipDescendants()
            } else {
                count += 1
            }
        }

        return count
    }

    private func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isIgnoredDirectoryName(_ name: String) -> Bool {
        name == ".git" || name == "node_modules" || name == ".build" || name == "target"
    }

    private func relativePath(for path: String, basePath: String) -> String {
        guard path.hasPrefix(basePath + "/") else { return path }
        return String(path.dropFirst(basePath.count + 1))
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
