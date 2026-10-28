import AirliftFFI
import Combine
import Foundation

/// Pairing and read-only service diagnostics. No cache deletion occurs here.
@MainActor
final class AirLiftCoordinator: ObservableObject {
    static let shared = AirLiftCoordinator()

    @Published private(set) var pairing = false
    @Published private(set) var checkingContainer = false
    @Published private(set) var checkingCanary = false
    @Published private(set) var checkingCacheTraversal = false
    @Published private(set) var scanningForeignCache = false
    @Published private(set) var deletingForeignCache = false
    @Published private(set) var checkingRemoteAfc = false
    @Published private(set) var pin: String?
    @Published private(set) var stage = "等待配对"
    @Published private(set) var diagnostic = "尚未验证设备服务连接"
    @Published private(set) var canaryDiagnostic = "尚未验证 AirLift 单文件读取通道"
    @Published private(set) var cacheTraversalDiagnostic = "尚未检测其他 App 的缓存目录权限"
    @Published private(set) var foreignCacheDiagnostic = "尚未扫描目标 App 的缓存"
    @Published private(set) var remoteAfcDiagnostic = "尚未检查 HouseArrest 远程 AFC 的容器访问权限"
    @Published private(set) var foreignCacheScan: ForeignCacheCleaner.Snapshot?
    @Published private(set) var hasRecord = PairingRecordStore.activePath != nil
    @Published private(set) var inspectedContainerPath: String?
    @Published private(set) var inspectedBundleIdentifier: String?

    private let audio = PairingBackgroundAudio()
    private var advertiser: NetService?
    private let identityKey = "cacheguard.airlift.hostAltIRK"

    private init() {
        if hasRecord { stage = "已恢复本机配对记录；开启 LocalDevVPN 后可直接尝试连接，无需重输 PIN。" }
    }

    func refresh() {
        hasRecord = PairingRecordStore.activePath != nil
        if hasRecord && !pairing {
            stage = "已保存配对记录：无需重复 PIN。打开 LocalDevVPN 直接进行容器查询；连接是否有效仍以实际测试为准。"
        }
    }

    func importPairingFile(_ url: URL) {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache else { return }
        inspectedContainerPath = nil
        inspectedBundleIdentifier = nil
        foreignCacheScan = nil
        do {
            _ = try PairingRecordStore.importRecord(from: url)
            stage = "配对文件已导入；尚未验证跨沙盒权限"
            diagnostic = "尚未验证设备服务连接"
        } catch {
            stage = "导入失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func forgetPairing() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache else { return }
        inspectedContainerPath = nil
        inspectedBundleIdentifier = nil
        foreignCacheScan = nil
        do {
            try PairingRecordStore.remove()
            stage = "本地配对记录已移除"
            diagnostic = "尚未验证设备服务连接"
        } catch {
            stage = "移除失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func startOnDevicePairing() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            stage = "系统设置内配对要求 iOS 27 或更高版本；可导入电脑生成的配对文件。"
            return
        }
        let file = PairingRecordStore.url
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            stage = "无法创建私有存储目录：\(error.localizedDescription)"
            return
        }

        pairing = true
        pin = nil
        stage = "正在启动本机配对服务…首次运行请允许“本地网络”访问。"
        audio.start()

        let previouslyIssuedIRK = UserDefaults.standard.string(forKey: identityKey) ?? ""
        let retained = Unmanaged.passRetained(self).toOpaque()
        let outputPath = file.path

        // Native FFI blocks until completion. It has no cancellation endpoint.
        DispatchQueue.global(qos: .userInitiated).async {
            var response = ALPairResult()
            let code = "0.0.0.0".withCString { address in
                "CacheGuard".withCString { name in
                    "Mac17,7".withCString { model in
                        outputPath.withCString { output in
                            previouslyIssuedIRK.withCString { irk in
                                al_pairing_run_host(
                                    address, 0, name, model, output, irk,
                                    cacheGuardReadyCallback, cacheGuardPinCallback,
                                    retained, &response
                                )
                            }
                        }
                    }
                }
            }
            let newIdentity = response.host_alt_irk_hex.map { String(cString: $0) } ?? ""
            let errorMessage = response.error.map { String(cString: $0) } ?? "配对失败（错误码 \(code)）"
            let generatedFile = response.pairing_file_path.map { String(cString: $0) } ?? outputPath
            al_pairing_result_free(&response)

            DispatchQueue.main.async {
                let coordinator = Unmanaged<AirLiftCoordinator>.fromOpaque(retained).takeRetainedValue()
                coordinator.finishPairing(
                    success: code == 0,
                    generatedFile: generatedFile,
                    newIdentity: newIdentity,
                    nativeError: errorMessage
                )
            }
        }
    }

    fileprivate func publish(serviceID: String, port: Int32, record: [String: Data]) {
        guard pairing else { return }
        advertiser?.stop()
        let next = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        next.setTXTRecord(NetService.data(fromTXTRecord: record))
        next.publish()
        advertiser = next
        stage = "配对广播已启动：打开 设置 → 隐私与安全性 → 开发者模式 → 与 CacheGuard 配对"
    }

    fileprivate func showPIN(_ value: String) {
        guard pairing else { return }
        pin = value
        stage = "请在系统设置的配对窗口输入下方 PIN。"
    }

    private func finishPairing(
        success: Bool, generatedFile: String, newIdentity: String, nativeError: String
    ) {
        advertiser?.stop()
        advertiser = nil
        pairing = false
        pin = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.audio.stop()
        }
        guard success else {
            stage = "配对失败：\(nativeError)"
            return
        }
        do {
            _ = try PairingRecordStore.adoptGeneratedRecord(at: generatedFile)
            if !newIdentity.isEmpty { UserDefaults.standard.set(newIdentity, forKey: identityKey) }
            stage = "本机配对成功；下一步启动 LocalDevVPN，再验证设备服务。"
            diagnostic = "尚未验证设备服务连接"
            refresh()
        } catch {
            stage = "配对返回成功，但保存记录失败：\(error.localizedDescription)"
        }
    }

    func inspectContainer(bundleID: String) {
        guard !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache, !checkingRemoteAfc,
              !pairing else { return }
        inspectedContainerPath = nil
        inspectedBundleIdentifier = nil
        foreignCacheScan = nil
        foreignCacheDiagnostic = "尚未扫描目标 App 的缓存"
        remoteAfcDiagnostic = "尚未检查 HouseArrest 远程 AFC 的容器访问权限"
        cacheTraversalDiagnostic = "尚未检测其他 App 的缓存目录权限"
        guard let record = PairingRecordStore.activePath else {
            diagnostic = "请先完成配对或导入配对文件。"
            return
        }
        let candidate = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard candidate.count >= 5, candidate.count <= 180,
              candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              candidate.contains(".") else {
            diagnostic = "请输入合法的 App Bundle ID，如 com.tencent.xin。"
            return
        }
        guard AirLiftNetwork.configureTarget() else {
            diagnostic = "LocalDevVPN 地址必须是合法的本地 IPv4 地址。"
            return
        }
        checkingContainer = true
        diagnostic = "正在通过 AirLift 查询 App 容器路径…"

        DispatchQueue.global(qos: .userInitiated).async {
            var found: UnsafeMutablePointer<CChar>?
            var failure: UnsafeMutablePointer<CChar>?
            let rc = record.withCString { pairingC in
                candidate.withCString { bundleC in
                    al_find_app_container(pairingC, bundleC, nil, nil, &found, &failure)
                }
            }
            let path = found.map { String(cString: $0) }
            let message = failure.map { String(cString: $0) } ?? "未返回错误详情"
            if let found { al_string_free(found) }
            if let failure { al_string_free(failure) }
            DispatchQueue.main.async {
                self.checkingContainer = false
                if rc == 0, let path, !path.isEmpty {
                    self.inspectedContainerPath = path
                    self.inspectedBundleIdentifier = candidate
                    self.diagnostic = "设备服务返回了 \(candidate) 的容器路径：\(path)。这只验证查询，未证明缓存可枚举或可删除。"
                } else {
                    self.diagnostic = "容器查询未成功：\(message)。请检查 VPN 地址、配对记录以及 App 是否已安装。"
                }
            }
        }
    }

    /// Probe only a random, self-owned temporary file. No third-party app data
    /// is opened and no system file is modified. Result verifies transport,
    /// not third-party cache or directory access.
    func checkReadTransportWithOwnCanary() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache else { return }
        guard let pairingPath = PairingRecordStore.activePath else {
            canaryDiagnostic = "请先完成配对。"
            return
        }
        guard AirLiftNetwork.configureTarget() else {
            canaryDiagnostic = "请设置有效的 LocalDevVPN 地址。"
            return
        }

        let probeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cacheguard-airlift-\(UUID().uuidString).txt")
        let marker = Data("CacheGuard controlled read probe \(UUID().uuidString)".utf8)
        do {
            try marker.write(to: probeFile, options: [.atomic])
        } catch {
            canaryDiagnostic = "无法准备测试文件：\(error.localizedDescription)"
            return
        }

        checkingCanary = true
        canaryDiagnostic = "正在通过 AirLift 读取清存自己创建的临时测试文件…"
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: probeFile) }
            var outData: UnsafeMutablePointer<UInt8>?
            var outLength: Int = 0
            var outError: UnsafeMutablePointer<CChar>?

            let rc = pairingPath.withCString { pairingC in
                probeFile.path.withCString { fileC in
                    al_exploit_read_file(pairingC, fileC, nil, nil, &outData, &outLength, &outError)
                }
            }
            let verified: Bool
            if rc == 0, let outData, outLength == marker.count {
                verified = Data(bytes: outData, count: outLength) == marker
            } else {
                verified = false
            }
            let errorText = outError.map { String(cString: $0) } ?? "未返回错误信息"
            if let outData { al_bytes_free(outData, outLength) }
            if let outError { al_string_free(outError) }

            DispatchQueue.main.async {
                self.checkingCanary = false
                self.canaryDiagnostic = verified
                    ? "测试通过：AirLift 返回的内容与本 App 临时文件完全一致（\(marker.count) 字节）。不代表微信缓存已可读或可删除。"
                    : "测试未通过：\(String(errorText.prefix(250)))。请检查配对文件与 VPN；这不等于跨 App 访问一定失败。"
            }
        }
    }

    /// Checks whether the 3105 direct-POSIX cleaner is even possible with the
    /// active process sandbox. No deletion, writes or file content reads.
    func inspectCacheDirectoryAccess() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache,
              let container = inspectedContainerPath,
              CacheTraversalProbe.validateAppRoot(container) else {
            cacheTraversalDiagnostic = "先成功查询目标 App 的数据容器。"
            return
        }
        checkingCacheTraversal = true
        cacheTraversalDiagnostic = "只读检测 Library/Caches 和 tmp 的目录遍历权限…"

        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = CacheTraversalProbe.inspect(containerPath: container)
            let summary = outcomes.map(\.summary).joined(separator: "\n")
            let atLeastOneAllowed = outcomes.contains { $0.count != nil }
            DispatchQueue.main.async {
                self.checkingCacheTraversal = false
                self.cacheTraversalDiagnostic = summary + "\n" + (
                    atLeastOneAllowed
                    ? "存在可读取的缓存目录；后续才可测试 3105 式受控扫描，当前不会删除。"
                    : "当前进程无法直接遍历这些目录；需要研究 AirLift 远程 AFC/HouseArrest 后端，不能直接复制 unlinkat 删除。"
                )
            }
        }
    }

    /// Preview only, restricted to Library/Caches and tmp. Can run even when
    /// the earlier fast probe fails so the user gets a concrete access error.
    func previewForeignCache() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache,
              let container = inspectedContainerPath,
              CacheTraversalProbe.validateAppRoot(container) else {
            foreignCacheDiagnostic = "先通过设备服务查询目标 App 的真实容器。"
            return
        }
        foreignCacheScan = nil
        scanningForeignCache = true
        foreignCacheDiagnostic = "正在只读统计 Library/Caches 和 tmp 内的普通文件…"
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = ForeignCacheCleaner.preview(container: container)
            DispatchQueue.main.async {
                self.scanningForeignCache = false
                guard self.inspectedContainerPath == container else { return }
                self.foreignCacheScan = snapshot
                self.foreignCacheDiagnostic = snapshot.summary
                    + (snapshot.accessibleScopes == 0
                       ? "。本进程没有目录遍历权限，不能使用 3105 的直接删除方式。"
                       : "。预览不修改任何文件；只有手动再次确认才会开始删除。")
            }
        }
    }

    /// Called only from the user-visible destructive confirmation dialog.
    func deletePreviewedForeignCache() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache,
              let snapshot = foreignCacheScan,
              let container = inspectedContainerPath,
              snapshot.container == container,
              !snapshot.truncated, !snapshot.files.isEmpty else { return }
        deletingForeignCache = true
        foreignCacheDiagnostic = "正在删除预览且未发生变化的缓存普通文件，不删除目录、符号链接或其他 App 数据…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ForeignCacheCleaner.delete(snapshot)
            DispatchQueue.main.async {
                self.deletingForeignCache = false
                self.foreignCacheScan = nil
                self.foreignCacheDiagnostic = result.summary
            }
        }
    }

    /// Remote, read-only HouseArrest/AFC permission probe. This is deliberately
    /// separate from the AirTraffic file-copy exploit and from direct POSIX IO.
    func inspectRemoteAfcContainer() {
        guard !pairing, !checkingContainer, !checkingCanary, !checkingCacheTraversal,
              !scanningForeignCache, !deletingForeignCache, !checkingRemoteAfc,
              let bundleID = inspectedBundleIdentifier,
              let record = PairingRecordStore.activePath else {
            remoteAfcDiagnostic = "先通过设备服务查询目标 App 的容器路径。"
            return
        }
        guard AirLiftNetwork.configureTarget() else {
            remoteAfcDiagnostic = "请配置合法的 LocalDevVPN 设备 IP。"
            return
        }
        let host = AirLiftNetwork.targetHost
        checkingRemoteAfc = true
        remoteAfcDiagnostic = "正在通过 RSD → HouseArrest → AFC 只读检查目标 App 的缓存目录…"
        DispatchQueue.global(qos: .userInitiated).async {
            var output = [CChar](repeating: 0, count: 2048)
            let code = output.withUnsafeMutableBufferPointer { destination in
                host.withCString { address in
                    record.withCString { pairingPath in
                        bundleID.withCString { bundle in
                            cg_probe_house_arrest(
                                address, pairingPath, bundle,
                                destination.baseAddress, destination.count
                            )
                        }
                    }
                }
            }
            let detail = output.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            DispatchQueue.main.async {
                self.checkingRemoteAfc = false
                self.remoteAfcDiagnostic = "远程 AFC 检查返回 \(code)：\(detail)"
                    + (code == 0
                       ? "\n至少一个远程目录可列举。后续还必须单独验证写权限与精确删除行为；本次未删除。"
                       : "\n这条服务路线当前未获得目标缓存目录权限；不会退回已失败的直接 POSIX 删除。")
            }
        }
    }
}

private let cacheGuardReadyCallback: ALPairReadyCb = { context, serviceID, port, keys, values, count in
    guard let context, let serviceID else { return }
    let coordinator = Unmanaged<AirLiftCoordinator>.fromOpaque(context).takeUnretainedValue()
    var record: [String: Data] = [:]
    if let keys, let values {
        for index in 0..<Int(count) {
            if let key = keys[index], let value = values[index] {
                record[String(cString: key)] = Data(String(cString: value).utf8)
            }
        }
    }
    let id = String(cString: serviceID)
    DispatchQueue.main.async { coordinator.publish(serviceID: id, port: Int32(port), record: record) }
}

private let cacheGuardPinCallback: ALPairPinCb = { value, context in
    guard let value, let context else { return }
    let coordinator = Unmanaged<AirLiftCoordinator>.fromOpaque(context).takeUnretainedValue()
    let text = String(cString: value)
    DispatchQueue.main.async { coordinator.showPIN(text) }
}
