import Darwin
import Foundation

/// A read-only permission test for the two cache roots used by 3105. It does
/// not follow links or return filenames, inspect file contents, or delete data.
enum CacheTraversalProbe {
    struct Entry {
        let directory: String
        let count: Int?
        let errorCode: Int32?

        var summary: String {
            if let count { return "\(directory)：能读取目录（顶层 \(count) 项）" }
            if let errorCode {
                return "\(directory)：无法打开（errno=\(errorCode)）"
            }
            return "\(directory)：不可用"
        }
    }

    static let eligibleDirectories = ["Library/Caches", "tmp"]

    static func validateAppRoot(_ path: String) -> Bool {
        let prefix = "/var/mobile/Containers/Data/Application/"
        guard path.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(path.dropFirst(prefix.count))) != nil
    }

    static func inspect(containerPath: String) -> [Entry] {
        guard validateAppRoot(containerPath) else { return [] }
        return eligibleDirectories.map { relative in
            let path = containerPath + "/" + relative
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                return Entry(directory: relative, count: nil, errorCode: errno)
            }
            guard let stream = fdopendir(descriptor) else {
                let code = errno
                close(descriptor)
                return Entry(directory: relative, count: nil, errorCode: code)
            }
            defer { closedir(stream) }

            var count = 0
            while let item = readdir(stream), count < 10_000 {
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name != "." && name != ".." { count += 1 }
            }
            return Entry(directory: relative, count: count, errorCode: nil)
        }
    }
}
