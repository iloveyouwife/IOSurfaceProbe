import SwiftUI
import UniformTypeIdentifiers

struct AirLiftSetupView: View {
    @StateObject private var bridge = AirLiftCoordinator.shared
    @State private var importing = false
    @State private var forgetConfirmation = false
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
                Text("1. 开启“设置 → 隐私与安全性 → 开发者模式”。")
                Text("2. 点击下方按钮，首次弹窗请允许本地网络权限。")
                Text("3. 不要结束清存；切到开发者模式页面，找到“与 CacheGuard 配对”，按提示输入 PIN。")
                Text("4. 返回清存，确认出现“本机配对成功”。")
                Button {
                    bridge.startOnDevicePairing()
                } label: {
                    if bridge.pairing { ProgressView().padding(.trailing, 5) }
                    Text(bridge.pairing ? "等待系统设置确认…" : "启动本机配对")
                }
                .disabled(bridge.pairing || bridge.checkingContainer)
                Text("原生配对接口暂不支持安全取消；若长时间无响应，请关闭并重开 App。后台静音音频仅在等待配对时启用。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("备选 · 导入配对文件") {
                Text("如果设置里没有配对入口，可从电脑、SideStore、LiveContainer 等导出配对文件，然后在本机导入。")
                    .font(.footnote)
                Button("从文件 App 导入配对记录") { importing = true }
                    .disabled(bridge.pairing || bridge.checkingContainer)
                if bridge.hasRecord {
                    Button("忘记本地配对记录", role: .destructive) { forgetConfirmation = true }
                        .disabled(bridge.pairing || bridge.checkingContainer)
                }
                Text("配对记录包含设备信任凭据，仅保存在 App 私有目录、排除系统备份；请勿发送到聊天、网盘或公开仓库。")
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
                .disabled(!bridge.hasRecord || bridge.pairing || bridge.checkingContainer)
                Text(bridge.diagnostic)
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
