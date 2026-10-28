import Foundation

enum CleanSource: String, CaseIterable, Identifiable, Hashable {
    case ownCaches
    case ownTemporary
    case chosenFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ownCaches: return "本应用缓存"
        case .ownTemporary: return "本应用临时文件"
        case .chosenFolder: return "手动授权的文件夹"
        }
    }

    var detail: String {
        switch self {
        case .ownCaches: return "仅扫描本工具自己的 Caches 目录"
        case .ownTemporary: return "仅扫描本工具自己的 tmp 目录"
        case .chosenFolder: return "仅列出其中可识别的缓存文件；可能包含离线资源"
        }
    }
}

struct ScanItem: Identifiable {
    let url: URL
    let bytes: Int64
    let modificationDate: Date?

    var id: String { url.path }
}

struct ScanBucket: Identifiable {
    let source: CleanSource
    let root: URL
    let items: [ScanItem]
    let truncated: Bool

    var id: String { source.id }
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var count: Int { items.count }
}

struct DeleteSummary {
    let deletedCount: Int
    let estimatedBytes: Int64
    let skippedCount: Int
    let failedCount: Int
}

enum CleanerFailure: LocalizedError {
    case missingDirectory
    case cannotEnumerate
    case invalidRoot

    var errorDescription: String? {
        switch self {
        case .missingDirectory: return "文件夹不存在或尚未选择。"
        case .cannotEnumerate: return "没有权限枚举此文件夹，请重新授权。"
        case .invalidRoot: return "文件夹路径无效。"
        }
    }
}

enum ByteText {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
