import Foundation

/// Baseline implementation using only public iOS APIs.
/// There is deliberately NO third-party app container or system data access.
enum LocalCleaner {
    private static let manager = FileManager.default

    static func root(for source: CleanSource, chosenFolder: URL?) throws -> URL {
        switch source {
        case .ownCaches:
            guard let url = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw CleanerFailure.missingDirectory
            }
            return url
        case .ownTemporary:
            return manager.temporaryDirectory
        case .chosenFolder:
            guard let chosenFolder else { throw CleanerFailure.missingDirectory }
            return chosenFolder
        }
    }

    static func scan(source: CleanSource, chosenFolder: URL?) throws -> ScanBucket {
        let root = try root(for: source, chosenFolder: chosenFolder)
        guard root.isFileURL else { throw CleanerFailure.invalidRoot }
        let scoped = source == .chosenFolder && root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var sawEnumerationError = false
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                sawEnumerationError = true
                return true
            }
        ) else {
            throw CleanerFailure.cannotEnumerate
        }

        var items: [ScanItem] = []
        var truncated = false
        for case let url as URL in enumerator {
            if items.count >= CachePolicy.maxItemsPerScope {
                truncated = true
                break
            }
            guard CachePolicy.isEligible(url, root: root, source: source) else { continue }
            guard let info = try? url.resourceValues(forKeys: Set(keys)),
                  info.isSymbolicLink != true,
                  info.isRegularFile == true else { continue }
            let bytes = Int64(max(0, info.totalFileAllocatedSize ?? info.fileSize ?? 0))
            items.append(ScanItem(
                url: url,
                bytes: bytes,
                modificationDate: info.contentModificationDate
            ))
        }
        return ScanBucket(
            source: source,
            root: root,
            items: items,
            truncated: truncated || sawEnumerationError
        )
    }

    static func delete(_ bucket: ScanBucket) -> DeleteSummary {
        // If scanning was incomplete, do not offer a misleading "clean everything" operation.
        guard !bucket.truncated else {
            return DeleteSummary(
                deletedCount: 0, estimatedBytes: 0,
                skippedCount: bucket.count, failedCount: 0
            )
        }

        let root = bucket.root
        let scoped = bucket.source == .chosenFolder && root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        var deleted = 0
        var deletedBytes: Int64 = 0
        var skipped = 0
        var failed = 0

        for item in bucket.items {
            guard CachePolicy.isEligible(item.url, root: root, source: bucket.source),
                  let info = try? item.url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
                  ]),
                  info.isRegularFile == true,
                  info.isSymbolicLink != true else {
                skipped += 1
                continue
            }

            let currentBytes = Int64(max(0, info.totalFileAllocatedSize ?? info.fileSize ?? 0))
            // Avoid removing files that changed between preview and confirmation.
            guard currentBytes == item.bytes,
                  info.contentModificationDate == item.modificationDate else {
                skipped += 1
                continue
            }

            var operationError: Error?
            if bucket.source == .chosenFolder {
                var coordinationError: NSError?
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(
                    writingItemAt: item.url,
                    options: .forDeleting,
                    error: &coordinationError
                ) { coordinatedURL in
                    do { try manager.removeItem(at: coordinatedURL) }
                    catch { operationError = error }
                }
                if let coordinationError { operationError = coordinationError }
            } else {
                do { try manager.removeItem(at: item.url) }
                catch { operationError = error }
            }

            if operationError == nil {
                deleted += 1
                deletedBytes += currentBytes
            } else {
                failed += 1
            }
        }

        return DeleteSummary(
            deletedCount: deleted,
            estimatedBytes: deletedBytes,
            skippedCount: skipped,
            failedCount: failed
        )
    }
}
