import Foundation

/// Pairing records contain device trust secrets. Never put them in logs or iCloud.
enum PairingRecordStore {
    enum StoreError: LocalizedError {
        case unsupportedFile
        case invalidSize
        case invalidRecord

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: return "请选择 .plist、.mobiledevicepairing 或 .mobilepair 配对文件。"
            case .invalidSize: return "配对文件为空或超出 2 MB 安全上限。"
            case .invalidRecord: return "无法识别配对记录的格式。"
            }
        }
    }

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirLift", isDirectory: true)
            .appendingPathComponent("aircard_pairing.plist")
    }

    static var activePath: String? {
        if hasUsableFile { return url.path }
        if let saved = DevicePairingVault.read(),
           (try? validate(saved)) != nil,
           (try? save(saved, persistToKeychain: false)) != nil {
            return url.path
        }
        return nil
    }

    private static var hasUsableFile: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue >= 64
    }

    @discardableResult
    static func importRecord(from source: URL) throws -> String {
        let allowed = ["plist", "mobiledevicepairing", "mobilepair"]
        guard allowed.contains(source.pathExtension.lowercased()) else { throw StoreError.unsupportedFile }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        try validate(data)
        try save(data)
        return url.path
    }

    @discardableResult
    static func adoptGeneratedRecord(at sourcePath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        try validate(data)
        try save(data)
        return url.path
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        DevicePairingVault.remove()
    }

    private static func validate(_ data: Data) throws {
        guard (64...2_097_152).contains(data.count) else { throw StoreError.invalidSize }
        // AirLift supports several pairing file formats. Never reveal contents.
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           object is [String: Any] { return }
        if let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] { return }
        throw StoreError.invalidRecord
    }

    private static func save(_ data: Data, persistToKeychain: Bool = true) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folderValues = URLResourceValues()
        folderValues.isExcludedFromBackup = true
        var mutableFolder = folder
        try mutableFolder.setResourceValues(folderValues)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableFile = url
        try mutableFile.setResourceValues(fileValues)
        if persistToKeychain { _ = DevicePairingVault.save(data) }
    }
}
