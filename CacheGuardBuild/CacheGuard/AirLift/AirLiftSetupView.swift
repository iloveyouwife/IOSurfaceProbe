import SwiftUI
import UniformTypeIdentifiers

struct AirLiftSetupView: View {
    @StateObject private var bridge = AirLiftCoordinator.shared
    @State private var importing = false
    @State private var forgetConfirmation = false
    @State private var repeatPairingConfirmation = false
    @State private var targetHost = AirLiftNetwork.targetHost
    @State private var networkError: String?
    @State private var bundleIdentifier = "com.tencent.xin"

    var body: some View {
        Form {
            Section("配对状态") {
                Label(
                    bridge.hasRecord ? "已保存本地配对记录" : "尚未保存配对记录",
                    systemImage: bridge.hasRecord ? "checkmark.shield.fill" : "lock.shield"
                )
                Text(bridge.stage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if bridge.hasRecord {
                    Label("下次启动可以直接连接，不需要重新配对", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let pin = bridge.pin {
                    HStack {
                        Text("系统设置中输入")
                        Spacer()
                        Text(pin)
                            .font(.title2.monospacedDigit().bold())
                            .textSelection(.enabled)
                    }
                }
            }

            Section("第一步 · 本机配对（iOS 27）") {
                if bridge.hasRecord && !bridge.pairing {
                    Label("已配对：跳过本步骤，直接连接 LocalDevVPN", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("仅在连接失效时重新配对") { repeatPairingConfirmation = true }
                        .disabled(bridge.checkingContainer || bridge.checkingCanary || bridge.checkingCacheTraversal)
                } else {
                    Text("1. 开启“设置 → 隐私与安全性 → 开发者模式”。")
                    Text("2. 首次点击配对按钮，并允许“本地网络”权限。")
                    Text("3. 切到开发者模式，选择“与 CacheGuard 配对”，输入 PIN。")
                    Text("4. 返回本 App，等到出现“本机配对成功”。")
                    Button {
                        bridge.startOnDevicePairing()
                    } label: {
                        if bridge.pairing { ProgressView().padding(.trailing, 5) }
                        Text(bridge.pairing ? "等待系统设置确认…" : "首次本机配对")
                    }
                    .disabled(bridge.pairing || bridge.checkingContainer || bridge.checkingCanary || bridge.checkingCacheTraversal)
                    Text("配对服务没有原生取消接口；卡住时可以关闭并重开 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("备选 · 导入配对文件") {
                Text("如果设置里没有配对入口，可从电脑、SideStore、LiveContainer 等导出配对文件，然后在本机导入。")
                    .font(.footnote)
                Button("从文件 App 导入配对记录") { importing = true }
                    .disabled(bridge.pairing || bridge.checkingContainer || bridge.checkingCanary)
                if bridge.hasRecord {
                    Button("忘记本地配对记录", role: .destructive) { forgetConfirmation = true }
                        .disabled(bridge.pairing || bridge.checkingContainer || bridge.checkingCanary)
                }
                Text("配对记录包含设备信任凭据，仅保存在 App 私有目录、排除系统备份；请勿发送到聊天、网盘或公开仓库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("会额外保存一份仅本设备可解锁的钥匙串备份。更换 Bundle ID、签名团队或清除系统配对关系后，可能仍需手动重新配对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("第二步 · VPN 与目标主机") {
                Text("启动 LocalDevVPN 的回环连接；默认设备地址为 10.7.0.1。连接也可能因 Wi-Fi 子网和路由设置失败。")
                    .font(.footnote)
                Text(AirLiftNetwork.networkSnapshot)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                TextField("LocalDevVPN 设备 IP", text: $targetHost)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存连接地址") {
                    saveTargetHost()
                }
                if let networkError {
                    Text(networkError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("第三步 · 只读容器查询") {
                Text("输入手机上已安装 App 的 Bundle ID；本步骤只查询其数据容器路径，不读取聊天记录，不写入或删除缓存。")
                    .font(.footnote)
                TextField("例如 com.tencent.xin", text: $bundleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    if saveTargetHost() {
                        bridge.inspectContainer(bundleID: bundleIdentifier)
                    }
                } label: {
                    if bridge.checkingContainer { ProgressView().padding(.trailing, 5) }
                    Text(bridge.checkingContainer ? "正在查询设备服务…" : "验证 App 容器查询")
                }
                .disabled(!bridge.hasRecord || bridge.pairing || bridge.checkingContainer || bridge.checkingCanary)
                Text(bridge.diagnostic)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section("第四步 · 安全读取通道测试") {
                Text("清存会在自己的临时目录创建一个随机测试文件，通过 AirLift 读取并比对，随后删除该测试文件。不会访问微信的配置、聊天或缓存内容。")
                    .font(.footnote)
                Button {
                    bridge.checkReadTransportWithOwnCanary()
                } label: {
                    if bridge.checkingCanary { ProgressView().padding(.trailing, 5) }
                    Text(bridge.checkingCanary ? "正在核对测试文件…" : "测试 AirLift 单文件读取")
                }
                .disabled(!bridge.hasRecord || bridge.pairing || bridge.checkingContainer || bridge.checkingCanary)
                Text(bridge.canaryDiagnostic)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section("第五步 · 3105 清理方式兼容性") {
                Text("只检测刚才查询到的 App 的 Library/Caches 和 tmp 两个目录能否通过本进程直接遍历。仅统计顶层项目数量，不读取内容，也不删除任何文件。")
                    .font(.footnote)
                Button {
                    bridge.inspectCacheDirectoryAccess()
                } label: {
                    if bridge.checkingCacheTraversal { ProgressView().padding(.trailing, 5) }
                    Text(bridge.checkingCacheTraversal ? "正在检测目录权限…" : "检测 3105 式缓存目录权限")
                }
                .disabled(bridge.inspectedContainerPath == nil || bridge.checkingCacheTraversal || bridge.checkingCanary || bridge.checkingContainer || bridge.pairing)
                Text(bridge.cacheTraversalDiagnostic)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section("缓存清理状态") {
                Label("跨 App 自动清理尚未启用", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("AirLift 能访问部分文件，不等于有稳定的“列目录 + 删除”接口。当前 FFI 提供配对、容器查询、读取指定文件、写入目录等接口；在验证精确删除语义和缓存白名单之前，不进行跨 App 删除。")
                    .font(.footnote)
                Text("在 iOS 27.0.1 上也需要真机验证：配对成功不代表漏洞利用一定成功。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AirLift 配对")
        .onAppear { bridge.refresh() }
        .sheet(isPresented: $importing) {
            PairingDocumentPicker { url in
                importing = false
                bridge.importPairingFile(url)
            }
        }
        .confirmationDialog("移除本机保存的配对记录？", isPresented: $forgetConfirmation) {
            Button("移除记录", role: .destructive) { bridge.forgetPairing() }
        } message: {
            Text("这不会取消系统设置内已有的配对关系，只会删除本 App 保存的信任记录。")
        }
        .confirmationDialog("确认重新配对？", isPresented: $repeatPairingConfirmation) {
            Button("重新配对") { bridge.startOnDevicePairing() }
        } message: {
            Text("仅当现有记录无法再连接时才需要。正常升级、重新打开 App 都应直接使用已保存的记录。")
        }
    }

    @discardableResult
    private func saveTargetHost() -> Bool {
        let entered = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AirLiftNetwork.isLocalIPv4(entered) else {
            networkError = "请输入局域网或 VPN 的 IPv4 地址，禁止公共网络地址。"
            return false
        }
        AirLiftNetwork.targetHost = entered
        networkError = nil
        return true
    }
}

/// UIKit's asCopy picker avoids depending on long-lived File Provider bookmarks.
private struct PairingDocumentPicker: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void
        init(onSelect: @escaping (URL) -> Void) { self.onSelect = onSelect }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let chosen = urls.first { onSelect(chosen) }
        }
    }
}
