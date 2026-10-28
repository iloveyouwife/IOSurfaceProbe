import Darwin
import Foundation

/// An opt-in, fd-relative cleaner for the same two disposable roots used by
/// 3105. This uses the *current process's* sandbox; it cannot assume that an
/// AirLift connection or a container-path lookup granted POSIX access.
///
/// Preview records file identity and timestamp. Delete reopens each ancestor
/// directory with O_NOFOLLOW and skips any file changed since the preview.
/// It never follows symlinks, removes directories, or opens file contents.
enum ForeignCacheCleaner {
    static let maxFiles = 100_000
    private static let maxDepth = 24
    private static let roots = ["Library/Caches", "tmp"]
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    struct Candidate {
        let scope: String
        let components: [String]
        let bytes: Int64
        let inode: UInt64
        let modificationSeconds: Int
        let modificationNanos: Int
    }

    struct Snapshot {
        let container: String
        let files: [Candidate]
        let estimatedBytes: Int64
        let accessibleScopes: Int
        let failures: Int
        let truncated: Bool

        var summary: String {
            let detail = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
            let availability = "可访问缓存根目录 \(accessibleScopes)/2，文件 \(files.count) 项，预计可清理 \(detail)"
            if truncated { return availability + "。超过安全扫描上限，禁止清理。" }
            if failures > 0 { return availability + "。遇到 \(failures) 处无法访问的目录或文件，这些项目将被跳过。" }
            return availability
        }
    }

    struct Result {
        let removed: Int
        let bytes: Int64
        let skipped: Int
        let errors: Int

        var summary: String {
            let freed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "本次删除 \(removed) 个缓存文件，按扫描时大小估算释放 \(freed)；跳过 \(skipped)，失败 \(errors)。iOS 存储统计可能稍后更新。"
        }
    }

    static func preview(container: String) -> Snapshot {
        guard CacheTraversalProbe.validateAppRoot(container) else {
            return Snapshot(container: container, files: [], estimatedBytes: 0,
                            accessibleScopes: 0, failures: 1, truncated: false)
        }
        var collector = Collector()
        for scope in roots {
            guard let descriptor = openScope(container: container, scope: scope) else {
                collector.failures += 1
                continue
            }
            collector.accessibleScopes += 1
            collect(in: descriptor, scope: scope, components: [], depth: 0, into: &collector)
            close(descriptor)
            if collector.truncated { break }
        }
        return Snapshot(container: container, files: collector.files,
                        estimatedBytes: collector.bytes, accessibleScopes: collector.accessibleScopes,
                        failures: collector.failures, truncated: collector.truncated)
    }

    static func delete(_ snapshot: Snapshot) -> Result {
        guard !snapshot.truncated, CacheTraversalProbe.validateAppRoot(snapshot.container) else {
            return Result(removed: 0, bytes: 0, skipped: snapshot.files.count, errors: 0)
        }
        var removed = 0
        var bytes: Int64 = 0
        var skipped = 0
        var failures = 0
        for candidate in snapshot.files {
            guard roots.contains(candidate.scope),
                  let scopeFD = openScope(container: snapshot.container, scope: candidate.scope) else {
                failures += 1
                continue
            }
            var parentFD = scopeFD
            var intermediate = false
            for component in candidate.components.dropLast() {
                let next = component.withCString { openat(parentFD, $0, directoryFlags) }
                if next < 0 {
                    intermediate = true
                    break
                }
                if parentFD != scopeFD { close(parentFD) }
                parentFD = next
            }
            if intermediate {
                failures += 1
            } else if let name = candidate.components.last {
                var current = stat()
                let checked = name.withCString { fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW) }
                let unchanged = checked == 0 && isRegularFile(current)
                    && UInt64(current.st_ino) == candidate.inode
                    && Int64(current.st_size) == candidate.bytes
                    && Int(current.st_mtimespec.tv_sec) == candidate.modificationSeconds
                    && Int(current.st_mtimespec.tv_nsec) == candidate.modificationNanos
                if unchanged {
                    let rc = name.withCString { unlinkat(parentFD, $0, 0) }
                    if rc == 0 {
                        removed += 1
                        bytes += candidate.bytes
                    } else {
                        failures += 1
                    }
                } else {
                    skipped += 1
                }
            } else {
                skipped += 1
            }
            if parentFD != scopeFD { close(parentFD) }
            close(scopeFD)
        }
        return Result(removed: removed, bytes: bytes, skipped: skipped, errors: failures)
    }

    private struct Collector {
        var files: [Candidate] = []
        var bytes: Int64 = 0
        var accessibleScopes = 0
        var failures = 0
        var truncated = false
    }

    private static func openScope(container: String, scope: String) -> Int32? {
        guard CacheTraversalProbe.validateAppRoot(container), roots.contains(scope) else { return nil }
        let rootFD = open(container, directoryFlags)
        guard rootFD >= 0 else { return nil }
        var current = rootFD
        for name in scope.split(separator: "/") {
            let next = String(name).withCString { openat(current, $0, directoryFlags) }
            if next < 0 {
                close(current)
                return nil
            }
            close(current)
            current = next
        }
        return current
    }

    private static func isRegularFile(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func collect(
        in descriptor: Int32, scope: String, components: [String],
        depth: Int, into collector: inout Collector
    ) {
        if depth >= maxDepth {
            collector.failures += 1
            return
        }
        let streamFD = dup(descriptor)
        guard streamFD >= 0 else {
            collector.failures += 1
            return
        }
        guard let stream = fdopendir(streamFD) else {
            close(streamFD)
            collector.failures += 1
            return
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            if collector.files.count >= maxFiles {
                collector.truncated = true
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.isEmpty { continue }
            var info = stat()
            let rc = name.withCString { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
            guard rc == 0 else {
                collector.failures += 1
                continue
            }
            if isRegularFile(info) {
                let size = max(Int64(info.st_size), 0)
                collector.files.append(Candidate(
                    scope: scope, components: components + [name], bytes: size,
                    inode: UInt64(info.st_ino),
                    modificationSeconds: Int(info.st_mtimespec.tv_sec),
                    modificationNanos: Int(info.st_mtimespec.tv_nsec)
                ))
                let (next, overflow) = collector.bytes.addingReportingOverflow(size)
                collector.bytes = overflow ? Int64.max : next
            } else if isDirectory(info) {
                let next = name.withCString { openat(descriptor, $0, directoryFlags) }
                guard next >= 0 else {
                    collector.failures += 1
                    continue
                }
                collect(in: next, scope: scope, components: components + [name],
                        depth: depth + 1, into: &collector)
                close(next)
                if collector.truncated { return }
            }
        }
    }
}
