import AirliftFFI
import Combine
import Foundation

/// Pairing and read-only service diagnostics. No cache deletion occurs here.
@MainActor
final class AirLiftCoordinator: ObservableObject {
    static let shared = AirLiftCoordinator()

    @Published private(set) var pairing = false
    @Published private(set) var checkingContainer = false
    @Published private(set) var pin: String?
    @Published private(set) var stage = "等待配对"
    @Published private(set) var diagnostic = "尚未验证设备服务连接"
    @Published private(set) var hasRecord = PairingRecordStore.activePath != nil

    private let audio = PairingBackgroundAudio()
    private var advertiser: NetService?
    private let identityKey = "cacheguard.airlift.hostAltIRK"

    private init() {}

    func refresh() {
        hasRecord = PairingRecordStore.activePath != nil
    }

    func importPairingFile(_ url: URL) {
        guard !pairing, !checkingContainer else { return }
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
        guard !pairing, !checkingContainer else { return }
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
        guard !pairing else { return }
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
        guard !checkingContainer, !pairing else { return }
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
                    self.diagnostic = "设备服务返回了 \(candidate) 的容器路径：\(path)。这只验证查询，未证明缓存可枚举或可删除。"
                } else {
                    self.diagnostic = "容器查询未成功：\(message)。请检查 VPN 地址、配对记录以及 App 是否已安装。"
                }
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
