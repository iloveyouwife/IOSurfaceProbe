import Foundation
import SwiftUI
import UIKit

@MainActor
final class CleanerViewModel: ObservableObject {
    @Published var chosenFolder: URL?
    @Published var buckets: [ScanBucket] = []
    @Published var selected: Set<CleanSource> = [.ownCaches, .ownTemporary]
    @Published var isBusy = false
    @Published var message: String?
    @Published var lastResult: DeleteSummary?

    var operatingSystem: String {
        "iOS " + UIDevice.current.systemVersion
    }

    var selectedBytes: Int64 {
        buckets
            .filter { selected.contains($0.source) && !$0.truncated }
            .reduce(0) { $0 + $1.bytes }
    }

    var canClean: Bool {
        !isBusy && buckets.contains {
            selected.contains($0.source) && !$0.truncated && $0.count > 0
        }
    }

    func selectFolder(_ url: URL) {
        chosenFolder = url
        selected.insert(.chosenFolder)
        buckets = []
        lastResult = nil
        message = "已选择文件夹。请开始扫描；不会自动删除任何文件。"
    }

    func toggle(_ source: CleanSource) {
        if selected.contains(source) {
            selected.remove(source)
        } else {
            selected.insert(source)
        }
    }

    func scan() {
        guard !isBusy else { return }
        isBusy = true
        lastResult = nil
        message = nil
        buckets = []
        let folder = chosenFolder

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [ScanBucket] = []
            var failures: [String] = []
            for source in CleanSource.allCases {
                if source == .chosenFolder && folder == nil { continue }
                do {
                    results.append(try LocalCleaner.scan(
                        source: source,
                        chosenFolder: folder
                    ))
                } catch {
                    failures.append("\(source.title)：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.buckets = results
                self.isBusy = false
                if !failures.isEmpty {
                    self.message = failures.joined(separator: "\n")
                }
            }
        }
    }

    func cleanSelected() {
        guard canClean else { return }
        isBusy = true
        message = nil
        let targets = buckets.filter {
            selected.contains($0.source) && !$0.truncated && $0.count > 0
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var deleted = 0
            var bytes: Int64 = 0
            var skipped = 0
            var failed = 0
            for bucket in targets {
                let result = LocalCleaner.delete(bucket)
                deleted += result.deletedCount
                bytes += result.estimatedBytes
                skipped += result.skippedCount
                failed += result.failedCount
            }
            DispatchQueue.main.async {
                self.lastResult = DeleteSummary(
                    deletedCount: deleted,
                    estimatedBytes: bytes,
                    skippedCount: skipped,
                    failedCount: failed
                )
                self.isBusy = false
                self.buckets = []
                self.message = "操作结束，请重新扫描确认剩余文件。"
            }
        }
    }
}
